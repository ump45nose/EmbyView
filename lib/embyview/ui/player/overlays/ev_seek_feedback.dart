import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Left / right frosted seek-feedback bubbles mirroring `.seekfx` and `seekFx()`.
class EvSeekFeedbackOverlay extends StatefulWidget {
  const EvSeekFeedbackOverlay({
    super.key, required this.leftNonce, required this.rightNonce,
    this.leftLabel = '-10 秒', this.rightLabel = '+10 秒',
  });

  final int leftNonce, rightNonce;
  final String leftLabel, rightLabel;

  @override
  State<EvSeekFeedbackOverlay> createState() => _EvSeekFeedbackOverlayState();
}

class _EvSeekFeedbackOverlayState extends State<EvSeekFeedbackOverlay> with TickerProviderStateMixin {
  late final _leftCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final _rightCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void didUpdateWidget(EvSeekFeedbackOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.leftNonce > oldWidget.leftNonce) _leftCtrl.forward(from: 0.0);
    if (widget.rightNonce > oldWidget.rightNonce) _rightCtrl.forward(from: 0.0);
  }

  @override
  void dispose() {
    _leftCtrl.dispose();
    _rightCtrl.dispose();
    super.dispose();
  }

  Widget _buildBubble(Key key, AnimationController ctrl, EvIconData icon, String label, EvTheme theme, EvScale scale) {
    final diameter = scale.rem(9.0);
    final inner = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        EvIcon(icon, size: scale.rem(2.0), color: const Color(0xFFFFFFFF)),
        SizedBox(height: scale.rem(0.25)),
        Text(label, style: theme.bodyStyle(scale.rem(1.0), fontWeight: FontWeight.w600, color: const Color(0xFFFFFFFF))),
      ],
    );
    return KeyedSubtree(
      key: key,
      child: AnimatedBuilder(
        animation: ctrl,
        builder: (_, child) {
          final double opacity, bubbleScale;
          if (!ctrl.isAnimating) {
            (opacity, bubbleScale) = (0.0, 0.7);
          } else if (ctrl.value <= 0.3) {
            final u = EvCurves.out.transform((ctrl.value / 0.3).clamp(0.0, 1.0));
            (opacity, bubbleScale) = (u, 0.7 + 0.3 * u);
          } else {
            final u = EvCurves.out.transform(((ctrl.value - 0.3) / 0.7).clamp(0.0, 1.0));
            (opacity, bubbleScale) = (1.0 - u, 1.0 + 0.1 * u);
          }
          Widget bubble = Container(
            width: diameter, height: diameter, alignment: Alignment.center,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Color.fromRGBO(255, 255, 255, 0.12)),
            child: child,
          );
          if (opacity > 0.001) {
            bubble = ClipOval(child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16), child: bubble));
          }
          return Opacity(opacity: opacity.clamp(0.0, 1.0), child: Transform.scale(scale: bubbleScale, child: bubble));
        },
        child: inner,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final edge = scale.vw(12);
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: edge, top: 0, bottom: 0,
            child: Center(child: _buildBubble(const Key('ev_seek_fx_left'), _leftCtrl, EvIcons.back10, widget.leftLabel, theme, scale)),
          ),
          Positioned(
            right: edge, top: 0, bottom: 0,
            child: Center(child: _buildBubble(const Key('ev_seek_fx_right'), _rightCtrl, EvIcons.fwd10, widget.rightLabel, theme, scale)),
          ),
        ],
      ),
    );
  }
}
