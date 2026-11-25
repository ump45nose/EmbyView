import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/panel/ev_audio_video_tabs.dart';
import 'package:moonfin/embyview/ui/player/panel/ev_subtitle_tab.dart';

const _kPaperInk = Color(0xFF141413), _kPaperSub = Color(0xFF66655F), _kCinemaInk = Color(0xFFF5F5F7);

/// Lightweight clickable wrapper with pointer cursor used across panel tabs.
Widget evPanelTap({Key? key, VoidCallback? onTap, required Widget child}) => MouseRegion(
  cursor: onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
  child: GestureDetector(key: key, behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
);

/// Shared palette tokens for the right-hand player panel across cinema & paper themes.
class EvPanelPalette {
  const EvPanelPalette._(this.isPaper);
  factory EvPanelPalette.of(EvTheme theme) => theme.isPaper ? paper : cinema;

  static const cinema = EvPanelPalette._(false);
  static const paper = EvPanelPalette._(true);

  final bool isPaper;
  Color get ink => isPaper ? _kPaperInk : _kCinemaInk;
  Color get subInk => isPaper ? _kPaperSub : const Color.fromRGBO(255, 255, 255, 0.55);
  Color get cardBg => isPaper ? const Color(0xFFFFFFFF) : const Color.fromRGBO(255, 255, 255, 0.05);
  Color get cardBorder => isPaper ? const Color(0xFFE8E6DC) : const Color.fromRGBO(255, 255, 255, 0.08);
  Color get rowHover => isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.07);
  Color get rowSelected => isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.10);
  Color get badgeBg => isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.10);
  Color get badgeFg => isPaper ? const Color(0xFF3D3D3A) : const Color.fromRGBO(255, 255, 255, 0.85);
  Color get checkColor => isPaper ? const Color(0xFFB5532F) : const Color(0xFFFFFFFF);
  Color get segBg => isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.08);
  Color get segActiveBg => isPaper ? const Color(0xFFFFFFFF) : const Color.fromRGBO(255, 255, 255, 0.18);
  Color get segActiveFg => isPaper ? _kPaperInk : const Color(0xFFFFFFFF);
  Color get segInactiveFg => isPaper ? _kPaperSub : const Color.fromRGBO(255, 255, 255, 0.72);
  Color get primaryBg => isPaper ? const Color(0xFFB5532F) : const Color(0xFFF5F5F7);
  Color get primaryFg => isPaper ? const Color(0xFFFFFFFF) : const Color(0xFF0B0B0D);
  Color get ghostBg => isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.10);
  Color get ghostFg => isPaper ? _kPaperInk : const Color(0xFFFFFFFF);
  Color get toggleOff => isPaper ? const Color(0xFFD1CFC5) : const Color.fromRGBO(255, 255, 255, 0.20);
  Color get toggleOn => isPaper ? const Color(0xFFB5532F) : const Color(0xFF34C759);
}

/// Section heading (`h5`) inside the player side panel.
class EvPanelHeading extends StatelessWidget {
  const EvPanelHeading(this.title, {super.key, this.trailing, this.topMargin = 1.375});
  final String title;
  final String? trailing;
  final double topMargin;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = EvPanelPalette.of(t);
    return Padding(
      padding: EdgeInsets.fromLTRB(s.rem(0.25), s.rem(topMargin), s.rem(0.25), s.rem(0.625)),
      child: Row(children: [
        Text(title, style: t.bodyStyle(s.rem(0.875), fontWeight: FontWeight.w600, color: pal.subInk)),
        if (trailing?.isNotEmpty == true) ...[
          const Spacer(),
          Text(trailing!, style: t.bodyStyle(s.rem(0.875), fontWeight: FontWeight.w500, color: pal.subInk)),
        ],
      ]),
    );
  }
}

/// Track selection row (`.trk`) shared by subtitle and audio tabs.
class EvPanelTrackRow extends StatefulWidget {
  const EvPanelTrackRow({
    super.key, required this.badge, required this.title, this.subtitle,
    required this.selected, required this.onTap, this.trailingAction,
  });
  final Widget badge;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailingAction;
  @override State<EvPanelTrackRow> createState() => _EvPanelTrackRowState();
}

