import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_controls.dart';
import 'package:moonfin/embyview/ui/player/open/ev_player_opening.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_anime4k_compare.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_credits_overlay.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_live_subtitle_layer.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_pause_overlay.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_player_toast.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_seek_feedback.dart';
import 'package:moonfin/embyview/ui/player/panel/ev_audio_video_tabs.dart';
import 'package:moonfin/embyview/ui/player/panel/ev_player_panel.dart';

/// Main Stage 5 player control page composing opening transition, video frame,
/// OSD controls, overlays, and the three-tab side panel around [PlaybackSession].
class EvPlayerPage extends StatefulWidget {
  const EvPlayerPage({
    super.key,
    required this.session,
    this.origin,
    this.art,
    this.subtitles,
    this.initialPanelOpen = false,
    this.initialPanelTab = 'subs',
    this.initialLowerTab,
    this.initialScrubHoverFraction,
    this.initialCompareSplit,
    this.holdOpening = false,
    this.autoTickCredits = true,
    this.autoTickRetry = true,
    this.retryCountdownSeconds = 30,
    this.pauseDelay = const Duration(milliseconds: 1500),
    this.idleHideDelay = const Duration(milliseconds: 3200),
    this.clock = DateTime.now,
    this.onClose,
  });

  final PlaybackSession session;
  final Rect? origin;
  final CardArtwork? art;
  final EmbyViewSubtitles? subtitles;
  final bool initialPanelOpen, holdOpening, autoTickCredits, autoTickRetry;
  final int retryCountdownSeconds;
  final String initialPanelTab;
  final String? initialLowerTab;
  final double? initialScrubHoverFraction, initialCompareSplit;
  final Duration pauseDelay, idleHideDelay;
  final DateTime Function() clock;
  final VoidCallback? onClose;

  @override State<EvPlayerPage> createState() => _EvPlayerPageState();
}

class _EvPlayerPageState extends State<EvPlayerPage> with SingleTickerProviderStateMixin {
  late final AnimationController _openCtrl;
  late final EvFirstFrameTracker _firstFrame;
  final _videoFrameKey = GlobalKey(debugLabel: 'ev_player_video_frame');
  final _focusNode = FocusNode(debugLabel: 'ev_player_page_focus');

  late PlaybackSnapshot _snap;
  StreamSubscription<PlaybackSnapshot>? _sessionSub;
  EmbyViewSubtitles? _resolvedSubtitles;
  SubtitlePanel? _subtitlePanel;
  SubtitleSnapshot? _subSnap;
  StreamSubscription<SubtitleSnapshot>? _subSub;

  late bool _panelOpen = widget.initialPanelOpen, _compareActive = widget.initialCompareSplit != null, _comparePersistent = widget.initialCompareSplit != null;
  late String _panelTab = widget.initialPanelTab;
  late double _compareSplit = (widget.initialCompareSplit ?? 0.5).clamp(0.04, 0.96);
  bool _subBound = false, _openingDone = false, _controlsVisible = true, _pauseCardVisible = false;
  bool _scrubHovering = false, _scrubbing = false, _bottomBarHover = false, _flashAuroraTip = false, _toastVisible = false;
  bool _autoCompareSwept = false;
  int _seekLeftNonce = 0, _seekRightNonce = 0, _compareSweepNonce = 0;
  int _retryAttempt = 1, _retryNonce = 0;
  String _toastMessage = '';
  int _trackSelection = 0;
  EvIconData? _toastIcon;
  Timer? _idleTimer, _pauseTimer, _toastTimer, _auroraFlashTimer;
  late final EvPlayerMenuDelegate _menuDelegate;

  bool get _creditsActive => _snap.creditsPrompt == CreditsPromptState.countingDown && _snap.nextEpisode != null;
  SubtitleSnapshot? get _activeSubSnap => _subSnap?.generation == _snap.generation ? _subSnap : null;

