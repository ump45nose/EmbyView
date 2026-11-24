import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/shelf/ev_card.dart';
import 'package:moonfin/embyview/ui/shelf/ev_skeleton.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Pure layout calculator mirroring `proto.js` `fit(base)` so every shelf fits
/// an integer number of full cards plus exactly 0.25 of the next card peeking.
abstract final class EvShelfLayout {
  static const double landscapeBaseRem = 19.5;
  static const double posterBaseRem = 11.0;
  static const double episodeBaseRem = 20.0;
  static const double personBaseRem = 7.5;
  static const double gapRem = 1.25;
  static const double peekFraction = 0.25;

  static double baseRemFor(EvCardStyle style) =>
      style == EvCardStyle.landscape ? landscapeBaseRem : posterBaseRem;

  /// Inter-card gap (`1.25rem`).
  static double gap(EvScale scale) => scale.rem(gapRem);

  /// Integer count of full cards visible inside `viewportWidth - gutter`.
  static int visibleFullCards({
    required double viewportWidth,
    required EvScale scale,
    required EvCardStyle style,
    double? baseRem,
  }) {
    final avail = math.max(0.0, viewportWidth - scale.gutter);
    final unit = scale.rem(baseRem ?? baseRemFor(style)) + gap(scale);
    return unit <= 0 ? 1 : math.max(1, (avail / unit - peekFraction).round());
  }

  /// Exact card width so `n` full cards + `n` gaps + `0.25` card == `avail`.
  static double cardWidth({
    required double viewportWidth,
    required EvScale scale,
    required EvCardStyle style,
    double? baseRem,
  }) {
    final avail = math.max(0.0, viewportWidth - scale.gutter);
    final g = gap(scale);
    final n = visibleFullCards(
      viewportWidth: viewportWidth, scale: scale, style: style, baseRem: baseRem,
    );
    return math.max(0.0, (avail - n * g) / (n + peekFraction));
  }
}

/// Thin horizontal scrollbar mirroring `.rail` in `.spec/mockups/proto.css`:
/// hidden when fitting or idle; reveals on shelf hover or horizontal scroll;
/// supports clicking the track and dragging the thumb.
class EvShelfScrollbar extends StatefulWidget {
  const EvShelfScrollbar({
    super.key,
    required this.controller,
    this.shelfHovered = false,
    this.margin,
    this.metricsRevision = 0,
  });

  final ScrollController controller;
  final bool shelfHovered;
  final EdgeInsetsGeometry? margin;
  final int metricsRevision;

  @override
  State<EvShelfScrollbar> createState() => _EvShelfScrollbarState();
}

