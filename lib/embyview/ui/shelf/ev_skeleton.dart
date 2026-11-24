import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/shelf/ev_card.dart';
import 'package:moonfin/embyview/ui/shelf/ev_shelf.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Animated shimmer box mirroring `.skel` in `.spec/mockups/proto.css`.
class _EvShimmerBox extends StatefulWidget {
  const _EvShimmerBox({required this.borderRadius, this.width, this.height, this.aspectRatio});

  final BorderRadius borderRadius;
  final double? width, height, aspectRatio;

  @override
  State<_EvShimmerBox> createState() => _EvShimmerBoxState();
}

class _EvShimmerBoxState extends State<_EvShimmerBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final base = theme.fill2;
    final hi = theme.isPaper ? const Color.fromRGBO(255, 255, 255, 0.55) : theme.fill3;

    Widget box = ClipRRect(
      borderRadius: widget.borderRadius,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) {
          final dx = -1.0 + 2.0 * _controller.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: base,
              gradient: LinearGradient(
                begin: Alignment(dx - 0.8, 0),
                end: Alignment(dx + 0.8, 0),
                colors: [base, Color.alphaBlend(hi, base), base],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          );
        },
      ),
    );
    if (widget.aspectRatio != null) box = AspectRatio(aspectRatio: widget.aspectRatio!, child: box);
    if (widget.width != null || widget.height != null) {
      box = SizedBox(width: widget.width, height: widget.height, child: box);
    }
    return box;
  }
}

/// Loading placeholder matching [EvCard] geometry for [style].
class EvCardSkeleton extends StatelessWidget {
  const EvCardSkeleton({super.key, this.style = EvCardStyle.poster, this.width, this.showLabel = false});

  final EvCardStyle style;
  final double? width;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final isLandscape = style == EvCardStyle.landscape;
    final radius = BorderRadius.circular(scale.rem(isLandscape ? theme.radius : theme.posterRadius));

    Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (style == EvCardStyle.collection) SizedBox(height: scale.rem(0.625)),
        _EvShimmerBox(aspectRatio: EvCard.aspectRatioFor(style), borderRadius: radius),
        if (showLabel) ...[
          SizedBox(height: scale.rem(0.875)),
          _EvShimmerBox(
            width: width != null ? width! * 0.72 : scale.rem(8.0),
            height: scale.rem(0.875),
            borderRadius: BorderRadius.circular(scale.rem(0.4375)),
          ),
        ],
      ],
    );
    return width != null ? SizedBox(width: width, child: body) : body;
  }
}

/// Loading placeholder matching [EvShelf] header and `N + 0.25` card track.
class EvShelfSkeleton extends StatelessWidget {
  const EvShelfSkeleton({super.key, this.style = EvCardStyle.poster, this.count = 6, this.title, this.baseRem});

  final EvCardStyle style;
  final int count;
  final String? title;
  final double? baseRem;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final gutter = scale.gutter, gap = EvShelfLayout.gap(scale);

    return Padding(
      padding: EdgeInsets.only(bottom: scale.rem(1.75)),
      child: LayoutBuilder(
        builder: (_, constraints) {
          final vw = constraints.hasBoundedWidth && constraints.maxWidth > 0
              ? constraints.maxWidth
              : scale.size.width;
          final cardW = EvShelfLayout.cardWidth(viewportWidth: vw, scale: scale, style: style, baseRem: baseRem);

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 0, gutter, scale.rem(0.25)),
                child: title != null
                    ? Text(title!, style: theme.shelfStyle(scale.font(1.5)))
                    : _EvShimmerBox(
                        width: scale.rem(9.0),
                        height: scale.rem(1.125),
                        borderRadius: BorderRadius.circular(scale.rem(0.4375)),
                      ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(gutter, scale.rem(1.0), gutter, scale.rem(1.25)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < count; i++) ...[
                      if (i > 0) SizedBox(width: gap),
                      EvCardSkeleton(style: style, width: cardW, showLabel: style == EvCardStyle.landscape),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
