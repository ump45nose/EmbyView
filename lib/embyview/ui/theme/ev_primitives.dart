import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide ThemeMode;
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Switches its subtree to `.onimage` light ink and dark frosted glass variables
/// so controls laid over hero/detail stills stay legible in paper theme.
class EvOnImage extends StatelessWidget {
  const EvOnImage({super.key, this.enabled = true, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final t = EvTheme.of(context).toOnImage();
    return Theme(
      data: t.toThemeData(),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: t.ink),
        child: IconTheme.merge(data: IconThemeData(color: t.ink), child: child),
      ),
    );
  }
}

/// Frosted glass container mirroring `.glass` in `proto.css`.
class EvGlass extends StatelessWidget {
  const EvGlass({
    super.key, this.borderRadius, this.padding, this.color, this.solid = false,
    this.blurSigma, this.borderColor, this.shadows, required this.child,
  });

  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final Color? color, borderColor;
  final bool solid;
  final double? blurSigma;
  final List<BoxShadow>? shadows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final radius = borderRadius ?? BorderRadius.circular(EvScale.of(context).rem(theme.radius));
    final sigma = solid ? 0.0 : (blurSigma ?? theme.blurSigma);
    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? (solid ? theme.glassSolid : theme.glass),
        borderRadius: radius,
        border: Border.all(color: borderColor ?? theme.glassBorder, width: 1),
      ),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          if (theme.glassEdge.a > 0 && !solid)
            Positioned(left: 1, right: 1, top: 0, height: 1,
              child: IgnorePointer(child: ColoredBox(color: theme.glassEdge))),
          if (padding != null) Padding(padding: padding!, child: child) else child,
        ],
      ),
    );
    if (sigma > 0) {
      content = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: content,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows ?? theme.glassShadow),
      child: ClipRRect(borderRadius: radius, child: content),
    );
  }
}

enum EvButtonVariant { primary, ghost }

/// Action button mirroring `.btn`, `.btn.primary`, `.btn.ghost`, `.btn.round`,
/// `.btn.sm`, and `.btn .edge` progress indicator from `proto.css`.
class EvButton extends StatefulWidget {
  const EvButton({
    super.key, this.variant = EvButtonVariant.primary, this.small = false,
    this.round = false, this.glass = true, this.icon, this.label,
    this.secondaryLabel, this.progress, this.tooltip, this.child, this.onPressed,
  });

  const EvButton.primary({
    super.key, this.small = false, this.round = false, this.icon, this.label,
    this.secondaryLabel, this.progress, this.tooltip, this.child, this.onPressed,
  }) : variant = EvButtonVariant.primary, glass = false;

  const EvButton.ghost({
    super.key, this.small = false, this.round = false, this.glass = true,
    this.icon, this.label, this.secondaryLabel, this.tooltip, this.child, this.onPressed,
  }) : variant = EvButtonVariant.ghost, progress = null;

  final EvButtonVariant variant;
  final bool small, round, glass;
  final EvIconData? icon;
  final String? label, secondaryLabel, tooltip;
  final double? progress;
  final Widget? child;
  final VoidCallback? onPressed;

  @override
  State<EvButton> createState() => _EvButtonState();
}

class _EvButtonState extends State<EvButton> {
  bool _hovered = false, _focused = false, _pressed = false;
  bool get _enabled => widget.onPressed != null;
  bool get _highlighted => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final height = scale.rem(widget.small ? 2.375 : 3.25);
    final hPad = widget.round ? 0.0 : scale.rem(widget.small ? 1.0625 : 1.625);
    final fontSize = scale.rem(widget.small ? 0.9375 : 1.0625);
    final radius = BorderRadius.circular(theme.isPaper ? scale.rem(0.625) : 999.0);
    final isPrimary = widget.variant == EvButtonVariant.primary;

    final Color fgColor;
    final Color bgColor;
    Color? borderColor;
    List<BoxShadow>? shadows;
    if (isPrimary) {
      fgColor = theme.priFg;
      bgColor = _highlighted && theme.isPaper ? const Color(0xFF9F4829) : theme.priBg;
      if (_highlighted && !theme.isPaper) shadows = [BoxShadow(color: theme.fill2, spreadRadius: 4)];
    } else if (theme.isPaper && theme.onImage) {
      fgColor = Colors.white;
      bgColor = Color.fromRGBO(255, 255, 255, _highlighted ? 0.24 : 0.14);
      borderColor = const Color.fromRGBO(255, 255, 255, 0.28);
    } else if (theme.isPaper) {
      fgColor = theme.ink;
      bgColor = _highlighted ? const Color(0xFFF0EEE6) : Colors.white;
      borderColor = const Color(0xFFD1CFC5);
    } else {
      fgColor = theme.ink;
      bgColor = _highlighted ? theme.fill3 : (widget.glass ? theme.glass : Colors.transparent);
      if (widget.glass) {
        borderColor = theme.glassBorder;
        shadows = theme.glassShadow;
      }
    }

