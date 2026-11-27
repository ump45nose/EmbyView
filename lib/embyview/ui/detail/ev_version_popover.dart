import 'dart:math' as math;

import 'package:flutter/material.dart' show Colors, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Version selector trigger button placed next to Play on multi-version movies
/// (`.verbtn` in `.spec/mockups/proto.css`).
class EvVersionButton extends StatefulWidget {
  const EvVersionButton({
    super.key,
    required this.activeVersion,
    required this.totalCount,
    required this.onPressed,
    this.focusNode,
  });

  final MediaVersion activeVersion;
  final int totalCount;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  State<EvVersionButton> createState() => _EvVersionButtonState();
}

class _EvVersionButtonState extends State<EvVersionButton> {
  bool _hovered = false, _focused = false, _pressed = false;
  bool get _hi => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final v = widget.activeVersion;
    final height = s.rem(3.25);
    final radius = BorderRadius.circular(t.isPaper ? s.rem(0.625) : 999.0);

    final Color fgColor;
    final Color bgColor;
    Color? borderColor;
    List<BoxShadow>? shadows;
    var useGlass = false;

    if (t.isPaper && t.onImage) {
      fgColor = Colors.white;
      bgColor = Color.fromRGBO(255, 255, 255, _hi ? 0.24 : 0.14);
      borderColor = const Color.fromRGBO(255, 255, 255, 0.28);
      useGlass = true;
    } else if (t.isPaper) {
      fgColor = t.ink;
      bgColor = _hi ? const Color(0xFFF0EEE6) : Colors.white;
      borderColor = const Color(0xFFD1CFC5);
    } else {
      fgColor = t.ink;
      bgColor = _hi ? t.fill3 : t.glass;
      borderColor = t.glassBorder;
      shadows = t.glassShadow;
      useGlass = !_hi;
    }

    final pillBg = t.indBg;
    final pillFg = t.indFg;

