import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_format.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_scrub_bar.dart';

const _kWhite = Color(0xFFFFFFFF), _kClear = Color(0x00000000);
const _kInk = Color(0xFF141413), _kPaperFg = Color(0xFFFAF9F5), _kPaperPill = Color(0xEBFAF9F5);
const _kCinemaFg = Color(0xFFF5F5F7), _kCinemaPill = Color(0x7528282E), _kTerracotta = Color(0xFFB5532F);
const _kMs200 = Duration(milliseconds: 200), _kMs300 = Duration(milliseconds: 300);
const _kMs450 = Duration(milliseconds: 450), _kMs600 = Duration(milliseconds: 600);

/// Top and bottom player OSD control overlay (`.osd` in `proto.css`) supporting
/// cinema and warm-paper themes, side-panel reflow, spring island entry, play/
/// pause icon morph, and seek spin feedback.
class EvPlayerControls extends StatefulWidget {
  const EvPlayerControls({
    super.key, required this.snapshot, this.art, this.aiRun, this.flashAuroraTip = false,
    required this.visible, required this.panelOpen, this.activePanelTab, this.pauseCardVisible = false,
    this.seekLeftNonce = 0, this.seekRightNonce = 0, this.forcedScrubHoverFraction,
    this.clock = DateTime.now, this.onBack, this.onTogglePlay, required this.onSeek, this.onSeekBy,
    this.onSetVolume, this.onToggleMute, this.onPlayNext, this.onOpenPanelTab,
    this.onToggleAnime4k, this.onTogglePip, this.onToggleFullscreen, this.onThumbnailAt,
    this.onScrubHoverChanged, this.onScrubbingChanged, this.onBottomBarHoverChanged, this.onBackdropTap,
  });

  final PlaybackSnapshot snapshot;
  final CardArtwork? art;
  final AiRun? aiRun;
  final bool flashAuroraTip, visible, panelOpen, pauseCardVisible;
  final String? activePanelTab;
  final int seekLeftNonce, seekRightNonce;
  final double? forcedScrubHoverFraction;
  final DateTime Function() clock;
  final VoidCallback? onBack, onTogglePlay, onToggleMute, onPlayNext;
  final VoidCallback? onToggleAnime4k, onTogglePip, onToggleFullscreen, onBackdropTap;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration>? onSeekBy;
  final ValueChanged<double>? onSetVolume;
  final ValueChanged<String>? onOpenPanelTab;
  final Future<ThumbnailFrame?> Function(Duration position)? onThumbnailAt;
  final ValueChanged<bool>? onScrubHoverChanged, onScrubbingChanged, onBottomBarHoverChanged;

  @override
  State<EvPlayerControls> createState() => _EvPlayerControlsState();
}

class _EvPlayerControlsState extends State<EvPlayerControls> with TickerProviderStateMixin {
  late final AnimationController _spinL, _spinR, _a4kGlow, _entry;
  bool _logoFailed = false, _volHover = false, _volDrag = false;
  bool get _a4kActive => widget.snapshot.anime4k.state == Anime4kState.active;

  @override
  void initState() {
    super.initState();
    _spinL = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _spinR = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _a4kGlow = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
    _entry = AnimationController(vsync: this, duration: const Duration(milliseconds: 800), value: widget.visible ? 1.0 : 0.0);
  }

  @override
  void didChangeDependencies() { super.didChangeDependencies(); _syncGlow(); }

  ArtworkRef? _titleLogo(EvPlayerControls controls) {
    final item = controls.snapshot.item;
    return item?.kind == MediaKind.episode ? item?.art.logo : controls.art?.logo ?? item?.art.logo;
  }

  @override
  void didUpdateWidget(EvPlayerControls old) {
    super.didUpdateWidget(old);
    if (_titleLogo(old)?.cacheKey != _titleLogo(widget)?.cacheKey) {
      _logoFailed = false;
    }
    if (widget.seekLeftNonce != old.seekLeftNonce) _spinL.forward(from: 0);
    if (widget.seekRightNonce != old.seekRightNonce) _spinR.forward(from: 0);
    if (widget.visible && !old.visible) _entry.forward(from: 0);
    _syncGlow();
  }