  @override
  void initState() {
    super.initState();
    final skip = widget.holdOpening || widget.initialPanelOpen || widget.initialCompareSplit != null || widget.initialScrubHoverFraction != null;
    _openCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 750), value: skip ? 1.0 : 0.0);
    if (!skip) _openCtrl.forward();
    _snap = widget.session.snapshot;
    final openedAt = identical(widget.clock, DateTime.now) ? EvPlayer.lastOpenedAt : null;
    _firstFrame = EvFirstFrameTracker(clock: widget.clock, startedAt: openedAt);
    _observeFirstFrame(_snap);
    _sessionSub = widget.session.changes.listen(_onSessionSnapshot);
    _syncPauseState(_snap);
    if (_snap.phase == PlaybackPhase.playing) _scheduleIdleHide();
    _menuDelegate = EvPlayerMenuDelegate(
      togglePlayPause: _togglePlayPause,
      seekBack10: () => _seekBy(const Duration(seconds: -10)),
      seekForward10: () => _seekBy(const Duration(seconds: 10)),
      nextEpisode: () {
        if (_snap.nextEpisode != null) {
          unawaited(widget.session.playNext(finishCurrent: true));
          _pokeControls();
        }
      },
      toggleSubtitlePanel: () => _togglePanelTab('subs'),
      triggerAiSubtitle: _triggerAiSubtitleFromMenu,
      toggleAnime4k: () {
        unawaited(widget.session.setAnime4k(!_snap.anime4k.requested));
        _pokeControls();
      },
      toggleFullscreen: () {
        unawaited(widget.session.setFullscreen(!_snap.fullscreen));
        _pokeControls();
      },
    );
    EvPlayer.registerActivePlayer(_menuDelegate);
  }

  void _triggerAiSubtitleFromMenu() {
    if (!_panelOpen || _panelTab != 'subs') {
      setState(() {
        _panelOpen = true;
        _panelTab = 'subs';
      });
    }
    _pokeControls();
    final panel = _subtitlePanel;
    final aiState = _activeSubSnap?.ai?.state;
    final busy = aiState == AiRunState.preparing ||
        aiState == AiRunState.generating ||
        aiState == AiRunState.catchingUp;
    if (panel != null && !busy) {
      unawaited(
        panel.startAi().catchError((Object err) {
          if (mounted) {
            _showToast(err is EmbyViewFailure ? err.reason : '启动 AI 字幕失败');
          }
        }),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextSubs = widget.subtitles ?? EvScope.maybeOf(context)?.services.subtitles;
    if (!_subBound || !identical(nextSubs, _resolvedSubtitles)) _bindSubtitles(nextSubs);
  }

  @override
  void didUpdateWidget(EvPlayerPage old) {
    super.didUpdateWidget(old);
    if (!identical(old.session, widget.session)) {
      unawaited(_sessionSub?.cancel());
      _snap = widget.session.snapshot;
      _retryAttempt = 1;
      _retryNonce = 0;
      _resetForGeneration(_snap);
      _sessionSub = widget.session.changes.listen(_onSessionSnapshot);
      _bindSubtitles(widget.subtitles ?? EvScope.maybeOf(context)?.services.subtitles);
    } else if (!identical(old.subtitles, widget.subtitles)) {
      _bindSubtitles(widget.subtitles ?? EvScope.maybeOf(context)?.services.subtitles);
    }
  }

  void _bindSubtitles(EmbyViewSubtitles? service) {
    unawaited(_subSub?.cancel()); _subSub = null;
    final prev = _subtitlePanel; _subtitlePanel = null;
    if (prev != null) unawaited(prev.close());
    _resolvedSubtitles = service; _subBound = true;
    if (service == null) { _subSnap = null; return; }
    final panel = service.bind(widget.session);
    _subtitlePanel = panel; _subSnap = panel.snapshot;
    _subSub = panel.changes.listen(_onSubtitleSnapshot);
  }

  void _observeFirstFrame(PlaybackSnapshot snap) => _firstFrame.observe(snap, onRecorded: () {
    if (!mounted) return;
    setState(() => _openingDone = true);
    _pokeControls();
  });

  void _resetForGeneration(PlaybackSnapshot next) {
    _pauseTimer?.cancel(); _pauseTimer = null;
    _auroraFlashTimer?.cancel(); _auroraFlashTimer = null;
    _toastTimer?.cancel(); _toastTimer = null;
    _firstFrame.reset(generation: next.generation);
    _openingDone = _pauseCardVisible = _flashAuroraTip = _compareActive = _comparePersistent = false;
    _toastVisible = _scrubHovering = _scrubbing = _autoCompareSwept = false;
    _compareSplit = 0.5;
    _observeFirstFrame(next);
  }

  void _onSessionSnapshot(PlaybackSnapshot next) {
    if (!mounted) return;
    final prev = _snap, genChanged = next.generation != prev.generation;
    final wasCredits = prev.creditsPrompt == CreditsPromptState.countingDown && prev.nextEpisode != null;
    final nowCredits = next.creditsPrompt == CreditsPromptState.countingDown && next.nextEpisode != null;
    var closedPanel = false;
    setState(() {
      _snap = next;
      if (next.target.itemId != prev.target.itemId || next.phase == PlaybackPhase.playing) {
        _retryAttempt = 1;
      }
      genChanged ? _resetForGeneration(next) : _observeFirstFrame(next);
      if (nowCredits || next.phase == PlaybackPhase.failed) {
        closedPanel = _panelOpen;
        _panelOpen = _pauseCardVisible = _compareActive = false; _pauseTimer?.cancel(); _pauseTimer = null;
      }
      if (next.anime4k.state != Anime4kState.active && _compareActive && widget.initialCompareSplit == null) _compareActive = false;
    });
    if (closedPanel) _reclaimPlayerFocus();
    if (!genChanged) _handleAnime4kTransition(prev.anime4k, next.anime4k);
    _syncPauseState(next);
    if ((next.phase == PlaybackPhase.playing && prev.phase != PlaybackPhase.playing) ||
        (!genChanged && wasCredits && !nowCredits)) {
      _pokeControls();
    }
  }

  void _handleAnime4kTransition(Anime4kSnapshot prev, Anime4kSnapshot next) {
    if (next.state == Anime4kState.active && prev.state != Anime4kState.active) {
      _showToast('Anime4K 已开启', icon: EvIcons.ok);
      if (next.comparison == ComparisonState.available && !_autoCompareSwept) {
        _autoCompareSwept = true;
        _startCompare(persistent: false);
      }
    } else if (next.state == Anime4kState.active &&
        next.comparison == ComparisonState.available &&
        prev.comparison != ComparisonState.available &&
        !_autoCompareSwept) {
      _autoCompareSwept = true;
      _startCompare(persistent: false);
    } else if (next.requested && next.state != Anime4kState.active && next.state != Anime4kState.pending &&
        (!prev.requested || prev.state != next.state || prev.reason != next.reason)) {
      _showToast(next.reason?.trim().isNotEmpty == true ? next.reason!.trim() : EvVideoTab.stateLabel(next.state), icon: EvIcons.info);
    } else if (!next.requested && prev.requested) {
      _showToast('Anime4K 已关闭');
    }
  }

  void _onSubtitleSnapshot(SubtitleSnapshot next) {
    if (!mounted) return;
    final prevAi = _activeSubSnap?.ai?.state;
    setState(() => _subSnap = next);
    if (next.generation == _snap.generation && next.ai?.state == AiRunState.generating && prevAi != AiRunState.generating) {
      _auroraFlashTimer?.cancel(); setState(() => _flashAuroraTip = true);
      _showToast('AI 字幕正在生成', icon: EvIcons.ok);
      _auroraFlashTimer = Timer(const Duration(seconds: 3), () { if (mounted) setState(() => _flashAuroraTip = false); });
    }
  }

  void _syncPauseState(PlaybackSnapshot snap) {
    if (snap.phase == PlaybackPhase.paused && !_creditsActive) {
      if (!_pauseCardVisible && _pauseTimer == null) {
        _pauseTimer = Timer(widget.pauseDelay, () {
          _pauseTimer = null;
          if (mounted && _snap.phase == PlaybackPhase.paused && !_creditsActive) setState(() => _pauseCardVisible = true);
        });
      }
    } else {
      _pauseTimer?.cancel(); _pauseTimer = null;
      if (_pauseCardVisible) setState(() => _pauseCardVisible = false);
    }
  }

  void _pokeControls() { if (!_controlsVisible) setState(() => _controlsVisible = true); _scheduleIdleHide(); }

  void _scheduleIdleHide() {
    _idleTimer?.cancel();
    _idleTimer = Timer(widget.idleHideDelay, () {
      if (mounted && !_panelOpen && _snap.phase == PlaybackPhase.playing && !_bottomBarHover && !_scrubbing && !_creditsActive && widget.initialScrubHoverFraction == null) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  Future<void> _selectTrack(String? id, {bool audio = false}) async {
    final session = widget.session, generation = _snap.generation, selection = ++_trackSelection;
    try {
      await (audio ? session.selectAudio(id!) : session.selectSubtitle(id));
    } catch (error) {
      if (mounted && selection == _trackSelection && identical(widget.session, session) && session.snapshot.generation == generation) {
        _showToast(error is EmbyViewFailure ? error.reason : audio ? '无法切换音轨，请重试。' : '无法切换字幕，请重试。');
      }
    }
  }

  void _showToast(String message, {EvIconData? icon}) {
    _toastTimer?.cancel();
    setState(() { _toastMessage = message; _toastIcon = icon; _toastVisible = true; });
    _toastTimer = Timer(const Duration(milliseconds: 3200), () { if (mounted) setState(() => _toastVisible = false); });
  }

  void _togglePlayPause() { unawaited(_snap.phase == PlaybackPhase.playing ? widget.session.pause() : widget.session.resume()); _pokeControls(); }
  void _seekBy(Duration d) { unawaited(widget.session.seekBy(d)); setState(() => d.isNegative ? _seekLeftNonce++ : _seekRightNonce++); _pokeControls(); }

  void _adjustVolume(double delta) {
    final next = (_snap.volume + delta).clamp(0.0, 1.0);
    if (_snap.muted && delta > 0) unawaited(widget.session.setMuted(false));
    unawaited(widget.session.setVolume(next));
    _showToast('音量 ${(next * 100).round()}%', icon: next <= 0 ? EvIcons.mute : EvIcons.vol);
    _pokeControls();
  }

  void _reclaimPlayerFocus() {
    if (_focusNode.canRequestFocus) _focusNode.requestFocus();
  }

  void _closePanel() {
    if (_panelOpen) setState(() => _panelOpen = false);
    _reclaimPlayerFocus();
    _pokeControls();
  }

  void _togglePanelTab(String tab) {
    final closing = _panelOpen && _panelTab == tab;
    if (closing) {
      _closePanel();
    } else {
      setState(() { _panelOpen = true; _panelTab = tab; });
      _pokeControls();
    }
  }

  void _startCompare({required bool persistent}) {
    setState(() { _compareActive = true; _comparePersistent = persistent; _compareSplit = 0.5; _compareSweepNonce++; });
    unawaited(widget.session.setAnime4kComparison(0.5));
  }

  void _endCompare() {
    if (!_compareActive) return;
    setState(() { _compareActive = _comparePersistent = false; });
    unawaited(widget.session.setAnime4kComparison(null));
  }

  void _handleClose() => widget.onClose != null ? widget.onClose!() : unawaited(Navigator.of(context).maybePop());

  void _retryPlayback() {
    setState(() {
      _retryAttempt++;
      _retryNonce++;
      _openingDone = false;
    });
    unawaited(widget.session.retryOpen());
  }

  bool _isTextInputFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    var found = false;
    ctx.visitAncestorElements((el) { if (el.widget is EditableText) { found = true; return false; } return true; });
    return found;
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_isTextInputFocused()) {
      if (key == LogicalKeyboardKey.escape) { FocusManager.instance.primaryFocus?.unfocus(); _focusNode.requestFocus(); return KeyEventResult.handled; }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (_panelOpen) { _closePanel(); }
      else if (_compareActive) { _endCompare(); }
      else { _handleClose(); }
      return KeyEventResult.handled;
    }
    if (_snap.phase == PlaybackPhase.failed) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.space && event is KeyDownEvent) { _togglePlayPause(); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.arrowLeft) { _seekBy(const Duration(seconds: -10)); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.arrowRight) { _seekBy(const Duration(seconds: 10)); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.arrowUp) { _adjustVolume(0.1); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.arrowDown) { _adjustVolume(-0.1); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.keyM && event is KeyDownEvent) { unawaited(widget.session.setMuted(!_snap.muted)); _pokeControls(); return KeyEventResult.handled; }
    if (key == LogicalKeyboardKey.keyF && event is KeyDownEvent) { unawaited(widget.session.setFullscreen(!_snap.fullscreen)); _pokeControls(); return KeyEventResult.handled; }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    EvPlayer.unregisterActivePlayer(_menuDelegate);
    _idleTimer?.cancel(); _pauseTimer?.cancel(); _toastTimer?.cancel(); _auroraFlashTimer?.cancel();
    unawaited(_sessionSub?.cancel()); unawaited(_subSub?.cancel());
    if (_subtitlePanel != null) unawaited(_subtitlePanel!.close());
    _firstFrame.dispose(); _openCtrl.dispose(); _focusNode.dispose();
    super.dispose();
  }

  void _dismissCredits() {
    unawaited(widget.session.dismissCreditsPrompt());
    _pokeControls();
  }

  @override
  Widget build(BuildContext context) {
    final scale = EvScale.of(context), creditsActive = _creditsActive;
    final failed = _snap.phase == PlaybackPhase.failed;
    final openingDone = _openingDone && !widget.holdOpening && !failed;
    final showControls = _controlsVisible && openingDone && !creditsActive && !failed;
    final origSize = _snap.anime4k.originalSize;
    final videoAspectRatio = (origSize != null && origSize.width > 0 && origSize.height > 0)
        ? origSize.width / origSize.height
        : 16 / 9;

    final videoFrame = EvCreditsVideoFrame(
      key: _videoFrameKey,
      creditsActive: creditsActive && !failed, panelOpen: _panelOpen, videoAspectRatio: videoAspectRatio, onTapMiniVideo: _dismissCredits,
      child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: widget.session.videoSurface(key: ValueKey('ev_video_${_snap.generation}'))),
        Positioned.fill(child: EvPlayerOpeningOverlay(
          snapshot: _snap, art: widget.art, uiFirstFrameLatency: _firstFrame.uiFirstFrameLatency,
          done: openingDone, holdVisible: widget.holdOpening || failed,
          retryAttempt: _retryAttempt, retryNonce: _retryNonce,
          retryCountdownSeconds: widget.retryCountdownSeconds, autoTickRetry: widget.autoTickRetry,
          onBack: _handleClose, onRetry: _retryPlayback,
        )),
      ]),
    );

    return Focus(
      focusNode: _focusNode, autofocus: true, onKeyEvent: _handleKeyEvent,
      child: Listener(
        behavior: HitTestBehavior.translucent, onPointerHover: (_) => _pokeControls(), onPointerMove: (_) => _pokeControls(), onPointerDown: (_) => _pokeControls(),
        child: ColoredBox(
          key: const Key('ev_player_page'), color: const Color(0xFF000000),
          child: Stack(fit: StackFit.expand, children: [
            Positioned.fill(child: EvCreditsOverlay(
              visible: creditsActive && !failed, snapshot: _snap, autoTick: widget.autoTickCredits,
              onPlayNext: () => unawaited(widget.session.playNext(finishCurrent: true)),
              onStay: _dismissCredits,
            )),
            Positioned.fill(child: AnimatedBuilder(
              animation: _openCtrl,
              builder: (_, child) => EvPlayerOpeningClip(origin: widget.origin, expandProgress: EvCurves.out.transform(_openCtrl.value), cornerRadius: scale.rem(1.25), child: child!),
              child: videoFrame,
            )),
            if (!failed)
              EvLiveSubtitleLayer(
                snapshot: _snap, subtitleSnapshot: _activeSubSnap, controlsVisible: showControls, panelOpen: _panelOpen,
                scrubHovering: _scrubHovering || _scrubbing || widget.initialScrubHoverFraction != null, paused: _pauseCardVisible, creditsActive: creditsActive,
              ),
            Positioned.fill(child: EvPauseOverlay(visible: _pauseCardVisible && !creditsActive && !failed, snapshot: _snap, art: widget.art, clock: widget.clock, onResume: _togglePlayPause)),
            Positioned.fill(child: EvPlayerControls(
              snapshot: _snap, art: widget.art, aiRun: _activeSubSnap?.ai, flashAuroraTip: _flashAuroraTip, visible: showControls,
              panelOpen: _panelOpen, activePanelTab: _panelTab, pauseCardVisible: _pauseCardVisible,
              seekLeftNonce: _seekLeftNonce, seekRightNonce: _seekRightNonce, forcedScrubHoverFraction: widget.initialScrubHoverFraction, clock: widget.clock,
              onBack: _handleClose, onTogglePlay: _togglePlayPause, onSeek: (p) { unawaited(widget.session.seek(p)); _pokeControls(); }, onSeekBy: _seekBy,
              onSetVolume: (v) { unawaited(widget.session.setVolume(v)); _pokeControls(); }, onToggleMute: () { unawaited(widget.session.setMuted(!_snap.muted)); _pokeControls(); },
              onPlayNext: () => unawaited(widget.session.playNext(finishCurrent: true)), onOpenPanelTab: _togglePanelTab,
              onToggleAnime4k: () { unawaited(widget.session.setAnime4k(!_snap.anime4k.requested)); _pokeControls(); },
              onTogglePip: () { unawaited(widget.session.setPictureInPicture(!_snap.pictureInPicture)); _pokeControls(); },
              onToggleFullscreen: () { unawaited(widget.session.setFullscreen(!_snap.fullscreen)); _pokeControls(); },
              onThumbnailAt: widget.session.thumbnailAt, onScrubHoverChanged: (h) => setState(() => _scrubHovering = h),
              onScrubbingChanged: (s) { setState(() => _scrubbing = s); if (!s) _scheduleIdleHide(); },
              onBottomBarHoverChanged: (h) { _bottomBarHover = h; if (!h) _scheduleIdleHide(); }, onBackdropTap: _togglePlayPause,
            )),
            Positioned.fill(child: AnimatedPadding(
              duration: const Duration(milliseconds: 600), curve: EvCurves.out,
              padding: _panelOpen && !creditsActive ? EdgeInsets.fromLTRB(scale.rem(1), scale.rem(1), scale.rem(30), scale.rem(1)) : EdgeInsets.zero,
              child: EvAnime4kCompareOverlay(
                active: _compareActive && !creditsActive, anime4k: _snap.anime4k, split: _compareSplit,
                sweepNonce: _compareSweepNonce, persistent: _comparePersistent,
                onManualDrag: () => setState(() => _comparePersistent = true),
                onSplitChanged: (s) { if (!_compareActive) return; _compareSplit = s; unawaited(widget.session.setAnime4kComparison(s)); },
                onEnd: _endCompare,
              ),
            )),
            Positioned.fill(child: EvSeekFeedbackOverlay(leftNonce: _seekLeftNonce, rightNonce: _seekRightNonce)),
            Positioned.fill(child: EvPlayerToast(visible: _toastVisible, message: _toastMessage, icon: _toastIcon)),
            EvPlayerPanel(
              open: _panelOpen && !creditsActive, activeTab: _panelTab, snapshot: _snap, subtitleSnapshot: _activeSubSnap,
              subtitlePanel: _subtitlePanel, subtitles: _resolvedSubtitles, initialLowerTab: widget.initialLowerTab,
              onSelectTab: (tab) => setState(() => _panelTab = tab), onClose: _closePanel,
              onSelectSubtitle: (id) => unawaited(_selectTrack(id)), onSelectAudio: (id) => unawaited(_selectTrack(id, audio: true)),
              onSeek: (p) => unawaited(widget.session.seek(p)), onToggleAnime4k: () => unawaited(widget.session.setAnime4k(!_snap.anime4k.requested)),
              onStartCompare: () => _startCompare(persistent: true), onToast: _showToast,
            ),
          ]),
        ),
      ),
    );
  }
}
