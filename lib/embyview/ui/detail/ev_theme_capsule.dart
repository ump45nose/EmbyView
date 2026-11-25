import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Top-right theme music capsule mirroring `.theme.glass` in `proto.css` / `proto.js`.
class EvThemeCapsule extends StatefulWidget {
  const EvThemeCapsule({super.key, required this.title, required this.snapshot, required this.onToggleMute, this.enableAnimations = true});
  final String title;
  final ImmersionSnapshot snapshot;
  final VoidCallback onToggleMute;
  final bool enableAnimations;
  @override State<EvThemeCapsule> createState() => _EvThemeCapsuleState();
}

class _EvThemeCapsuleState extends State<EvThemeCapsule> with SingleTickerProviderStateMixin {
  late final _eq = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  bool _muteHov = false, _noAnim = false;
  bool get _runEq => widget.enableAnimations && !_noAnim && !widget.snapshot.themeMuted;

  void _sync() { if (_runEq) { if (!_eq.isAnimating) _eq.repeat(reverse: true); } else if (_eq.isAnimating) { _eq.stop(); } }

  @override void initState() { super.initState(); _sync(); }
  @override void didChangeDependencies() { super.didChangeDependencies(); _noAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false; _sync(); }
  @override void didUpdateWidget(EvThemeCapsule old) { super.didUpdateWidget(old); if (old.snapshot.themeMuted != widget.snapshot.themeMuted || old.enableAnimations != widget.enableAnimations) _sync(); }
  @override void dispose() { _eq.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), muted = widget.snapshot.themeMuted, rSz = s.rem(1.75);
    final dur = widget.snapshot.themeDuration;
    final p = (dur == null || dur <= Duration.zero) ? 0.0 : (widget.snapshot.themePosition.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    const phases = [0.0, 0.38, 0.72], rest = [0.45, 0.85, 0.6];

    return EvGlass(
      key: const Key('ev_detail_theme_capsule'), borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.fromLTRB(s.rem(0.5), 0, s.rem(0.375), 0),
      child: SizedBox(
        height: s.rem(2.5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            key: const Key('ev_detail_theme_ring'), width: rSz, height: rSz,
            child: Stack(alignment: Alignment.center, children: [
              CustomPaint(key: ValueKey<double>(p), size: Size.square(rSz),
                  painter: EvRingProgressPainter(progress: p, trackColor: t.fill3, progressColor: t.ink, strokeWidth: 2)),
              AnimatedBuilder(
                animation: _eq,
                builder: (_, _) {
                  final h = s.rem(0.7);
                  return SizedBox(height: h, child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 1.5),
                      Container(
                        width: 1.5, decoration: BoxDecoration(color: t.ink, borderRadius: BorderRadius.circular(1)),
                        height: muted ? h * 0.22 : (_runEq ? h * (0.22 + 0.78 * (0.5 + 0.5 * math.sin((_eq.value + phases[i]) * 2 * math.pi))) : h * rest[i]),
                      ),
                    ],
                  ]));
                },
              ),
            ]),
          ),
          SizedBox(width: s.rem(0.625)),
          Text('主题曲', style: t.bodyStyle(s.font(0.875), color: t.ink2)),
          SizedBox(width: s.rem(0.625)),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: s.rem(11)),
            child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: t.ink)),
          ),
          SizedBox(width: s.rem(0.375)),
          Semantics(
            button: true, label: muted ? '取消静音' : '静音',
            child: Focus(
              onKeyEvent: (_, e) { if (!evIsActivateKey(e)) return KeyEventResult.ignored; widget.onToggleMute(); return KeyEventResult.handled; },
              child: MouseRegion(
                cursor: SystemMouseCursors.click, onEnter: (_) => setState(() => _muteHov = true), onExit: (_) => setState(() => _muteHov = false),
                child: GestureDetector(
                  key: const Key('ev_detail_theme_mute'), behavior: HitTestBehavior.opaque, onTap: widget.onToggleMute,
                  child: AnimatedContainer(
                    duration: EvDurations.fast, curve: EvCurves.soft, width: rSz, height: rSz, alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _muteHov ? t.fill2 : const Color(0x00000000)),
                    child: EvIcon(muted ? EvIcons.mute : EvIcons.vol, size: s.rem(1), color: t.ink),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Circular progress ring shared by theme capsule, countdown, resume pill, and AI season button.
class EvRingProgressPainter extends CustomPainter {
  const EvRingProgressPainter({required this.progress, required this.trackColor, required this.progressColor, required this.strokeWidth});
  final double progress, strokeWidth;
  final Color trackColor, progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2), r = math.max(0.0, size.shortestSide / 2 - strokeWidth / 2);
    canvas.drawCircle(c, r, Paint()..color = trackColor..style = PaintingStyle.stroke..strokeWidth = strokeWidth);
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep > 0) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, sweep, false,
          Paint()..color = progressColor..style = PaintingStyle.stroke..strokeWidth = strokeWidth..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(EvRingProgressPainter o) =>
      o.progress != progress || o.trackColor != trackColor || o.progressColor != progressColor || o.strokeWidth != strokeWidth;
}
