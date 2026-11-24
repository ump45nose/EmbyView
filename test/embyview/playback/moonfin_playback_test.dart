import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:moonfin/playback/aether_backend.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/contracts/playback.dart';
import 'package:moonfin/embyview/playback/moonfin_playback.dart';
import 'package:moonfin/embyview/playback/native_playback.dart';
import 'package:moonfin/embyview/playback/playback_subtitle_input.dart';
import 'package:moonfin/embyview/playback/source_resolution.dart';

class _Backend extends PlayerBackend implements AetherBackend {
  final errors = StreamController<Map<String, dynamic>>.broadcast();
  final urls = <String>[];
  final starts = <Duration>[];
  bool failOpen = false, playing = false;
  int asyncFailureOpens = 0;
  Duration at = Duration.zero;
  @override
  bool get nativelyHandlesStartPosition => true;
  @override
  bool get requiresStartupMediaReadyCheck => false;
  @override
  Stream<Map<String, dynamic>> get errorStream => errors.stream;
  @override
  dynamic noSuchMethod(Invocation call) => switch (call.memberName) {
    #position => at,
    #duration => const Duration(minutes: 30),
    #buffer => Duration.zero,
    #isPlaying || #playWhenReady => playing,
    #isBuffering || #isSubtitleLoading => false,
    #playbackSpeed => 1.0,
    #supportsRuntimeTrackSelection => true,
    #positionStream || #durationStream || #bufferStream => const Stream<Duration>.empty(),
    #playingStream ||
    #bufferingStream ||
    #completedStream ||
    #subtitleLoadingStream => const Stream<bool>.empty(),
    #remoteCommandStream => const Stream<Map<String, dynamic>>.empty(),
    #getDeviceProfile => <String, dynamic>{},
    #waitForTracksReady ||
    #setAudioTrack ||
    #setSubtitleRendererMode ||
    #setSubtitleTrack ||
    #setVolume ||
    #disableSubtitleTrack ||
    #setRepeatMode => Future<void>.value(),
    _ => throw UnimplementedError('${call.memberName}'),
  };
  @override
  Future<void> play(dynamic item, {Duration startPosition = Duration.zero}) async {
    urls.add(item['url'] as String);
    starts.add(startPosition);
    if (failOpen) throw TimeoutException('opening');
    at = startPosition;
    playing = item['autoPlay'] != false;
    if (urls.length <= asyncFailureOpens) {
      errors.add({'event': 'error', 'status': 403});
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<void> stop() async {
    playing = false;
  }

  @override
  Future<void> pause() async {
    playing = false;
  }

  @override
  Future<void> resume() async {
    playing = true;
  }

  @override
  void dispose() {
    errors.close();
  }
}

class _Native extends Fake implements EmbyViewNativePlayback {
  _Native(this.backend);
  @override
  final AetherBackend backend;
  final events = StreamController<NativePlaybackSnapshot>.broadcast();
  int generation = 0;
  final animeOptions = <bool>[];
  final externalLoads = <int>[];
  @override
  Future<void> loadExternalSubtitle(
    String url, {
    String? title,
    String? language,
    String? codec,
    int? sourceGeneration,
  }) async {
    expect(sourceGeneration, generation);
    externalLoads.add(sourceGeneration!);
  }

  @override
  Stream<NativePlaybackSnapshot> get changes => events.stream;
  @override
  void configureNextSource({
    required int sourceGeneration,
    int? sessionCacheByteBudget,
    bool anime4k = false,
  }) {
    generation = sourceGeneration;
    animeOptions.add(anime4k);
  }
}

class _Audio extends Fake implements NativePlaybackAudioInput {
  int stops = 0;
  @override
  Future<void> stop() async {
    stops++;
  }
}

class _Items extends Fake implements ItemsApi {
  Completer<Map<String, dynamic>>? gate;
  final metadata = <String, Map<String, dynamic>>{};
  int reads = 0;
  @override
  Future<Map<String, dynamic>> getItem(String id, {String? mediaSourceId, String? fields}) async {
    reads++;
    return gate?.future ??
        {
          'Id': id,
          'Type': 'Movie',
          'Name': id,
          'Path': '/library/$id.strm',
          'RunTimeTicks': 18000000000,
          'MediaSources': [
            {'Id': 'source', 'Path': 'https://redirect.test/video'},
          ],
          ...?metadata[id],
        };
  }
}

class _PlaybackApi extends Fake implements PlaybackApi {
  final starts = <Map<String, dynamic>>[];
  final stops = <Map<String, dynamic>>[];
  final progresses = <Map<String, dynamic>>[];
  Completer<void>? stopGate;
  Completer<void>? progressGate;
  Completer<void>? compensationStopGate;
  int? compensationStopNumber;
  String? Function()? currentUser;
  final stopUsers = <String?>[];
  @override
  Future<Map<String, dynamic>> getPlaybackInfo(
    String itemId, {
    Map<String, dynamic>? requestBody,
    String? userId,
    int? startTimeTicks,
    bool waitForMediaProbe = false,
  }) async => {
    'PlaySessionId': 'session-$itemId',
    'MediaSources': [
      {
        'Id': 'source',
        'Path': 'https://redirect.test/video',
        'IsRemote': true,
        'Protocol': 'Http',
        'SupportsDirectPlay': true,
        'MediaStreams': [
          {'Type': 'Video', 'Index': 0, 'Width': 1920},
          {'Type': 'Audio', 'Index': 1, 'Language': 'jpn'},
        ],
      },
    ],
  };
  @override
  Future<void> reportPlaybackStart(Map<String, dynamic> info) async {
    starts.add(info);
  }

  @override
  Future<void> reportPlaybackProgress(Map<String, dynamic> info) async {
    progresses.add(info);
    await progressGate?.future;
  }

  @override
  Future<void> reportPlaybackStopped(Map<String, dynamic> info) async {
    stops.add(info);
    stopUsers.add(currentUser?.call());
    await (stops.length == compensationStopNumber ? compensationStopGate : stopGate)?.future;
  }
}

class _Client extends Fake implements MediaServerClient {
  @override
  String baseUrl = 'https://emby.test';
  @override
  String? userId = 'sfw';
  @override
  String? accessToken = 'secret';
  @override
  final _Items itemsApi = _Items();
  @override
  final _PlaybackApi playbackApi = _PlaybackApi();
  @override
  TrickplayApi? get trickplayApi => null;
}

class _OriginalResolver extends MediaStreamResolver {
  int calls = 0;
  @override
  Future<StreamResolutionResult> resolve(
    dynamic mediaItem, {
    Map<String, dynamic>? deviceProfile,
    int? maxStreamingBitrate,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int? startTimeTicks,
    String? mediaSourceId,
    bool enableDirectPlay = true,
    bool enableDirectStream = true,
    bool enableTranscoding = true,
  }) async => StreamResolutionResult(
    streamUrl: 'https://cdn.test/${++calls}',
    mediaSourceId: 's',
    playSessionId: 'session-$calls',
    playMethod: StreamPlayMethod.directPlay,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Anime4K defaults follow known anime library and latest preferences without extra item reads',
    () async {
      final backend = _Backend();
      final manager = PlaybackManager()..setBackend(backend);
      final native = _Native(backend);
      final client = _Client();
      client.itemsApi.metadata.addAll({
        'anime': {'Type': 'Episode', 'LibraryId': 'anime-library'},
        'other': {
          'Type': 'Episode',
          'LibraryId': 'drama-library',
          'Genres': ['Animation'],
          'Language': 'jpn',
        },
      });
      var defaults = (anime: true, other: false);
      final adapter = MoonfinPlaybackAdapter(
        manager: manager,
        client: client,
        native: native,
        audioInput: _Audio(),
        anime4kForAnime: true,
        anime4kForOther: false,
        anime4kDefaults: () => defaults,
        isAnimeItem: (raw) => raw['LibraryId'] == 'anime-library',
        redirectCache: PlaybackRedirectCache(
          request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/movie')),
        ),
      );
      for (final item in ['anime', 'other', 'anime']) {
        if (native.animeOptions.length == 2) defaults = (anime: false, other: true);
        final session = adapter.open(PlayTarget(itemId: item));
        await pumpEventQueue(times: 30);
        await session.close();
      }
      expect(native.animeOptions, [true, false, false]);
      expect(client.itemsApi.reads, 3);
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    },
  );
  test('real resolver/reporting ownership, generation-filtered first frame and repeatable close', () async {
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final oldResolver = _OriginalResolver();
    manager.setResolver(oldResolver);
    final native = _Native(backend);
    final audio = _Audio();
    final client = _Client();
    var redirects = 0;
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: audio,
      redirectCache: PlaybackRedirectCache(
        request: (uri, headers) async {
          redirects++;
          expect(headers, {'User-Agent': embyViewPlaybackUserAgent});
          return RedirectReply(302, Uri.parse('https://cdn.test/movie'));
        },
      ),
    );
    await adapter.prepare('movie');
    expect(client.playbackApi.starts, isEmpty);
    final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 10)));
    await pumpEventQueue(times: 30);
    expect(redirects, 1);
    expect(client.playbackApi.starts, hasLength(1), reason: '${session.snapshot.failure}');
    expect(client.playbackApi.starts.single['PositionTicks'], 6000000000);
    final input = session as PlaybackSubtitleInput;
    final source = input.subtitleSource!;
    expect(source.itemFilePath, '/library/movie.strm');
    expect(source.userAgent, embyViewPlaybackUserAgent);
    final externalId = await input.loadExternalSubtitle(
      'file:///subtitles/chinese.srt',
      generation: source.generation,
      title: '中文',
      source: PlaybackTrackSource.ai,
    );
    expect(session.snapshot.selectedSubtitleId, externalId);
    expect(session.snapshot.subtitleTracks.last.source, PlaybackTrackSource.ai);
    await session.selectSubtitle(null);
    expect(session.snapshot.selectedSubtitleId, isNull);
    await session.selectSubtitle(externalId);
    expect(session.snapshot.selectedSubtitleId, externalId);
    expect(session.snapshot.firstFrameLatency, isNull);
    native.events.add(NativePlaybackSnapshot(sourceGeneration: native.generation - 1, firstFrame: true));
    await pumpEventQueue(times: 3);
    expect(session.snapshot.firstFrameLatency, isNull);
    native.events.add(NativePlaybackSnapshot(sourceGeneration: native.generation, firstFrame: true));
    await pumpEventQueue(times: 3);
    expect(session.snapshot.firstFrameLatency, isNotNull);
    client.playbackApi.stopGate = Completer<void>();
    final first = session.close();
    final second = session.close();
    expect(identical(first, second), isTrue);
    var closed = false;
    first.then((_) {
      closed = true;
    });
    await pumpEventQueue(times: 5);
    expect(closed, isFalse);
    client.playbackApi.stopGate!.complete();
    await first;
    expect(client.playbackApi.stops, hasLength(1));
    expect(client.playbackApi.stops.single['PositionTicks'], 6000000000);
    expect(audio.stops, 1);
    await manager.playItems([
      {'Id': 'old-route', 'Type': 'Movie'},
    ]);
    expect(oldResolver.calls, 1);
    expect(manager.sourceFailureRecovery, isNull);
    await manager.stop();
    await adapter.dispose();
    await native.events.close();
    manager.dispose();
  });

  test('close before pending metadata prevents source open and reports', () async {
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    client.itemsApi.gate = Completer<Map<String, dynamic>>();
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
    );
    final session = adapter.open(const PlayTarget(itemId: 'old'));
    await pumpEventQueue(times: 4);
    await session.close();
    client.itemsApi.gate!.complete({'Id': 'old', 'Type': 'Movie'});
    await pumpEventQueue(times: 20);
    expect(backend.urls, isEmpty);
    expect(client.playbackApi.starts, isEmpty);
    await adapter.dispose();
    await native.events.close();
    manager.dispose();
  });

  test(
    'real 115 session refreshes once at position, retires old tracks and refuses the next failure',
    () async {
      final backend = _Backend();
      final manager = PlaybackManager()..setBackend(backend);
      final native = _Native(backend);
      final client = _Client();
      var redirects = 0;
      final adapter = MoonfinPlaybackAdapter(
        manager: manager,
        client: client,
        native: native,
        audioInput: _Audio(),
        redirectCache: PlaybackRedirectCache(
          request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/${++redirects}')),
        ),
      );
      final session = adapter.open(const PlayTarget(itemId: 'movie'));
      await pumpEventQueue(times: 30);
      final generation = session.snapshot.generation;
      final oldTrack = session.snapshot.audioTracks.single.id;
      final externalId = await (session as PlaybackSubtitleInput).loadExternalSubtitle(
        'file:///subtitles/retained.srt',
        generation: generation,
      );
      backend.at = const Duration(minutes: 10);
      await session.pause();
      backend.errors.add({'event': 'error', 'status': 403});
      await pumpEventQueue(times: 40);
      expect(redirects, 2);
      expect(backend.starts.last, const Duration(minutes: 10));
      expect(backend.playing, isFalse);
      expect(session.snapshot.generation, greaterThan(generation));
      expect(native.externalLoads, hasLength(2));
      expect(session.snapshot.selectedSubtitleId, isNot(externalId));
      await expectLater(session.selectAudio(oldTrack), throwsA(isA<Exception>()));
      backend.errors.add({'event': 'error', 'status': 403});
      await pumpEventQueue(times: 40);
      expect(redirects, 2);
      expect(session.snapshot.phase, PlaybackPhase.failed);
      await session.close();
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    },
  );

  test('opening timeout spends exactly one retry without nested transcode recovery', () async {
    final backend = _Backend()..failOpen = true;
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    var redirects = 0;
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(
        request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/${++redirects}')),
      ),
    );
    final session = adapter.open(const PlayTarget(itemId: 'movie'));
    await pumpEventQueue(times: 40);
    expect(redirects, 2);
    expect(backend.urls, hasLength(2));
    expect(session.snapshot.phase, PlaybackPhase.failed);
    expect(client.playbackApi.starts, isEmpty);
    await session.close();
    await adapter.dispose();
    await native.events.close();
    manager.dispose();
  });

  test('close drains retired progress and its final compensating Stop before shared auth changes', () async {
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    final api = client.playbackApi;
    api.currentUser = () => client.userId;
    api.progressGate = Completer<void>();
    api.compensationStopGate = Completer<void>();
    api.compensationStopNumber = 3;
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(
        request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/movie')),
      ),
    );
    final session = adapter.open(const PlayTarget(itemId: 'movie'));
    await pumpEventQueue(times: 30);
    await session.setVolume(.5);
    expect(api.progresses, hasLength(1));
    // A source replacement retires the generation while its Progress is in flight.
    backend.errors.add({'event': 'error', 'status': 403});
    await pumpEventQueue(times: 30);
    expect(api.stops, hasLength(1));
    expect(backend.urls, hasLength(2));
    var closed = false;
    final closing = adapter.dispose().then((_) {
      closed = true;
      client.userId = 'other';
    });
    await pumpEventQueue(times: 10);
    expect(api.stops, hasLength(2));
    expect(closed, isFalse);
    api.progressGate!.complete();
    await pumpEventQueue(times: 10);
    expect(api.stops, hasLength(3));
    expect(closed, isFalse);
    expect(client.userId, 'sfw');
    api.compensationStopGate!.complete();
    await closing;
    expect(api.stopUsers, ['sfw', 'sfw', 'sfw']);
    expect(client.userId, 'other');
    await native.events.close();
    manager.dispose();
  });

  test('asynchronous native startup 403 cannot be ready from a positive resume position', () async {
    final backend = _Backend()..asyncFailureOpens = 2;
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    var redirects = 0;
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(
        request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/${++redirects}')),
      ),
    );
    final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 10)));
    await pumpEventQueue(times: 40);
    expect(redirects, 2);
    expect(backend.urls, hasLength(2));
    expect(session.snapshot.phase, PlaybackPhase.failed);
    expect(client.playbackApi.starts, isEmpty);
    expect(adapter.diagnostics.records.where((event) => event.event == 'ready'), isEmpty);
    await session.close();
    await adapter.dispose();
    await native.events.close();
    manager.dispose();
  });
}
