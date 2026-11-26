import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:playback_core/playback_core.dart';
import 'package:playback_emby/playback_emby.dart';
import 'package:server_core/server_core.dart';
import 'package:window_manager/window_manager.dart';

import '../../ui/widgets/aether_video_view.dart';
import '../../util/fullscreen_helper.dart';
import '../contracts/common.dart';
import '../contracts/media.dart';
import '../contracts/playback.dart';
import '../data/media_mapper.dart';
import 'native_playback.dart';
import 'playback_diagnostics.dart';
import 'playback_subtitle_input.dart';
import 'playback_thumbnails.dart';
import 'resolved_stream_resolver.dart';
import 'source_resolution.dart';

/// User-scoped facade over the existing Moonfin manager. The manager remains
/// the sole owner of queues and Emby start/progress/stop reports.
class MoonfinPlaybackAdapter implements EmbyViewPlayback {
  MoonfinPlaybackAdapter({
    required this.manager,
    required this.client,
    required this.native,
    this.data,
    this.beforeOpen,
    this.userAgent = embyViewPlaybackUserAgent,
    this.prefetch115 = true,
    this.autoNext = true,
    this.anime4k = false,
    bool? anime4kForAnime,
    bool? anime4kForOther,
    this.anime4kDefaults,
    this.isAnimeItem,
    this.sessionCacheByteBudget,
    PlaybackRedirectCache? redirectCache,
    NativePlaybackAudioInput? audioInput,
  }) : anime4kForAnime = anime4kForAnime ?? anime4k,
       anime4kForOther = anime4kForOther ?? anime4k,
       _cache = redirectCache ?? PlaybackRedirectCache(),
       audioInput = audioInput ?? NativePlaybackAudioInput() {
    _server = client.baseUrl;
    _user = client.userId ?? '';
    _resolver = EmbyViewStreamResolver(
      delegate: EmbyMediaStreamResolver(client),
      cache: _cache,
      server: _server,
      user: _user,
      userAgent: userAgent,
      prefetchEnabled: prefetch115,
      onResolved: _resolved,
    );
  }
  late final _mapper = MediaMapper(server: _server, user: _user, token: client.accessToken ?? '');
  final PlaybackManager manager;
  final MediaServerClient client;
  final EmbyViewNativePlayback native;
  final EmbyViewData? data;
  final Future<void> Function()? beforeOpen;
  final String userAgent;
  final bool prefetch115;
  final bool autoNext;
  final bool anime4k;
  final bool anime4kForAnime;
  final bool anime4kForOther;
  final ({bool anime, bool other}) Function()? anime4kDefaults;

  /// Uses the data adapter's known library membership; null means unknown.
  final bool? Function(Map<String, dynamic> item)? isAnimeItem;
  final int? sessionCacheByteBudget;
  final NativePlaybackAudioInput audioInput;
  final PlaybackRedirectCache _cache;
  final diagnostics = PlaybackDiagnostics();
  late final String _server;
  late final String _user;
  late final EmbyViewStreamResolver _resolver;
  final _prepared = <String, Future<void>>{};
  MoonfinPlaybackSession? _active;
  Future<void> _handoff = Future.value();
  Future<void>? _dispose;
  void Function()? _restoreManager;
  static int _sourceGeneration = 0;
  bool get _valid => _dispose == null && client.baseUrl == _server && client.userId == _user;

  @override
  Future<void> prepare(String itemId) {
    if (!_valid || !prefetch115) return Future.value();
    return _prepared.putIfAbsent(itemId, () async {
      final watch = Stopwatch()..start();
      try {
        final item = await client.itemsApi.getItem(itemId);
        final resolver = EmbyViewStreamResolver(
          delegate: EmbyMediaStreamResolver(client),
          cache: _cache,
          server: _server,
          user: _user,
          userAgent: userAgent,
          onResolved: (_, result, info, address) {
            diagnostics.record(
              PlaybackTiming(
                itemId: itemId,
                generation: 0,
                event: 'prepare',
                elapsed: watch.elapsed,
                playbackInfo: info,
                redirect: address?.elapsed,
                cacheHit: address?.cacheHit,
              ),
            );
          },
        );
        if (_valid) {
          await resolver.resolve(item, deviceProfile: native.backend.getDeviceProfile());
        }
      } catch (_) {
        diagnostics.record(
          PlaybackTiming(
            itemId: itemId,
            generation: 0,
            event: 'prepare',
            elapsed: watch.elapsed,
            failure: 'prepareUnavailable',
          ),
        );
      } finally {
        _prepared.remove(itemId);
      }
    });
  }

  @override
  PlaybackSession open(PlayTarget target) {
    if (!_valid) throw const EmbyViewFailure('播放账号已变更，请重新打开。', retryable: true);
    final previous = _active;
    final session = MoonfinPlaybackSession._(this, target);
    _active = session;
    _handoff = _handoff
        .catchError((_) {})
        .then((_) async {
          await previous?.close();
          if (!_valid || !identical(_active, session) || session._closing) {
            return;
          }
          _restoreManager ??= manager.bindPlaybackSource(
            _resolver,
            EmbyPlaySessionService(client),
            backend: native.backend,
            verifyExternalSubtitles: true,
          );
          manager.autoAdvanceEnabled = autoNext;
          manager.sourceFailureRecovery = session._recoverSource;
          await beforeOpen?.call();
          if (_valid && identical(_active, session) && !session._closing) {
            unawaited(session._start());
          }
        })
        .catchError((Object error) {
          session._fail('播放无法打开，请重试。', 'openFailed');
        });
    return session;
  }

