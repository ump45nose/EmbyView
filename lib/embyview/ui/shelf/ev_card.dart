import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/shelf/ev_artwork.dart';
import 'package:moonfin/embyview/ui/shell/ev_scope.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Card visual variants matching `.spec/mockups/proto.css`.
enum EvCardStyle { landscape, poster, collection }

/// Media card supporting 16:9 landscape, 2:3 poster, and 2:3 collection
/// (up to 2 stacked back posters fanning ±3° on hover/focus).
class EvCard extends StatefulWidget {
  const EvCard({
    super.key,
    required this.card,
    required this.style,
    this.resume,
    this.width,
    this.posterHeight,
    this.animateArtworkFade = true,
    this.showTitle = true,
    this.showSubtitle = true,
    this.subtitle,
    this.alwaysShowLabel = false,
    this.accentColor,
    this.focusNode,
    this.onTap,
    this.onPlay,
    this.onHoverChanged,
    this.onFocusChanged,
    this.onActivateWithOrigin,
  });

  final MediaCard card;
  final EvCardStyle style;
  final ResumeCard? resume;
  final double? width;
  final double? posterHeight;
  final bool animateArtworkFade;
  final bool showTitle;
  final bool showSubtitle;
  final String? subtitle;
  final bool alwaysShowLabel;
  final Color? accentColor;
  final FocusNode? focusNode;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final ValueChanged<bool>? onHoverChanged;
  final ValueChanged<bool>? onFocusChanged;
  final void Function(Rect origin)? onActivateWithOrigin;

  static double aspectRatioFor(EvCardStyle style) =>
      style == EvCardStyle.landscape ? 16.0 / 9.0 : 2.0 / 3.0;

  /// Formats remaining time as 「剩 X 分钟」 or 「剩 X 小时 X 分」.
  static String formatRemaining(Duration remaining) {
    final totalMinutes = math.max(1, (math.max(0, remaining.inSeconds) / 60.0).ceil());
    if (totalMinutes < 60) return '剩 $totalMinutes 分钟';
    final h = totalMinutes ~/ 60, m = totalMinutes % 60;
    return m == 0 ? '剩 $h 小时' : '剩 $h 小时 $m 分';
  }