  void _syncGlow() {
    if (_a4kActive && widget.visible && !EvTheme.of(context).isPaper) {
      if (!_a4kGlow.isAnimating) _a4kGlow.repeat(reverse: true);
    } else if (_a4kGlow.isAnimating) {
      _a4kGlow.stop();
    }
  }

  @override
  void dispose() { _spinL.dispose(); _spinR.dispose(); _a4kGlow.dispose(); _entry.dispose(); super.dispose(); }

  Widget _logo(EvTheme t, double maxH, double maxW, double fs, Alignment align) {
    final item = widget.snapshot.item;
    final ref = _titleLogo(widget);
    final title = item?.kind == MediaKind.episode ? item?.seriesName : item?.title;
    if (ref != null && !_logoFailed) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH, maxWidth: maxW),
        child: Image(
          image: ref.image, fit: BoxFit.contain, alignment: align, filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && !_logoFailed) setState(() => _logoFailed = true); });
            return const SizedBox.shrink();
          },
        ),
      );
    }
    if (title == null || title.trim().isEmpty) return const SizedBox.shrink();
    return Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(fs, fontWeight: FontWeight.w700, color: _kWhite));
  }

  Widget _island(EvScale s, bool paper, double delay, EdgeInsets pad, Widget child) {
    final curve = Interval(delay, 1.0, curve: EvCurves.out);
    return AnimatedBuilder(
      animation: _entry,
      builder: (_, c) {
        final v = curve.transform(_entry.value).clamp(0.0, 1.0);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * s.rem(0.75)),
            child: Transform.scale(scale: 0.96 + 0.04 * v, child: c),
          ),
        );
      },
      child: _Pill(paper: paper, island: true, height: s.rem(3.375), padding: pad, child: child),
    );
  }

  Widget _tool(
    EvScale s, bool paper, String keyId, String label, EvIconData icon, VoidCallback? onTap, {
    bool active = false, Animation<double>? spin, int dir = 1,
  }) {
    final sz = s.rem(2.625);
    return _Btn(
      key: Key(keyId), label: label, selected: active, pressScale: 0.88, onTap: onTap,
      builder: (hov) {
        final bg = active ? (paper ? _kInk : const Color(0xEBFFFFFF))
            : hov ? (paper ? const Color(0x14141413) : const Color(0x24FFFFFF)) : _kClear;
        final fg = active ? (paper ? _kPaperFg : const Color(0xFF111111)) : (paper ? _kInk : _kCinemaFg);
        Widget ic = EvIcon(icon, size: s.rem(1.375), color: fg);
        ic = spin != null
            ? AnimatedBuilder(
                animation: spin,
                builder: (_, c) => Transform.rotate(
                  angle: dir * 2 * math.pi * EvCurves.out.transform(spin.value),
                  child: Transform.scale(scale: 1 - 0.1 * math.sin(math.pi * spin.value), child: c),
                ),
                child: ic,
              )
            : AnimatedScale(scale: hov ? 1.1 : 1.0, duration: _kMs450, curve: EvCurves.spring, child: ic);
        return AnimatedContainer(
          duration: _kMs200, width: sz, height: sz,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle), child: Center(child: ic),
        );
      },
    );
  }

  Widget _playBtn(EvScale s, bool paper, bool playing) {
    final sz = s.rem(3.0), fg = paper ? _kWhite : const Color(0xFF0B0B0D);
    return _Btn(
      key: const Key('ev_player_play_pause'), label: playing ? '暂停' : '播放', tooltip: '播放 / 暂停',
      hoverScale: 1.07, pressScale: 0.88, onTap: widget.onTogglePlay,
      builder: (hov) => AnimatedContainer(
        duration: _kMs200, width: sz, height: sz,
        decoration: BoxDecoration(color: paper ? _kTerracotta : (hov ? _kWhite : _kCinemaFg), shape: BoxShape.circle),
        child: Center(
          child: AnimatedSwitcher(
            duration: _kMs450, switchInCurve: EvCurves.spring, switchOutCurve: EvCurves.soft,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: AnimatedBuilder(
                animation: anim,
                builder: (_, c) => Transform.rotate(
                  angle: (1 - anim.value) * (-math.pi / 2),
                  child: Transform.scale(scale: 0.4 + 0.6 * anim.value, child: c),
                ),
                child: child,
              ),
            ),
            child: EvIcon(playing ? EvIcons.pause : EvIcons.play, key: ValueKey(playing ? 'pause' : 'play'), size: s.rem(1.5), color: fg),
          ),
        ),
      ),
    );
  }

  Widget _a4kBtn(EvScale s, bool paper) {
    final sz = s.rem(2.625), on = _a4kActive;
    final fg = on ? (paper ? _kPaperFg : const Color(0xFF1C1206)) : (paper ? _kInk : _kCinemaFg);
    return _Btn(
      key: const Key('ev_player_a4k'), label: 'Anime4K', selected: on, pressScale: 0.88, onTap: widget.onToggleAnime4k,
      builder: (hov) => AnimatedBuilder(
        animation: _a4kGlow,
        builder: (_, child) {
          final p = Curves.easeInOut.transform(_a4kGlow.value);
          final deco = on && paper
              ? const BoxDecoration(color: _kInk, shape: BoxShape.circle)
              : on
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(begin: Alignment(-0.8, -0.6), end: Alignment(0.8, 0.6), colors: [Color(0xFFFFD57E), Color(0xFFFF9D57)]),
                      boxShadow: [BoxShadow(blurRadius: s.rem(1.25 + 0.5 * p), color: Color.fromRGBO(255, 176, 90, 0.42 + 0.26 * p))],
                    )
                  : BoxDecoration(shape: BoxShape.circle, color: hov ? (paper ? const Color(0x14141413) : const Color(0x24FFFFFF)) : _kClear);
          return Container(width: sz, height: sz, decoration: deco, child: child);
        },
        child: Center(
          child: AnimatedScale(scale: hov ? 1.1 : 1.0, duration: _kMs450, curve: EvCurves.spring, child: EvIcon(EvIcons.a4k, size: s.rem(1.375), color: fg)),
        ),
      ),
    );
  }

  Widget _volumeBar(EvScale s, bool paper, double vol) {
    final open = _volHover || _volDrag;
    void emit(double dx, double w) { if (w > 0) widget.onSetVolume?.call((dx / w).clamp(0.0, 1.0)); }
    return AnimatedContainer(
      duration: _kMs450, curve: EvCurves.out,
      width: open ? s.rem(6.0) : 0.0, margin: EdgeInsets.symmetric(horizontal: open ? s.rem(0.5) : 0.0),
      child: ClipRect(
        child: LayoutBuilder(
          builder: (_, c) {
            final cw = c.maxWidth;
            if (cw <= 1) return const SizedBox.shrink();
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: const Key('ev_player_volume_slider'), behavior: HitTestBehavior.opaque,
                onTapDown: (d) => emit(d.localPosition.dx, cw),
                onHorizontalDragStart: (d) { setState(() => _volDrag = true); emit(d.localPosition.dx, cw); },
                onHorizontalDragUpdate: (d) => emit(d.localPosition.dx, cw),
                onHorizontalDragEnd: (_) => setState(() => _volDrag = false),
                onHorizontalDragCancel: () => setState(() => _volDrag = false),
                child: SizedBox(
                  height: s.rem(2.0),
                  child: Center(
                    child: Container(
                      height: s.rem(0.25), clipBehavior: Clip.antiAlias, alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(color: paper ? const Color(0x33141413) : const Color(0x40FFFFFF), borderRadius: BorderRadius.circular(2)),
                      child: FractionallySizedBox(widthFactor: vol.clamp(0.0, 1.0), child: ColoredBox(color: paper ? _kInk : _kWhite)),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _topBar(EvTheme t, EvScale s, ({String primary, String secondary}) meta) {
    final paper = t.isPaper;
    final tech = evPlayerTechSummary(widget.snapshot.quality);
    final titleMeta = [
      if (meta.primary.isNotEmpty) meta.primary,
      if (widget.snapshot.item?.kind == MediaKind.episode && meta.secondary.isNotEmpty) meta.secondary,
    ].join(' · ');
    return AnimatedPositioned(
      duration: _kMs600, curve: EvCurves.out, left: 0, right: widget.panelOpen ? s.rem(29.0) : 0, top: 0,
      child: AnimatedContainer(
        duration: _kMs600, curve: EvCurves.out,
        transform: Matrix4.translationValues(0, widget.visible ? 0 : -s.rem(0.75), 0),
        padding: EdgeInsets.fromLTRB(s.rem(5.75), s.rem(0.875), s.gutter, 0),
        child: Row(
          children: [
            _Btn(
              key: const Key('ev_player_back'), label: '返回', hoverScale: 1.08, onTap: widget.onBack,
              builder: (_) => _Pill(
                paper: paper, width: s.rem(2.5), height: s.rem(2.5),
                child: Center(child: EvIcon(EvIcons.left, size: s.rem(1.125), color: paper ? _kInk : _kCinemaFg)),
              ),
            ),
            SizedBox(width: s.rem(1.0)),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: widget.panelOpen ? 1.0 : 0.0), duration: _kMs600, curve: EvCurves.out,
                  builder: (_, v, child) => v <= 0.001
                      ? const SizedBox.shrink()
                      : ClipRect(
                          child: Align(
                            alignment: Alignment.centerLeft, widthFactor: v.clamp(0.0, 1.0),
                            child: Opacity(opacity: ((v - 0.15) / 0.85).clamp(0.0, 1.0), child: child),
                          ),
                        ),
                  child: Row(
                    key: const Key('ev_player_top_title'), mainAxisSize: MainAxisSize.min, spacing: s.rem(0.75),
                    children: [
                      Flexible(child: _logo(t, s.rem(1.875), s.rem(9.0), s.rem(1.125), Alignment.centerLeft)),
                      if (titleMeta.isNotEmpty)
                        Flexible(
                          child: Text(titleMeta, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.9375), color: const Color(0xCCFFFFFF))),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: s.rem(1.0)),
            if (tech.isNotEmpty) ConstrainedBox(
              constraints: BoxConstraints(maxWidth: s.rem(24.0)),
              child: _Pill(
                key: const Key('ev_player_tech_pill'), paper: paper, height: s.rem(2.5),
                padding: EdgeInsets.symmetric(horizontal: s.rem(1.0)),
                child: Row(
                  mainAxisSize: MainAxisSize.min, spacing: s.rem(0.5),
                  children: [
                    Container(
                      width: s.rem(0.375), height: s.rem(0.375),
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF4FD18B), boxShadow: [BoxShadow(blurRadius: 8, color: Color(0xFF4FD18B))]),
                    ),
                    Flexible(
                      child: Text(
                        tech, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: t.bodyStyle(s.rem(0.875), color: paper ? const Color(0xFF66655F) : const Color(0xD9FFFFFF)),
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

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final paper = t.isPaper, snap = widget.snapshot;
    final meta = evPlayerEpisodeMeta(snap.item, snap.target);

    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        opacity: widget.visible ? 1.0 : 0.0, duration: _kMs450, curve: EvCurves.soft,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('ev_player_osd_backdrop'), behavior: HitTestBehavior.translucent, onTap: widget.onBackdropTap,
                child: AnimatedOpacity(
                  opacity: widget.panelOpen ? 0.5 : 1.0, duration: const Duration(milliseconds: 500),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        stops: [0.0, 0.22, 0.52, 1.0], colors: [Color(0x8C000000), _kClear, _kClear, Color(0xBF000000)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _topBar(t, s, meta),
            AnimatedPositioned(
              duration: _kMs600, curve: EvCurves.out,
              left: widget.panelOpen ? s.rem(2.5) : s.gutter, right: widget.panelOpen ? s.rem(31.5) : s.gutter, bottom: s.rem(1.75),
              child: MouseRegion(
                onEnter: (_) => widget.onBottomBarHoverChanged?.call(true),
                onExit: (_) => widget.onBottomBarHoverChanged?.call(false),
                child: AnimatedContainer(
                  duration: _kMs600, curve: EvCurves.out,
                  transform: Matrix4.translationValues(0, widget.visible ? 0 : s.rem(0.75), 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!widget.panelOpen)
                        IgnorePointer(
                          ignoring: widget.pauseCardVisible,
                          child: AnimatedOpacity(
                            opacity: widget.pauseCardVisible ? 0.0 : 1.0, duration: const Duration(milliseconds: 400),
                            child: Padding(
                              key: const Key('ev_player_bottom_title'), padding: EdgeInsets.only(bottom: s.rem(1.125)),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end, spacing: s.rem(1.25),
                                children: [
                                  Flexible(child: _logo(t, s.rem(3.5), s.rem(17.0), s.rem(1.875), Alignment.bottomLeft)),
                                  if (meta.primary.isNotEmpty || meta.secondary.isNotEmpty)
                                    Flexible(
                                      child: Padding(
                                        padding: EdgeInsets.only(bottom: s.rem(0.25)),
                                        child: Text.rich(
                                          maxLines: 1, overflow: TextOverflow.ellipsis,
                                          TextSpan(
                                            style: t.bodyStyle(s.rem(1.0), color: const Color(0xCCFFFFFF)),
                                            children: [
                                              if (meta.primary.isNotEmpty)
                                                TextSpan(text: meta.primary, style: const TextStyle(color: _kWhite, fontWeight: FontWeight.w600)),
                                              if (meta.secondary.isNotEmpty)
                                                TextSpan(text: meta.primary.isNotEmpty ? '\u3000${meta.secondary}' : meta.secondary),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      EvPlayerScrubBar(
                        position: snap.position, duration: snap.duration, bufferedUntil: snap.bufferedUntil,
                        chapters: snap.chapters, aiRun: widget.aiRun, flashAuroraTip: widget.flashAuroraTip,
                        visible: widget.visible, generation: snap.generation,
                        onThumbnailAt: widget.onThumbnailAt, onSeek: widget.onSeek,
                        onHoverChanged: widget.onScrubHoverChanged, onScrubbingChanged: widget.onScrubbingChanged,
                        forcedHoverFraction: widget.forcedScrubHoverFraction, clock: widget.clock,
                      ),
                      SizedBox(height: s.rem(0.75)),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          MouseRegion(
                            onEnter: (_) => setState(() => _volHover = true),
                            onExit: (_) => setState(() => _volHover = false),
                            child: _island(
                              s, paper, 0.0, EdgeInsets.only(left: s.rem(0.375), right: s.rem(0.5)),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _tool(s, paper, 'ev_player_mute', snap.muted ? '取消静音' : '静音', snap.muted || snap.volume <= 0 ? EvIcons.mute : EvIcons.vol, widget.onToggleMute),
                                  _volumeBar(s, paper, snap.muted ? 0.0 : snap.volume),
                                ],
                              ),
                            ),
                          ),
                          _island(
                            s, paper, 0.0625, EdgeInsets.symmetric(horizontal: s.rem(0.5)),
                            Row(
                              mainAxisSize: MainAxisSize.min, spacing: s.rem(0.375),
                              children: [
                                _tool(s, paper, 'ev_player_back10', '后退 10 秒', EvIcons.back10, () => widget.onSeekBy?.call(const Duration(seconds: -10)), spin: _spinL, dir: -1),
                                _playBtn(s, paper, snap.phase == PlaybackPhase.playing),
                                _tool(s, paper, 'ev_player_fwd10', '前进 10 秒', EvIcons.fwd10, () => widget.onSeekBy?.call(const Duration(seconds: 10)), spin: _spinR, dir: 1),
                                if (snap.nextEpisode != null) _tool(s, paper, 'ev_player_next', '下一集', EvIcons.next, widget.onPlayNext),
                              ],
                            ),
                          ),
                          _island(
                            s, paper, 0.125, EdgeInsets.symmetric(horizontal: s.rem(0.375)),
                            Row(
                              mainAxisSize: MainAxisSize.min, spacing: s.rem(0.125),
                              children: [
                                _tool(s, paper, 'ev_player_tab_subs', '字幕', EvIcons.cc, () => widget.onOpenPanelTab?.call('subs'), active: widget.panelOpen && widget.activePanelTab == 'subs'),
                                _tool(s, paper, 'ev_player_tab_audio', '音频', EvIcons.audio, () => widget.onOpenPanelTab?.call('audio'), active: widget.panelOpen && widget.activePanelTab == 'audio'),
                                _a4kBtn(s, paper),
                                _tool(s, paper, 'ev_player_pip', '画中画', EvIcons.pip, widget.onTogglePip, active: snap.pictureInPicture),
                                _tool(s, paper, 'ev_player_fullscreen', '全屏', EvIcons.full, widget.onToggleFullscreen, active: snap.fullscreen),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatefulWidget {
  const _Pill({super.key, required this.paper, required this.child, this.island = false, this.width, this.height, this.padding});
  final bool paper, island;
  final double? width, height;
  final EdgeInsetsGeometry? padding;
  final Widget child;
  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _hov = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.paper, isl = widget.island, r = BorderRadius.circular(999), sigma = p ? 20.0 : 30.0;
    final bg = p
        ? (isl && _hov ? _kPaperFg : _kPaperPill)
        : (isl ? (_hov ? const Color(0x8F28282E) : const Color(0x6B28282E)) : _kCinemaPill);
    final box = Container(
      width: widget.width, height: widget.height,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: p || !isl ? [BoxShadow(offset: const Offset(0, 8), blurRadius: 32, color: Color.fromRGBO(0, 0, 0, p ? 0.25 : 0.28))] : null,
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: AnimatedContainer(
            duration: _kMs200, padding: widget.padding,
            decoration: BoxDecoration(color: bg, borderRadius: r, border: Border.all(color: p ? const Color(0x14141413) : const Color(0x12FFFFFF))),
            child: isl && !p
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      const Positioned(left: 12, right: 12, top: 0, height: 1, child: IgnorePointer(child: ColoredBox(color: Color(0x24FFFFFF)))),
                      widget.child,
                    ],
                  )
                : widget.child,
          ),
        ),
      ),
    );
    if (!isl) return box;
    return MouseRegion(
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() => _hov = false),
      child: AnimatedContainer(duration: _kMs300, curve: EvCurves.spring, transform: Matrix4.translationValues(0, _hov ? -2.0 : 0.0, 0), child: box),
    );
  }
}

class _Btn extends StatefulWidget {
  const _Btn({
    super.key, required this.label, this.tooltip, this.selected,
    this.hoverScale = 1.0, this.pressScale = 0.92, required this.onTap, required this.builder,
  });
  final String label;
  final String? tooltip;
  final bool? selected;
  final double hoverScale, pressScale;
  final VoidCallback? onTap;
  final Widget Function(bool hovered) builder;
  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _hov = false, _down = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true, selected: widget.selected, label: widget.label, tooltip: widget.tooltip ?? widget.label,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hov = true),
      onExit: (_) => setState(() { _hov = false; _down = false; }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? widget.pressScale : (_hov ? widget.hoverScale : 1.0),
          duration: _kMs300, curve: EvCurves.spring,
          child: widget.builder(_hov),
        ),
      ),
    ),
  );
}