    final inner = SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsets.fromLTRB(s.rem(0.5), 0, s.rem(1.125), 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: s.rem(2.125),
              constraints: BoxConstraints(minWidth: s.rem(2.75)),
              padding: EdgeInsets.symmetric(horizontal: s.rem(0.5)),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: pillBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                v.resolution,
                style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w800, color: pillFg).copyWith(
                  letterSpacing: s.font(0.875) * 0.02,
                ),
              ),
            ),
            SizedBox(width: s.rem(0.625)),
            Text(
              v.buttonSubtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.bodyStyle(s.font(1.0625), fontWeight: FontWeight.w600, color: fgColor),
            ),
            SizedBox(width: s.rem(0.625)),
            Text(
              '${widget.totalCount} 个版本',
              style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w500, color: t.ink3),
            ),
            SizedBox(width: s.rem(0.5)),
            EvIcon(
              EvIcons.down,
              size: s.rem(1.0),
              color: fgColor.withValues(alpha: fgColor.a * 0.7),
            ),
          ],
        ),
      ),
    );

    final surface = useGlass
        ? EvGlass(
            borderRadius: radius,
            color: bgColor,
            borderColor: borderColor,
            shadows: shadows,
            blurSigma: t.isPaper ? 20 : null,
            child: inner,
          )
        : AnimatedContainer(
            duration: EvDurations.fast,
            curve: EvCurves.soft,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: radius,
              border: borderColor != null ? Border.all(color: borderColor, width: 1) : null,
              boxShadow: shadows,
            ),
            child: inner,
          );

    return Semantics(
      button: true,
      label: '选择版本，当前 ${v.resolution} ${v.buttonSubtitle}，共 ${widget.totalCount} 个版本',
      child: Tooltip(
        message: '选择版本',
        child: Focus(
          focusNode: widget.focusNode,
          onFocusChange: (val) => setState(() => _focused = val),
          onKeyEvent: (_, event) {
            if (!evIsActivateKey(event)) return KeyEventResult.ignored;
            widget.onPressed();
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
              onTap: widget.onPressed,
              child: AnimatedScale(
                scale: _pressed ? 0.96 : _hi ? 1.04 : 1.0,
                duration: EvDurations.normal,
                curve: EvCurves.spring,
                child: surface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Anchored popover listing all available [MediaVersion] entries for a movie
/// (`.pop.glass.verpop` in `.spec/mockups/proto.css` & `openVer` in `proto.js`).
class EvVersionPopover extends StatelessWidget {
  const EvVersionPopover({
    super.key,
    required this.versions,
    required this.activeVersion,
    required this.defaultRule,
    required this.warnHighBitrate,
    required this.anchorRect,
    required this.onSelect,
    required this.onOpenPlaySettings,
    required this.onDismiss,
  });

  final List<MediaVersion> versions;
  final MediaVersion activeVersion;
  final DefaultVersionRule defaultRule;
  final bool warnHighBitrate;
  final Rect anchorRect;
  final ValueChanged<MediaVersion> onSelect;
  final VoidCallback onOpenPlaySettings;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final vw = s.size.width > 0 ? s.size.width : 1440.0;
    final vh = s.size.height > 0 ? s.size.height : 900.0;
    final popW = math.min(s.rem(34), math.max(s.rem(20), vw - s.rem(2)));
    final left = anchorRect.left.clamp(s.rem(1), math.max(s.rem(1), vw - popW - s.rem(1))).toDouble();
    final bottom = (vh - anchorRect.top + 10.0).clamp(s.rem(1), math.max(s.rem(1), vh - s.rem(8))).toDouble();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onDismiss,
      },
      child: FocusScope(
        autofocus: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('ev_version_popover_scrim'),
                behavior: HitTestBehavior.translucent,
                onTap: onDismiss,
              ),
            ),
            Positioned(
              left: left,
              bottom: bottom,
              width: popW,
              child: EvGlass(
                key: const Key('ev_version_popover'),
                borderRadius: BorderRadius.circular(s.rem(1.125)),
                padding: EdgeInsets.all(s.rem(0.5)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(s.rem(0.75), s.rem(0.625), s.rem(0.75), s.rem(0.75)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '选择版本',
                            style: t.bodyStyle(s.font(1.125), fontWeight: FontWeight.w700, color: t.ink),
                          ),
                          SizedBox(width: s.rem(0.75)),
                          Expanded(
                            child: Text(
                              '${versions.length} 个版本 · 选了会记在这部片上',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodyStyle(s.font(0.875), color: t.ink3),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: math.max(s.rem(12), vh * 0.55)),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final v in versions)
                              _EvVersionRow(
                                key: Key('ev_version_row_${v.id}'),
                                version: v,
                                selected: v.id == activeVersion.id,
                                warnHighBitrate: warnHighBitrate,
                                onTap: () => onSelect(v),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Container(
                      margin: EdgeInsets.only(top: s.rem(0.375)),
                      padding: EdgeInsets.fromLTRB(s.rem(0.75), s.rem(0.75), s.rem(0.75), s.rem(0.375)),
                      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.line))),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                style: t.bodyStyle(s.font(0.875), color: t.ink3),
                                children: [
                                  const TextSpan(text: '没选过时默认 '),
                                  TextSpan(
                                    text: defaultVersionRuleSentenceLabel(defaultRule),
                                    style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w600, color: t.ink),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          SizedBox(width: s.rem(1)),
                          EvButton.ghost(
                            key: const Key('ev_version_open_settings'),
                            small: true,
                            glass: false,
                            label: '改默认规则',
                            onPressed: onOpenPlaySettings,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EvVersionRow extends StatefulWidget {
  const _EvVersionRow({
    super.key,
    required this.version,
    required this.selected,
    required this.warnHighBitrate,
    required this.onTap,
  });

  final MediaVersion version;
  final bool selected;
  final bool warnHighBitrate;
  final VoidCallback onTap;

  @override
  State<_EvVersionRow> createState() => _EvVersionRowState();
}

class _EvVersionRowState extends State<_EvVersionRow> {
  bool _hovered = false, _focused = false;
  bool get _hi => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), v = widget.version;
    final rowBg = _hi
        ? t.fill2
        : widget.selected
        ? (t.isPaper ? const Color(0xFFF0EEE6) : t.fill)
        : Colors.transparent;

    final badge = Container(
      width: s.rem(4),
      height: s.rem(2.5),
      alignment: Alignment.center,
      decoration: v.is4k
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(s.rem(0.625)),
              color: t.isPaper ? const Color(0xFFD97757) : null,
              gradient: t.isPaper
                  ? null
                  : const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFF1D18A), Color(0xFFC99A45)],
                    ),
            )
          : BoxDecoration(
              borderRadius: BorderRadius.circular(s.rem(0.625)),
              border: Border.all(color: t.fill3, width: 1.5),
            ),
      child: Text(
        v.resolution,
        style: t.bodyStyle(
          s.font(1.0),
          fontWeight: FontWeight.w800,
          color: v.is4k ? (t.isPaper ? Colors.white : const Color(0xFF1D1406)) : t.ink2,
        ),
      ),
    );

    final isDv =
        v.videoRange != null &&
        (v.videoRange!.toLowerCase().contains('dolby') || v.videoRange!.contains('杜比'));
    final metaParts = <String>[
      if (v.formattedSizeGb.isNotEmpty) v.formattedSizeGb,
      if (v.formattedBitrateMbps.isNotEmpty) v.formattedBitrateMbps,
      v.origin == MediaOrigin.direct115 ? '115 网盘直连' : 'NAS 本地文件',
    ];
    final showWarn = widget.warnHighBitrate && v.isHighBitrate;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${v.resolution} ${v.name}',
      child: Focus(
        onFocusChange: (val) => setState(() => _focused = val),
        onKeyEvent: (_, event) {
          if (!evIsActivateKey(event)) return KeyEventResult.ignored;
          widget.onTap();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: EdgeInsets.symmetric(horizontal: s.rem(0.75), vertical: s.rem(0.875)),
              decoration: BoxDecoration(
                color: rowBg,
                borderRadius: BorderRadius.circular(s.rem(0.875)),
                border: _focused ? Border.all(color: t.focusColor, width: 1.5) : null,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  badge,
                  SizedBox(width: s.rem(1)),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                v.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodyStyle(s.font(1.0625), fontWeight: FontWeight.w600, color: t.ink),
                              ),
                            ),
                            if (widget.selected) ...[
                              SizedBox(width: s.rem(0.5)),
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: s.rem(0.4375), vertical: s.rem(0.125)),
                                decoration: BoxDecoration(
                                  color: t.fill2,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '正在用',
                                  style: t.bodyStyle(s.font(0.75), fontWeight: FontWeight.w600, color: t.ink2),
                                ),
                              ),
                            ],
                          ],
                        ),
                        SizedBox(height: s.rem(0.4375)),
                        Wrap(
                          spacing: s.rem(0.375),
                          runSpacing: s.rem(0.25),
                          children: [
                            EvQualityBadge(
                              label: (v.videoRange != null && v.videoRange!.isNotEmpty) ? v.videoRange! : 'SDR',
                              kind: isDv ? EvQualityBadgeKind.dolbyVision : EvQualityBadgeKind.standard,
                            ),
                            if (v.videoCodec != null && v.videoCodec!.isNotEmpty)
                              EvQualityBadge(label: v.videoCodec!),
                            if (v.audioLabel != null && v.audioLabel!.isNotEmpty)
                              EvQualityBadge(label: v.audioLabel!),
                          ],
                        ),
                        SizedBox(height: s.rem(0.4375)),
                        Text.rich(
                          TextSpan(
                            style: t.bodyStyle(s.font(0.875), color: t.ink3),
                            children: [
                              TextSpan(text: metaParts.join(' · ')),
                              if (showWarn) ...[
                                const TextSpan(text: ' · '),
                                TextSpan(
                                  text: '外网较慢时可能卡顿',
                                  style: t.bodyStyle(
                                    s.font(0.875),
                                    fontWeight: FontWeight.w500,
                                    color: t.isPaper ? const Color(0xFFB56B12) : const Color(0xFFF0A64A),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: s.rem(1)),
                  SizedBox(
                    width: s.rem(1.5),
                    child: widget.selected
                        ? Center(child: EvIcon(EvIcons.check, size: s.rem(1.25), color: t.ink))
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
