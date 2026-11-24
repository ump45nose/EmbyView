import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Home page "片库" zone entry strip with a "管理分区 ›" action.
class EvZoneStrip extends StatelessWidget {
  const EvZoneStrip({super.key, required this.zones, this.onZoneTap, this.onManageZones});

  final List<ZoneTile> zones;
  final ValueChanged<ZoneTile>? onZoneTap;
  final VoidCallback? onManageZones;

  @override
  Widget build(BuildContext context) {
    if (zones.isEmpty) return const SizedBox.shrink();
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final gutter = scale.gutter, gap = scale.rem(1.25);
    final cols = math.min(6, zones.length), rows = (zones.length / cols).ceil();

    return Padding(
      key: const Key('ev_zone_strip'),
      padding: EdgeInsets.only(bottom: scale.rem(1.75)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, scale.rem(0.25)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('片库', style: theme.shelfStyle(scale.font(1.5))),
                const Spacer(),
                if (onManageZones != null) _ManageZonesButton(onTap: onManageZones!),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, scale.rem(1.0), gutter, scale.rem(1.25)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var r = 0; r < rows; r++) ...[
                  if (r > 0) SizedBox(height: gap),
                  Row(
                    children: [
                      for (var c = 0; c < cols; c++) ...[
                        if (c > 0) SizedBox(width: gap),
                        if (r * cols + c < zones.length)
                          Expanded(
                            child: _ZoneTileCard(
                              zone: zones[r * cols + c],
                              onTap: onZoneTap != null ? () => onZoneTap!(zones[r * cols + c]) : null,
                            ),
                          )
                        else
                          const Expanded(child: SizedBox.shrink()),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ManageZonesButton extends StatefulWidget {
  const _ManageZonesButton({required this.onTap});
  final VoidCallback onTap;
  @override State<_ManageZonesButton> createState() => _ManageZonesButtonState();
}

class _ManageZonesButtonState extends State<_ManageZonesButton> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    return Semantics(
      button: true, label: '管理分区',
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.space)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            key: const Key('ev_zone_manage'), behavior: HitTestBehavior.opaque, onTap: widget.onTap,
            child: Text(
              '管理分区 ›',
              style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w500, color: _hovered || _focused ? theme.ink : theme.ink3),
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoneTileCard extends StatefulWidget {
  const _ZoneTileCard({required this.zone, this.onTap});
  final ZoneTile zone;
  final VoidCallback? onTap;
  @override State<_ZoneTileCard> createState() => _ZoneTileCardState();
}

class _ZoneTileCardState extends State<_ZoneTileCard> {
  static const List<double> _cinemaRestMatrix = <double>[
    0.168, 0.255, 0.025, 0, 0,
    0.075, 0.348, 0.025, 0, 0,
    0.075, 0.255, 0.118, 0, 0,
    0, 0, 0, 1, 0,
  ];

  bool _hovered = false, _focused = false;
  bool get _hi => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), isPaper = theme.isPaper;
    final zone = widget.zone, zoneColor = theme.zoneColor(zone.colorSlot);
    final radius = BorderRadius.circular(scale.rem(1.0)), countText = _formatCount(zone);

    final shadows = _hi
        ? (isPaper
              ? [BoxShadow(offset: Offset(scale.rem(0.625), scale.rem(0.625)), color: zoneColor)]
              : [...theme.cardShadowHi, BoxShadow(blurRadius: scale.rem(3.0), color: zoneColor.withValues(alpha: 0.22))])
        : (isPaper ? const <BoxShadow>[] : theme.cardShadow);
    final borderColor = _hi
        ? (isPaper ? const Color(0xFF141413) : theme.focusColor)
        : (isPaper ? const Color(0xFFE8E6DC) : theme.line);
    final titleColor = isPaper && _hi ? const Color(0xFFFFFFFF) : theme.ink;
    final subColor = isPaper && _hi ? const Color.fromRGBO(255, 255, 255, 0.85) : (_hi ? theme.ink2 : theme.ink3);
    final iconColor = isPaper
        ? (_hi ? const Color(0xFFFFFFFF) : const Color(0xFF141413))
        : (_hi ? zoneColor : theme.ink3);

    return Semantics(
      button: true, label: '${zone.name}，$countText',
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
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            key: Key('ev_zone_tile_${zone.id}'), behavior: HitTestBehavior.opaque, onTap: widget.onTap,
            child: TweenAnimationBuilder<Offset>(
              tween: Tween<Offset>(end: isPaper && _hi ? Offset(-scale.rem(0.3125), -scale.rem(0.3125)) : Offset.zero),
              duration: EvDurations.medium, curve: EvCurves.spring,
              builder: (_, off, child) => AnimatedScale(
                scale: isPaper ? 1.0 : (_hi ? 1.05 : 1.0), duration: EvDurations.medium, curve: EvCurves.spring,
                child: Transform.translate(offset: off, child: child),
              ),
              child: AspectRatio(
                aspectRatio: 16.0 / 8.6,
                child: AnimatedContainer(
                  duration: EvDurations.medium, curve: EvCurves.out,
                  decoration: BoxDecoration(color: isPaper ? const Color(0xFFFFFFFF) : const Color(0xFF121216), borderRadius: radius, boxShadow: shadows),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: LayoutBuilder(
                      builder: (_, c) {
                        final compact = c.maxHeight < scale.rem(7.5);
                        final iconSize = scale.rem(isPaper ? (compact ? 1.875 : 2.5) : 1.875);
                        final pad = scale.rem(compact ? 0.75 : 1.0), hPad = scale.rem(compact ? 0.875 : 1.125);
                        final titleSize = scale.font(compact ? 1.375 : (isPaper ? 1.75 : 1.625));
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            if (zone.art != null)
                              Positioned.fill(
                                child: AnimatedOpacity(
                                  opacity: isPaper ? (_hi ? 1.0 : 0.0) : (_hi ? 1.0 : 0.9),
                                  duration: EvDurations.slow, curve: EvCurves.soft,
                                  child: AnimatedScale(
                                    scale: _hi ? 1.1 : 1.0, duration: const Duration(milliseconds: 900), curve: EvCurves.soft,
                                    child: _zoneImg(zone.art!, isPaper),
                                  ),
                                ),
                              ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: AnimatedOpacity(
                                  opacity: _hi ? 1.0 : 0.0, duration: EvDurations.stage, curve: EvCurves.soft,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: isPaper
                                          ? const LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, stops: [0.0, 0.70], colors: [Color.fromRGBO(20, 20, 19, 0.72), Color.fromRGBO(20, 20, 19, 0.0)])
                                          : LinearGradient(stops: const [0.0, 0.75], colors: [zoneColor.withValues(alpha: 0.50), zoneColor.withValues(alpha: 0.0)]),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: isPaper ? hPad : null, right: isPaper ? null : scale.rem(1.0), top: pad,
                              child: TweenAnimationBuilder<double>(
                                tween: Tween<double>(end: _hi ? 1.0 : 0.0), duration: EvDurations.slow, curve: EvCurves.spring,
                                builder: (_, t, child) => Transform(
                                  alignment: Alignment.center,
                                  transform: Matrix4.identity()..rotateZ((-8.0 * math.pi / 180.0) * t)..scaleByDouble(1.0 + 0.12 * t, 1.0 + 0.12 * t, 1.0, 1.0),
                                  child: child,
                                ),
                                child: EvIcon(EvIcons.byKey(zone.iconKey), size: iconSize, color: iconColor, active: _hi || isPaper),
                              ),
                            ),
                            Positioned(
                              left: hPad, right: scale.rem(1.0), bottom: pad,
                              child: Column(
                                mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    zone.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: isPaper
                                        ? theme.displayStyle(titleSize, color: titleColor, height: 1.05)
                                        : theme.shelfStyle(titleSize, color: titleColor).copyWith(fontWeight: FontWeight.w700, height: 1.05),
                                  ),
                                  SizedBox(height: scale.rem(compact ? 0.25 : 0.45)),
                                  Text(
                                    countText, maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: theme.bodyStyle(scale.font(0.875), color: subColor).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                                  ),
                                ],
                              ),
                            ),
                            IgnorePointer(
                              child: AnimatedContainer(
                                duration: EvDurations.normal, curve: EvCurves.soft,
                                decoration: BoxDecoration(borderRadius: radius, border: Border.all(color: borderColor, width: _hi ? 1.5 : 1.0)),
                              ),
                            ),
                          ],
                        );
                      },
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

  Widget _zoneImg(ArtworkRef art, bool isPaper) {
    final img = Image(image: art.image, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, errorBuilder: (_, _, _) => const SizedBox.shrink());
    return (isPaper || _hi) ? img : ColorFiltered(colorFilter: const ColorFilter.matrix(_cinemaRestMatrix), child: img);
  }

  static String _formatCount(ZoneTile z) =>
      '${_fmtInt(z.total)} ${z.unit}${(z.episodeTotal ?? 0) > 0 ? ' · ${_fmtInt(z.episodeTotal!)} 集' : ''}';

  static String _fmtInt(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}
