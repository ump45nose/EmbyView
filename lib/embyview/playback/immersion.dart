import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../data/services/theme_music_service.dart';
import '../../playback/appletv_preview_player.dart';
import '../contracts/common.dart';
import '../contracts/internal/authorized_resources.dart';
import '../contracts/media.dart';
import '../contracts/playback.dart';
import '../contracts/preferences.dart';

/// Two ambient players. Neither creates a main playback/progress session.
class MacImmersionPlayback implements ImmersionPlayback {
  MacImmersionPlayback({
    required this.preferences,
    this.legacyThemeMusic,
    Stream<bool>? mainPlaybackChanges,
    Stream<Map>? themeEvents,
  }) {
    _themeEvents =
        (themeEvents ??
                _events
                    .receiveBroadcastStream()
                    .where((event) => event is Map)
                    .cast<Map>())
            .listen(_onThemeEvent, onError: (_) => _failTheme());
    _preferenceChanges = preferences.changes.listen(
      (_) => unawaited(_applyPreferences().catchError((_) {})),
    );
    _mainPlayback = mainPlaybackChanges?.listen((playing) {
      if (playing) unawaited(stop().catchError((_) {}));
    });
  }

  static const _control = MethodChannel('moonfin/appletv_theme_music');
  static const _events = EventChannel('moonfin/appletv_theme_music_events');
  // Moonfin's AppleTvThemeAudioPlayer owns nonnegative tokens.
  static int _nextToken = -2;
  Future<void> _send(
    String method,
    int token, [
    Map<String, Object?> extra = const {},
  ]) => _control.invokeMethod<void>(method, {'token': token, ...extra});
  final EmbyViewPreferences preferences;
  final ThemeMusicService? legacyThemeMusic;
  final _changes = StreamController<ImmersionSnapshot>.broadcast(sync: true);
  final _texture = ValueNotifier<int?>(null);
  late final StreamSubscription<Map> _themeEvents;
  late final StreamSubscription<LocalPreferences> _preferenceChanges;
  StreamSubscription<bool>? _mainPlayback;
  List<StreamSubscription<void>> _videoSubscriptions = [];
  AppleTvPreviewPlayer? _video;
  int? _themeToken;
  int _videoRevision = 0;
  int _themeRevision = 0;
  bool _muted = false;
  bool _closed = false;
  Future<void>? _closeFuture;
  EmbyViewFailure? _videoFailure;
  EmbyViewFailure? _themeFailure;
  ImmersionSnapshot _snapshot = const ImmersionSnapshot();
  @override
  ImmersionSnapshot get snapshot => _snapshot;
  @override
  Stream<ImmersionSnapshot> get changes => _changes.stream;
  void _publish({
    PreviewState? video,
    PreviewState? theme,
    Duration? position,
    Duration? duration,
    bool? muted,
    EmbyViewFailure? failure,
  }) {
    if (_closed) return;
    if (video != null) {
      _videoFailure = video == PreviewState.failed
          ? failure ?? _videoFailure
          : null;
    }
    if (theme != null) {
      _themeFailure = theme == PreviewState.failed
          ? failure ?? _themeFailure
          : null;
    }
    _snapshot = ImmersionSnapshot(
      video: video ?? _snapshot.video,
      theme: theme ?? _snapshot.theme,
      themePosition: position ?? _snapshot.themePosition,
      themeDuration: theme == PreviewState.idle || theme == PreviewState.loading
          ? duration
          : duration ?? _snapshot.themeDuration,
      themeMuted: muted ?? _snapshot.themeMuted,
      failure: _videoFailure ?? _themeFailure,
    );
    _changes.add(_snapshot);
  }

  AuthorizedPreviewRef _authorized(PreviewRef value) {
    if (value is! AuthorizedPreviewRef) {
      throw const EmbyViewFailure('预览资源不属于当前授权会话。');
    }
    return value;
  }