  void _resolved(
    dynamic item,
    StreamResolutionResult result,
    Duration infoTime,
    ResolvedPlaybackAddress? address, {
    int? subtitleSwitchFrom,
    bool disablesSubtitles = false,
  }) {
    final session = _active;
    if (!_valid || session == null || session._closing || playbackItemId(item) != session._target.itemId) {
      return;
    }
    final generation = ++_sourceGeneration;
    final defaults = anime4kDefaults?.call() ?? (anime: anime4kForAnime, other: anime4kForOther);
    session._animeRequested =
        session._animeOverride ??
        (isAnimeItem?.call(playbackItemData(item)) == true ? defaults.anime : defaults.other);
    native.configureNextSource(
      sourceGeneration: generation,
      sessionCacheByteBudget: sessionCacheByteBudget,
      anime4k: session._animeRequested,
    );
    session._resolved(item, result, generation, infoTime, address, subtitleSwitchFrom, disablesSubtitles);
  }

  /// Called before replacing an authenticated client. This waits for the old
  /// manager's Stop and any late progress completion before releasing bindings.
  Future<void> dispose() => _dispose ??= () async {
    await _active?.close();
    await _handoff;
    _restoreManager?.call();
    _restoreManager = null;
    _cache.close();
    _resolver.forget();
    await diagnostics.close();
  }();
}

class MoonfinPlaybackSession with WindowListener implements PlaybackSession, PlaybackSubtitleInput {
  MoonfinPlaybackSession._(this._owner, this._target)
    : _snapshot = PlaybackSnapshot(generation: 0, target: _target),
      _animeRequested = _owner.anime4k,
      _thumbnails = PlaybackThumbnails(_owner.client, '${_owner._server}:${_owner._user}') {
    _intent.start();
  }
  final MoonfinPlaybackAdapter _owner;
  PlaybackManager get _manager => _owner.manager;
  PlayTarget _target;
  PlaybackSnapshot _snapshot;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();
  final _sources = StreamController<PlaybackSubtitleSource?>.broadcast();
  final _subscriptions = <StreamSubscription>[];
  final _intent = Stopwatch();
  final PlaybackThumbnails _thumbnails;
  Future<void>? _close;
  bool _ended = false;
  bool _failed = false;
  bool _retryUsed = false;
  bool _fullscreen = false;
  bool _creditsDismissed = false;
  bool _creditsShown = false;
  bool _binding = false;
  bool _acceptNativeEvents = false;
  bool _animeRequested;
  bool? _animeOverride;
  final _externalSubtitles = <_SessionSubtitle>[];
  final _indexedExternalIds = <String, int>{};
  int? _selectedExternal;
  int? _pendingExternal;
  String? _liveSubtitleId, _previousSubtitleId;
  bool _wantsLiveSubtitle = false, _liveRendererReady = false;
  int _subtitleChoice = 0;
  int _audioChoice = 0, _transportRevision = 0;
  int? _previousTrackGeneration;
  bool _reopenedWithoutSubtitles = false;
  int _nativeEnableAttempts = 0;
  ({String? selected, String? previous, bool live, int nativeEnableAttempts})? _beforeSubtitleChoice;
  int _subtitleMediaEpoch = 0;
  bool _reloadExternal = false;
  Future<void> _subtitleOperations = Future.value();
  Duration? _reopenPosition;
  Duration? _firstFrame;
  Duration? _creditsStart;
  Duration? _navigationTime;
  Duration? _infoTime;
  Duration? _redirectTime;
  Duration? _openingAt;
  Duration? _engineOpen;
  bool? _cacheHit;
  Map<String, dynamic> _raw = {};
  List<ChapterMark> _chapters = const [];
  MediaCard? _item;
  MediaCard? _next;
  MediaQuality? _quality;
  PlaybackSubtitleSource? _subtitleSource;
  NativePlaybackSnapshot _native = const NativePlaybackSnapshot();
  bool get _closing => _close != null;
  bool get _current => !_closing && identical(_owner._active, this) && _owner._valid;
  @override
  PlaybackSnapshot get snapshot => _snapshot;
  @override
  Stream<PlaybackSnapshot> get changes => _changes.stream;
  @override
  PlaybackSubtitleSource? get subtitleSource => _subtitleSource;
  @override
  Stream<PlaybackSubtitleSource?> get subtitleSources => _sources.stream;
  @override
  NativePlaybackAudioInput get audioInput => _owner.audioInput;

  Future<void> _start() async {
    _bind();
    try {
      final raw = await _owner.client.itemsApi.getItem(_target.itemId);
      if (!_current) return;
      _raw = raw;
      _item = _owner._mapper.card(raw);
      final series = _target.seriesId ?? raw['SeriesId'] as String?;
      var queue = <dynamic>[raw];
      var index = 0;
      if (series != null) {
        try {
          final response = await _owner.client.itemsApi.getEpisodes(
            series,
            fields: 'MediaSources,MediaStreams,Chapters,Path,UserData',
          );
          if (!_current) return;
          final episodes = (response['Items'] as List? ?? [])
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
          final current = episodes.indexWhere((item) => playbackItemId(item) == _target.itemId);
          if (current >= 0) {
            queue = episodes;
            index = current;
            queue[index] = raw;
          }
        } catch (_) {
          /* Current episode can play when next-up is unavailable. */
        }
      }
      if (!_current) return;
      _navigationTime = _intent.elapsed;
      await _manager.playItems(queue, startIndex: index, startPosition: _target.startAt ?? Duration.zero);
      if (_current) _emit();
    } catch (_) {
      if (_current) _fail('播放无法打开，请重试。', 'openFailed');
    }
  }