    final inner = widget.child ??
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.icon != null) EvIcon(widget.icon!, size: scale.rem(1.125), color: fgColor),
            if (widget.icon != null && widget.label != null) SizedBox(width: scale.rem(0.5)),
            if (widget.label != null)
              Text(widget.label!, style: theme.bodyStyle(fontSize, fontWeight: FontWeight.w600, color: fgColor)),
            if (widget.secondaryLabel != null) ...[
              SizedBox(width: scale.rem(0.375)),
              Text(
                widget.secondaryLabel!,
                style: theme.bodyStyle(fontSize, fontWeight: FontWeight.w500, color: fgColor.withValues(alpha: fgColor.a * 0.66)),
              ),
            ],
          ],
        );

    final body = SizedBox(
      height: height,
      width: widget.round ? height : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(padding: EdgeInsets.symmetric(horizontal: hPad), child: inner),
          if (widget.progress != null && isPrimary && !widget.round)
            Positioned(
              left: scale.rem(1.375), right: scale.rem(1.375), bottom: scale.rem(0.4375), height: 2,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(1),
                child: ColoredBox(
                  color: theme.isPaper ? const Color.fromRGBO(255, 255, 255, 0.30) : fgColor.withValues(alpha: 0.18),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: widget.progress!.clamp(0.0, 1.0),
                      child: ColoredBox(color: fgColor),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final surface = !isPrimary && widget.glass && !theme.isPaper && !_highlighted
        ? EvGlass(borderRadius: radius, color: bgColor, borderColor: borderColor, shadows: shadows, child: body)
        : AnimatedContainer(
            duration: EvDurations.fast, curve: EvCurves.soft,
            decoration: BoxDecoration(
              color: bgColor, borderRadius: radius,
              border: borderColor != null ? Border.all(color: borderColor, width: 1) : null,
              boxShadow: shadows,
            ),
            child: body,
          );

    Widget button = Focus(
      canRequestFocus: _enabled,
      onFocusChange: (v) => setState(() => _focused = v),
      child: MouseRegion(
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          onTap: widget.onPressed,
          child: AnimatedScale(
            scale: !_enabled ? 1.0 : _pressed ? 0.96 : _highlighted ? 1.04 : 1.0,
            duration: EvDurations.normal, curve: EvCurves.spring,
            child: Opacity(opacity: _enabled ? 1.0 : 0.45, child: surface),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) button = Tooltip(message: widget.tooltip!, child: button);
    return Semantics(button: true, enabled: _enabled, label: widget.tooltip ?? widget.label, child: button);
  }
}

/// Community rating badge mirroring `.meta .sc` in `proto.css`.
class EvScoreBadge extends StatelessWidget {
  const EvScoreBadge({super.key, required this.score});
  final double score;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    return Container(
      height: scale.rem(1.75),
      padding: EdgeInsets.symmetric(horizontal: scale.rem(0.625)),
      decoration: BoxDecoration(
        color: theme.fill2,
        borderRadius: BorderRadius.circular(scale.rem(0.4375)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          EvIcon(EvIcons.star, size: scale.rem(0.875),
              color: theme.isPaper ? theme.brand : const Color(0xFFF5C451)),
          SizedBox(width: scale.rem(0.3125)),
          Text(
            score.toStringAsFixed(1),
            style: theme.bodyStyle(
              math.max(scale.minFontSize, scale.rem(0.9375)),
              fontWeight: FontWeight.w700, color: theme.ink,
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

enum EvQualityBadgeKind { standard, dolbyVision, source }

/// Technical quality / source pill mirroring `.q`, `.q.dv`, and `.q.src`.
class EvQualityBadge extends StatelessWidget {
  const EvQualityBadge({super.key, required this.label, this.kind = EvQualityBadgeKind.standard});
  final String label;
  final EvQualityBadgeKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final isDv = kind == EvQualityBadgeKind.dolbyVision;
    final isSrc = kind == EvQualityBadgeKind.source;
    final radius = BorderRadius.circular(scale.rem(0.375));
    final decoration = isDv && !theme.isPaper
        ? BoxDecoration(
            gradient: LinearGradient(colors: [
              theme.fg.withValues(alpha: 0.18), theme.fg.withValues(alpha: 0.06),
            ]),
            borderRadius: radius,
          )
        : (isDv || isSrc)
        ? BoxDecoration(color: theme.fill2, borderRadius: radius)
        : BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: theme.isPaper
                  ? (theme.onImage ? const Color.fromRGBO(255, 255, 255, 0.32) : const Color(0xFFD1CFC5))
                  : theme.fill3,
              width: 1.25,
            ),
          );
    final fontSize = scale.rem(isSrc ? 0.8125 : 0.75);
    return Container(
      height: scale.rem(1.5),
      padding: EdgeInsets.symmetric(horizontal: scale.rem(0.5)),
      decoration: decoration,
      alignment: Alignment.center,
      child: Text(
        isDv ? label.toUpperCase() : label,
        style: theme.bodyStyle(
          fontSize,
          fontWeight: isSrc ? FontWeight.w600 : FontWeight.w700,
          color: (isDv || isSrc) ? theme.ink : theme.ink2,
        ).copyWith(letterSpacing: isSrc ? 0 : fontSize * 0.04),
      ),
    );
  }
}