class _EvPanelTrackRowState extends State<EvPanelTrackRow> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = EvPanelPalette.of(t);
    final bg = widget.selected ? pal.rowSelected : (_hov ? pal.rowHover : const Color(0x00000000));
    return Semantics(
      button: true, selected: widget.selected, label: widget.title,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hov = true), onExit: (_) => setState(() => _hov = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.symmetric(horizontal: s.rem(0.75), vertical: s.rem(0.625)),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(s.rem(0.75))),
            child: Row(children: [
              widget.badge,
              SizedBox(width: s.rem(0.875)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(1.0), color: pal.ink)),
                  if (widget.subtitle?.isNotEmpty == true)
                    Padding(
                      padding: EdgeInsets.only(top: s.rem(0.125)),
                      child: Text(widget.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.8125), color: pal.subInk)),
                    ),
                ]),
              ),
              if (widget.trailingAction != null) ...[SizedBox(width: s.rem(0.5)), widget.trailingAction!],
              SizedBox(width: s.rem(0.5)),
              AnimatedOpacity(
                opacity: widget.selected ? 1.0 : 0.0, duration: const Duration(milliseconds: 250),
                child: AnimatedScale(
                  scale: widget.selected ? 1.0 : 0.4, duration: const Duration(milliseconds: 450), curve: EvCurves.spring,
                  child: EvIcon(EvIcons.check, size: s.rem(1.375), color: pal.checkColor),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Compact pill button styled specifically for the player side panel.
class EvPanelButton extends StatefulWidget {
  const EvPanelButton({super.key, required this.label, this.icon, this.primary = false, this.enabled = true, this.onPressed});
  final String label;
  final EvIconData? icon;
  final bool primary, enabled;
  final VoidCallback? onPressed;
  @override State<EvPanelButton> createState() => _EvPanelButtonState();
}

class _EvPanelButtonState extends State<EvPanelButton> {
  bool _hov = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = EvPanelPalette.of(t);
    final on = widget.enabled && widget.onPressed != null;
    final fg = widget.primary ? pal.primaryFg : pal.ghostFg;
    return Semantics(
      button: true, enabled: on, label: widget.label,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hov = true), onExit: (_) => setState(() { _hov = false; _down = false; }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: on ? (_) => setState(() => _down = true) : null,
          onTapUp: on ? (_) => setState(() => _down = false) : null,
          onTapCancel: on ? () => setState(() => _down = false) : null,
          onTap: on ? widget.onPressed : null,
          child: Opacity(
            opacity: on ? 1.0 : 0.42,
            child: AnimatedScale(
              scale: !on ? 1.0 : (_down ? 0.96 : (_hov ? 1.01 : 1.0)),
              duration: const Duration(milliseconds: 250), curve: EvCurves.spring,
              child: Container(
                height: s.rem(2.375), padding: EdgeInsets.symmetric(horizontal: s.rem(1.0)),
                decoration: BoxDecoration(
                  color: widget.primary ? pal.primaryBg : pal.ghostBg,
                  borderRadius: BorderRadius.circular(pal.isPaper ? s.rem(0.625) : 999),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (widget.icon != null) ...[EvIcon(widget.icon!, size: s.rem(1.0625), color: fg), SizedBox(width: s.rem(0.45))],
                  Flexible(child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.9375), fontWeight: FontWeight.w600, color: fg))),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Right-hand player side panel (`.panel` in `proto.css`) with animated spring
/// slide-in, three sliding tabs (`字幕` / `音频` / `画面`), and dual themes.
class EvPlayerPanel extends StatefulWidget {
  const EvPlayerPanel({
    super.key, required this.open, required this.activeTab, required this.snapshot,
    this.subtitleSnapshot, this.subtitlePanel, this.subtitles, this.initialLowerTab,
    required this.onSelectTab, required this.onClose, required this.onSelectSubtitle,
    required this.onSelectAudio, required this.onSeek, required this.onToggleAnime4k,
    required this.onStartCompare, this.onToast,
  });

  final bool open;
  final String activeTab;
  final PlaybackSnapshot snapshot;
  final SubtitleSnapshot? subtitleSnapshot;
  final SubtitlePanel? subtitlePanel;
  final EmbyViewSubtitles? subtitles;
  final String? initialLowerTab;
  final ValueChanged<String> onSelectTab, onSelectAudio;
  final ValueChanged<String?> onSelectSubtitle;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onClose, onToggleAnime4k, onStartCompare;
  final void Function(String message, {EvIconData? icon})? onToast;

  @override State<EvPlayerPanel> createState() => _EvPlayerPanelState();
}

class _EvPlayerPanelState extends State<EvPlayerPanel> {
  bool _closeHov = false;

  static const _tabs = [
    ('subs', '字幕', EvIcons.cc, Key('ev_panel_tab_subs')),
    ('audio', '音频', EvIcons.audio, Key('ev_panel_tab_audio')),
    ('video', '画面', EvIcons.image, Key('ev_panel_tab_video')),
  ];

  String get _tab => widget.activeTab == 'pic' ? 'video' : widget.activeTab;
  int get _tabIndex { final i = _tabs.indexWhere((t) => t.$1 == _tab); return i < 0 ? 0 : i; }

  Widget _header(EvTheme t, EvScale s, EvPanelPalette pal) {
    final dimFg = pal.isPaper ? _kPaperSub : const Color.fromRGBO(255, 255, 255, 0.62);
    return Padding(
      padding: EdgeInsets.fromLTRB(s.rem(1.125), s.rem(1.125), s.rem(1.125), s.rem(0.75)),
      child: Row(children: [
        Expanded(child: Container(
          padding: EdgeInsets.all(s.rem(0.25)),
          decoration: BoxDecoration(color: pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.07), borderRadius: BorderRadius.circular(s.rem(0.875))),
          child: LayoutBuilder(builder: (_, c) => Stack(children: [
            Positioned.fill(child: AnimatedAlign(
              duration: const Duration(milliseconds: 500), curve: EvCurves.spring, alignment: Alignment(-1.0 + _tabIndex * 1.0, 0),
              child: Container(
                width: c.maxWidth / 3, height: s.rem(2.25),
                decoration: BoxDecoration(
                  color: pal.isPaper ? const Color(0xFFFFFFFF) : const Color.fromRGBO(255, 255, 255, 0.16),
                  borderRadius: BorderRadius.circular(s.rem(0.625)),
                  boxShadow: [BoxShadow(offset: const Offset(0, 1), blurRadius: pal.isPaper ? 3 : 4, color: pal.isPaper ? const Color.fromRGBO(20, 20, 19, 0.12) : const Color.fromRGBO(0, 0, 0, 0.25))],
                ),
              ),
            )),
            Row(children: [
              for (final (id, label, icon, key) in _tabs)
                Expanded(child: Semantics(
                  button: true, selected: _tab == id, label: label,
                  child: evPanelTap(
                    key: key, onTap: () => widget.onSelectTab(id),
                    child: SizedBox(
                      height: s.rem(2.25),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, spacing: s.rem(0.4375), children: [
                        EvIcon(icon, size: s.rem(1.125), color: _tab == id ? pal.ink : dimFg),
                        Text(label, maxLines: 1, style: t.bodyStyle(s.rem(0.9375), fontWeight: FontWeight.w600, color: _tab == id ? pal.ink : dimFg)),
                      ]),
                    ),
                  ),
                )),
            ]),
          ])),
        )),
        SizedBox(width: s.rem(0.5)),
        Semantics(
          button: true, label: '关闭',
          child: MouseRegion(
            cursor: SystemMouseCursors.click, onEnter: (_) => setState(() => _closeHov = true), onExit: (_) => setState(() => _closeHov = false),
            child: GestureDetector(
              key: const Key('ev_panel_close'), behavior: HitTestBehavior.opaque, onTap: widget.onClose,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200), width: s.rem(2.25), height: s.rem(2.25),
                decoration: BoxDecoration(shape: BoxShape.circle, color: _closeHov ? (pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.12)) : const Color(0x00000000)),
                child: Center(child: AnimatedRotation(turns: _closeHov ? 0.25 : 0.0, duration: const Duration(milliseconds: 300), curve: EvCurves.spring, child: EvIcon(EvIcons.x, size: s.rem(0.9375), color: pal.ink))),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = EvPanelPalette.of(t);
    final panelW = s.rem(28.0), radius = BorderRadius.circular(s.rem(1.75));
    final body = switch (_tab) {
      'audio' => EvAudioTab(snapshot: widget.snapshot, onSelectAudio: widget.onSelectAudio),
      'video' => EvVideoTab(snapshot: widget.snapshot, onToggleAnime4k: widget.onToggleAnime4k, onStartCompare: widget.onStartCompare),
      _ => EvSubtitleTab(
          snapshot: widget.snapshot, subtitleSnapshot: widget.subtitleSnapshot, subtitlePanel: widget.subtitlePanel,
          subtitles: widget.subtitles, initialLowerTab: widget.initialLowerTab,
          onSelectSubtitle: widget.onSelectSubtitle, onSeek: widget.onSeek, onToast: widget.onToast,
        ),
    };

    return Positioned(
      top: s.rem(1.0), right: s.rem(1.0), bottom: s.rem(1.0), width: panelW,
      child: IgnorePointer(
        ignoring: !widget.open,
        child: AnimatedContainer(
          key: const Key('ev_player_panel'), duration: const Duration(milliseconds: 700), curve: EvCurves.spring, transformAlignment: Alignment.center,
          transform: widget.open ? Matrix4.identity() : (Matrix4.translationValues(panelW + s.rem(2.0), 0, 0)..multiply(Matrix4.diagonal3Values(0.98, 0.98, 1.0))),
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [BoxShadow(offset: Offset(0, s.rem(pal.isPaper ? 0.5 : 1.0)), blurRadius: s.rem(pal.isPaper ? 2.0 : 3.0), color: Color.fromRGBO(0, 0, 0, pal.isPaper ? 0.25 : 0.40))],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: pal.isPaper ? 30 : 40, sigmaY: pal.isPaper ? 30 : 40),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: pal.isPaper ? const Color.fromRGBO(250, 249, 245, 0.92) : const Color.fromRGBO(26, 26, 31, 0.74),
                  borderRadius: radius,
                  border: Border.all(color: pal.isPaper ? const Color.fromRGBO(20, 20, 19, 0.08) : const Color.fromRGBO(255, 255, 255, 0.07)),
                ),
                child: Stack(children: [
                  if (!pal.isPaper)
                    const Positioned(left: 1, right: 1, top: 0, height: 1, child: IgnorePointer(child: ColoredBox(color: Color.fromRGBO(255, 255, 255, 0.14)))),
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _header(t, s, pal),
                    Expanded(
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                        child: SingleChildScrollView(padding: EdgeInsets.fromLTRB(s.rem(1.125), s.rem(0.25), s.rem(1.125), s.rem(1.5)), child: body),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