  void _bind() {
    if (_binding) return;
    _binding = true;
    windowManager.addListener(this);
    final state = _manager.state;
    _subscriptions.addAll([
      state.positionStream.listen((_) => _emit()),
      state.durationStream.listen((_) => _emit()),
      state.bufferStream.listen((_) => _emit()),
      state.playingStream.listen((_) => _emit()),
      state.bufferingStream.listen((_) => _emit()),
      _manager.volumeStream.listen((_) => _emit()),
      _manager.bringupStateStream.listen((bringup) {
        if (!_current) return;
        if (bringup.phase == PlaybackBringupPhase.resolving) _acceptNativeEvents = false;
        if (bringup.phase == PlaybackBringupPhase.failed) {
          _fail('播放中断，请重试。', 'engineFailed');
        } else if (bringup.phase == PlaybackBringupPhase.ready) {
          if (_openingAt != null) _engineOpen = _intent.elapsed - _openingAt!;
          _record('ready');
          _emit();
          if (_reloadExternal) unawaited(_restoreExternalSubtitles());
        } else {
          _emit();
        }
      }),
      _manager.queueService.queueChangedStream.listen((_) => _queueChanged()),
      _manager.sessionEndedStream.listen((_) {
        if (_current) {
          _ended = true;
          _emit();
          unawaited(close());
        }
      }),
      _owner.native.changes.listen((native) {
        if (!_current || !_acceptNativeEvents || native.sourceGeneration != _subtitleSource?.generation) {
          return;
        }
        _native = native;
        if (native.firstFrame && _firstFrame == null) {
          _firstFrame = _intent.elapsed;
          _record('firstFrame');
        }
        _emit();
      }),
      _owner.native.backend.remoteCommandStream.listen((event) {
        if (!_current) return;
        switch (event['event']) {
          case 'play':
            unawaited(resume());
          case 'pause':
            unawaited(pause());
          case 'togglePlayPause':
            unawaited(_manager.state.isPlaying ? pause() : resume());
          case 'next':
            unawaited(playNext());
          case 'stop':
            unawaited(close());
        }
      }),
    ]);
  }

  @override
  void onWindowEnterFullScreen() {
    _fullscreen = true;
    _emit();
  }

  @override
  void onWindowLeaveFullScreen() {
    _fullscreen = false;
    _emit();
  }

  void _queueChanged() {
    if (!_current) return;
    final raw = playbackItemData(_manager.queueService.currentItem);
    final id = playbackItemId(raw);
    if (id.isNotEmpty && id != _target.itemId) {
      _target = PlayTarget(
        itemId: id,
        seriesId: raw['SeriesId'] as String?,
        seasonId: raw['SeasonId'] as String?,
        episodeNumber: (raw['IndexNumber'] as num?)?.toInt(),
      );
      _raw = raw;
      _item = _owner._mapper.card(raw);
      _quality = null;
      _chapters = const [];
      _retryUsed = false;
      _animeOverride = null;
      _failed = false;
      _ended = false;
      _creditsShown = false;
      _creditsDismissed = false;
      _creditsStart = null;
      _firstFrame = null;
      _reopenPosition = null;
      _navigationTime = Duration.zero;
      _engineOpen = null;
      _native = const NativePlaybackSnapshot();
      _acceptNativeEvents = false;
      _externalSubtitles.clear();
      ++_subtitleMediaEpoch;
      _indexedExternalIds.clear();
      _selectedExternal = null;
      _pendingExternal = null;
      _reloadExternal = false;
      _subtitleSource = null;
      _clearLiveSubtitle();
      _sources.add(null);
      _thumbnails.clear();
      _intent
        ..reset()
        ..start();
    }
    final next = playbackItemData(_manager.queueService.peekNext);
    _next = next.isEmpty ? null : _owner._mapper.card(next);
    _emit();
  }

  void _resolved(
    dynamic item,
    StreamResolutionResult result,
    int generation,
    Duration infoTime,
    ResolvedPlaybackAddress? address,
    int? subtitleSwitchFrom,
    bool disablesSubtitles,
  ) {
    _raw = playbackItemData(item);
    _creditsStart = null;
    _infoTime = infoTime;
    _redirectTime = address?.elapsed;
    _cacheHit = address?.cacheHit;
    _openingAt = _intent.elapsed;
    _beforeSubtitleChoice = null;
    _previousTrackGeneration = null;
    final reopensForSubtitle = subtitleSwitchFrom != null &&
        _subtitleSource?.generation == subtitleSwitchFrom &&
        _subtitleSource?.mediaSourceId == result.mediaSourceId &&
        _subtitleSource?.target.itemId == _target.itemId;
    _reopenedWithoutSubtitles = reopensForSubtitle && disablesSubtitles;
    _clearLiveSubtitle();
    _native = NativePlaybackSnapshot(sourceGeneration: generation);
    _acceptNativeEvents = true;
    if (_subtitleSource?.mediaSourceId != result.mediaSourceId) {
      _externalSubtitles.clear();
      ++_subtitleMediaEpoch;
      _pendingExternal = null;
    } else {
      _pendingExternal = reopensForSubtitle ? null : _selectedExternal ?? _pendingExternal;
    }
    _indexedExternalIds.clear();
    _selectedExternal = null;
    _reloadExternal = _externalSubtitles.isNotEmpty;
    final source = (_raw['MediaSources'] as List? ?? [])
        .whereType<Map>()
        .where((source) => source['Id'].toString() == result.mediaSourceId)
        .firstOrNull;
    _subtitleSource = PlaybackSubtitleSource(
      generation: generation,
      target: _target,
      mediaSourceId: result.mediaSourceId,
      address: Uri.parse(result.streamUrl),
      headers: Map.unmodifiable(result.requestHeaders),
      userAgent: _owner.userAgent,
      itemFilePath: playbackItemPath(item),
      subtitleSwitchFrom: reopensForSubtitle ? subtitleSwitchFrom : null,
      mediaSourceFilePath: source?['Path'] as String?,
    );
    _snapshot = PlaybackSnapshot(
      generation: generation,
      target: _target,
      item: _item,
      mediaSourceId: result.mediaSourceId,
      firstFrameLatency: _firstFrame,
      phase: PlaybackPhase.opening,
    );
    _sources.add(_subtitleSource);
    _record('resolved');
    _emit();
    unawaited(_refreshFacts(generation, result));
  }

