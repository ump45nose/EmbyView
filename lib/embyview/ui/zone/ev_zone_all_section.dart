import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Bottom "全部<分区名>" section mirroring `.genres`, `.chip`, and `.wallcta`
/// from `.spec/mockups/proto.css` and `proto.js`.
class EvZoneAllSection extends StatelessWidget {
  const EvZoneAllSection({
    super.key, required this.zone, required this.genreCounts,
    required this.collage, required this.onGenreTap, required this.onBrowseAll,
  });

  final ZoneTile zone;
  final List<FacetOption<String>> genreCounts;
  final List<ArtworkRef> collage;
  final ValueChanged<FacetOption<String>> onGenreTap;
  final VoidCallback onBrowseAll;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final accent = theme.zoneColor(zone.colorSlot);
    final visibleGenres = genreCounts.take(10).toList(growable: false);

    return Padding(
      padding: EdgeInsets.only(bottom: scale.rem(1.75)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(scale.gutter, 0, scale.gutter, scale.rem(0.25)),
            child: Text('全部${zone.name}', style: theme.shelfStyle(scale.font(1.5))),
          ),
          if (visibleGenres.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(scale.gutter, scale.rem(0.5), scale.gutter, scale.rem(1.0)),
              child: Wrap(
                spacing: scale.rem(0.5),
                runSpacing: scale.rem(0.5),
                children: [
                  for (final option in visibleGenres)
                    _EvGenreChip(
                      key: Key('ev_zone_genre_chip_${option.value}'),
                      option: option,
                      onTap: () => onGenreTap(option),
                    ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(scale.gutter, scale.rem(1.0), scale.gutter, scale.rem(1.25)),
            child: _EvWallCtaCard(
              key: const Key('ev_zone_wall_cta'),
              zone: zone,
              accent: accent,
              collage: collage.take(9).toList(growable: false),
              onTap: onBrowseAll,
            ),
          ),
        ],
      ),
    );
  }
}

class _EvGenreChip extends StatefulWidget {
  const _EvGenreChip({super.key, required this.option, required this.onTap});
  final FacetOption<String> option;
  final VoidCallback onTap;

  @override
  State<_EvGenreChip> createState() => _EvGenreChipState();
}

class _EvGenreChipState extends State<_EvGenreChip> {
  bool _hovered = false, _focused = false, _pressed = false;
  bool get _hi => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final fg = _hi ? theme.ink : theme.ink2;
    final bg = _hi ? theme.fill2 : (theme.isPaper ? const Color(0xFFFFFFFF) : theme.fill);

    return Semantics(
      button: true,
      focused: _focused,
      label: widget.option.count != null ? '${widget.option.label} ${widget.option.count}' : widget.option.label,
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!evIsActivateKey(e)) return KeyEventResult.ignored;
          widget.onTap();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _pressed ? 0.95 : 1.0,
              duration: EvDurations.normal,
              curve: EvCurves.spring,
              child: AnimatedContainer(
                duration: EvDurations.fast,
                curve: EvCurves.soft,
                height: scale.rem(2.375),
                padding: EdgeInsets.symmetric(horizontal: scale.rem(1.0625)),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _focused ? theme.focusColor : theme.line, width: _focused ? 1.5 : 1.0),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.option.label, style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w500, color: fg)),
                    if (widget.option.count != null) ...[
                      SizedBox(width: scale.rem(0.5)),
                      Text(
                        '${widget.option.count}',
                        style: theme
                            .bodyStyle(scale.font(0.8125), fontWeight: FontWeight.w500, color: fg.withValues(alpha: fg.a * 0.55))
                            .copyWith(fontFeatures: const [ui.FontFeature.tabularFigures()]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvWallCtaCard extends StatefulWidget {
  const _EvWallCtaCard({super.key, required this.zone, required this.accent, required this.collage, required this.onTap});
  final ZoneTile zone;
  final Color accent;
  final List<ArtworkRef> collage;
  final VoidCallback onTap;

  @override
  State<_EvWallCtaCard> createState() => _EvWallCtaCardState();
}

class _EvWallCtaCardState extends State<_EvWallCtaCard> {
  bool _hovered = false, _focused = false, _pressed = false;
  bool get _hi => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final radius = BorderRadius.circular(scale.rem(theme.radius));
    final width = scale.rem(19.5), height = width * 9.0 / 16.0;
    final cardScale = theme.isPaper ? (_pressed ? 0.99 : 1.0) : (_pressed ? 0.98 : (_hi ? 1.04 : 1.0));
    final offset = theme.isPaper && _hi ? Offset(-scale.rem(0.25), -scale.rem(0.25)) : Offset.zero;

    return Semantics(
      button: true,
      focused: _focused,
      label: '浏览全部 ${evFormatCount(widget.zone.total)} ${widget.zone.unit}',
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!evIsActivateKey(e)) return KeyEventResult.ignored;
          widget.onTap();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onTap,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: cardScale),
              duration: EvDurations.medium,
              curve: EvCurves.spring,
              builder: (_, s, child) => Transform.translate(offset: offset, child: Transform.scale(scale: s, child: child)),
              child: AnimatedContainer(
                duration: EvDurations.medium,
                curve: EvCurves.out,
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: theme.isPaper ? theme.fill2 : null,
                  gradient: theme.isPaper
                      ? null
                      : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [widget.accent.withValues(alpha: 0.32), widget.accent.withValues(alpha: 0.05)],
                        ),
                  borderRadius: radius,
                  border: Border.all(color: _hi ? theme.focusColor : theme.line, width: _hi ? 1.5 : 1.0),
                  boxShadow: theme.isPaper && _hi
                      ? [BoxShadow(offset: Offset(scale.rem(0.5), scale.rem(0.5)), color: widget.accent)]
                      : null,
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.collage.isNotEmpty) _buildMosaic(scale, width),
                    Padding(
                      padding: EdgeInsets.all(scale.rem(1.25)),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '浏览全部 ${evFormatCount(widget.zone.total)} ${widget.zone.unit}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.bodyStyle(scale.font(1.25), fontWeight: FontWeight.w700, color: theme.ink),
                          ),
                          SizedBox(height: scale.rem(0.25)),
                          Text(
                            '按标题、评分、年份排列，支持字母跳转',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.bodyStyle(scale.font(0.875), color: theme.ink2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMosaic(EvScale scale, double cardWidth) {
    final mosaicW = cardWidth * 0.70, gap = scale.rem(0.375);
    final tileW = (mosaicW - gap * 2) / 3.0, tileH = tileW * 1.5;

    return Positioned(
      right: -cardWidth * 0.10,
      top: -cardWidth * 0.06,
      width: mosaicW,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.55,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: _hi ? 1.0 : 0.0),
            duration: EvDurations.stage,
            curve: EvCurves.out,
            builder: (_, t, child) => Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..rotateZ(ui.lerpDouble(-8.0 * math.pi / 180.0, -4.0 * math.pi / 180.0, t)!)
                ..multiply(Matrix4.diagonal3Values(1.0 + 0.05 * t, 1.0 + 0.05 * t, 1.0)),
              child: child,
            ),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final ref in widget.collage)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(scale.rem(0.25)),
                    child: SizedBox(
                      width: tileW,
                      height: tileH,
                      child: Image(image: ref.image, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