class _EvShelfScrollbarState extends State<EvShelfScrollbar> {
  bool _railHovered = false, _scrolling = false, _dragging = false;
  bool _overflows = false;
  double _fraction = 1.0, _scrollRatio = 0.0;
  double _lastPixels = 0.0, _dragStartX = 0.0, _dragStartPixels = 0.0;
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScrollChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncMetrics());
  }

  @override
  void didUpdateWidget(EvShelfScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScrollChanged);
      widget.controller.addListener(_onScrollChanged);
      _lastPixels = 0.0;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncMetrics());
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    widget.controller.removeListener(_onScrollChanged);
    super.dispose();
  }

  void _onScrollChanged() {
    if (!mounted || !widget.controller.hasClients) return;
    final pixels = widget.controller.position.pixels;
    final moved = (pixels - _lastPixels).abs() > 0.5;
    _lastPixels = pixels;
    if (moved) {
      _scrolling = true;
      _liveTimer?.cancel();
      _liveTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _scrolling = false);
      });
    }
    _syncMetrics();
  }

  void _syncMetrics() {
    if (!mounted) return;
    if (!widget.controller.hasClients) {
      if (_overflows) setState(() => _overflows = false);
      return;
    }
    final pos = widget.controller.position;
    if (!pos.hasViewportDimension || !pos.hasContentDimensions) return;
    final viewport = pos.viewportDimension, maxExtent = pos.maxScrollExtent;
    final scrollWidth = viewport + maxExtent;
    final fraction = scrollWidth <= 0 ? 1.0 : (viewport / scrollWidth).clamp(0.0, 1.0);
    final overflows = fraction <= 0.995 && maxExtent > 0.5;
    final ratio = maxExtent <= 0 ? 0.0 : (pos.pixels / maxExtent).clamp(0.0, 1.0);

    if (overflows != _overflows ||
        (fraction - _fraction).abs() > 0.0005 ||
        (ratio - _scrollRatio).abs() > 0.0005 ||
        _scrolling) {
      setState(() {
        _overflows = overflows;
        _fraction = fraction;
        _scrollRatio = ratio;
      });
    }
  }

  void _jumpToTrackX(double localX, double railWidth) {
    if (!widget.controller.hasClients || railWidth <= 0) return;
    final pos = widget.controller.position;
    final scrollWidth = pos.viewportDimension + pos.maxScrollExtent;
    final target = ((localX / railWidth) * scrollWidth - pos.viewportDimension / 2)
        .clamp(0.0, pos.maxScrollExtent);
    widget.controller.animateTo(target, duration: EvDurations.normal, curve: EvCurves.out);
  }

  void _onDragStart(DragStartDetails d, double railWidth, double thumbLeft, double thumbWidth) {
    if (!widget.controller.hasClients) return;
    final pos = widget.controller.position;
    final x = d.localPosition.dx;
    if (x < thumbLeft || x > thumbLeft + thumbWidth) {
      final scrollWidth = pos.viewportDimension + pos.maxScrollExtent;
      widget.controller.jumpTo(
        ((x / railWidth) * scrollWidth - pos.viewportDimension / 2).clamp(0.0, pos.maxScrollExtent),
      );
    }
    setState(() {
      _dragging = true;
      _dragStartX = x;
      _dragStartPixels = widget.controller.position.pixels;
    });
  }

  void _onDragUpdate(DragUpdateDetails d, double railWidth, double thumbWidth) {
    if (!_dragging || !widget.controller.hasClients) return;
    final pos = widget.controller.position;
    final span = railWidth - thumbWidth;
    if (span <= 0) return;
    final target = (_dragStartPixels + (d.localPosition.dx - _dragStartX) * (pos.maxScrollExtent / span))
        .clamp(0.0, pos.maxScrollExtent);
    widget.controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final railHeight = scale.rem(1.0);
    final margin = widget.margin ?? EdgeInsets.symmetric(horizontal: scale.gutter);

    if (!_overflows) {
      return Padding(padding: margin, child: SizedBox(height: railHeight));
    }

    final visible = widget.shelfHovered || _railHovered || _scrolling || _dragging;
    final expanded = widget.shelfHovered || _railHovered || _dragging;
    final barHeight = expanded ? 4.0 : 2.0;

    return Padding(
      padding: margin,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _railHovered = true),
        onExit: (_) => setState(() => _railHovered = false),
        child: AnimatedOpacity(
          key: const ValueKey('ev_shelf_scrollbar_opacity'),
          opacity: visible ? 1.0 : 0.0,
          duration: EvDurations.normal,
          curve: EvCurves.soft,
          child: IgnorePointer(
            ignoring: !visible,
            child: LayoutBuilder(
              builder: (_, constraints) {
                final railWidth = constraints.maxWidth;
                final thumbWidth = math.min(railWidth, math.max(24.0, railWidth * _fraction));
                final thumbLeft = _scrollRatio * math.max(0.0, railWidth - thumbWidth);

                return GestureDetector(
                  key: const ValueKey('ev_shelf_scrollbar_track'),
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _jumpToTrackX(d.localPosition.dx, railWidth),
                  onHorizontalDragStart: (d) => _onDragStart(d, railWidth, thumbLeft, thumbWidth),
                  onHorizontalDragUpdate: (d) => _onDragUpdate(d, railWidth, thumbWidth),
                  onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                  onHorizontalDragCancel: () => setState(() => _dragging = false),
                  child: SizedBox(
                    height: railHeight,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        AnimatedContainer(
                          duration: EvDurations.normal,
                          curve: EvCurves.soft,
                          width: railWidth,
                          height: barHeight,
                          decoration: BoxDecoration(
                            color: expanded ? theme.fill2 : theme.fill,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Positioned(
                          left: thumbLeft,
                          child: AnimatedContainer(
                            key: const ValueKey('ev_shelf_scrollbar_thumb'),
                            duration: _dragging ? Duration.zero : EvDurations.fast,
                            curve: EvCurves.soft,
                            width: thumbWidth,
                            height: barHeight,
                            decoration: BoxDecoration(
                              color: expanded ? theme.ink2 : theme.ink4,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal media shelf without arrow buttons: uses [EvShelfLayout] for
/// `N + 0.25` peek width, reveals [EvShelfScrollbar] on hover/scroll, and
/// auto-scrolls keyboard-focused cards into view with `--g` scroll padding.
class EvShelf extends StatefulWidget {
  const EvShelf({
    super.key,
    required this.title,
    this.items = const [],
    this.resumeItems,
    this.itemCount,
    this.itemBuilder,
    this.style = EvCardStyle.poster,
    this.badge,
    this.moreLabel,
    this.onMoreTap,
    this.loading = false,
    this.skeletonCount = 6,
    this.cardBaseRem,
    this.onCardTap,
    this.onCardPlay,
    this.onCardActivateWithOrigin,
    this.onCardHoverChanged,
    this.onCardFocusChanged,
    this.controller,
  });

  final String title;
  final List<MediaCard> items;
  final List<ResumeCard>? resumeItems;
  final int? itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  final EvCardStyle style;
  final String? badge;
  final String? moreLabel;
  final VoidCallback? onMoreTap;
  final bool loading;
  final int skeletonCount;
  final double? cardBaseRem;
  final ValueChanged<MediaCard>? onCardTap;
  final ValueChanged<MediaCard>? onCardPlay;
  final void Function(MediaCard card, Rect origin)? onCardActivateWithOrigin;
  final void Function(MediaCard card, bool hovered)? onCardHoverChanged;
  final void Function(MediaCard card, bool focused)? onCardFocusChanged;
  final ScrollController? controller;

  @override
  State<EvShelf> createState() => _EvShelfState();
}

class _EvShelfState extends State<EvShelf> {
  ScrollController? _ownedController;
  bool _hovered = false, _moreHovered = false, _moreFocused = false;
  int _metricsVersion = 0;

  ScrollController get _controller => widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  int get _effectiveCount => widget.itemBuilder != null
      ? (widget.itemCount ?? widget.resumeItems?.length ?? widget.items.length)
      : (widget.resumeItems?.length ?? widget.items.length);

  void _ensureVisible(int i, double cardW, double gap, double gutter, double vw) {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    if (!pos.hasContentDimensions) return;
    final left = gutter + i * (cardW + gap), right = left + cardW;
    double? target;
    if (left - gutter < pos.pixels) {
      target = (left - gutter).clamp(0.0, pos.maxScrollExtent);
    } else if (right + gutter > pos.pixels + vw) {
      target = (right + gutter - vw).clamp(0.0, pos.maxScrollExtent);
    }
    if (target != null && (target - pos.pixels).abs() > 0.5) {
      _controller.animateTo(target, duration: EvDurations.normal, curve: EvCurves.out);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return EvShelfSkeleton(
        style: widget.style,
        count: widget.skeletonCount,
        title: widget.title.isNotEmpty ? widget.title : null,
        baseRem: widget.cardBaseRem,
      );
    }

    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final gutter = scale.gutter, gap = EvShelfLayout.gap(scale);
    final count = _effectiveCount;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: EdgeInsets.only(bottom: scale.rem(1.75)),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final vw = constraints.hasBoundedWidth && constraints.maxWidth > 0
                ? constraints.maxWidth
                : scale.size.width;
            final cardW = EvShelfLayout.cardWidth(
              viewportWidth: vw, scale: scale, style: widget.style, baseRem: widget.cardBaseRem,
            );

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(theme, scale, gutter),
                NotificationListener<ScrollMetricsNotification>(
                  onNotification: (_) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() => _metricsVersion++);
                    });
                    return false;
                  },
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      controller: _controller,
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      padding: EdgeInsets.fromLTRB(gutter, scale.rem(1.0), gutter, scale.rem(1.25)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < count; i++) ...[
                            if (i > 0) SizedBox(width: gap),
                            _buildItem(context, i, cardW, gap, gutter, vw),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                Transform.translate(
                  offset: Offset(0, -scale.rem(0.375)),
                  child: EvShelfScrollbar(
                    controller: _controller,
                    shelfHovered: _hovered,
                    margin: EdgeInsets.symmetric(horizontal: gutter),
                    metricsRevision: _metricsVersion,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(EvTheme theme, EvScale scale, double gutter) {
    final hasMore = widget.onMoreTap != null || widget.moreLabel != null;
    final moreVisible = _hovered || _moreHovered || _moreFocused;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, scale.rem(0.25)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(widget.title, style: theme.shelfStyle(scale.font(1.5))),
          if (widget.badge != null && widget.badge!.isNotEmpty) ...[
            SizedBox(width: scale.rem(0.75)),
            Text(
              widget.badge!,
              style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w500, color: theme.ink3),
            ),
          ],
          const Spacer(),
          if (hasMore)
            Focus(
              canRequestFocus: widget.onMoreTap != null,
              onFocusChange: (v) => setState(() => _moreFocused = v),
              onKeyEvent: (_, event) {
                if (widget.onMoreTap == null || !evIsActivateKey(event)) return KeyEventResult.ignored;
                widget.onMoreTap!();
                return KeyEventResult.handled;
              },
              child: MouseRegion(
                cursor: widget.onMoreTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
                onEnter: (_) => setState(() => _moreHovered = true),
                onExit: (_) => setState(() => _moreHovered = false),
                child: GestureDetector(
                  onTap: widget.onMoreTap,
                  child: AnimatedOpacity(
                    opacity: moreVisible ? 1.0 : 0.0,
                    duration: EvDurations.normal,
                    curve: EvCurves.soft,
                    child: Text(
                      widget.moreLabel ?? '查看全部 ›',
                      style: theme.bodyStyle(
                        scale.font(0.9375),
                        fontWeight: FontWeight.w500,
                        color: _moreHovered || _moreFocused ? theme.ink : theme.ink3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, int i, double cardW, double gap, double gutter, double vw) {
    if (widget.itemBuilder != null) {
      return Focus(
        skipTraversal: true,
        onFocusChange: (f) { if (f) _ensureVisible(i, cardW, gap, gutter, vw); },
        child: SizedBox(width: cardW, child: widget.itemBuilder!(context, i)),
      );
    }
    final resume = widget.resumeItems?[i];
    final card = resume?.card ?? widget.items[i];
    return EvCard(
      card: card,
      style: widget.style,
      resume: resume,
      width: cardW,
      onTap: widget.onCardTap != null ? () => widget.onCardTap!(card) : null,
      onPlay: widget.onCardPlay != null ? () => widget.onCardPlay!(card) : null,
      onActivateWithOrigin: widget.onCardActivateWithOrigin != null
          ? (origin) => widget.onCardActivateWithOrigin!(card, origin)
          : null,
      onHoverChanged: widget.onCardHoverChanged != null
          ? (hovered) => widget.onCardHoverChanged!(card, hovered)
          : null,
      onFocusChanged: (f) {
        if (f) _ensureVisible(i, cardW, gap, gutter, vw);
        widget.onCardFocusChanged?.call(card, f);
      },
    );
  }
}
