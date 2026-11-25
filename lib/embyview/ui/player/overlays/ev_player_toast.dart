import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Top-centered player toast pill mirroring `.ptoast` across cinema & paper themes.
class EvPlayerToast extends StatelessWidget {
  const EvPlayerToast({super.key, required this.visible, required this.message, this.icon, this.iconColor});

  final bool visible;
  final String message;
  final EvIconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final isPaper = theme.isPaper;
    final fgColor = isPaper ? const Color(0xFF141413) : const Color(0xFFF5F5F7);
    final resolvedIconColor = iconColor ?? (isPaper ? const Color(0xFF5F7346) : const Color(0xFF7BE0A5));
    final pillRadius = BorderRadius.circular(999);

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: pillRadius,
        boxShadow: [BoxShadow(offset: Offset(0, scale.rem(0.5)), blurRadius: scale.rem(2.0), color: Color.fromRGBO(0, 0, 0, isPaper ? 0.25 : 0.30))],
      ),
      child: ClipRRect(
        borderRadius: pillRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isPaper ? const Color.fromRGBO(250, 249, 245, 0.92) : const Color.fromRGBO(28, 28, 33, 0.74),
              borderRadius: pillRadius,
              border: isPaper ? Border.all(color: const Color.fromRGBO(20, 20, 19, 0.08), width: 1) : null,
            ),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                if (!isPaper)
                  const Positioned(left: 1, right: 1, top: 0, height: 1, child: ColoredBox(color: Color.fromRGBO(255, 255, 255, 0.14))),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: scale.rem(1.125), vertical: scale.rem(0.75)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        EvIcon(icon!, size: scale.rem(1.125), color: resolvedIconColor),
                        SizedBox(width: scale.rem(0.625)),
                      ],
                      Flexible(
                        child: Text(
                          message, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                          style: theme.bodyStyle(scale.rem(0.9375), color: fgColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: scale.rem(5.5)),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: math.max(0.0, scale.size.width - scale.gutter * 2)),
            child: AnimatedOpacity(
              opacity: visible ? 1.0 : 0.0, duration: const Duration(milliseconds: 300), curve: EvCurves.soft,
              child: AnimatedContainer(
                key: const Key('ev_player_toast'),
                duration: const Duration(milliseconds: 450), curve: EvCurves.spring,
                transform: visible
                    ? Matrix4.identity()
                    : (Matrix4.translationValues(0.0, -scale.rem(0.5), 0.0)..multiply(Matrix4.diagonal3Values(0.96, 0.96, 1.0))),
                transformAlignment: Alignment.center,
                child: surface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