  @override
  Future<void> showMutedVideo(PreviewRef? video) async {
    if (_closed) return;
    final revision = ++_videoRevision;
    await _disposeVideo();
    if (revision != _videoRevision || _closed) return;
    if (video == null || !preferences.current.backgroundVideo) {
      _publish(video: PreviewState.idle);
      return;
    }
    _publish(video: PreviewState.loading);
    final player = AppleTvPreviewPlayer();
    _video = player;
    _videoSubscriptions = [
      player.errorStream.listen((_) {
        if (_video == player) {
          _publish(
            video: PreviewState.failed,
            failure: const EmbyViewFailure('背景预览暂时无法播放。', retryable: true),
          );
        }
      }),
      player.completedStream.listen((_) {
        if (_video == player) unawaited(showMutedVideo(null));
      }),
    ];
    try {
      final ref = _authorized(video);
      // Native open completes after AVPlayerItem.readyToPlay, including seek.
      await player
          .open(ref.uri.toString(), headers: ref.headers, volume: 0)
          .timeout(const Duration(seconds: 15));
      if (_video != player || revision != _videoRevision || _closed) return;
      _texture.value = player.textureId;
      await player.resume();
      _publish(video: PreviewState.ready);
    } catch (_) {
      if (_video != player || revision != _videoRevision || _closed) return;
      await _disposeVideo();
      const failure = EmbyViewFailure('背景预览暂时无法播放。', retryable: true);
      _publish(video: PreviewState.failed, failure: failure);
      throw failure;
    }
  }

  Future<void> _disposeVideo() async {
    final player = _video;
    final subscriptions = _videoSubscriptions;
    _video = null;
    _videoSubscriptions = [];
    _texture.value = null;
    await Future.wait(subscriptions.map((s) => s.cancel()));
    await player?.dispose();
  }

  @override
  Widget videoSurface({Key? key}) => ValueListenableBuilder<int?>(
    key: key,
    valueListenable: _texture,
    builder: (_, id, _) =>
        id == null ? const SizedBox.shrink() : Texture(textureId: id),
  );

  @override
  Future<void> playTheme(PreviewRef? song) async {
    if (_closed) return;
    final revision = ++_themeRevision;
    await _stopTheme();
    if (revision != _themeRevision || _closed) return;
    if (song == null || !preferences.current.themeMusic) return;
    _publish(
      theme: PreviewState.loading,
      position: Duration.zero,
      duration: song.duration,
    );
    try {
      final ref = _authorized(song);
      legacyThemeMusic?.forceStop();
      final token = _nextToken--;
      _themeToken = token;
      await _send('open', token, {
        'url': ref.uri.toString(),
        'headers': ref.headers,
      });
      if (_themeToken != token || revision != _themeRevision || _closed) return;
      await _send('setVolume', token, {
        'volume': preferences.current.themeVolume * 100,
      });
      await _send('setMuted', token, {'muted': _muted});
    } catch (_) {
      if (revision != _themeRevision || _closed) return;
      await _stopTheme();
      _failTheme();
      throw _snapshot.failure!;
    }
  }

  void _onThemeEvent(Map event) {
    if (_themeToken == null || event['token'] != _themeToken) return;
    final state = PreviewState.values
        .where((v) => v.name == event['state'])
        .firstOrNull;
    if (state == PreviewState.failed) {
      _failTheme();
      return;
    }
    _publish(
      theme: state,
      position: Duration(
        milliseconds: (event['positionMs'] as num? ?? 0).toInt(),
      ),
      duration: event['durationMs'] is num
          ? Duration(milliseconds: (event['durationMs'] as num).toInt())
          : null,
      muted: event['muted'] as bool?,
    );
  }

  void _failTheme() => _publish(
    theme: PreviewState.failed,
    failure: const EmbyViewFailure('主题曲暂时无法播放。', retryable: true),
  );
  @override
  Future<void> setThemeMuted(bool muted) async {
    _muted = muted;
    final token = _themeToken;
    if (token != null) {
      await _send('setMuted', token, {'muted': muted});
    }
    _publish(muted: muted || preferences.current.themeVolume == 0);
  }

  Future<void> _stopTheme() async {
    final token = _themeToken;
    _themeToken = null;
    if (token != null) {
      try {
        await _send('stop', token);
      } catch (_) {
        _themeToken ??= token;
        rethrow;
      }
    }
    _publish(theme: PreviewState.idle, position: Duration.zero);
  }

  Future<void> _applyPreferences() async {
    if (!preferences.current.backgroundVideo) await showMutedVideo(null);
    if (!preferences.current.themeMusic) {
      ++_themeRevision;
      await _stopTheme();
    } else if (_themeToken != null) {
      await _send('setVolume', _themeToken!, {
        'volume': preferences.current.themeVolume * 100,
      });
    }
  }

  @override
  Future<void> stop() async {
    if (_closed) return;
    ++_videoRevision;
    ++_themeRevision;
    legacyThemeMusic?.forceStop();
    await Future.wait([_disposeVideo(), _stopTheme()]);
    _publish(video: PreviewState.idle);
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    await stop();
    _closed = true;
    await _preferenceChanges.cancel();
    await _mainPlayback?.cancel();
    await _themeEvents.cancel();
    _texture.dispose();
    await _changes.close();
  }
}
