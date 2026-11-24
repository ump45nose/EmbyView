import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/stage/ev_stage_controller.dart';

/// Coordinates card-hover dwell timers, stage backdrop/veil updates, muted
/// background video previews, and detail theme music across the whole app.
///
/// Guarantees at most one background video and one theme song at any moment,
/// and stops all previews immediately on window blur, player entry, or rebind.
class Immersion extends ChangeNotifier {
  Immersion({EvStageController? stage, EmbyViewServices? services})
    : _ownsStage = stage == null,
      stage = stage ?? EvStageController() {
    this.stage.addListener(_onStageChanged);
    if (services != null) _attachServices(services);
  }

  /// Card hover delay before switching stage backdrop (`.spec/mockups/proto.js`).
  static const Duration backdropDwellDelay = Duration(milliseconds: 400);

  /// Default delay before requesting background video when preferences are unbound.
  static const Duration defaultVideoDwellDelay = Duration(milliseconds: 1700);
  static const String _defaultClipLabel = '片段 · 静音';

  final bool _ownsStage;
  final EvStageController stage;

  EmbyViewServices? _services;
  StreamSubscription<ImmersionSnapshot>? _immersionSub;
  StreamSubscription<LocalPreferences>? _prefsSub;
  WidgetBuilder? _videoSurfaceBuilder;

  ImmersionSnapshot _snapshot = const ImmersionSnapshot();
  bool _playerActive = false;
  bool _windowActive = true;
  bool _disposed = false;

  String? _hoveredCardId;
  String? _activePreviewItemId;
  bool _videoFromHover = false;
  PreviewRef? _activeVideo;
  PreviewRef? _activeTheme;

  Timer? _backdropTimer;
  Timer? _videoTimer;
  int _hoverToken = 0;
  int _videoToken = 0;
  int _themeToken = 0;

  ImmersionSnapshot get snapshot => _snapshot;
  bool get isVideoVisible => stage.videoVisible;
  bool get isPlayerActive => _playerActive;
  bool get isWindowActive => _windowActive;
  String? get activePreviewItemId => _activePreviewItemId;
  WidgetBuilder? get videoSurfaceBuilder => _videoSurfaceBuilder;

  bool get _canRun => !_disposed && !_playerActive && _windowActive;

  void _onStageChanged() {
    if (!_disposed) notifyListeners();
  }

  void _attachServices(EmbyViewServices? services) {
    _services = services;
    final playback = services?.immersion;
    _snapshot = playback?.snapshot ?? const ImmersionSnapshot();
    _videoSurfaceBuilder = playback == null
        ? null
        : (_) => playback.videoSurface(key: ValueKey<Object>(playback));
    _immersionSub = playback?.changes.listen(_onImmersionSnapshot);
    _prefsSub = services?.preferences.changes.listen(_onPreferencesChanged);
  }

  void _onImmersionSnapshot(ImmersionSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    if (next.video == PreviewState.idle || next.video == PreviewState.failed) {
      _activeVideo = null;
      _videoFromHover = false;
      if (stage.videoVisible) stage.setVideoState(visible: false);
    }
    if (next.theme == PreviewState.idle || next.theme == PreviewState.failed) {
      _activeTheme = null;
    }
    notifyListeners();
  }

  void _onPreferencesChanged(LocalPreferences prefs) {
    if (_disposed) return;
    if (!prefs.backgroundVideo &&
        (_videoTimer != null || _activeVideo != null || stage.videoVisible)) {
      _videoTimer?.cancel();
      _videoTimer = null;
      unawaited(stopVideo());
    }
    if (!prefs.themeMusic && _activeTheme != null) unawaited(stopTheme());
  }

  /// Switches to a new account binding, stopping previews on the old service
  /// and cancelling all pending timers and in-flight requests.
  Future<void> rebind(EmbyViewServices? services) async {
    if (_disposed || identical(_services, services)) return;
    _cancelHoverTimers();
    ++_hoverToken;
    ++_videoToken;
    ++_themeToken;

    final previous = _services;
    final oldImmersionSub = _immersionSub;
    final oldPrefsSub = _prefsSub;
    _immersionSub = null;
    _prefsSub = null;

    _hoveredCardId = _activePreviewItemId = null;
    _videoFromHover = false;
    _activeVideo = _activeTheme = null;

    stage.setVideoState(visible: false);
    stage.setVeilLifted(false);
    stage.clearPreviewBackdrop();

    _attachServices(services);
    notifyListeners();

    await oldImmersionSub?.cancel();
    await oldPrefsSub?.cancel();
    await _quiet(() => previous?.immersion?.stop());
  }

