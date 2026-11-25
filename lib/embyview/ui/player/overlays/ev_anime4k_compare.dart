import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

const _kWhite = Color(0xFFFFFFFF);
const _kMinSplit = 0.04, _kMaxSplit = 0.96;

/// Formats a [VideoSize] height for Anime4K labels (e.g. `1080p`, `4K`).
String evFormatVideoHeight(VideoSize? size, {required String fallback}) {
  final h = size?.height ?? 0;
  return h <= 0 ? fallback : (h >= 2160 ? '4K' : '${h}p');
}

/// Evaluates the Anime4K auto-sweep curve (`0.50 -> 0.80 -> 0.22 -> 0.50`) at `t` in `[0, 1]`.
double evAnime4kSweepSplit(double t) {
  const seq = [0.50, 0.80, 0.22, 0.50];
  final seg = t.clamp(0.0, 1.0) * 3.0;
  final i = math.min(2, seg.floor()), f = seg - i;
  final e = f < 0.5 ? 2 * f * f : 1 - math.pow(-2 * f + 2, 2) / 2;
  return seq[i] + (seq[i + 1] - seq[i]) * e;
}

/// Draggable Anime4K split-line comparison overlay (`.divider` in `proto.css`).
class EvAnime4kCompareOverlay extends StatefulWidget {
  const EvAnime4kCompareOverlay({
    super.key, required this.active, required this.anime4k,
    this.split = 0.5, this.sweepNonce = 0, this.persistent = true,
    required this.onSplitChanged, required this.onEnd, this.onManualDrag,
  });

  final bool active, persistent;
  final Anime4kSnapshot anime4k;
  final double split;
  final int sweepNonce;
  final ValueChanged<double> onSplitChanged;
  final VoidCallback onEnd;
  final VoidCallback? onManualDrag;

  @override
  State<EvAnime4kCompareOverlay> createState() => _EvAnime4kCompareOverlayState();
}

