import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:moonfin/playback/aether_backend.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/playback.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/contracts/subtitles.dart';
import 'package:moonfin/embyview/playback/moonfin_playback.dart';
import 'package:moonfin/embyview/playback/native_playback.dart';
import 'package:moonfin/embyview/playback/playback_subtitle_input.dart';
import 'package:moonfin/embyview/playback/source_resolution.dart';
import 'package:moonfin/embyview/subtitles/ai/subtitle_ai.dart';
import 'package:moonfin/embyview/subtitles/model/subtitle_document.dart';
import 'package:moonfin/embyview/subtitles/sources/subtitle_sources.dart';
import 'package:moonfin/embyview/subtitles/store/subtitle_store.dart';
import 'package:moonfin/embyview/subtitles/subtitle_panel.dart';

class _Backend extends PlayerBackend implements AetherBackend {
  final errors = StreamController<Map<String, dynamic>>.broadcast();
  final urls = <String>[];
  final starts = <Duration>[];
  final seeks = <Duration>[];
  final subtitlePicks = <(int, String?)>[];
  final secondaryPicks = <(int?, String?)>[];
  final secondaryOpenSelections = <Object?>[];
  @override
  Future<void> setSecondarySubtitle({String? url, String? codec, String? language, int? embeddedTrackId}) async {
    secondaryPicks.add((embeddedTrackId, url));
  }

