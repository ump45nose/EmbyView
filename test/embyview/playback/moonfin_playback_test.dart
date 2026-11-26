import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:moonfin/playback/aether_backend.dart';
import 'package:moonfin/embyview/contracts/media.dart';
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
  bool failOpen = false, playing = false, runtimeTracks = true;
  bool failDisableSubtitle = false, failSelectSubtitle = false;
  int subtitleDisables = 0;
  Completer<void>? subtitleDisableGate, subtitleSelectGate;
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
    #supportsRuntimeTrackSelection => runtimeTracks,
    #canRenderBitmapSubtitles => true,
    #positionStream || #durationStream || #bufferStream => const Stream<Duration>.empty(),
    #playingStream || #bufferingStream || #completedStream || #subtitleLoadingStream => const Stream<bool>.empty(),
    #remoteCommandStream => const Stream<Map<String, dynamic>>.empty(),
    #getDeviceProfile => <String, dynamic>{},
    #waitForTracksReady ||
    #waitForEmbeddedSubtitleCount ||
    #addExternalSubtitle ||
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
  }
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
  final externalLoads = <(int, String, bool)>[];
  Completer<void>? selecting, selectGate;
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
    if (select) {
      if (selecting?.isCompleted == false) selecting!.complete();
      await selectGate?.future;
    }
  }

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
  List<Map<String, dynamic>> subtitles = [];
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
          ...subtitles,
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
        preferences: () => LocalPreferences(autoSelectChineseSubtitle: autoSelect),
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
}