  /// Starts dwell timers for [card]: 0.4s backdrop swap (notifying hero via
  /// [onBackdropReady] or lifting scroll veil when [scrolledDown]) and
  /// `backgroundVideoDelay` (default 1.7s) muted video fade-in.
  void onCardHoverStart(
    MediaCard card, {
    bool scrolledDown = false,
    VoidCallback? onBackdropReady,
  }) {
    if (_disposed) return;
    _cancelHoverTimers();
    final token = ++_hoverToken;
    if (_videoFromHover && _activePreviewItemId != card.id) {
      unawaited(stopVideo());
    }
    _hoveredCardId = card.id;
    if (!_canRun) return;

    _backdropTimer = Timer(backdropDwellDelay, () {
      _backdropTimer = null;
      if (!_canRun || token != _hoverToken) return;
      _activePreviewItemId = card.id;
      stage.setPreviewBackdrop(card.art.stage);
      if (scrolledDown) {
        stage.setVeilLifted(true);
      } else {
        stage.setVeilLifted(false);
        onBackdropReady?.call();
      }
      notifyListeners();
    });

    final prefs = _services?.preferences.current;
    if (prefs?.backgroundVideo == false ||
        _services?.data == null ||
        _services?.immersion == null) {
      return;
    }

    _videoTimer = Timer(prefs?.backgroundVideoDelay ?? defaultVideoDwellDelay, () {
      _videoTimer = null;
      if (!_canRun || token != _hoverToken) return;
      if (_services?.preferences.current.backgroundVideo == false) return;
      unawaited(_loadHoverVideo(card, token));
    });
  }

  Future<void> _loadHoverVideo(MediaCard card, int token) async {
    final data = _services?.data;
    if (data == null) return;
    ThemeMedia media;
    try {
      media = await data.themeMedia(card.id);
    } catch (_) {
      return;
    }
    if (!_canRun ||
        token != _hoverToken ||
        _services?.preferences.current.backgroundVideo == false) {
      return;
    }
    final video = media.backgroundVideo;
    if (video == null) return;
    await _showMutedVideoInternal(
      video,
      label: _defaultClipLabel,
      fromHover: true,
      hoverTokenCheck: token,
    );
  }

  /// Ends hover, cancels timers/in-flight fetches, stops hover video, lowers
  /// scroll veil, and restores base backdrop.
  void onCardHoverEnd({String? cardId}) {
    if (_disposed) return;
    if (cardId != null && _hoveredCardId != null && _hoveredCardId != cardId) return;
    _cancelHoverTimers();
    ++_hoverToken;
    _hoveredCardId = null;

    final hadPreview =
        _activePreviewItemId != null || stage.previewBackdrop != null || stage.veilLifted;
    _activePreviewItemId = null;
    if (_videoFromHover) unawaited(stopVideo());
    stage.setVeilLifted(false);
    stage.clearPreviewBackdrop();
    if (hadPreview) notifyListeners();
  }

  /// Plays a single muted video preview on the stage. Passing `null` stops it.
  Future<void> showMutedVideo(PreviewRef? video, {String? label}) =>
      video == null ? stopVideo() : _showMutedVideoInternal(video, label: label, fromHover: false);

