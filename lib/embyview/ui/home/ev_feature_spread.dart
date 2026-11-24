import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Editorial feature spread (`.feature`) pairing a left callout panel (with a
/// hand-drawn doodle icon in paper theme) and a right tilted multi-column
/// counter-scrolling portrait poster wall that pauses when scrolled off-screen.
class EvFeatureSpread extends StatefulWidget {
  const EvFeatureSpread({
    super.key,
    required this.spread,
    required this.title,
    required this.accentColor,
    required this.doodleIcon,
    this.onTap,
    this.enableAnimations = true,
  });

  final FeatureSpread spread;
  final String title;
  final Color accentColor;
  final EvIconData doodleIcon;
  final VoidCallback? onTap;
  final bool enableAnimations;

  /// Extracts portrait-only poster [ArtworkRef]s, filtering out square/landscape
  /// primary images and text-overlay backdrop fallbacks.
  static List<ArtworkRef> filterPortraitPosters(List<MediaCard> cards) {
    final result = <ArtworkRef>[];
    for (final card in cards) {
      final layer = card.art.poster.layers.firstOrNull;
      if (layer == null || layer.text != null) continue;
      final ref = layer.source;
      final ratio = ref.aspectRatio ??
          (ref.width != null && ref.height != null && ref.height! > 0 ? ref.width! / ref.height! : null);
      if (ratio != null && (ratio <= 0 || ratio >= 1.0)) continue;
      result.add(ref);
    }
    return result;
  }

  @override
  State<EvFeatureSpread> createState() => EvFeatureSpreadState();
}

class EvFeatureSpreadState extends State<EvFeatureSpread> with TickerProviderStateMixin {
  static const int _columnCount = 6;
  static const int _postersPerColumn = 4;

  late final AnimationController _upController;
  late final AnimationController _downController;
  ScrollPosition? _scrollPosition;
  List<ArtworkRef> _portraitPosters = const [];
  bool _hovered = false, _focused = false, _inViewport = false, _disableAnimations = false;

  bool get isWallAnimating => _upController.isAnimating || _downController.isAnimating;
  List<ArtworkRef> get portraitPosters => _portraitPosters;
  bool get _highlighted => _hovered || _focused;

  @override
  void initState() {
    super.initState();
    _upController = AnimationController(vsync: this, duration: const Duration(seconds: 60));
    _downController = AnimationController(vsync: this, duration: const Duration(seconds: 72));
    _portraitPosters = EvFeatureSpread.filterPortraitPosters(widget.spread.posters);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisibility());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final nextPos = Scrollable.maybeOf(context)?.position;
    if (!identical(_scrollPosition, nextPos)) {
      _scrollPosition?.removeListener(_checkVisibility);
      _scrollPosition = nextPos;
      _scrollPosition?.addListener(_checkVisibility);
    }
    _syncAnimationState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisibility());
  }

  @override
  void didUpdateWidget(EvFeatureSpread oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.spread.posters, widget.spread.posters)) {
      _portraitPosters = EvFeatureSpread.filterPortraitPosters(widget.spread.posters);
    }
    _syncAnimationState();
  }

  void _checkVisibility() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final vp = Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    final bool visible;
    if (vp != null && vp.hasSize && vp.attached) {
      final tl = box.localToGlobal(Offset.zero, ancestor: vp);
      final br = box.localToGlobal(Offset(box.size.width, box.size.height), ancestor: vp);
      visible = br.dy > 0 && tl.dy < vp.size.height && br.dx > 0 && tl.dx < vp.size.width;
    } else {
      final tl = box.localToGlobal(Offset.zero);
      final br = box.localToGlobal(Offset(box.size.width, box.size.height));
      visible = br.dy > 0 && tl.dy < MediaQuery.sizeOf(context).height;
    }
    _inViewport = visible;
    _syncAnimationState();
  }

  void _syncAnimationState() {
    final shouldRun = widget.enableAnimations && !_disableAnimations && _inViewport && _portraitPosters.isNotEmpty;
    if (shouldRun) {
      if (!_upController.isAnimating) _upController.repeat();
      if (!_downController.isAnimating) _downController.repeat();
    } else {
      if (_upController.isAnimating) _upController.stop(canceled: false);
      if (_downController.isAnimating) _downController.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_checkVisibility);
    _upController.dispose();
    _downController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), isPaper = theme.isPaper;
    final height = scale.vh(40).clamp(scale.rem(18.0), scale.rem(25.0));
    final radius = BorderRadius.circular(scale.rem(1.25));
    final decoration = isPaper
        ? BoxDecoration(
            color: theme.fill2, borderRadius: radius,
            border: _highlighted ? Border.all(color: const Color(0xFF141413), width: 1.5) : null,
            boxShadow: _highlighted ? [BoxShadow(offset: Offset(scale.rem(0.5), scale.rem(0.5)), color: widget.accentColor)] : null,
          )
        : BoxDecoration(
            color: const Color(0xFF141418), borderRadius: radius,
            gradient: LinearGradient(
              begin: const Alignment(-1.0, -0.35), end: const Alignment(1.0, 0.35), stops: const [0.0, 0.55],
              colors: [widget.accentColor.withValues(alpha: 0.26), widget.accentColor.withValues(alpha: 0.05)],
            ),
            border: Border.all(color: _highlighted ? theme.fill3 : theme.line),
            boxShadow: _highlighted ? theme.cardShadowHi : null,
          );

    return Padding(
      padding: EdgeInsets.fromLTRB(scale.gutter, scale.rem(1.0), scale.gutter, scale.rem(2.75)),
      child: Semantics(
        button: true,
        label: '${widget.title.replaceAll('\n', '')}，看看这 ${widget.spread.total} 部',
        child: Focus(
          onFocusChange: (v) => setState(() => _focused = v),
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent &&
                (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter || e.logicalKey == LogicalKeyboardKey.space)) {
              widget.onTap?.call();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: MouseRegion(
            cursor: widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              key: Key('ev_feature_${widget.spread.feature.name}'),
              behavior: HitTestBehavior.opaque, onTap: widget.onTap,
              child: TweenAnimationBuilder<Offset>(
                tween: Tween<Offset>(end: isPaper && _highlighted ? Offset(-scale.rem(0.25), -scale.rem(0.25)) : Offset.zero),
                duration: EvDurations.slow, curve: EvCurves.spring,
                builder: (_, off, child) => AnimatedScale(
                  scale: !isPaper && _highlighted ? 1.006 : 1.0, duration: EvDurations.slow, curve: EvCurves.spring,
                  child: Transform.translate(offset: off, child: child),
                ),
                child: AnimatedContainer(
                  duration: EvDurations.medium, curve: EvCurves.soft, height: height, decoration: decoration,
                  child: ClipRRect(
                    borderRadius: radius,
                    child: LayoutBuilder(
                      builder: (_, c) => Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_portraitPosters.isNotEmpty)
                            Positioned(right: 0, top: 0, bottom: 0, width: c.maxWidth * 0.66, child: IgnorePointer(child: _buildPosterWall(theme, scale, c.maxWidth * 0.66))),
                          Positioned(left: 0, top: 0, bottom: 0, width: c.maxWidth * 0.40, child: _buildCallout(theme, scale)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCallout(EvTheme theme, EvScale scale) {
    final isPaper = theme.isPaper;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: scale.rem(2.5), vertical: scale.rem(2.25)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isPaper ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          if (isPaper) ...[
            EvIcon(widget.doodleIcon, key: Key('ev_feature_doodle_${widget.spread.feature.name}'), size: scale.rem(4.25), color: const Color(0xFF141413), forcePaper: true),
            const Spacer(),
          ],
          Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.displayStyle(scale.font(isPaper ? 2.5 : 2.375), color: theme.ink, height: 1.15)),
          SizedBox(height: scale.rem(1.25)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('看看这 ${widget.spread.total} 部', style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w600, color: theme.ink)),
              SizedBox(width: scale.rem(0.375)),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: _highlighted ? scale.rem(0.25) : 0.0),
                duration: EvDurations.normal, curve: EvCurves.spring,
                builder: (_, dx, child) => Transform.translate(offset: Offset(dx, 0), child: child),
                child: EvIcon(EvIcons.right, size: scale.rem(0.875), color: theme.ink),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPosterWall(EvTheme theme, EvScale scale, double wallW) {
    final posters = _portraitPosters, gap = scale.rem(0.75), planeW = wallW * 1.14;
    final colW = math.max(48.0, (planeW - gap * (_columnCount - 1)) / _columnCount);
    final posterH = colW * 1.5, halfCycleH = _postersPerColumn * (posterH + gap);
    final r = BorderRadius.circular(scale.rem(theme.isPaper ? 0.375 : 0.5));
    final shadow = theme.isPaper
        ? [BoxShadow(offset: Offset(scale.rem(0.25), scale.rem(0.25)), color: const Color.fromRGBO(20, 20, 19, 0.12))]
        : [BoxShadow(offset: Offset(0, scale.rem(0.75)), blurRadius: scale.rem(1.75), color: const Color.fromRGBO(0, 0, 0, 0.45))];

    return ShaderMask(
      shaderCallback: (rect) => LinearGradient(
        stops: [0.0, theme.isPaper ? 0.24 : 0.28],
        colors: const [Color(0x00000000), Color(0xFF000000)],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ClipRect(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _highlighted ? 1.0 : 0.0),
          duration: EvDurations.ambient, curve: EvCurves.out,
          builder: (_, t, child) {
            final s = 1.0 + 0.04 * t;
            final m = Matrix4.identity()
              ..setEntry(3, 2, 0.0009)
              ..rotateX((16.0 - 6.0 * t) * math.pi / 180.0)
              ..rotateY((-20.0 + 7.0 * t) * math.pi / 180.0)
              ..rotateZ((10.0 - 3.0 * t) * math.pi / 180.0)
              ..scaleByDouble(s, s, 1.0, 1.0);
            return OverflowBox(
              minWidth: planeW, maxWidth: planeW, minHeight: halfCycleH * 2, maxHeight: halfCycleH * 2,
              child: Transform(alignment: Alignment.center, transform: m, child: child),
            );
          },
          child: Row(
            key: Key('ev_feature_wall_${widget.spread.feature.name}'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var ci = 0; ci < _columnCount; ci++) ...[
                if (ci > 0) SizedBox(width: gap),
                _buildColumn(ci, colW, posterH, gap, halfCycleH, posters, r, shadow, theme.cardBg),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColumn(
    int ci, double colW, double posterH, double gap, double halfCycleH,
    List<ArtworkRef> posters, BorderRadius r, List<BoxShadow> shadow, Color cardBg,
  ) {
    final downward = ci.isOdd, ctrl = downward ? _downController : _upController;
    final base = [for (var j = 0; j < _postersPerColumn; j++) posters[(ci * 3 + j + (posters.length > 12 ? ci * 6 : 0)) % posters.length]];
    final doubled = [...base, ...base];
    final col = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < doubled.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          Container(
            width: colW, height: posterH, clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: r, boxShadow: shadow, color: cardBg),
            child: Image(
              key: ValueKey<String>('ev_fp_${ci}_${i}_${doubled[i].cacheKey}'),
              image: doubled[i].image, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) => ColoredBox(color: cardBg),
            ),
          ),
        ],
      ],
    );
    return SizedBox(
      width: colW,
      child: AnimatedBuilder(
        animation: ctrl, child: col,
        builder: (_, child) => Transform.translate(
          key: Key('ev_feature_col_${widget.spread.feature.name}_$ci'),
          offset: Offset(0, downward ? -halfCycleH * (1.0 - ctrl.value) : -halfCycleH * ctrl.value),
          child: child,
        ),
      ),
    );
  }
}