  /// Resume progress in `[0.0, 1.0]` when total duration is available.
  static double? resumeProgress(ResumeCard? resume) {
    if (resume == null) return null;
    final total = resume.duration ?? resume.card.duration;
    if (total == null || total <= Duration.zero) return null;
    return (resume.position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Subtitle for a resume card (optional episode prefix + remaining time).
  static String? resumeSubtitle(ResumeCard? resume) {
    if (resume == null) return null;
    final total = resume.duration ?? resume.card.duration;
    final ep = resume.target.episodeNumber ?? resume.card.episodeNumber;
    final parts = <String>[
      if (ep != null) '第 $ep 集',
      if (total != null && total > Duration.zero)
        formatRemaining(total > resume.position ? total - resume.position : Duration.zero),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  State<EvCard> createState() => _EvCardState();
}

class _EvCardState extends State<EvCard> {
  static const _white = Color(0xFFFFFFFF);
  static const _paperInk = Color(0xFF141413);

  final GlobalKey _artKey = GlobalKey();
  bool _hovered = false, _focused = false, _pressed = false, _useAnimations = false;
  Alignment _glareAlign = const Alignment(0.0, -1.0);

  bool get _highlighted => _hovered || _focused;

  void _maybeDemoteAnimations() {
    if (mounted && !_highlighted && !_pressed && _useAnimations) setState(() => _useAnimations = false);
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() {
      _hovered = value;
      if (value) { _useAnimations = true; } else { _pressed = false; }
    });
    widget.onHoverChanged?.call(value);
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() { _focused = value; if (value) _useAnimations = true; });
    widget.onFocusChanged?.call(value);
  }

  void _activate() {
    final box = _artKey.currentContext?.findRenderObject() as RenderBox?;
    widget.onActivateWithOrigin?.call(box != null && box.hasSize ? (box.localToGlobal(Offset.zero) & box.size) : Rect.zero);
    if (widget.onTap != null) { widget.onTap!(); } else { widget.onPlay?.call(); }
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (!evIsActivateKey(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space && widget.onPlay != null) { widget.onPlay!(); } else { _activate(); }
    return KeyEventResult.handled;
  }

  Color _blockColor(BuildContext context, EvTheme theme) {
    if (widget.accentColor != null) return widget.accentColor!;
    final lib = widget.card.libraryId;
    if (lib != null) {
      for (final z in context.getInheritedWidgetOfExactType<EvScope>()?.shell.zones ?? const <ZoneTile>[]) {
        if (z.id == lib) return theme.zoneColor(z.colorSlot);
      }
    }
    return switch (widget.card.kind) {
      MediaKind.movie => theme.movie,
      MediaKind.series || MediaKind.episode => theme.tv,
      MediaKind.collection => theme.box,
    };
  }

  String _resolvedSubtitle() {
    if (widget.subtitle != null) return widget.subtitle!;
    final resumeSub = EvCard.resumeSubtitle(widget.resume);
    if (resumeSub != null) return resumeSub;
    if (widget.style == EvCardStyle.collection && widget.card.childCount != null) return '${widget.card.childCount} 部';
    return [if (widget.card.year != null) '${widget.card.year}', if (widget.card.genres.isNotEmpty) widget.card.genres.first].join(' · ');
  }

  static Transform _artTransform(double s, Offset off, Widget child) => Transform(
    key: const ValueKey('ev_card_art_transform'),
    alignment: Alignment.center,
    transform: Matrix4.translationValues(off.dx, off.dy, 0.0)..multiply(Matrix4.diagonal3Values(s, s, 1.0)),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final aspect = EvCard.aspectRatioFor(widget.style);
    final isLandscape = widget.style == EvCardStyle.landscape;
    final radius = BorderRadius.circular(scale.rem(isLandscape ? theme.radius : theme.posterRadius));
    final plan = isLandscape ? widget.card.art.landscape : widget.card.art.poster;
    final progress = EvCard.resumeProgress(widget.resume);
    final sub = widget.showSubtitle ? _resolvedSubtitle() : '';

    final art = _buildArtSurface(
      context: context, theme: theme, scale: scale, plan: plan, aspect: aspect,
      radius: radius, progress: progress, played: widget.card.played == true,
    );
    final visual = widget.style == EvCardStyle.collection ? _buildCollectionStack(theme, scale, radius, aspect, art) : art;

    final labelVisible = isLandscape || widget.alwaysShowLabel || _highlighted;
    final labelOffset = _highlighted
        ? (theme.isPaper ? Offset(-scale.rem(0.3125), scale.rem(0.125)) : Offset(0, scale.rem(0.375)))
        : Offset.zero;

    Widget? titleBlock;
    if (widget.showTitle) {
      Widget label = Padding(
        padding: EdgeInsets.only(top: scale.rem(0.875)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.card.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: theme.bodyStyle(scale.font(1.0), fontWeight: FontWeight.w600, color: theme.ink).copyWith(
                decoration: theme.isPaper && _highlighted ? TextDecoration.underline : TextDecoration.none,
                decorationColor: theme.brand, decorationThickness: 2.0,
              ),
            ),
            if (sub.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: scale.rem(0.25)),
                child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.bodyStyle(scale.font(0.875), color: theme.ink3)),
              ),
          ],
        ),
      );
      if (_useAnimations) {
        label = AnimatedOpacity(
          opacity: labelVisible ? 1.0 : 0.0, duration: EvDurations.normal, curve: EvCurves.soft,
          child: TweenAnimationBuilder<Offset>(
            tween: Tween<Offset>(begin: Offset.zero, end: labelOffset),
            duration: EvDurations.medium, curve: EvCurves.spring,
            builder: (_, offset, child) => Transform.translate(offset: offset, child: child),
            child: label,
          ),
        );
      } else if (!labelVisible) {
        label = Opacity(opacity: 0.0, child: label);
      }
      titleBlock = label;
    }