  Future<void> _showMutedVideoInternal(
    PreviewRef video, {
    String? label,
    required bool fromHover,
    int? hoverTokenCheck,
  }) async {
    if (!_canRun || _services?.preferences.current.backgroundVideo == false) return;
    final playback = _services?.immersion;
    if (playback == null) return;

    final token = ++_videoToken;
    _activeVideo = video;
    _videoFromHover = fromHover;

    try {
      await playback.showMutedVideo(video);
    } catch (_) {
      if (token == _videoToken && !_disposed) {
        _activeVideo = null;
        _videoFromHover = false;
        stage.setVideoState(visible: false);
        notifyListeners();
      }
      return;
    }

    final staleHover = hoverTokenCheck != null && hoverTokenCheck != _hoverToken;
    if (!_canRun || token != _videoToken || staleHover) {
      if (_activeVideo == null && (staleHover || !_canRun)) {
        await _quiet(() => playback.showMutedVideo(null));
      }
      return;
    }

    if (playback.snapshot.video == PreviewState.failed) {
      _activeVideo = null;
      _videoFromHover = false;
      stage.setVideoState(visible: false);
      notifyListeners();
      return;
    }

    final resolvedLabel = label == null
        ? (video.name.trim().isNotEmpty ? '${video.name.trim()} · 静音' : _defaultClipLabel)
        : (label.isEmpty ? null : label);
    stage.setVideoState(visible: true, label: resolvedLabel);
    notifyListeners();
  }

  Future<void> stopVideo() async {
    ++_videoToken;
    final hadVideo =
        _activeVideo != null || stage.videoVisible || _snapshot.video != PreviewState.idle;
    _activeVideo = null;
    _videoFromHover = false;
    stage.setVideoState(visible: false);
    if (!hadVideo) return;
    await _quiet(() => _services?.immersion?.showMutedVideo(null));
    if (!_disposed) notifyListeners();
  }

  /// Plays a single detail-page theme song. Passing `null` stops the theme.
  Future<void> playTheme(PreviewRef? song) async {
    if (song == null) return stopTheme();
    if (!_canRun || _services?.preferences.current.themeMusic == false) return;
    final playback = _services?.immersion;
    if (playback == null) return;

    final token = ++_themeToken;
    _activeTheme = song;
    try {
      await playback.playTheme(song);
    } catch (_) {
      if (token == _themeToken && !_disposed) {
        _activeTheme = null;
        notifyListeners();
      }
      return;
    }

    if (!_canRun || token != _themeToken) {
      if (_activeTheme == null && !_canRun) {
        await _quiet(() => playback.playTheme(null));
      }
      return;
    }
    notifyListeners();
  }

  Future<void> setThemeMuted(bool muted) async {
    if (_disposed) return;
    await _quiet(() => _services?.immersion?.setThemeMuted(muted));
    if (!_disposed) notifyListeners();
  }

  Future<void> stopTheme() async {
    ++_themeToken;
    final hadTheme = _activeTheme != null || _snapshot.theme != PreviewState.idle;
    _activeTheme = null;
    if (!hadTheme) return;
    await _quiet(() => _services?.immersion?.playTheme(null));
    if (!_disposed) notifyListeners();
  }

  /// Immediately stops all timers, hover previews, muted video, and theme music.
  Future<void> stopAll() async {
    _cancelHoverTimers();
    ++_hoverToken;
    ++_videoToken;
    ++_themeToken;
    _hoveredCardId = _activePreviewItemId = null;
    _videoFromHover = false;
    _activeVideo = _activeTheme = null;

    if (!_disposed) {
      stage.setVideoState(visible: false);
      stage.setVeilLifted(false);
      stage.clearPreviewBackdrop();
    }
    await _quiet(() => _services?.immersion?.stop());
    if (!_disposed) notifyListeners();
  }

  void enterPlayer() {
    if (_disposed) return;
    _playerActive = true;
    unawaited(stopAll());
    notifyListeners();
  }

  void exitPlayer() {
    if (_disposed || !_playerActive) return;
    _playerActive = false;
    notifyListeners();
  }

  void setWindowActive(bool active) {
    if (_disposed || _windowActive == active) return;
    _windowActive = active;
    if (!active) unawaited(stopAll());
    notifyListeners();
  }

  void _cancelHoverTimers() {
    _backdropTimer?.cancel();
    _backdropTimer = null;
    _videoTimer?.cancel();
    _videoTimer = null;
  }

  static Future<void> _quiet(Future<void>? Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelHoverTimers();
    ++_hoverToken;
    ++_videoToken;
    ++_themeToken;
    unawaited(_immersionSub?.cancel());
    unawaited(_prefsSub?.cancel());
    unawaited(_quiet(() => _services?.immersion?.stop()));
    stage.removeListener(_onStageChanged);
    if (_ownsStage) stage.dispose();
    super.dispose();
  }
}