class _EvAnime4kCompareOverlayState extends State<EvAnime4kCompareOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep;
  Timer? _autoEnd;
  late double _split = widget.split.clamp(_kMinSplit, _kMaxSplit);
  bool _dragged = false, _hovered = false, _pressed = false;

  @override
  void initState() {
    super.initState();
    _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))
      ..addListener(_onSweepTick)..addStatusListener(_onSweepStatus);
    if (widget.active && widget.sweepNonce > 0) _startSweep();
  }

  @override
  void didUpdateWidget(EvAnime4kCompareOverlay old) {
    super.didUpdateWidget(old);
    if (!widget.active) { _stopSweep(); _dragged = false; return; }
    if (widget.sweepNonce != old.sweepNonce && widget.sweepNonce > 0) {
      _startSweep();
    } else if (!_sweep.isAnimating && (widget.split - old.split).abs() > 0.0001) {
      _split = widget.split.clamp(_kMinSplit, _kMaxSplit);
    }
    if (widget.persistent && !old.persistent) _autoEnd?.cancel();
  }

  void _startSweep() { _stopSweep(); _dragged = false; _split = 0.5; _sweep.forward(from: 0.0); }
  void _stopSweep() { _autoEnd?.cancel(); _autoEnd = null; if (_sweep.isAnimating) _sweep.stop(); }

  void _onSweepTick() {
    if (!mounted || !widget.active || _dragged) return;
    final next = evAnime4kSweepSplit(_sweep.value).clamp(_kMinSplit, _kMaxSplit);
    if ((next - _split).abs() > 0.0005) { setState(() => _split = next); widget.onSplitChanged(next); }
  }

  void _onSweepStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted || !widget.active || _dragged || widget.persistent) return;
    _autoEnd?.cancel();
    _autoEnd = Timer(const Duration(milliseconds: 1200), () {
      if (mounted && widget.active && !_dragged && !widget.persistent) widget.onEnd();
    });
  }

  void _updateDrag(Offset globalPos) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 0) return;
    final next = (box.globalToLocal(globalPos).dx / box.size.width).clamp(_kMinSplit, _kMaxSplit);
    if ((next - _split).abs() > 0.0005) { setState(() => _split = next); widget.onSplitChanged(next); }
  }

  @override
  void dispose() { _autoEnd?.cancel(); _sweep.dispose(); super.dispose(); }

  Widget _pill(EvTheme t, EvScale s, String text) => ClipRRect(
    borderRadius: BorderRadius.circular(999),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: s.rem(0.75), vertical: s.rem(0.375)),
        color: const Color.fromRGBO(0, 0, 0, 0.5),
        child: Text(text, maxLines: 1, softWrap: false, style: t.bodyStyle(s.rem(0.875), fontWeight: FontWeight.w600, color: _kWhite)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final orig = evFormatVideoHeight(widget.anime4k.originalSize, fallback: '1080p');
    final enh = evFormatVideoHeight(widget.anime4k.enhancedSize, fallback: '4K');
    final handleSz = s.rem(3.0);

    return IgnorePointer(
      key: const Key('ev_anime4k_compare_overlay'),
      ignoring: !widget.active,
      child: AnimatedOpacity(
        opacity: widget.active ? 1.0 : 0.0, duration: const Duration(milliseconds: 400), curve: EvCurves.soft,
        child: LayoutBuilder(builder: (_, c) {
          final w = c.maxWidth, h = c.maxHeight;
          if (w <= 0 || h <= 0) return const SizedBox.expand();
          final x = _split.clamp(_kMinSplit, _kMaxSplit) * w;
          final endX = x.clamp(math.min(w / 2, s.rem(5.0)), math.max(w / 2, w - s.rem(5.0)));
          return Stack(
            fit: StackFit.expand, clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: x - 1, top: 0, bottom: 0, width: 2,
                child: const IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(color: Color.fromRGBO(255, 255, 255, 0.9), boxShadow: [BoxShadow(blurRadius: 12, color: Color.fromRGBO(0, 0, 0, 0.5))]))),
              ),
              Positioned(right: w - x + s.rem(1.0), top: s.rem(6.0), child: IgnorePointer(child: _pill(t, s, '原画 $orig'))),
              Positioned(left: x + s.rem(1.0), top: s.rem(6.0), child: IgnorePointer(child: _pill(t, s, 'Anime4K · 放大至 $enh'))),
              Positioned(
                left: 0, right: 0, top: s.rem(8.75),
                child: Align(
                  alignment: Alignment((endX / w) * 2 - 1, -1.0),
                  child: EvOnImage(child: EvButton.ghost(key: const Key('ev_compare_end'), small: true, label: '结束对比', onPressed: () { _stopSweep(); widget.onEnd(); })),
                ),
              ),
              Positioned(
                left: x - handleSz / 2, top: (h - handleSz) / 2,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
                  child: GestureDetector(
                    key: const Key('ev_compare_handle'), behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) { _stopSweep(); setState(() { _dragged = true; _pressed = true; }); widget.onManualDrag?.call(); _updateDrag(d.globalPosition); },
                    onHorizontalDragUpdate: (d) => _updateDrag(d.globalPosition),
                    onHorizontalDragEnd: (_) => setState(() => _pressed = false), onHorizontalDragCancel: () => setState(() => _pressed = false),
                    child: Semantics(
                      slider: true, label: '拖动对比原画与 Anime4K',
                      child: AnimatedScale(
                        scale: _pressed ? 0.95 : (_hovered ? 1.1 : 1.0), duration: const Duration(milliseconds: 300), curve: EvCurves.spring,
                        child: Container(
                          width: handleSz, height: handleSz,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: t.isPaper ? const Color(0xFFD97757) : const Color(0xFFF5F5F7), boxShadow: [BoxShadow(offset: Offset(0, s.rem(0.5)), blurRadius: s.rem(1.5), color: const Color.fromRGBO(0, 0, 0, 0.4))]),
                          child: Center(child: EvIcon(EvIcons.cmp, size: s.rem(1.25), color: t.isPaper ? const Color(0xFF141413) : const Color(0xFF111111))),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}