    Widget body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [visual, ?titleBlock]);
    if (widget.width != null) body = SizedBox(width: widget.width, child: body);

    return Semantics(
      button: true, focused: _focused, label: sub.isNotEmpty ? '${widget.card.title}，$sub' : widget.card.title,
      child: Focus(
        focusNode: widget.focusNode, onFocusChange: _setFocused, onKeyEvent: _handleKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _setHovered(true), onExit: (_) => _setHovered(false),
          onHover: (event) {
            if (theme.isPaper) return;
            final box = _artKey.currentContext?.findRenderObject() as RenderBox?;
            if (box == null || !box.hasSize) return;
            final local = box.globalToLocal(event.position);
            setState(() => _glareAlign = Alignment(
              (local.dx / box.size.width * 2 - 1).clamp(-1.0, 1.0),
              (local.dy / box.size.height * 2 - 1).clamp(-1.0, 1.0),
            ));
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() { _pressed = true; _useAnimations = true; }),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: _activate,
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _buildArtSurface({
    required BuildContext context, required EvTheme theme, required EvScale scale,
    required ArtworkPlan plan, required double aspect, required BorderRadius radius,
    required double? progress, required bool played,
  }) {
    final isPaper = theme.isPaper;
    final targetScale = isPaper ? (_pressed ? 0.99 : 1.0) : (_pressed ? 1.01 : (_highlighted ? 1.07 : 1.0));
    final targetOffset = isPaper && _highlighted
        ? (_pressed ? Offset(-scale.rem(0.125), -scale.rem(0.125)) : Offset(-scale.rem(0.3125), -scale.rem(0.3125)))
        : Offset.zero;
    final shadows = _highlighted
        ? (isPaper ? [BoxShadow(offset: Offset(scale.rem(0.625), scale.rem(0.625)), color: _blockColor(context, theme))] : theme.cardShadowHi)
        : theme.cardShadow;
    final borderDec = BoxDecoration(
      borderRadius: radius,
      border: Border.all(color: _highlighted ? theme.focusColor : theme.line, width: _highlighted ? 1.5 : 1.0),
    );
    final hasFixedArtSize = widget.width != null && widget.posterHeight != null;
    final borderOverlay = IgnorePointer(
      child: _useAnimations
          ? AnimatedContainer(key: const ValueKey('ev_card_border'), duration: EvDurations.normal, curve: EvCurves.soft, decoration: borderDec)
          : DecoratedBox(key: const ValueKey('ev_card_border'), decoration: borderDec),
    );
    final needsGlare = !isPaper && _useAnimations;
    final Widget artOverlay = (!needsGlare && progress == null && !played)
        ? borderOverlay
        : Stack(
            fit: StackFit.expand,
            children: [
              if (needsGlare)
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _highlighted ? 1.0 : 0.0, duration: EvDurations.normal, curve: EvCurves.soft,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: _glareAlign, radius: 0.7,
                          colors: const [Color.fromRGBO(255, 255, 255, 0.24), Color.fromRGBO(255, 255, 255, 0.0)],
                        ),
                      ),
                    ),
                  ),
                ),
              if (progress != null)
                Positioned(
                  left: scale.rem(0.75), right: scale.rem(0.75), bottom: scale.rem(0.75), height: scale.rem(0.25),
                  child: ClipRRect(
                    key: const ValueKey('ev_card_progress'), borderRadius: BorderRadius.circular(2),
                    child: ColoredBox(
                      color: isPaper ? const Color.fromRGBO(255, 255, 255, 0.55) : const Color.fromRGBO(255, 255, 255, 0.30),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(widthFactor: progress.clamp(0.0, 1.0), child: ColoredBox(color: isPaper ? theme.brand : _white)),
                      ),
                    ),
                  ),
                ),
              if (played)
                Positioned(
                  right: scale.rem(0.5), top: scale.rem(0.5),
                  child: Container(
                    key: const ValueKey('ev_card_played'), width: scale.rem(1.625), height: scale.rem(1.625),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isPaper ? theme.brand : const Color.fromRGBO(0, 0, 0, 0.50),
                      border: isPaper ? Border.all(color: _paperInk, width: 1.25) : null,
                    ),
                    alignment: Alignment.center,
                    child: EvIcon(EvIcons.check, size: scale.rem(isPaper ? 1.0 : 0.875), color: isPaper ? _paperInk : _white),
                  ),
                ),
              borderOverlay,
            ],
          );
    final artwork = EvArtwork(
      plan: plan,
      width: hasFixedArtSize ? widget.width : null,
      height: hasFixedArtSize ? widget.posterHeight : null,
      aspectRatio: hasFixedArtSize ? null : aspect,
      decodeWidth: hasFixedArtSize ? widget.width : null,
      animateFade: widget.animateArtworkFade,
      borderRadius: radius,
      overlay: artOverlay,
    );
    final cardDec = BoxDecoration(borderRadius: radius, boxShadow: shadows);
    final surface = _useAnimations
        ? AnimatedContainer(key: _artKey, duration: EvDurations.medium, curve: EvCurves.out, decoration: cardDec, child: artwork)
        : DecoratedBox(key: _artKey, decoration: cardDec, child: artwork);
    if (!_useAnimations) return surface;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 1.0, end: targetScale), duration: EvDurations.medium, curve: EvCurves.spring,
      onEnd: _maybeDemoteAnimations,
      builder: (_, s, child) => isPaper
          ? TweenAnimationBuilder<Offset>(
              tween: Tween<Offset>(begin: Offset.zero, end: targetOffset), duration: EvDurations.medium, curve: EvCurves.spring,
              onEnd: _maybeDemoteAnimations,
              builder: (_, off, inner) => _artTransform(s, off, inner!),
              child: child,
            )
          : _artTransform(s, Offset.zero, child!),
      child: surface,
    );
  }

  Widget _buildCollectionStack(
    EvTheme theme, EvScale scale, BorderRadius radius, double aspect, Widget frontCard,
  ) {
    final backPosters = widget.card.art.poster.stack.take(2).toList();
    Widget backLayer({
      required Key key, required ArtworkRef ref, required double hInset, required double topOffset,
      required double liftRem, required double angleDeg, required double paperOpacity, required double cinemaScrim,
    }) {
      Transform fan(double t, Widget child) => Transform(
        key: key, alignment: Alignment.bottomCenter,
        transform: Matrix4.translationValues(0.0, -scale.rem(liftRem) * t, 0.0)
          ..multiply(Matrix4.rotationZ((angleDeg * math.pi / 180.0) * t)),
        child: child,
      );
      final layer = Opacity(
        opacity: theme.isPaper ? paperOpacity : 1.0,
        child: ClipRRect(
          borderRadius: radius,
          child: AspectRatio(
            aspectRatio: aspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: theme.cardBg),
                Image(image: ref.image, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => ColoredBox(color: theme.fill2)),
                if (!theme.isPaper) ColoredBox(color: Color.fromRGBO(0, 0, 0, cinemaScrim)),
                if (theme.isPaper)
                  DecoratedBox(decoration: BoxDecoration(borderRadius: radius, border: Border.all(color: const Color(0xFFD1CFC5), width: 1))),
              ],
            ),
          ),
        ),
      );
      return Positioned(
        left: hInset, right: hInset, top: topOffset,
        child: _useAnimations
            ? TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: _highlighted ? 1.0 : 0.0),
                duration: EvDurations.medium, curve: EvCurves.spring, onEnd: _maybeDemoteAnimations,
                builder: (_, t, child) => fan(t, child!), child: layer,
              )
            : fan(0.0, layer),
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: scale.rem(0.625)),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (backPosters.length >= 2)
            backLayer(
              key: const ValueKey('ev_collection_stack_back'), ref: backPosters[1],
              hInset: scale.rem(1.0), topOffset: -scale.rem(0.625), liftRem: 0.75, angleDeg: 3.0, paperOpacity: 0.30, cinemaScrim: 0.72,
            ),
          if (backPosters.isNotEmpty)
            backLayer(
              key: const ValueKey('ev_collection_stack_mid'), ref: backPosters[0],
              hInset: scale.rem(0.5), topOffset: -scale.rem(0.3125), liftRem: 0.375, angleDeg: -3.0, paperOpacity: 0.55, cinemaScrim: 0.55,
            ),
          frontCard,
        ],
      ),
    );
  }
}