  Future<void> _refreshFacts(int generation, StreamResolutionResult result) async {
    final raw = _raw;
    final source = (raw['MediaSources'] as List? ?? [])
        .whereType<Map>()
        .where((source) => source['Id'].toString() == result.mediaSourceId)
        .firstOrNull;
    final chapterRows = source?['Chapters'] as List? ?? raw['Chapters'] as List? ?? const [];
    _chapters =
        chapterRows
            .whereType<Map>()
            .map(
              (chapter) => ChapterMark(
                start: Duration(microseconds: ((chapter['StartPositionTicks'] as num?)?.toInt() ?? 0) ~/ 10),
                name: chapter['Name'] as String?,
              ),
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    for (final chapter in chapterRows.whereType<Map>()) {
      final name = '${chapter['MarkerType'] ?? ''} ${chapter['Name'] ?? ''}'.toLowerCase();
      if (name.contains('credits') || name.contains('片尾')) {
        final ticks = (chapter['StartPositionTicks'] as num?)?.toInt();
        if (ticks != null && ticks > 0) {
          _creditsStart = Duration(microseconds: ticks ~/ 10);
          break;
        }
      }
    }
    _manager.setChapterStarts(_chapters.map((c) => c.start).toList());
    _quality = _sourceQuality(result);
    _emit();
    unawaited(_thumbnails.load(_target.itemId, result.mediaSourceId, raw).catchError((_) {}));
    unawaited(_loadCredits(generation));
    final data = _owner.data;
    if (data == null) return;
    try {
      final detail = await data.detail(_target.itemId);
      if (!_current || _snapshot.generation != generation) return;
      _item = detail.card;
      _emit();
    } catch (_) {
      /* Browsing labels do not block the negotiated source. */
    }
  }

  Future<void> _loadCredits(int generation) async {
    try {
      final segments = await _owner.client.itemsApi.getMediaSegments(_target.itemId);
      if (!_current || _snapshot.generation != generation) return;
      for (final segment in segments) {
        final kind = '${segment['Type'] ?? segment['SegmentType'] ?? ''}'.toLowerCase();
        final ticks = segment['StartTicks'] ?? segment['StartPositionTicks'];
        if (kind.contains('credits') && ticks is num && ticks > 0) {
          _creditsStart = Duration(microseconds: ticks.toInt() ~/ 10);
          _emit();
          break;
        }
      }
    } catch (_) {
      /* Missing segment metadata uses the final five seconds. */
    }
  }

  Future<bool?> _recoverSource(PlaybackSourceFailureContext context) async {
    if (!_current) return false;
    final key = _owner._resolver.keyFor(context.resolution);
    if (key == null || !isExpiringPlaybackAddress(context.error)) return null;
    if (context.position > Duration.zero) _reopenPosition = context.position;
    _owner._cache.invalidate(key);
    if (_retryUsed) {
      _record('failed', failure: 'addressRetryExhausted');
      return false;
    }
    _retryUsed = true;
    _record('retry', failure: context.error == null ? 'openTimeout' : 'addressExpired');
    return true;
  }

  void _record(String event, {String? failure}) => _owner.diagnostics.record(
    PlaybackTiming(
      itemId: _target.itemId,
      generation: _snapshot.generation,
      event: event,
      elapsed: _intent.elapsed,
      navigation: _navigationTime,
      playbackInfo: _infoTime,
      redirect: _redirectTime,
      engineOpen: _engineOpen,
      firstFrame: _firstFrame,
      cacheHit: _cacheHit,
      failure: failure,
    ),
  );

  void _fail(String reason, String category) {
    if (_closing) return;
    _failed = true;
    _record('failed', failure: category);
    _emit(failure: EmbyViewFailure(reason, retryable: true, code: category));
  }

  void _emit({EmbyViewFailure? failure}) {
    if (!_current) return;
    final state = _manager.state;
    final resolution = _subtitleSource == null ? null : _manager.currentResolution;
    if (resolution != null) {
      _quality = _sourceQuality(
        resolution,
        audioIndex: _manager.audioStreamIndex,
        server: _owner._server,
        itemPath: _raw['Path'] as String?,
      );
    }
    // Aether can emit an empty clock while its old item is being stopped,
    // including after a failed replacement. Keep the last resumable point.
    final position = state.position == Duration.zero ? _reopenPosition ?? state.position : state.position;
    final duration = state.duration > Duration.zero ? state.duration : _item?.duration;
    final credits =
        _creditsStart ??
        (duration != null && duration > const Duration(seconds: 5)
            ? duration - const Duration(seconds: 5)
            : null);
    if (!_creditsShown && !_creditsDismissed && _next != null && credits != null && position >= credits) {
      _creditsShown = true;
    }
    final phase = _failed
        ? PlaybackPhase.failed
        : _ended
        ? PlaybackPhase.ended
        : _manager.bringupState.phase.isInProgress
        ? (_manager.bringupState.phase == PlaybackBringupPhase.resolving
              ? PlaybackPhase.preparing
              : PlaybackPhase.opening)
        : state.isBuffering
        ? PlaybackPhase.buffering
        : state.isPlaying
        ? PlaybackPhase.playing
        : PlaybackPhase.paused;
    String? trackId(int? index) => index == null || index < 0 ? null : '${_snapshot.generation}:$index';
    _snapshot = PlaybackSnapshot(
      generation: _snapshot.generation,
      target: _target,
      item: _item,
      phase: phase,
      firstFrameLatency: _firstFrame,
      position: position,
      duration: duration,
      bufferedUntil: state.buffer,
      mediaSourceId: _subtitleSource?.mediaSourceId,
      quality: _quality,
      chapters: List.unmodifiable(_chapters),
      audioTracks: _tracks(resolution?.mediaStreams ?? [], 'Audio'),
      subtitleTracks: [
        ..._tracks(resolution?.mediaStreams ?? [], 'Subtitle'),
        if (_liveSubtitleId case final liveId?)
          PlaybackTrack(id: liveId, name: '简体中文 · AI 生成', language: 'zh', source: PlaybackTrackSource.ai),
        for (var i = 0; i < _externalSubtitles.length; i++)
          if (_indexedExternalIds[_externalSubtitles[i].contentKey] == null)
            PlaybackTrack(
              id: _externalId(i),
              name: _externalSubtitles[i].title ?? '外挂字幕',
              language: _externalSubtitles[i].language,
              source: _externalSubtitles[i].source,
              format: _externalSubtitles[i].codec,
            ),
      ],
      selectedAudioId: trackId(_manager.audioStreamIndex),
      subtitleOverlayId: _wantsLiveSubtitle && _liveRendererReady ? _liveSubtitleId : null,
      selectedSubtitleId: _wantsLiveSubtitle
          ? _liveSubtitleId
          : _selectedExternal != null
          ? _visibleExternalId(_selectedExternal!)
          : _pendingExternal != null
          ? null
          : trackId(_manager.subtitleStreamIndex),
      volume: (_manager.volume / 100).clamp(0.0, 1.0),
      muted: _manager.isMuted,
      nextEpisode: _next,
      creditsStart: credits,
      creditsPrompt: _creditsDismissed
          ? CreditsPromptState.dismissed
          : _creditsShown
          ? CreditsPromptState.countingDown
          : CreditsPromptState.hidden,
      fullscreenSupported: true,
      fullscreen: _fullscreen,
      pictureInPictureSupported: _native.pictureInPictureSupported,
      pictureInPicture: _native.pictureInPicture,
      anime4k: _native.anime4k,
      failure: failure ?? (_failed ? _snapshot.failure : null),
    );
    _changes.add(_snapshot);
  }

  List<PlaybackTrack> _tracks(List<Map<String, dynamic>> streams, String type) => [
    for (final stream in streams)
      if (stream['Type'] == type && stream['Index'] is num)
        PlaybackTrack(
          id: '${_snapshot.generation}:${(stream['Index'] as num).toInt()}',
          name: (stream['DisplayTitle'] ?? stream['Title'] ?? stream['Language'] ?? type).toString(),
          language: stream['Language'] as String?,
          format: stream['Codec'] as String?,
          layout: stream['ChannelLayout'] as String?,
          isForced: stream['IsForced'] == true,
          qualifiers: type == 'Subtitle' ? embySubtitleQualifiers(stream) : const [],
          source: stream['IsExternal'] == true
              ? PlaybackTrackSource.embyExternal
              : PlaybackTrackSource.embedded,
        ),
  ];
  int _trackIndex(String id) {
    final parts = id.split(':');
    if (parts.length != 2 ||
        int.tryParse(parts[0]) != _snapshot.generation ||
        int.tryParse(parts[1]) == null) {
      throw const EmbyViewFailure('音轨或字幕已更新，请重新选择。', retryable: true);
    }
    return int.parse(parts[1]);
  }

  @override
  Widget videoSurface({Key? key}) => AetherVideoView(key: key);
  @override
  Future<void> resume() => _control(_manager.resume);

  @override
  Future<void> pause() => _control(_manager.pause);

  @override
  Future<void> seek(Duration position) async {
    if (!_current) return;
    ++_transportRevision;
    _reopenPosition = null;
    final end = _snapshot.duration;
    final clamped = position < Duration.zero
        ? Duration.zero
        : end != null && position > end
        ? end
        : position;
    await _manager.seekTo(clamped);
    _emit();
  }

  @override
  Future<void> seekBy(Duration delta) => seek(_snapshot.position + delta);
  @override
  Future<void> setVolume(double fraction) async {
    if (!_current) return;
    final volume = fraction.clamp(0.0, 1.0) * 100;
    await _owner.native.backend.setVolume(_manager.isMuted ? 0 : volume);
    _manager.reportVolumeState(volume: volume, isMuted: _manager.isMuted, reportImmediately: true);
    _emit();
  }

  @override
  Future<void> setMuted(bool muted) async {
    if (!_current) return;
    await _owner.native.backend.setVolume(muted ? 0 : _manager.volume);
    _manager.reportVolumeState(volume: _manager.volume, isMuted: muted, reportImmediately: true);
    _emit();
  }

  @override
  Future<void> selectAudio(String trackId) async {
    final index = _trackIndex(trackId);
    final choice = ++_audioChoice, generation = _snapshot.generation, mediaEpoch = _subtitleMediaEpoch;
    return _subtitleOperation(() async {
      final currentGeneration = _snapshot.generation;
      if (!_current || choice != _audioChoice || mediaEpoch != _subtitleMediaEpoch ||
          (generation != currentGeneration && _previousTrackGeneration != generation) ||
          index == _manager.audioStreamIndex && _manager.currentResolution != null) return;
      try {
        await _control(() => _manager.changeAudioTrack(
          index, prepareReopen: _prepareTrackReopen(currentGeneration, () => choice == _audioChoice, 'audio'),
        ));
      } on EmbyViewFailure catch (failure) {
        if (failure.code != 'trackSwitchCancelled') rethrow;
      }
    });
  }

  PrepareTrackReopen _prepareTrackReopen(int generation, bool Function() stillSelected, String kind) {
    final transport = _transportRevision;
    bool current() => _current && !_failed && !_ended && stillSelected() &&
        _transportRevision == transport && _snapshot.generation == generation;
    return (request) async {
      void checkCurrent() {
        if (!current()) throw const EmbyViewFailure('轨道选择已更新。', code: 'trackSwitchCancelled');
      }
      checkCurrent();
      late StreamResolutionResult Function() activate;
      try {
        await _owner._resolver.resolve(
          _manager.queueService.currentItem,
          deviceProfile: request.deviceProfile,
          maxStreamingBitrate: request.maxStreamingBitrate,
          audioStreamIndex: request.audioStreamIndex,
          subtitleStreamIndex: request.subtitleStreamIndex,
          startTimeTicks: request.position.inMicroseconds * 10,
          mediaSourceId: request.mediaSourceId,
          enableDirectPlay: request.enableDirectPlay,
          enableDirectStream: request.enableDirectStream,
          enableTranscoding: request.enableTranscoding,
          freshAddress: true,
          onPrepared: (item, result, info, address) {
            activate = () {
              _owner._resolved(item, result, info, address,
                subtitleSwitchFrom: kind == 'audio' ? null : generation, disablesSubtitles: kind == 'off');
              if (result.mediaSourceId == request.mediaSourceId) _previousTrackGeneration = generation;
              _record('trackReopen.$kind');
              return result;
            };
          },
        );
      } catch (_) {
        checkCurrent();
        _record('trackReopenRejected.$kind', failure: 'sourceUnavailable');
        throw const EmbyViewFailure('暂时无法取得播放源，已保留原轨道。', retryable: true, code: 'trackSourceUnavailable');
      }
      checkCurrent();
      _reopenPosition = _manager.currentPlaybackPosition;
      return activate;
    };
  }

  @override
  int get subtitleSelectionRevision => _subtitleChoice;

  void _clearLiveSubtitle() {
    _previousSubtitleId = null;
    _liveSubtitleId = null;
    _wantsLiveSubtitle = false;
    _liveRendererReady = false;
  }

  @override
  Future<void> setLiveSubtitle(String trackId, {required int generation, required bool select}) async {
    _checkSubtitleGeneration(generation);
    final follow = select || _wantsLiveSubtitle;
    _liveSubtitleId = trackId;
    if (follow) {
      if (_wantsLiveSubtitle && _liveRendererReady) {
        if (select) ++_subtitleChoice;
      } else {
        return selectSubtitle(trackId);
      }
    }
    _emit();
  }

  @override
  Future<void> endLiveSubtitle(String trackId, {String? replacementId}) {
    if (trackId != _liveSubtitleId) return Future.value();
    if (replacementId == null || !_wantsLiveSubtitle) {
      final restore = _wantsLiveSubtitle, previous = _previousSubtitleId;
      _clearLiveSubtitle();
      _emit();
      return restore && _current && !_ended && !_failed && _acceptNativeEvents
          ? selectSubtitle(previous)
          : Future.value();
    }
    final generation = _snapshot.generation;
    return _subtitleOperation(() async {
      bool current() => _current && trackId == _liveSubtitleId && _wantsLiveSubtitle;
      if (trackId != _liveSubtitleId) return;
      if (current()) {
        _liveRendererReady = false;
        _emit();
        await _selectNativeSubtitle(replacementId, generation, current);
      }
      if (trackId == _liveSubtitleId) {
        _clearLiveSubtitle();
        _emit();
      }
    });
  }

  @override
  Future<void> selectSubtitle(String? trackId) async {
    final generation = _snapshot.generation, mediaEpoch = _subtitleMediaEpoch;
    if (trackId != null && trackId != _liveSubtitleId && !trackId.startsWith('$generation:external')) {
      _trackIndex(trackId); // Reject a retired row before changing the current selection.
    }
    final before = _beforeSubtitleChoice ??= (
      selected: _snapshot.selectedSubtitleId,
      previous: _previousSubtitleId,
      live: _wantsLiveSubtitle && _liveRendererReady,
      nativeEnableAttempts: _nativeEnableAttempts,
    );
    final choice = ++_subtitleChoice;
    final live = trackId != null && trackId == _liveSubtitleId;
    if (live && !_wantsLiveSubtitle) _previousSubtitleId = _snapshot.selectedSubtitleId;
    _wantsLiveSubtitle = live;
    _liveRendererReady = false;
    _emit();
    return _subtitleOperation(() async {
      bool current() => choice == _subtitleChoice && (!live || trackId == _liveSubtitleId);
      try {
        if (choice != _subtitleChoice) return;
        var targetGeneration = generation;
        var rendererId = live ? null : trackId;
        // A pick made after teardown began still belongs to this file. Only
        // carry it through this exact track replacement, never through a
        // navigation, seek recovery or a different media version.
        if (_snapshot.generation != generation && _previousTrackGeneration == generation &&
            _subtitleMediaEpoch == mediaEpoch) {
          targetGeneration = _snapshot.generation;
          if (rendererId != null) rendererId = '$targetGeneration:${rendererId.split(':').last}';
          if (live && _liveSubtitleId == null) _liveSubtitleId = trackId;
          _wantsLiveSubtitle = live;
        }
        if (!current()) return;
        await _selectNativeSubtitle(rendererId, targetGeneration, current);
        if (current()) _liveRendererReady = live;
      } catch (error) {
        if (current() && _current && generation == _snapshot.generation) {
          final restoreLive = before.live && before.selected == _liveSubtitleId;
          final restore = before.live ? before.previous : before.selected;
          _wantsLiveSubtitle = restoreLive;
          _previousSubtitleId = before.previous;
          // The manager may already have changed its stream index before the
          // renderer rejected the command. Reapply the last committed choice.
          // If only a disable was attempted, the native renderer was already
          // confirmed off for this live track and could never have turned on.
          final sourceUntouched = error is ExternalSubtitleUnavailable || error is EmbyViewFailure &&
              (error.code == 'trackSourceUnavailable' || error.code == 'trackSwitchCancelled');
          if (!sourceUntouched && (!restoreLive || before.nativeEnableAttempts != _nativeEnableAttempts)) {
            await _selectNativeSubtitle(restoreLive ? null : restore, generation, current, force: true);
          }
          if (current()) _liveRendererReady = restoreLive;
        }
        if (error is ExternalSubtitleUnavailable) {
          throw const EmbyViewFailure('外挂字幕载入失败，已保留原轨道。', retryable: true);
        }
        if (error is EmbyViewFailure && error.code == 'trackSwitchCancelled') return;
        rethrow;
      } finally {
        if (choice == _subtitleChoice) {
          _beforeSubtitleChoice = null;
          _emit();
        }
      }
    });
  }

  Future<void> _selectNativeSubtitle(String? trackId, int generation, bool Function() current, {bool force = false}) async {
    _checkSubtitleGeneration(generation);
    final alreadyOff = _reopenedWithoutSubtitles && (_manager.subtitleStreamIndex ?? -1) < 0 &&
        _selectedExternal == null && _pendingExternal == null;
    _reopenedWithoutSubtitles = false;
    if (trackId == null && alreadyOff) return;
    await _applyNativeSubtitle(trackId, generation, current, force: force);
  }

  Future<void> _applyNativeSubtitle(String? trackId, int generation, bool Function() current, {required bool force}) async {
    final source = _subtitleSource!;
    final mediaEpoch = _subtitleMediaEpoch;
    int? externalIndex, streamIndex;
    if (trackId != null && trackId.startsWith('$generation:external')) {
      externalIndex = int.tryParse(trackId.split('external').last);
      if (externalIndex == null || externalIndex < 0 || externalIndex >= _externalSubtitles.length) {
        throw const EmbyViewFailure('字幕已更新，请重新选择。', retryable: true);
      }
    } else if (trackId != null) {
      streamIndex = _trackIndex(trackId);
      final retained = _externalSubtitles.indexWhere((track) => _indexedExternalIds[track.contentKey] == streamIndex);
      // The surviving Emby ID represents the same subtitle. The retained
      // local delivery remains selectable without another server download.
      if (retained >= 0) externalIndex = retained;
    }
    if (externalIndex != null) {
      if (!force && _selectedExternal == externalIndex) return;
      final subtitle = _externalSubtitles[externalIndex];
      // An already active local sidecar can be replaced directly: turning
      // it off first would lose the current subtitle when loading fails.
      if (_selectedExternal == null) {
        await _manager.disableSubtitles(prepareReopen: _prepareTrackReopen(generation, current, 'off'));
        if (!current()) return;
        if (_subtitleSource?.subtitleSwitchFrom == generation && _subtitleMediaEpoch == mediaEpoch) {
          generation = _snapshot.generation;
        }
        _checkSubtitleGeneration(generation);
      }
      try {
        await _loadExternal(subtitle, generation, select: true);
      } catch (_) {
        if (_current && generation == _snapshot.generation) _emit();
        rethrow;
      }
      _checkSubtitleGeneration(generation);
      if (!current()) {
        // This RPC changed the renderer. A queued choice must reapply its
        // own delivery even if it was the previously committed sidecar.
        _selectedExternal = null;
        return;
      }
      _selectedExternal = externalIndex;
      _pendingExternal = null;
      return;
    }
    if (streamIndex == null) {
      await _manager.disableSubtitles(prepareReopen: _prepareTrackReopen(generation, current, 'off'));
    } else {
      ++_nativeEnableAttempts;
      await _manager.changeSubtitleTrack(streamIndex, prepareReopen: _prepareTrackReopen(generation, current, 'subtitle'));
    }
    // The manager may rebuild the same media source to apply the choice.
    // Only commit it after success; never clear a successor item's state.
    if (!_current ||
        mediaEpoch != _subtitleMediaEpoch ||
        _subtitleSource?.target.itemId != source.target.itemId ||
        _subtitleSource?.mediaSourceId != source.mediaSourceId) {
      throw const EmbyViewFailure('字幕所属的影片已变更。', retryable: true);
    }
    _selectedExternal = null;
    _pendingExternal = null;
  }

  @override
  Future<void> setAnime4k(bool enabled) async {
    if (_current) {
      _animeRequested = enabled;
      _animeOverride = enabled;
      await _owner.native.setAnime4k(enabled);
    }
  }

  @override
  Future<void> setAnime4kComparison(double? split) =>
      _control(() => _owner.native.setAnime4kComparison(split));

  @override
  Future<void> setPictureInPicture(bool enabled) =>
      _control(() => _owner.native.setPictureInPicture(enabled));

  @override
  Future<void> setFullscreen(bool enabled) async {
    if (!_current) return;
    await FullscreenHelper.setFullscreen(enabled);
    _fullscreen = await FullscreenHelper.isFullscreen();
    _emit();
  }

  @override
  Future<void> playNext({bool finishCurrent = false}) =>
      _control(finishCurrent ? _manager.nextInQueueAsFinished : _manager.nextInQueue);

  Future<void> _control(Future<void> Function() action) async {
    if (!_current) return;
    await action();
    _emit();
  }

  @override
  Future<void> dismissCreditsPrompt() async {
    if (!_current) return;
    _creditsDismissed = true;
    _manager.suppressAutoNext = true;
    _emit();
  }

  @override
  Future<ThumbnailFrame?> thumbnailAt(Duration position) async => _current ? _thumbnails.at(position) : null;
  @override
  Future<String> registerExternalSubtitle(
    String url, {
    required int generation,
    String? title,
    String? language,
    String? codec,
    String? contentKey,
    String? liveTrackId,
    PlaybackTrackSource source = PlaybackTrackSource.online,
  }) => _subtitleOperation(() async {
    void checkRegistration() {
      _checkSubtitleGeneration(generation);
      if (liveTrackId != null && liveTrackId != _liveSubtitleId) {
        throw const EmbyViewFailure('此轮字幕生成已结束。');
      }
    }
    checkRegistration();
    if (_indexedExternalIds[contentKey] case final index?) {
      return '$generation:$index';
    }
    final existing = _externalSubtitles.indexWhere((track) =>
        track.url == url || contentKey != null && track.contentKey == contentKey);
    final subtitle = existing >= 0
        ? _externalSubtitles[existing]
        : _SessionSubtitle(url, title, language, codec, contentKey, source);
    await _loadExternal(subtitle, generation, select: false);
    checkRegistration();
    if (existing >= 0) return _visibleExternalId(existing);
    final index = _externalSubtitles.length;
    _externalSubtitles.add(subtitle);
    _emit();
    return _visibleExternalId(index);
  });

  @override
  Future<void> reconcileIndexedSubtitle({
    required int generation,
    required String indexedTrackId,
    required String contentKey,
  }) async {
    _checkSubtitleGeneration(generation);
    final index = _trackIndex(indexedTrackId);
    if (!_snapshot.subtitleTracks.any((track) =>
        track.id == indexedTrackId && track.source == PlaybackTrackSource.embyExternal)) {
      throw const EmbyViewFailure('字幕已更新，请重新选择。', retryable: true);
    }
    if (_indexedExternalIds.containsKey(contentKey)) return;
    // Pure source-generation metadata, not an engine operation. This can
    // finish during a restoration RPC; its eventual selection is then
    // published directly under the surviving Emby ID.
    _indexedExternalIds[contentKey] = index;
    if (_externalSubtitles.any((track) => track.contentKey == contentKey)) _emit();
  }

  Future<T> _subtitleOperation<T>(Future<T> Function() action) {
    final pending = _subtitleOperations.then((_) => action());
    _subtitleOperations = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  void _checkSubtitleGeneration(int generation) {
    if (!_current ||
        !_acceptNativeEvents ||
        generation != _snapshot.generation ||
        _subtitleSource?.generation != generation) {
      throw const EmbyViewFailure('字幕所属的影片已变更。', retryable: true);
    }
  }

  Future<void> _loadExternal(_SessionSubtitle subtitle, int generation, {required bool select}) {
    if (select) ++_nativeEnableAttempts;
    return _owner.native.loadExternalSubtitle(
      subtitle.url,
      title: subtitle.title,
      language: subtitle.language,
      codec: subtitle.codec,
      sourceGeneration: generation,
      select: select,
    );
  }

  String _externalId(int index) => '${_snapshot.generation}:external$index';
  String _visibleExternalId(int index) {
    final indexed = _indexedExternalIds[_externalSubtitles[index].contentKey];
    return indexed == null ? _externalId(index) : '${_snapshot.generation}:$indexed';
  }
  Future<void> _restoreExternalSubtitles() {
    _reloadExternal = false;
    final generation = _snapshot.generation;
    return _subtitleOperation(() async {
      if (!_current || generation != _snapshot.generation) return;
      try {
        for (final subtitle in _externalSubtitles.toList()) {
          _checkSubtitleGeneration(generation);
          try {
            await _loadExternal(subtitle, generation, select: false);
          } catch (_) {
            // Keep the URL available for explicit retry even if this sidecar
            // temporarily failed to register; other tracks can still restore.
          }
        }
        _checkSubtitleGeneration(generation);
        if (_pendingExternal case final index?) {
          await _loadExternal(_externalSubtitles[index], generation, select: true);
          _checkSubtitleGeneration(generation);
          _selectedExternal = index;
          _pendingExternal = null;
          _emit();
        }
      } catch (_) {
        if (_current && _acceptNativeEvents && generation == _snapshot.generation) {
          _pendingExternal = null;
          _emit(failure: const EmbyViewFailure('外挂字幕加载失败，请重新选择。', retryable: true));
        }
      }
    });
  }

  @override
  Future<void> close() => _close ??= () async {
    _intent.stop();
    windowManager.removeListener(this);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    if (_binding) {
      if (_fullscreen) await FullscreenHelper.setFullscreen(false);
      await _manager.stopAndDrainReports();
      try {
        await audioInput.stop();
      } catch (_) {}
      _owner._restoreManager?.call();
      _owner._restoreManager = null;
    }
    _thumbnails.clear();
    _subtitleSource = null;
    _sources.add(null);
    await _sources.close();
    await _changes.close();
  }();
}

class _SessionSubtitle {
  const _SessionSubtitle(this.url, this.title, this.language, this.codec, this.contentKey, this.source);
  final String url;
  final String? title;
  final String? language;
  final String? codec;
  final String? contentKey;
  final PlaybackTrackSource source;
}

MediaQuality _sourceQuality(StreamResolutionResult result, {int? audioIndex, String? server, String? itemPath}) {
  final video = result.mediaStreams.where((s) => s['Type'] == 'Video').firstOrNull;
  final width = (video?['Width'] as num?)?.toInt();
  final audios = result.mediaStreams.where((s) => s['Type'] == 'Audio');
  final index = audioIndex ?? result.selectedAudioStreamIndex;
  final audio = index == null
      ? audios.where((s) => s['IsDefault'] == true).firstOrNull ?? audios.singleOrNull
      : audios.where((s) => s['Index'] == index).firstOrNull;
  final host = Uri.tryParse(result.streamUrl)?.host ?? '';
  return MediaQuality(
    resolution: width == null
        ? null
        : width >= 3840
        ? '4K'
        : width >= 1920
        ? '1080p'
        : width >= 1280
        ? '720p'
        : null,
    videoRange: result.videoRangeType,
    audioLabel: embyAudioTechnicalLabel(audio),
    origin: const ['115.com', '115cdn.net', '115cdn.com'].any((domain) => host == domain || host.endsWith('.$domain'))
        ? MediaOrigin.direct115
        : server != null &&
              itemPath != null &&
              itemPath.startsWith('/') &&
              !itemPath.toLowerCase().endsWith('.strm') &&
              PlaybackRedirectCache.sameOrigin(Uri.parse(result.streamUrl), Uri.parse(server))
        ? MediaOrigin.nasLocal
        : null,
  );
}