  int? refusedExternal;
  @override
  Future<void> seekTo(Duration position) async { seeks.add(position); at = position; }
  @override
  Future<void> addExternalSubtitle(String url, {String? title, String? language, String? codec}) async {
    if (refusedExternal != null && url.contains('/Subtitles/$refusedExternal/')) throw StateError('registration failed');
  }
  bool failOpen = false, playing = false, runtimeTracks = true;
  bool failDisableSubtitle = false, failSelectSubtitle = false;
  int subtitleDisables = 0;
  Completer<void>? subtitleDisableGate, subtitleSelectGate;
  int asyncFailureOpens = 0;
  Completer<void>? stopping, releaseStop, opening, releaseOpen;
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
    #supportsRuntimeTrackSelection => runtimeTracks,
    #canRenderBitmapSubtitles => true,
    #positionStream || #durationStream || #bufferStream => const Stream<Duration>.empty(),
    #playingStream || #bufferingStream || #completedStream || #subtitleLoadingStream => const Stream<bool>.empty(),
    #remoteCommandStream => const Stream<Map<String, dynamic>>.empty(),
    #getDeviceProfile => <String, dynamic>{},
    #waitForTracksReady ||
    #waitForEmbeddedSubtitleCount ||
    #setAudioTrack ||
    #setSubtitleRendererMode ||
    #setVolume ||
    #setRepeatMode => Future<void>.value(),
    _ => throw UnimplementedError('${call.memberName}'),
  };
  @override
  Future<void> disableSubtitleTrack() async {
    await subtitleDisableGate?.future;
    subtitleDisables++;
    if (failDisableSubtitle) throw StateError('disable failed');
  }

  @override
  Future<void> setSubtitleTrack(
    int index, {
    bool isBitmapSubtitle = false,
    String? subtitleCodec,
    bool isExternalSubtitle = false,
    String? externalSubtitleUrl,
  }) async {
    await subtitleSelectGate?.future;
    if (failSelectSubtitle) throw StateError('select failed');
    subtitlePicks.add((index, externalSubtitleUrl));
  }
  @override
  Future<void> play(dynamic item, {Duration startPosition = Duration.zero}) async {
    urls.add(item['url'] as String);
    secondaryOpenSelections.add(item['secondarySubtitleTrackId'] ?? item['secondarySubtitleUrl']);
    starts.add(startPosition);
    if (failOpen) throw TimeoutException('opening');
    if (opening?.isCompleted == false) opening!.complete();
    await releaseOpen?.future;
    at = startPosition;
    playing = item['autoPlay'] != false;
    if (urls.length <= asyncFailureOpens) {
      errors.add({'event': 'error', 'status': 403});
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<void> stop() async {
    if (stopping?.isCompleted == false) stopping!.complete();
    await releaseStop?.future;
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
  final externalLoads = <(int, String, bool)>[];
  Completer<void>? selecting, selectGate;
  String? failingSelectionUrl;
  bool failUnselectedLoad = false;
  @override
  Future<void> loadExternalSubtitle(
    String url, {
    String? title,
    String? language,
    String? codec,
    int? sourceGeneration,
    bool select = true,
  }) async {
    expect(sourceGeneration, generation);
    externalLoads.add((sourceGeneration!, url, select));
    if (!select && failUnselectedLoad) {
      throw StateError('播放源已变更或尚未就绪');
    }
    if (select) {
      if (selecting?.isCompleted == false) selecting!.complete();
      await selectGate?.future;
      if (url == failingSelectionUrl) throw ExternalSubtitleSelectionFailed();
    }
  }

  @override
  Future<void> supersedeExternalSubtitleSelection() async {}
  @override
  Stream<NativePlaybackSnapshot> get changes => events.stream;
  @override
  void configureNextSource({required int sourceGeneration, int? sessionCacheByteBudget, bool anime4k = false}) {
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
  List<Map<String, dynamic>> episodes = [];
  @override
  Future<Map<String, dynamic>> getEpisodes(String seriesId, {String? seasonId, String? fields}) async =>
      {'Items': episodes};

  @override
  Future<Map<String, dynamic>> getItems({
    bool? serverWide,
    String? parentId,
    List<String>? ids,
    List<String>? includeItemTypes,
    List<String>? excludeItemTypes,
    String? sortBy,
    String? sortOrder,
    int? startIndex,
    int? limit,
    bool? recursive,
    String? searchTerm,
    String? fields,
    List<String>? personIds,
    List<String>? artistIds,
    List<String>? filters,
    List<String>? seriesStatus,
    String? nameStartsWith,
    String? nameLessThan,
    List<String>? genreIds,
    List<String>? genres,
    bool? isFavorite,
    bool? collapseBoxSetItems,
    bool? enableTotalRecordCount,
    String? enableImageTypes,
    int? imageTypeLimit,
    List<String>? tags,
    List<String>? studios,
    DateTime? minPremiereDate,
    String? maxOfficialRating,
    bool? hasParentalRating,
    String? anyProviderIdEquals,
    List<String>? officialRatings,
    List<int>? years,
    List<String>? videoTypes,
    List<String>? audioLanguages,
    List<String>? subtitleLanguages,
    bool? hasSubtitles,
    bool? hasTrailer,
    bool? hasSpecialFeature,
    bool? hasThemeSong,
    bool? hasThemeVideo,
    bool? isHd,
    bool? is4K,
    bool? is3D,
    bool? enableUserData,
  }) async {
    final out = <Map<String, dynamic>>[];
    for (final id in ids ?? const <String>[]) {
      out.add(await getItem(id));
    }
    return {'Items': out, 'TotalRecordCount': out.length};
  }

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
  _PlaybackApi(this.baseUrl);
  final String Function() baseUrl;
  final starts = <Map<String, dynamic>>[];
  final stops = <Map<String, dynamic>>[];
  final progresses = <Map<String, dynamic>>[];
  Completer<void>? stopGate;
  Completer<void>? progressGate;
  Completer<void>? compensationStopGate;
  int? compensationStopNumber;
  String? Function()? currentUser;
  final stopUsers = <String?>[];
  Map<String, dynamic> sourcePatch = {};
  Map<String, dynamic> audio = {'Type': 'Audio', 'Index': 1, 'Language': 'jpn'};
  List<Map<String, dynamic>> subtitles = [];
  List<Map<String, dynamic>>? streamsOverride;
    final requestedMediaSourceIds = <String?>[];
    List<Map<String, dynamic>>? mediaSourcesOverride;
    @override
    Future<Map<String, dynamic>> getPlaybackInfo(
      String itemId, {
      Map<String, dynamic>? requestBody,
      String? userId,
      int? startTimeTicks,
      bool waitForMediaProbe = false,
    }) async {
      requestedMediaSourceIds.add(requestBody?['MediaSourceId'] as String?);
      return {
        'PlaySessionId': 'session-$itemId',
        'MediaSources': mediaSourcesOverride ??
            [
              {
                'Id': 'source',
                'Path': 'https://redirect.test/video',
                'IsRemote': true,
                'Protocol': 'Http',
                'SupportsDirectPlay': true,
                ...sourcePatch,
                'MediaStreams': streamsOverride ??
                    [
                      {'Type': 'Video', 'Index': 0, 'Width': 1920},
                      audio,
                      ...subtitles,
                    ],
              },
            ],
      };
    }
  @override
  String getStreamUrl(
    String itemId, {
    String? mediaSourceId,
    String? audioStreamIndex,
    String? subtitleStreamIndex,
    String? liveStreamId,
  }) => '${baseUrl()}/Videos/$itemId/stream?Static=true';

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
  late final _PlaybackApi playbackApi = _PlaybackApi(() => baseUrl);
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
  test('secondary text subtitles overlay without reopening, dedupe and clear on off, AI and next episode', () async {
    final backend = _Backend(), client = _Client();
    final manager = PlaybackManager()
      ..setBackend(backend)
      ..secondarySubtitleTrackSelector = (_, _) => 3;
    final native = _Native(backend);
    client.playbackApi.subtitles = [
      {'Type': 'Subtitle', 'Index': 2, 'Codec': 'ass', 'Language': 'zh'},
      {'Type': 'Subtitle', 'Index': 3, 'Codec': 'subrip', 'Language': 'eng'},
      {'Type': 'Subtitle', 'Index': 4, 'Codec': 'webvtt', 'Language': 'jpn'},
      {'Type': 'Subtitle', 'Index': 5, 'Codec': 'pgssub'},
      {'Type': 'Subtitle', 'Index': 6, 'Codec': 'srt', 'IsExternal': true,
        'DeliveryMethod': 'External', 'DeliveryUrl': '/Videos/movie/source/Subtitles/6/Stream.srt'},
    ];
    client.itemsApi.episodes = [
      {'Id': 'movie', 'Type': 'Episode', 'SeriesId': 'series', 'Name': 'First'},
      {'Id': 'next', 'Type': 'Episode', 'SeriesId': 'series', 'Name': 'Second'},
    ];
    final adapter = MoonfinPlaybackAdapter(
      manager: manager, client: client, native: native, audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(request: (_, _) async =>
          RedirectReply(302, Uri.parse('https://cdn.115.com/file'))),
    );
    addTearDown(() async { await adapter.dispose(); await native.events.close(); manager.dispose(); });
    final session = adapter.open(const PlayTarget(itemId: 'movie', seriesId: 'series'));
    await pumpEventQueue(times: 30);
    final generation = session.snapshot.generation;
    final primary = '$generation:2', english = '$generation:3', japanese = '$generation:4';
    final pgs = '$generation:5', embyExternal = '$generation:6';
    final input = session as PlaybackSubtitleInput;
    final nas = await input.registerExternalSubtitle('file:///nas.srt', generation: generation,
        codec: 'srt', source: PlaybackTrackSource.nas);
    final online = await input.registerExternalSubtitle('file:///online.vtt', generation: generation,
        codec: 'vtt', source: PlaybackTrackSource.online);

    await session.selectSubtitle(primary);
    expect(session.snapshot.subtitleTracks.where((track) => track.supportsSecondarySubtitle).map((track) => track.id),
        unorderedEquals([english, japanese, embyExternal, nas, online]));
    await expectLater(session.selectSecondarySubtitle(pgs), throwsA(isA<EmbyViewFailure>()));
    await session.selectSecondarySubtitle(english);
    expect(backend.secondaryPicks.last.$1, 2);
    expect(session.snapshot.secondarySubtitleId, english);
    expect(session.snapshot.selectedSubtitleId, primary);

    await session.selectSubtitle(japanese);
    expect(session.snapshot.secondarySubtitleId, english);
    await expectLater(session.selectSecondarySubtitle(primary), throwsA(isA<EmbyViewFailure>()));
    await session.selectSubtitle(nas);
    expect(session.snapshot.secondarySubtitleId, english);
    await session.selectSubtitle(english);
    expect(session.snapshot.secondarySubtitleId, isNull);
    expect(backend.secondaryPicks.last, (null, null));

    await session.selectSecondarySubtitle(nas);
    expect(backend.secondaryPicks.last, (null, 'file:///nas.srt'));
    await session.selectSecondarySubtitle(online);
    expect(backend.secondaryPicks.last, (null, 'file:///online.vtt'));
    await session.selectSecondarySubtitle(embyExternal);
    expect(backend.secondaryPicks.last.$1, isNull);
    expect(backend.secondaryPicks.last.$2, contains('/Subtitles/6/Stream.srt'));
    await session.selectSecondarySubtitle(null);
    expect(session.snapshot.secondarySubtitleId, isNull);

    await session.selectSecondarySubtitle(nas);
    await session.selectSecondarySubtitle(english);
    expect(session.snapshot.secondarySubtitleId, isNull);
    await session.selectSecondarySubtitle(nas);
    await session.selectSubtitle(null);
    expect(session.snapshot.secondarySubtitleId, isNull);
    await expectLater(session.selectSecondarySubtitle(nas), throwsA(isA<EmbyViewFailure>()));

    await session.selectSubtitle(primary);
    await session.selectSecondarySubtitle(nas);
    await input.setLiveSubtitle('live', generation: generation, select: true);
    expect(session.snapshot.secondarySubtitleId, isNull);
    expect(session.snapshot.subtitleOverlayId, 'live');
    await expectLater(session.selectSecondarySubtitle(nas), throwsA(isA<EmbyViewFailure>()));
    await session.selectSubtitle(primary);
    await session.selectSecondarySubtitle(english);
    expect(backend.urls, hasLength(1));
    expect(session.snapshot.generation, generation);

    await session.playNext();
    await pumpEventQueue(times: 30);
    expect(session.snapshot.target.itemId, 'next');
    expect(session.snapshot.generation, isNot(generation));
    expect(session.snapshot.secondarySubtitleId, isNull);
    expect(backend.secondaryOpenSelections, [null, null]);
    await expectLater(session.selectSecondarySubtitle(english), throwsA(isA<EmbyViewFailure>()));
  });
  test('receipt failure restores the previous sidecar and ignores a retired request', () async {
    final backend = _Backend(), client = _Client();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final adapter = MoonfinPlaybackAdapter(
      manager: manager, client: client, native: native, audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.115.com/file'))),
    );
    addTearDown(() async { await adapter.dispose(); await native.events.close(); manager.dispose(); });
    final session = adapter.open(const PlayTarget(itemId: 'movie'));
    await pumpEventQueue(times: 30);
    final input = session as PlaybackSubtitleInput;
    final generation = session.snapshot.generation;
    final old = await input.registerExternalSubtitle('file:///old.srt', generation: generation, title: '原轨');
    final bad = await input.registerExternalSubtitle('http://127.0.0.1/bad.srt', generation: generation, title: '损坏');
    final newer = await input.registerExternalSubtitle('file:///new.srt', generation: generation, title: '新轨');
    await session.selectSubtitle(old);
    native.failingSelectionUrl = 'http://127.0.0.1/bad.srt';
    await expectLater(session.selectSubtitle(bad), throwsA(isA<EmbyViewFailure>().having(
      (failure) => failure.reason, 'message', '字幕加载失败，已切回 原轨')));
    expect(session.snapshot.selectedSubtitleId, old);
    expect(session.snapshot.subtitleSelectionNotice?.message, '字幕加载失败，已切回 原轨');
    expect(backend.urls, hasLength(1));
    native.selecting = Completer();
    native.selectGate = Completer();
    final pending = session.selectSubtitle(bad);
    await native.selecting!.future;
    final latest = session.selectSubtitle(newer);
    native.selectGate!.complete();
    await Future.wait([pending, latest]);
    expect(session.snapshot.selectedSubtitleId, newer);
    expect(session.snapshot.subtitleSelectionNotice, isNull);
    expect(backend.urls, hasLength(1));
  });
  test('failed automatic external selection switches off without stopping playback', () async {
    final backend = _Backend()..failSelectSubtitle = true;
    final client = _Client();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    client.playbackApi.sourcePatch = {'DefaultSubtitleStreamIndex': 3};
    client.playbackApi.subtitles.add({
      'Type': 'Subtitle', 'Index': 3, 'Codec': 'srt', 'IsExternal': true,
      'IsDefault': true, 'DeliveryMethod': 'External',
      'DeliveryUrl': '/Videos/movie/source/Subtitles/3/Stream.srt',
    });
    final adapter = MoonfinPlaybackAdapter(manager: manager, client: client, native: native, audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.115.com/file'))));
    addTearDown(() async { await adapter.dispose(); await native.events.close(); manager.dispose(); });
    final session = adapter.open(const PlayTarget(itemId: 'movie'));
    await session.changes.firstWhere((state) => state.subtitleSelectionNotice != null)
        .timeout(const Duration(seconds: 5));
    expect(session.snapshot.selectedSubtitleId, isNull);
    expect(session.snapshot.subtitleSelectionNotice?.message, '字幕加载失败，已切回 关闭字幕');
    expect(backend.playing, isTrue);
    expect(backend.urls, hasLength(1));
  });
  for (final (autoSelect, indexed) in [(true, false), (false, false), (false, true)]) {
    test('real playback registers all NAS sidecars, auto-select=$autoSelect, indexed=$indexed', () async {
      final directory = await Directory.current.createTemp('.subtitle-playback-');
      final first = '1\n00:00:01,000 --> 00:00:03,000\n第一条\n';
      final second = first.replaceFirst('第一条', '第二条');
      final firstFile = File('${directory.path}/movie.zh.srt');
      final secondFile = File('${directory.path}/movie.zh-cn.srt');
      await File('${directory.path}/movie.strm').writeAsString('https://example.test/movie');
      await firstFile.writeAsString(first);
      await secondFile.writeAsString(second);
      final backend = _Backend();
      final manager = PlaybackManager()..setBackend(backend);
      final native = _Native(backend);
      final client = _Client();
      client.itemsApi.metadata['movie'] = {'Path': '/mnt/media/movie.strm'};
      if (indexed) {
        // Emby already indexes the first NAS file; keep its original ID
        // rather than adding a second copy of the same subtitle.
        client.playbackApi.subtitles.add({
          'Type': 'Subtitle',
          'Index': 3,
          'Language': 'zho',
          'Codec': 'srt',
          'IsExternal': true,
          'IsTextSubtitleStream': true,
          'DeliveryUrl': '/Videos/movie/source/Subtitles/3/Stream.srt',
          'Path': '/mnt/media/indexed-other-name.srt',
        });
      }
      final adapter = MoonfinPlaybackAdapter(
        manager: manager,
        client: client,
        native: native,
        audioInput: _Audio(),
        redirectCache: PlaybackRedirectCache(
          request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/movie')),
        ),
      );
      var session = adapter.open(const PlayTarget(itemId: 'movie'));
      final store = SubtitleStore(
        folderStatus: () async =>
            MediaFolderStatus(state: MediaFolderState.authorized, localRoot: directory.path, writable: true),
        localDirectory: () async => Directory('${directory.path}/cache'),
      );
      final sources = SubtitleSources(readSecret: (_) async => null);
      BoundSubtitlePanel bind(PlaybackSession session) => BoundSubtitlePanel(
        session: session,
        input: session as PlaybackSubtitleInput,
        store: store,
        loadItem: (id, _) async => (
          item: {'Name': id},
          source: (session as PlaybackSubtitleInput).subtitleSource!,
          streams: client.playbackApi.subtitles,
          duration: session.snapshot.duration,
          audioIndex: null,
        ),
        loadDocument: (_, _) async => SubtitleDocument.parse(utf8.encode(first), format: 'srt', language: 'zh'),
        sources: sources,
        processor: SubtitleAiProcessor(
          readTranslationKey: (_) async => null,
          meter: <T>(_, invoke) async => (await invoke()).value,
        ),
        preferences: () => LocalPreferences(
          subtitleAutoMode: autoSelect ? SubtitleAutoMode.always : SubtitleAutoMode.off,
        ),
        onClosed: () {},
        boundaries: const Stream.empty(),
      );
      var panel = bind(session);
      addTearDown(() async {
        if (native.selectGate?.isCompleted == false) native.selectGate!.complete();
        await panel.close();
        sources.close();
        await adapter.dispose();
        await native.events.close();
        manager.dispose();
        await directory.delete(recursive: true);
      });
      await panel.changes
          .firstWhere(
            (state) =>
                state.tracks.length == 2 &&
                state.tracks.every((track) => track.save == SubtitleSaveState.saved) &&
                (autoSelect ? state.selectedTrackId != null : true),
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError(
              'phase=${session.snapshot.phase}, failure=${session.snapshot.failure?.reason}, '
              'tracks=${session.snapshot.subtitleTracks.map((t) => (t.id, t.name, t.source))}, '
              'panel=${panel.snapshot.tracks.map((t) => (t.trackId, t.save, t.origin))}, '
              'nativeLoads=${native.externalLoads}',
            ),
          );
      final tracks = session.snapshot.subtitleTracks;
      expect(tracks, hasLength(2));
      expect(tracks.map((track) => track.id).toSet(), hasLength(2));
      expect(panel.snapshot.tracks.map((track) => track.trackId), tracks.map((track) => track.id));
      expect(native.externalLoads.where((call) => !call.$3), hasLength(indexed ? 1 : 2));
      if (autoSelect) {
        expect(panel.snapshot.tracks.where((track) => track.active), hasLength(1));
        expect(native.externalLoads.where((call) => call.$3), hasLength(1));
        final firstId = session.snapshot.selectedSubtitleId!;
        final otherId = tracks.singleWhere((track) => track.id != firstId).id;
        final firstCue = panel.snapshot.cues!.single.text;
        expect(await File.fromUri(Uri.parse(native.externalLoads.last.$2)).readAsString(), contains(firstCue));
        await session.selectSubtitle(otherId);
        await pumpEventQueue();
        expect(panel.snapshot.selectedTrackId, otherId);
        expect(panel.snapshot.tracks.where((track) => track.active), hasLength(1));
        expect(panel.snapshot.cues!.single.text, isNot(firstCue));
        expect(
          await File.fromUri(Uri.parse(native.externalLoads.last.$2)).readAsString(),
          contains(panel.snapshot.cues!.single.text),
        );
        await session.selectSubtitle(firstId);
        await pumpEventQueue();
        expect(panel.snapshot.selectedTrackId, firstId);
        expect(panel.snapshot.cues!.single.text, firstCue);
        expect(await File.fromUri(Uri.parse(native.externalLoads.last.$2)).readAsString(), contains(firstCue));
        final retained = tracks.singleWhere((track) => track.name == 'movie.zh.srt');
        await session.selectSubtitle(retained.id);
        final oldGeneration = session.snapshot.generation;
        // Emby indexes an existing local sidecar between two resolutions.
        client.playbackApi.subtitles.add({
          'Type': 'Subtitle',
          'Index': 3,
          'Language': 'zho',
          'Codec': 'srt',
          'IsExternal': true,
          'IsTextSubtitleStream': true,
          'DeliveryUrl': '/Videos/movie/source/Subtitles/3/Stream.srt',
          'Path': '/mnt/media/indexed-other-name.srt',
        });
        native.selecting = Completer<void>();
        native.selectGate = Completer<void>();
        backend.errors.add({'event': 'error', 'status': 403});
        await native.selecting!.future.timeout(const Duration(seconds: 5));
        expect(session.snapshot.generation, greaterThan(oldGeneration));
        expect(session.snapshot.selectedSubtitleId, isNull, reason: 'native restoration has not succeeded yet');
        if (panel.snapshot.tracks.length != 2) {
          await panel.changes.firstWhere((state) => state.tracks.length == 2).timeout(const Duration(seconds: 5));
        }
        expect(panel.snapshot.selectedTrackId, isNull);
        expect(session.snapshot.subtitleTracks, hasLength(2));
        final indexedId = '${session.snapshot.generation}:3';
        final reconciled = panel.changes.firstWhere((state) =>
          state.tracks.length == 2 &&
          state.tracks.every((track) => track.save == SubtitleSaveState.saved) &&
          state.selectedTrackId == indexedId
        );
        native.selectGate!.complete();
        await reconciled.timeout(const Duration(seconds: 5));
        expect(session.snapshot.subtitleTracks.map((track) => track.source), [
          PlaybackTrackSource.embyExternal, PlaybackTrackSource.nas,
        ]);
        expect(panel.snapshot.cues!.single.text, '第一条');
        expect(panel.snapshot.tracks.where((track) => track.active).single.trackId, indexedId);
        expect(session.snapshot.selectedSubtitleId, indexedId);
        final other = session.snapshot.subtitleTracks.singleWhere((track) => track.id != indexedId).id;
        await session.selectSubtitle(other);
        await session.selectSubtitle(indexedId);
        await pumpEventQueue();
        expect(panel.snapshot.selectedTrackId, indexedId);
        expect(await File.fromUri(Uri.parse(native.externalLoads.last.$2)).readAsString(), contains('第一条'));
        client.playbackApi.subtitles.clear();
        // Open the same episode again through the real adapter, not through
        // a synthetic snapshot. The persisted files must all be listed anew.
        await panel.close();
        await session.close();
        native.externalLoads.clear();
        session = adapter.open(const PlayTarget(itemId: 'movie'));
        panel = bind(session);
        await panel.changes.firstWhere((state) =>
          state.tracks.length == 2 &&
          state.tracks.every((track) => track.save == SubtitleSaveState.saved) &&
          state.selectedTrackId != null
        ).timeout(const Duration(seconds: 5));
        expect(session.snapshot.subtitleTracks.map((track) => track.id), isNot(contains(firstId)));
        expect(panel.snapshot.tracks.where((track) => track.active), hasLength(1));
        expect(native.externalLoads.where((call) => call.$3), hasLength(1));
        await expectLater(session.selectSubtitle(firstId), throwsA(isA<Exception>()));
      } else {
        expect(native.externalLoads.where((call) => call.$3), isEmpty);
        expect(tracks.where((track) => track.source == PlaybackTrackSource.embyExternal), hasLength(indexed ? 1 : 0));
        expect(tracks.where((track) => track.source == PlaybackTrackSource.nas), hasLength(indexed ? 1 : 2));
        if (!indexed) expect(panel.snapshot.selectedTrackId, isNull);
        final nas = tracks.singleWhere((track) => track.name == 'movie.zh-cn.srt');
        await session.selectSubtitle(nas.id);
        await pumpEventQueue();
        expect(panel.snapshot.cues!.single.text, '第二条');
        await session.selectSubtitle(null);
        await pumpEventQueue();
        expect(panel.snapshot.selectedTrackId, isNull);
      }
    });
  }
  test('NAS AI tracks still appear when reopening and immediately seeking before native session ready', () async {
    final directory = await Directory.current.createTemp('.subtitle-reopen-seek-');
    const enSrt = '1\n00:00:01,000 --> 00:00:03,000\nHello world\n';
    const zhSrt = '1\n00:00:01,000 --> 00:00:03,000\n你好世界\n';
    await File('${directory.path}/movie.mkv').writeAsString('video');
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend)..failUnselectedLoad = true;
    final client = _Client();
    client.itemsApi.metadata['movie'] = {
      'Path': '/mnt/media/movie.mkv',
      'MediaSources': [
        {'Id': 'source', 'Path': '/mnt/media/movie.mkv'},
      ],
    };
    final store = SubtitleStore(
      folderStatus: () async =>
          MediaFolderStatus(state: MediaFolderState.authorized, localRoot: directory.path, writable: true),
      localDirectory: () async => Directory('${directory.path}/cache'),
    );
    final media = const SubtitleMedia(
      itemId: 'movie',
      mediaSourceId: 'source',
      itemFilePath: '/mnt/media/movie.mkv',
      duration: Duration(minutes: 30),
    );
    for (final (lang, text) in [('en', enSrt), ('zh', zhSrt)]) {
      final doc = SubtitleDocument.parse(utf8.encode(text), format: 'srt', language: lang);
      final retained = await store.retain(
        media,
        doc,
        language: lang,
        origin: SubtitleOrigin.ai,
        pairId: 'pair-1',
        coverage: const [TimeRange(start: Duration(minutes: 24), end: Duration(minutes: 28))],
      );
      expect((await store.save(retained)).state, SubtitleSaveState.saved);
    }
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(
        request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/movie')),
      ),
    );
    final sources = SubtitleSources(readSecret: (_) async => null);
    final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 24)));
    final panel = BoundSubtitlePanel(
      session: session,
      input: session as PlaybackSubtitleInput,
      store: store,
      loadItem: (id, _) async => (
        item: {'Name': id},
        source: (session as PlaybackSubtitleInput).subtitleSource!,
        streams: client.playbackApi.subtitles,
        duration: session.snapshot.duration,
        audioIndex: null,
      ),
      loadDocument: (_, _) async => null,
      sources: sources,
      processor: SubtitleAiProcessor(
        readTranslationKey: (_) async => null,
        meter: <T>(_, invoke) async => (await invoke()).value,
      ),
      preferences: () => const LocalPreferences(subtitleAutoMode: SubtitleAutoMode.off),
      onClosed: () {},
      boundaries: const Stream.empty(),
    );
    addTearDown(() async {
      await panel.close();
      sources.close();
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
      await directory.delete(recursive: true);
    });

    // Seek immediately upon reopen while native loadExternalSubtitle(select: false)
    // is still rejecting because engine.isSessionReady == false.
    final discovered = panel.changes
        .firstWhere(
          (state) =>
              state.tracks.length == 2 &&
              state.tracks.every((t) => t.origin == SubtitleOrigin.ai && t.save == SubtitleSaveState.saved),
        )
        .timeout(const Duration(seconds: 5));
    await session.seek(const Duration(minutes: 25));
    await discovered;
    expect(session.snapshot.subtitleTracks, hasLength(2));
    expect(session.snapshot.subtitleTracks.map((t) => t.language), unorderedEquals(['en', 'zh']));

    // Once the native engine reaches first frame, deferred pre-registration retries
    // and selecting the Chinese AI track renders bilingual dialogue.
    native.failUnselectedLoad = false;
    final loadsBeforeFirstFrame = native.externalLoads.length;
    native.events.add(NativePlaybackSnapshot(sourceGeneration: native.generation, firstFrame: true));
    await pumpEventQueue(times: 20);
    expect(native.externalLoads.length, greaterThanOrEqualTo(loadsBeforeFirstFrame + 2));

    final zhTrack = session.snapshot.subtitleTracks.singleWhere((t) => t.language == 'zh');
    await session.selectSubtitle(zhTrack.id);
    await pumpEventQueue();
    expect(session.snapshot.selectedSubtitleId, zhTrack.id);
    expect(panel.snapshot.cues?.single.text, 'Hello world');
    expect(panel.snapshot.cues?.single.translation, '你好世界');
  });
  test('115 direct mov_text switches AI, embedded, AI, off, AI without reopening', () async {
    final backend = _Backend(), client = _Client();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    client.playbackApi.subtitles.add({
      'Type': 'Subtitle', 'Index': 2, 'Codec': 'mov_text', 'Language': 'zhi', 'IsExternal': false,
      'SupportsExternalStream': true, 'DeliveryMethod': 'Embed',
    });
    var redirects = 0;
    final adapter = MoonfinPlaybackAdapter(
      manager: manager, client: client, native: native, audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(request: (_, _) async {
        redirects++;
        return RedirectReply(302, Uri.parse('https://cdn.115cdn.net/fixture'));
      }),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });
    final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 3)));
    await pumpEventQueue(times: 30);
    final input = session as PlaybackSubtitleInput;
    final gen = session.snapshot.generation;
    final embedded = session.snapshot.subtitleTracks.single.id;
    await input.setLiveSubtitle('live', generation: gen, select: true);
    expect(session.snapshot.subtitleOverlayId, 'live');
    for (final (index, pick) in [embedded, 'live', null, 'live'].indexed) {
      backend.at = Duration(minutes: 3, seconds: index + 1);
      await session.selectSubtitle(pick);
      expect(session.snapshot.selectedSubtitleId, pick);
      expect(session.snapshot.subtitleOverlayId, pick == 'live' ? pick : null);
      expect(session.snapshot.generation, gen);
      expect(backend.at, Duration(minutes: 3, seconds: index + 1));
      expect(backend.playing, isTrue);
      expect(backend.urls, hasLength(1));
      expect(redirects, 1);
    }
    expect(backend.subtitlePicks, contains((1, null)));
    expect(input.subtitleSource!.subtitleSwitchFrom, isNull);
  });

  for (final track in ['subtitle', 'audio']) {
    test('a required $track reopen renews the redirect before stopping and preserves playback intent at the playhead', () async {
      final backend = _Backend();
      final manager = PlaybackManager()..setBackend(backend);
      final native = _Native(backend);
      final client = _Client();
      client.playbackApi.subtitles.addAll([
        {'Type': 'Subtitle', 'Index': 2, 'Codec': 'subrip', 'Language': 'zh'},
        {'Type': 'Audio', 'Index': 3, 'Codec': 'aac', 'Language': 'eng'},
        {'Type': 'Subtitle', 'Index': 4, 'Codec': 'srt', 'Language': 'eng', 'IsExternal': true,
         'DeliveryMethod': 'External', 'DeliveryUrl': '/Videos/movie/source/Subtitles/4/Stream.srt'},
      ]);
      int redirects = 0;
      final refresh = Completer<RedirectReply>();
      final adapter = MoonfinPlaybackAdapter(
        manager: manager, client: client, native: native, audioInput: _Audio(),
        redirectCache: PlaybackRedirectCache(request: (_, _) async {
          if (++redirects == 1) return RedirectReply(302, Uri.parse('https://cdn.115.com/first'));
          return refresh.future;
        }),
      );
      addTearDown(() async {
        await adapter.dispose();
        await native.events.close();
        manager.dispose();
      });
      final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 3)));
      await pumpEventQueue(times: 30);
      final gen = session.snapshot.generation;
      final embedded = session.snapshot.subtitleTracks.first.id;
      final input = session as PlaybackSubtitleInput;
      final external = await input.registerExternalSubtitle('file:///captions.srt', generation: gen);
      await session.selectSubtitle(embedded);
      await session.selectSubtitle(session.snapshot.subtitleTracks.firstWhere((t) => t.source == PlaybackTrackSource.embyExternal).id);
      await session.selectSubtitle(external);
      await input.setLiveSubtitle('live', generation: gen, select: true);
      await session.selectSubtitle(null);
      expect(backend.urls, hasLength(1));
      expect(redirects, 1);
      expect(session.snapshot.generation, gen);
      backend.at = const Duration(minutes: 4);
      backend.runtimeTracks = false;
      Future<void> switchTrack() => track == 'audio'
          ? session.selectAudio(session.snapshot.audioTracks.last.id)
          : session.selectSubtitle(embedded);
      final change = switchTrack();
      await pumpEventQueue();
      expect(redirects, 2);
      expect(backend.playing, isTrue);
      if (track == 'audio') await session.pause();
      refresh.complete(RedirectReply(302, Uri.parse('https://cdn.115.com/second')));
      await change;
      expect(backend.urls.map((url) => Uri.parse(url).path), ['/first', '/second']);
      expect(backend.starts.last, const Duration(minutes: 4));
      expect(backend.playing, track == 'subtitle');
      expect(input.subtitleSource!.subtitleSwitchFrom, track == 'subtitle' ? gen : null);
      expect(adapter.diagnostics.records.where((e) => e.event == 'resolved').last.cacheHit, false);
    });
  }
  for (final action in ['fail', 'cancel', 'audioFail']) {
    test('track renewal $action keeps the active source, playhead and user selection', () async {
      final backend = _Backend();
      final manager = PlaybackManager()..setBackend(backend);
      final native = _Native(backend);
      final client = _Client();
      client.playbackApi.subtitles.addAll([
        {'Type': 'Subtitle', 'Index': 2, 'Codec': 'srt', 'Language': 'zh'},
        {'Type': 'Audio', 'Index': 3, 'Codec': 'aac', 'Language': 'eng'},
      ]);
      final gate = Completer<RedirectReply>();
      var requests = 0;
      final adapter = MoonfinPlaybackAdapter(
        manager: manager, client: client, native: native, audioInput: _Audio(),
        redirectCache: PlaybackRedirectCache(request: (_, _) async => ++requests == 1
            ? RedirectReply(302, Uri.parse('https://cdn.115.com/original')) : gate.future),
      );
      addTearDown(() async {
        await adapter.dispose();
        await native.events.close();
        manager.dispose();
      });
      const start = Duration(minutes: 5);
      final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: start));
      await pumpEventQueue(times: 30);
      final input = session as PlaybackSubtitleInput, gen = session.snapshot.generation;
      await input.setLiveSubtitle('live', generation: gen, select: true);
      final audio = session.snapshot.selectedAudioId;
      backend.runtimeTracks = false;
      final change = action == 'audioFail'
          ? session.selectAudio(session.snapshot.audioTracks.last.id)
          : session.selectSubtitle(session.snapshot.subtitleTracks.first.id);
      final completion = action == 'cancel' ? change : expectLater(change, throwsA(isA<EmbyViewFailure>()));
      await pumpEventQueue();
      expect(requests, 2);
      Future<void>? newer;
      if (action == 'cancel') {
        backend.runtimeTracks = true;
        newer = session.selectSubtitle(null);
        gate.complete(RedirectReply(302, Uri.parse('https://cdn.115.com/retired')));
      } else {
        gate.complete(const RedirectReply(403));
      }
      await completion;
      await newer;
      expect(requests, 2);
      expect(backend.urls, hasLength(1));
      expect(backend.playing, isTrue);
      expect(session.snapshot.generation, gen);
      expect(session.snapshot.position, start);
      expect(session.snapshot.selectedAudioId, audio);
      expect(session.snapshot.subtitleOverlayId, action == 'cancel' ? null : 'live');
      expect(input.subtitleSource!.subtitleSwitchFrom, isNull);
    });
  }
  for (final backToFirst in [false, true]) {
    test('a newer audio pick and backward seek during teardown reach the replacement, backToFirst=$backToFirst', () async {
      final backend = _Backend(), client = _Client();
      final manager = PlaybackManager()..setBackend(backend);
      final native = _Native(backend);
      client.playbackApi.sourcePatch['DefaultAudioStreamIndex'] = 1;
      client.playbackApi.subtitles.addAll([
        {'Type': 'Audio', 'Index': 2, 'Language': 'en'},
        {'Type': 'Audio', 'Index': 3, 'Language': 'fr'},
      ]);
      final adapter = MoonfinPlaybackAdapter(
        manager: manager, client: client, native: native, audioInput: _Audio(),
        redirectCache: PlaybackRedirectCache(request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.115.com/file'))),
      );
      addTearDown(() async { await adapter.dispose(); await native.events.close(); manager.dispose(); });
      final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 5)));
      await pumpEventQueue(times: 30);
      final tracks = session.snapshot.audioTracks;
      backend.stopping = Completer();
      backend.releaseStop = Completer();
      final first = session.selectAudio(tracks[1].id);
      await backend.stopping!.future;
      final latestIndex = backToFirst ? 1 : 3;
      final newer = session.selectAudio(tracks[backToFirst ? 0 : 2].id);
      await session.seek(const Duration(minutes: 8));
      await session.seek(const Duration(minutes: 2));
      expect(backend.seeks, isEmpty);
      backend.releaseStop!.complete();
      await Future.wait([first, newer]);
      expect(session.snapshot.selectedAudioId, '${session.snapshot.generation}:$latestIndex');
      expect(backend.starts.skip(1), everyElement(const Duration(minutes: 2)));
      expect(backend.playing, isTrue);
    });
  }

  test('a seek during the new backend open survives the delayed track-restore check', () async {
    final backend = _Backend(), client = _Client();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    client.playbackApi.subtitles.add({'Type': 'Audio', 'Index': 2, 'Language': 'en'});
    final adapter = MoonfinPlaybackAdapter(manager: manager, client: client, native: native, audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.115.com/file'))));
    addTearDown(() async { await adapter.dispose(); await native.events.close(); manager.dispose(); });
    final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 5)));
    await pumpEventQueue(times: 30);
    backend.opening = Completer();
    backend.releaseOpen = Completer();
    final change = session.selectAudio(session.snapshot.audioTracks.last.id);
    await backend.opening!.future;
    await session.seek(const Duration(minutes: 2));
    backend.releaseOpen!.complete();
    await change;
    await Future<void>.delayed(const Duration(milliseconds: 230));
    expect(backend.seeks, [const Duration(minutes: 2)]);
    expect(backend.at, const Duration(minutes: 2));
  });
  for (final (codec, target) in [('ass', const Duration(minutes: 2)), ('ssa', const Duration(minutes: 8))]) {
    test('transcoded $codec keeps the latest seek during audio reopen', () async {
      final backend = _Backend(), client = _Client();
      final manager = PlaybackManager()..setBackend(backend);
      final native = _Native(backend);
      client.playbackApi.sourcePatch = {
        'IsRemote': false, 'SupportsDirectPlay': false, 'SupportsDirectStream': false,
        'SupportsTranscoding': true, 'TranscodingUrl': '/Videos/movie/master.m3u8',
        'DefaultSubtitleStreamIndex': 3,
      };
      client.playbackApi.subtitles.addAll([
        {'Type': 'Audio', 'Index': 2, 'Language': 'en'},
        {
          'Type': 'Subtitle', 'Index': 3, 'Codec': codec, 'IsExternal': true,
          'DeliveryMethod': 'External', 'DeliveryUrl': '/Videos/movie/source/Subtitles/3/Stream.$codec',
        },
      ]);
      final adapter = MoonfinPlaybackAdapter(manager: manager, client: client, native: native, audioInput: _Audio());
      addTearDown(() async { await adapter.dispose(); await native.events.close(); manager.dispose(); });
      final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 5)));
      await pumpEventQueue(times: 30);
      expect(manager.currentResolution?.playMethod, StreamPlayMethod.transcode);
      await session.selectSubtitle(session.snapshot.subtitleTracks.single.id);
      expect(manager.subtitleStreamIndex, 3);
      backend.opening = Completer();
      backend.releaseOpen = Completer();
      final change = session.selectAudio(session.snapshot.audioTracks.last.id);
      await backend.opening!.future;
      await session.seek(const Duration(minutes: 1));
      await session.seek(target);
      backend.releaseOpen!.complete();
      await change;
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(manager.currentResolution?.playMethod, StreamPlayMethod.transcode);
      expect(manager.subtitleStreamIndex, 3);
      expect(backend.subtitlePicks.last.$2, contains('/Subtitles/3/'));
      expect(backend.seeks, [target]);
      expect(backend.at, target);
    });
  }
  for (final method in ['direct', 'remux']) {
    test('a refused sidecar cannot steal the mounted bitmap or select another ordinal on $method', () async {
      final backend = _Backend()..refusedExternal = 2;
      final manager = PlaybackManager()..setBackend(backend);
      final native = _Native(backend), client = _Client();
      if (method == 'remux') client.playbackApi.sourcePatch = {
        'IsRemote': false, 'SupportsDirectPlay': false, 'SupportsDirectStream': true, 'DirectStreamUrl': '/Videos/movie/stream.mkv',
      };
      for (final index in [2, 3, 4]) {
        client.playbackApi.subtitles.add({
          'Type': 'Subtitle', 'Index': index, 'Language': 'eng', 'Codec': 'pgssub',
          'IsExternal': true, 'DeliveryMethod': 'External', 'DeliveryUrl': '/Videos/movie/source/Subtitles/$index/Stream.sup',
        });
      }
      final adapter = MoonfinPlaybackAdapter(
        manager: manager, client: client, native: native, audioInput: _Audio(),
        redirectCache: PlaybackRedirectCache(request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.115.com/file'))),
      );
      addTearDown(() async { await adapter.dispose(); await native.events.close(); manager.dispose(); });
      final session = adapter.open(const PlayTarget(itemId: 'movie'));
      await pumpEventQueue(times: 30);
      expect(manager.currentResolution?.playMethod, method == 'remux' ? StreamPlayMethod.directStream : StreamPlayMethod.directPlay);
      final gen = session.snapshot.generation;
      await session.selectSubtitle('$gen:3');
      expect(backend.urls, hasLength(1));
      expect(backend.subtitlePicks.last.$1, 1);
      expect(backend.subtitlePicks.last.$2, contains('/Subtitles/3/'));
      final picks = backend.subtitlePicks.length;
      await expectLater(session.selectSubtitle('$gen:2'), throwsA(isA<EmbyViewFailure>()));
      backend.failSelectSubtitle = true;
      await expectLater(session.selectSubtitle('$gen:4'), throwsA(isA<EmbyViewFailure>().having((e) => e.reason, 'failure message', contains('字幕加载失败，已切回'))));
      expect(backend.subtitlePicks, hasLength(picks));
      expect(session.snapshot.selectedSubtitleId, '$gen:3');
      expect(backend.urls, hasLength(1));
    });
  }

  test('a newer sidecar pick during teardown follows the same media into its new generation', () async {
    final backend = _Backend(), client = _Client();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    client.playbackApi.subtitles.add({'Type': 'Subtitle', 'Index': 2, 'Codec': 'srt'});
    final adapter = MoonfinPlaybackAdapter(
      manager: manager, client: client, native: native, audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.115.com/file'))),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });
    final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 5)));
    await pumpEventQueue(times: 30);
    final input = session as PlaybackSubtitleInput, gen = session.snapshot.generation;
    final sidecar = await input.registerExternalSubtitle('file:///chosen.srt', generation: gen);
    backend.runtimeTracks = false;
    backend.stopping = Completer();
    backend.releaseStop = Completer();
    final first = session.selectSubtitle(session.snapshot.subtitleTracks.first.id);
    await backend.stopping!.future;
    final newer = session.selectSubtitle(sidecar);
    backend.runtimeTracks = true;
    backend.releaseStop!.complete();
    await Future.wait([first, newer]);
    await pumpEventQueue();
    expect(backend.urls, hasLength(2));
    expect(session.snapshot.selectedSubtitleId, '${session.snapshot.generation}:external0');
    expect(native.externalLoads.lastWhere((load) => load.$3).$2, 'file:///chosen.srt');
  });
  test('failed embedded or off selection keeps the original active sidecar', () async {
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    client.playbackApi.subtitles.add({
      'Type': 'Subtitle',
      'Index': 3,
      'Language': 'jpn',
      'Codec': 'srt',
      'IsTextSubtitleStream': true,
    });
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(
        request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/movie')),
      ),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });
    final session = adapter.open(const PlayTarget(itemId: 'movie'));
    await pumpEventQueue(times: 30);
    expect(session.snapshot.phase, anyOf(PlaybackPhase.playing, PlaybackPhase.paused));
    final embedded = session.snapshot.subtitleTracks.single.id;
    final local = await (session as PlaybackSubtitleInput).registerExternalSubtitle(
      'file:///subtitles/active.srt',
      generation: session.snapshot.generation,
    );
    await session.selectSubtitle(local);
    final input = session as PlaybackSubtitleInput;
    const live = 'live-test';
    await input.setLiveSubtitle(live, generation: session.snapshot.generation, select: false);
    backend.failDisableSubtitle = true;
    await expectLater(session.selectSubtitle(live), throwsStateError);
    expect(session.snapshot.selectedSubtitleId, local);
    expect(session.snapshot.subtitleOverlayId, isNull);
    expect(native.externalLoads.last.$2, 'file:///subtitles/active.srt');
    backend.failDisableSubtitle = false;

    await session.selectSubtitle(live);
    final loadsBefore = native.externalLoads.length, disablesBefore = backend.subtitleDisables;
    backend.failDisableSubtitle = true;
    await expectLater(session.selectSubtitle(local), throwsStateError);
    expect(native.externalLoads.length, loadsBefore);
    expect(backend.subtitleDisables, disablesBefore + 1);
    expect(session.snapshot.selectedSubtitleId, live);
    expect(session.snapshot.subtitleOverlayId, live);
    backend.failDisableSubtitle = false;
    backend.failSelectSubtitle = true;
    final disabled = backend.subtitleDisables;
    await expectLater(session.selectSubtitle(embedded), throwsStateError);
    expect(session.snapshot.selectedSubtitleId, live);
    expect(session.snapshot.subtitleOverlayId, live);
    expect(backend.subtitleDisables, greaterThan(disabled));

    final delayed = backend.subtitleSelectGate = Completer<void>();
    final first = expectLater(session.selectSubtitle(embedded), throwsStateError);
    await pumpEventQueue();
    final newer = session.selectSubtitle(null);
    delayed.complete();
    await Future.wait([first, newer]);
    expect(session.snapshot.selectedSubtitleId, isNull);
    expect(session.snapshot.subtitleOverlayId, isNull);
    backend.failSelectSubtitle = false;
    await session.selectSubtitle(local);
    for (final disable in [false, true]) {
      final gate = Completer<void>();
      if (disable) {
        backend.subtitleDisableGate = gate;
        backend.failDisableSubtitle = true;
      } else {
        backend.subtitleSelectGate = gate;
        backend.failSelectSubtitle = true;
      }
      final failure = expectLater(session.selectSubtitle(disable ? null : embedded), throwsStateError);
      await pumpEventQueue();
      expect(session.snapshot.selectedSubtitleId, local);
      gate.complete();
      await failure;
      expect(session.snapshot.selectedSubtitleId, local);
      backend.failDisableSubtitle = false;
      backend.failSelectSubtitle = false;
    }
    await session.selectSubtitle(embedded);
    expect(session.snapshot.selectedSubtitleId, embedded);
    await session.selectSubtitle(null);
    expect(session.snapshot.selectedSubtitleId, isNull);
    // The real manager reopens the source when runtime switching is unavailable.
    backend.runtimeTracks = false;
    final previousGeneration = session.snapshot.generation;
    await session.selectSubtitle(embedded);
    expect(session.snapshot.generation, greaterThan(previousGeneration));
    expect(input.subtitleSource!.subtitleSwitchFrom, previousGeneration);
    final generationWithOld = session.snapshot.generation;
    await input.setLiveSubtitle('first-live', generation: generationWithOld, select: true);
    final generationWithoutOld = session.snapshot.generation;
    expect(generationWithoutOld, greaterThan(generationWithOld));
    await input.setLiveSubtitle('rebound-live', generation: generationWithoutOld, select: true);
    expect(session.snapshot.generation, generationWithoutOld);
    expect(session.snapshot.subtitleOverlayId, 'rebound-live');
  });
  test('live selection waits for native off before drawing and late sidecar selection yields to cancellation or the viewer', () async {
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final adapter = MoonfinPlaybackAdapter(
      manager: manager, client: _Client(), native: native, audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/movie'))),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });
    final session = adapter.open(const PlayTarget(itemId: 'movie'));
    await pumpEventQueue(times: 30);
    final input = session as PlaybackSubtitleInput, gen = session.snapshot.generation;
    final old = await input.registerExternalSubtitle('file:///old.srt', generation: gen);
    final formal = await input.registerExternalSubtitle('file:///generated.srt', generation: gen);
    await session.selectSubtitle(old);
    for (final action in ['cancel', 'old', 'new']) {
      final live = '$gen:live-$action';
      final off = backend.subtitleDisableGate = Completer<void>();
      final start = input.setLiveSubtitle(live, generation: gen, select: true);
      expect(session.snapshot.selectedSubtitleId, live);
      expect(session.snapshot.subtitleOverlayId, isNull);
      final before = backend.subtitleDisables;
      off.complete();
      await start;
      expect(backend.subtitleDisables, greaterThan(before));
      expect(session.snapshot.subtitleOverlayId, live);

      final gate = native.selectGate = Completer<void>();
      final entered = native.selecting = Completer<void>();
      final handoff = input.endLiveSubtitle(live, replacementId: formal);
      await entered.future;
      expect(session.snapshot.subtitleOverlayId, isNull);
      final disablesBeforeChoice = backend.subtitleDisables;
      final superseding = switch (action) {
        'cancel' => input.endLiveSubtitle(live),
        'old' => session.selectSubtitle(old),
        _ => input.setLiveSubtitle('$gen:new', generation: gen, select: true),
      };
      gate.complete();
      await Future.wait([handoff, superseding]);
      expect(session.snapshot.selectedSubtitleId, switch (action) {
        'cancel' || 'old' => old, _ => '$gen:new',
      });
      expect(session.snapshot.subtitleTracks.any((t) => t.id == live), isFalse);
      if (action == 'new') {
        expect(backend.subtitleDisables, greaterThan(disablesBeforeChoice));
      } else {
        expect(native.externalLoads.last, (gen, 'file:///old.srt', true));
      }
    }
  });
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
    final externalId = await input.registerExternalSubtitle(
      'file:///subtitles/chinese.srt',
      generation: source.generation,
      title: '中文',
      source: PlaybackTrackSource.ai,
    );
    expect(session.snapshot.selectedSubtitleId, isNull);
    expect(native.externalLoads.single.$3, isFalse);
    final repeated = await input.registerExternalSubtitle(
      'file:///subtitles/chinese.srt',
      generation: source.generation,
      title: '中文',
      source: PlaybackTrackSource.ai,
    );
    expect(repeated, externalId);
    expect(session.snapshot.subtitleTracks, hasLength(1));
    expect(session.snapshot.subtitleTracks.last.source, PlaybackTrackSource.ai);
    await session.selectSubtitle(null);
    expect(session.snapshot.selectedSubtitleId, isNull);
    await session.selectSubtitle(externalId);
    expect(session.snapshot.selectedSubtitleId, externalId);
    expect(native.externalLoads.last.$3, isTrue);
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

  test('player snapshot maps series artwork and selected audio independently of the server display title', () async {
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    client.itemsApi.metadata['20806'] = {
      'Type': 'Episode', 'Name': '第 2 集', 'IndexNumber': 2, 'ParentIndexNumber': 1,
      'SeriesId': '20800', 'SeriesName': '北斗神拳 拳王军杂兵们的挽歌', 'SeasonId': '20804',
      'ImageTags': {'Logo': 'episode'}, 'ParentLogoItemId': '20800', 'ParentLogoImageTag': 'series',
    };
    client.playbackApi.audio.addAll({
      'Codec': 'eac3', 'ChannelLayout': 'stereo', 'Channels': 2, 'DisplayTitle': 'Japanese EAC3 stereo (默认)',
    });
    client.playbackApi.subtitles.add({
      'Type': 'Subtitle', 'Index': 3, 'Codec': 'subrip', 'Language': 'tur', 'DisplayTitle': 'Turkish (SUBRIP)',
      'Title': 'Forced (SDH)', 'IsDefault': true,
    });
    final adapter = MoonfinPlaybackAdapter(
      manager: manager, client: client, native: native, audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(request: (_, _) async => RedirectReply(302, Uri.parse('https://fixture.115cdn.net/video'))),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });
    final session = adapter.open(const PlayTarget(itemId: '20806'));
    await pumpEventQueue(times: 30);
    final snap = session.snapshot;
    expect(snap.item?.seriesName, '北斗神拳 拳王军杂兵们的挽歌');
    expect(snap.item?.seasonNumber, 1);
    expect(snap.item?.art.logo?.id, '20800:Logo:0');
    expect(snap.quality?.origin, MediaOrigin.direct115);
    expect(snap.quality?.resolution, '1080p');
    expect(snap.quality?.audioLabel, 'EAC3 2.0');
    expect(snap.subtitleTracks.single.qualifiers, ['强制', 'SDH', '默认']);
    expect(snap.subtitleTracks.single.isForced, isFalse); // Display hints do not change auto-selection.
  });

  test('real 115 session refreshes once at position, retires old tracks and refuses the next failure', () async {
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
    final externalId = await (session as PlaybackSubtitleInput).registerExternalSubtitle(
      'file:///subtitles/retained.srt',
      generation: generation,
    );
    await (session as PlaybackSubtitleInput).registerExternalSubtitle(
      'file:///subtitles/unselected.srt',
      generation: generation,
    );
    await session.selectSubtitle(externalId);
    backend.at = const Duration(minutes: 10);
    await session.pause();
    native.selecting = Completer<void>();
    native.selectGate = Completer<void>();
    addTearDown(() {
      if (!native.selectGate!.isCompleted) native.selectGate!.complete();
    });
    backend.errors.add({'event': 'error', 'status': 403});
    await native.selecting!.future.timeout(const Duration(seconds: 5));
    expect(redirects, 2);
    expect(backend.starts.last, const Duration(minutes: 10));
    expect(backend.playing, isFalse);
    expect(session.snapshot.generation, greaterThan(generation));
    expect(session.snapshot.selectedSubtitleId, isNull);
    final nextChoice = session.snapshot.subtitleTracks.last.id;
    final chooseOther = session.selectSubtitle(nextChoice);
    native.selectGate!.complete();
    await chooseOther;
    expect(native.externalLoads.where((load) => load.$1 == native.generation).map((load) => (load.$2, load.$3)), [
      ('file:///subtitles/retained.srt', false),
      ('file:///subtitles/unselected.srt', false),
      ('file:///subtitles/retained.srt', true),
      ('file:///subtitles/unselected.srt', true),
    ]);
    expect(session.snapshot.selectedSubtitleId, nextChoice);
    expect(session.snapshot.subtitleTracks, hasLength(2));
    await expectLater(session.selectSubtitle(externalId), throwsA(isA<Exception>()));
    await expectLater(session.selectAudio(oldTrack), throwsA(isA<Exception>()));
    backend.errors.add({'event': 'error', 'status': 403});
    await pumpEventQueue(times: 40);
    expect(redirects, 2);
    expect(session.snapshot.phase, PlaybackPhase.failed);
    await session.close();
    await adapter.dispose();
    await native.events.close();
    manager.dispose();
  });

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

  test('115 HTTP 403 redirect failure exposes structured rate-limit metadata and retryOpen fetches fresh address', () async {
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
        request: (_, _) async {
          redirects++;
          if (redirects == 1) return const RedirectReply(403);
          return RedirectReply(302, Uri.parse('https://cdn.115.com/fresh-$redirects'));
        },
      ),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });

    final session = adapter.open(const PlayTarget(itemId: 'movie'));
    await pumpEventQueue(times: 30);
    expect(redirects, 1);
    expect(session.snapshot.phase, PlaybackPhase.failed);
    expect(session.snapshot.failure?.httpStatus, 403);
    expect(session.snapshot.failure?.isRateLimited, isTrue);
    expect(session.snapshot.failure?.sourceLabel, '115 网盘');
    expect(session.snapshot.failure?.reason, '115 暂时限制了播放');

    await session.retryOpen();
    await pumpEventQueue(times: 30);
    expect(redirects, 2);
    expect(session.snapshot.phase, isNot(PlaybackPhase.failed));
    expect(session.snapshot.failure, isNull);
    expect(Uri.parse(backend.urls.last).host, 'cdn.115.com');
    expect(Uri.parse(backend.urls.last).path, '/fresh-2');
    expect(adapter.diagnostics.records.where((e) => e.event == 'resolved').last.cacheHit, isFalse);
  });

  test('retryOpen invalidates cached redirect after backend 403 exhaustion and re-resolves a new address', () async {
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
        request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.115.com/attempt-${++redirects}')),
      ),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });

    final session = adapter.open(const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 4)));
    await pumpEventQueue(times: 40);
    expect(redirects, 2);
    expect(session.snapshot.phase, PlaybackPhase.failed);
    expect(session.snapshot.failure?.httpStatus, 403);
    expect(session.snapshot.failure?.isRateLimited, isTrue);
    expect(session.snapshot.failure?.sourceLabel, '115 网盘');

    await session.retryOpen();
    await pumpEventQueue(times: 40);
    expect(redirects, 3);
    expect(session.snapshot.phase, isNot(PlaybackPhase.failed));
    expect(Uri.parse(backend.urls.last).host, 'cdn.115.com');
    expect(Uri.parse(backend.urls.last).path, '/attempt-3');
    expect(backend.starts.last, const Duration(minutes: 4));
    expect(adapter.diagnostics.records.where((e) => e.event == 'resolved').last.cacheHit, isFalse);
  });

  test('switching server baseUrl on same session keeps MoonfinPlaybackAdapter working and uses new address', () async {
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    client.itemsApi.metadata['local1'] = {
      'Type': 'Movie',
      'Name': 'Local Movie',
      'Path': '/mnt/media/local.mkv',
      'ImageTags': {'Primary': 'img1'},
    };
    client.playbackApi.sourcePatch = {
      'Path': '/mnt/media/local.mkv',
      'IsRemote': false,
      'Protocol': 'File',
      'DirectStreamUrl': '/Videos/local1/stream?Static=true',
    };
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });

    // Switch to backup address on same server/user/token session.
    client.baseUrl = 'https://backup.ts.net:8920';

    final session = adapter.open(const PlayTarget(itemId: 'local1'));
    await pumpEventQueue(times: 30);
    expect(session.snapshot.phase, isNot(PlaybackPhase.failed));
    expect(backend.urls.last, startsWith('https://backup.ts.net:8920/'));
    expect(session.snapshot.quality?.origin, MediaOrigin.nasLocal);
    final poster = session.snapshot.item?.art.poster.layers.first.source.image as NetworkImage?;
    expect(poster?.url, startsWith('https://backup.ts.net:8920/'));
    await session.close();
  });

  test('non-115 HTTP 403 does not report 115 rate limiting', () async {
    final backend = _Backend()..asyncFailureOpens = 2;
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    client.itemsApi.metadata['local403'] = {
      'Type': 'Movie',
      'Name': 'Local Movie',
      'Path': '/mnt/media/local.mkv',
    };
    client.playbackApi.sourcePatch = {
      'Path': '/mnt/media/local.mkv',
      'IsRemote': false,
      'Protocol': 'File',
      'DirectStreamUrl': '/Videos/local403/stream?Static=true',
    };
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });

    final session = adapter.open(const PlayTarget(itemId: 'local403'));
    await pumpEventQueue(times: 30);
    expect(session.snapshot.phase, PlaybackPhase.failed);
    expect(session.snapshot.failure?.httpStatus, 403);
    expect(session.snapshot.failure?.isRateLimited, isFalse);
    expect(session.snapshot.failure?.code, isNot('rateLimited115'));
    expect(session.snapshot.failure?.sourceLabel, isNull);
    await session.close();
  });

  test('startup audio and subtitle selectors apply LocalPreferences and restore previous selectors on close', () async {
    final backend = _Backend();
    int? prevAudio(List<Map<String, dynamic>> s, int? e) => 99;
    int? prevSub(List<Map<String, dynamic>> s, List<Map<String, dynamic>> a, int? e) => 88;
    final manager = PlaybackManager()
      ..setBackend(backend)
      ..audioTrackSelector = prevAudio
      ..subtitleTrackSelector = prevSub;
    final native = _Native(backend);
    final client = _Client();
    client.playbackApi.streamsOverride = [
      {'Type': 'Video', 'Index': 0, 'Width': 1920},
      {'Type': 'Audio', 'Index': 1, 'Language': 'eng', 'Channels': 6, 'IsDefault': true},
      {'Type': 'Audio', 'Index': 2, 'Language': 'jpn', 'Channels': 2},
      {'Type': 'Subtitle', 'Index': 3, 'Language': 'eng', 'Codec': 'srt', 'IsDefault': true},
      {'Type': 'Subtitle', 'Index': 4, 'Language': 'chi', 'Title': '简体中文', 'Codec': 'ass'},
      {'Type': 'Subtitle', 'Index': 5, 'Language': 'jpn', 'Codec': 'srt'},
    ];
    var currentPrefs = const LocalPreferences(
      audioLanguages: ['ja', 'en'],
      subtitleLanguages: ['zh', 'en'],
      subtitleAutoMode: SubtitleAutoMode.always,
    );
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
      preferences: () => currentPrefs,
      redirectCache: PlaybackRedirectCache(
        request: (_, _) async => RedirectReply(302, Uri.parse('https://cdn.test/movie')),
      ),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });

    Future<PlaybackSession> openReady() async {
      final session = adapter.open(const PlayTarget(itemId: 'movie'));
      await pumpEventQueue(times: 30);
      expect(session.snapshot.phase, isNot(PlaybackPhase.failed));
      expect(session.snapshot.generation, greaterThan(0));
      return session;
    }

    // 1. Selects preferred audio (jpn -> 2) and preferred subtitle (chi -> 4).
    var session = await openReady();
    expect(session.snapshot.selectedAudioId, '${session.snapshot.generation}:2');
    expect(session.snapshot.selectedSubtitleId, '${session.snapshot.generation}:4');

    // Manual switch takes effect immediately without selector overriding it.
    await session.selectSubtitle('${session.snapshot.generation}:5');
    expect(session.snapshot.selectedSubtitleId, '${session.snapshot.generation}:5');
    await session.close();

    // Closing session restores previous upstream selectors.
    expect(identical(manager.audioTrackSelector, prevAudio), isTrue);
    expect(identical(manager.subtitleTrackSelector, prevSub), isTrue);

    // 2. foreignOnly with native audio (jpn matches preferred audio ['ja']) keeps subtitles off.
    currentPrefs = const LocalPreferences(
      audioLanguages: ['ja'],
      subtitleLanguages: ['zh', 'en'],
      subtitleAutoMode: SubtitleAutoMode.foreignOnly,
    );
    session = await openReady();
    expect(session.snapshot.selectedAudioId, '${session.snapshot.generation}:2');
    expect(session.snapshot.selectedSubtitleId, isNull);
    await session.close();

    // 3. foreignOnly with foreign audio (eng audio when user prefers zh) enables zh subtitle.
    currentPrefs = const LocalPreferences(
      audioLanguages: [],
      subtitleLanguages: ['zh', 'en'],
      subtitleAutoMode: SubtitleAutoMode.foreignOnly,
    );
    session = await openReady();
    expect(session.snapshot.selectedAudioId, '${session.snapshot.generation}:1'); // IsDefault eng
    expect(session.snapshot.selectedSubtitleId, '${session.snapshot.generation}:4'); // zh
    await session.close();

    // 4. SubtitleAutoMode.off leaves subtitles disabled.
    currentPrefs = const LocalPreferences(
      audioLanguages: ['ja'],
      subtitleLanguages: ['zh', 'en'],
      subtitleAutoMode: SubtitleAutoMode.off,
    );
    session = await openReady();
    expect(session.snapshot.selectedSubtitleId, isNull);
    await session.close();
  });

  test('open() selects requested mediaSourceId with resume position and queues sequential collection items', () async {
    final backend = _Backend();
    final manager = PlaybackManager()..setBackend(backend);
    final native = _Native(backend);
    final client = _Client();
    client.itemsApi.metadata['movie'] = {
      'MediaSources': [
        {'Id': 'uhd', 'Path': 'https://redirect.test/uhd'},
        {'Id': 'nas', 'Path': '/mnt/media/nas.mkv'},
      ],
    };
    client.playbackApi.mediaSourcesOverride = [
      {
        'Id': 'uhd',
        'Path': 'https://redirect.test/uhd',
        'IsRemote': true,
        'Protocol': 'Http',
        'SupportsDirectPlay': true,
        'MediaStreams': [
          {'Type': 'Video', 'Index': 0, 'Width': 3840},
          {'Type': 'Audio', 'Index': 1, 'Language': 'eng'},
        ],
      },
      {
        'Id': 'nas',
        'Path': '/mnt/media/nas.mkv',
        'IsRemote': false,
        'Protocol': 'File',
        'SupportsDirectPlay': true,
        'MediaStreams': [
          {'Type': 'Video', 'Index': 0, 'Width': 1920},
          {'Type': 'Audio', 'Index': 1, 'Language': 'eng'},
        ],
      },
    ];
    final adapter = MoonfinPlaybackAdapter(
      manager: manager,
      client: client,
      native: native,
      audioInput: _Audio(),
      redirectCache: PlaybackRedirectCache(
        request: (uri, _) async => RedirectReply(302, Uri.parse('https://cdn.115.com${uri.path}')),
      ),
    );
    addTearDown(() async {
      await adapter.dispose();
      await native.events.close();
      manager.dispose();
    });

    // Resume movie with switched version ('nas') preserves resume startAt and selects 'nas' mediaSourceId
    final session = adapter.open(
      const PlayTarget(itemId: 'movie', startAt: Duration(minutes: 42), mediaSourceId: 'nas'),
    );
    await pumpEventQueue(times: 30);
    expect(client.playbackApi.requestedMediaSourceIds, contains('nas'));
    expect(session.snapshot.mediaSourceId, 'nas');
    expect(backend.starts.last, const Duration(minutes: 42));
    await session.close();

    // Sequential collection queue starts at item 2 and queues item 3 as next
    client.playbackApi.mediaSourcesOverride = null;
    final seqSession = adapter.open(
      const PlayTarget(itemId: 'm2', queueItemIds: ['m1', 'm2', 'm3']),
    );
    await pumpEventQueue(times: 30);
    expect(seqSession.snapshot.target.itemId, 'm2');
    expect(seqSession.snapshot.nextEpisode?.id, 'm3');
    await seqSession.close();
  });
}
