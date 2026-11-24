import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/playback/native_playback.dart';
import 'package:moonfin/embyview/playback/playback_subtitle_input.dart';
import 'package:moonfin/embyview/subtitles/ai/subtitle_ai.dart';
import 'package:moonfin/embyview/subtitles/audio/subtitle_audio.dart';
import 'package:moonfin/embyview/subtitles/emby_subtitle_library.dart';
import 'package:moonfin/embyview/subtitles/model/subtitle_document.dart';
import 'package:moonfin/embyview/subtitles/sources/subtitle_sources.dart';
import 'package:moonfin/embyview/subtitles/store/subtitle_store.dart';
import 'package:moonfin/embyview/subtitles/subtitle_panel.dart';

const _movie = PlayTarget(itemId: 'movie');
const _srt = '1\n00:00:01,000 --> 00:00:03,000\n中文字幕\n';

void main() {
  test('online subtitle plays before NAS save, retries, and reopens from NAS', () async {
    final fixture = await _Fixture.open();
    addTearDown(fixture.close);
    final groups = await fixture.panel.search(null);
    expect(groups.map((group) => group.source), SubtitleSource.values);
    expect(groups.skip(1).map((group) => group.failure?.code), List.filled(3, 'subtitle_source_disabled'));
    final saving = fixture.panel.changes.firstWhere(
      (value) => value.tracks.any((t) => t.save == SubtitleSaveState.failed),
    );
    await fixture.panel.useCandidate(groups.first.candidates.single);
    final failed = await saving;
    expect(failed.selectedTrackId, fixture.playback.snapshot.selectedSubtitleId);
    expect(failed.cues!.single.text, '中文字幕');
    expect(fixture.playback.rendered, _srt);
    fixture.mount();
    await fixture.panel.retrySave(failed.selectedTrackId!);
    expect(fixture.panel.snapshot.tracks.single.save, SubtitleSaveState.saved);
    expect(await File('${fixture.root.path}/movie.zh.srt').exists(), isTrue);

    final ready = fixture.panel.changes.firstWhere((state) => state.generation == 3 && state.cues?.isNotEmpty == true);
    fixture.playback.open(const PlayTarget(itemId: 'next'), 2);
    expect(fixture.panel.snapshot.selectedTrackId, isNull);
    fixture.playback.open(_movie, 3);
    final reopened = await ready;
    expect(reopened.tracks.single.origin, SubtitleOrigin.online);
    expect(reopened.tracks.single.save, SubtitleSaveState.saved);
    expect(reopened.selectedTrackId, fixture.playback.snapshot.selectedSubtitleId);
    expect(reopened.cues!.single.start, const Duration(seconds: 1));
  });

  test('a source change and account teardown cancel requests and reject old handles', () async {
    final fixture = await _Fixture.open();
    addTearDown(fixture.close);
    final candidate = (await fixture.panel.search(null)).first.candidates.single;
    fixture.download = Completer<http.Response>();
    final obsolete = expectLater(fixture.panel.useCandidate(candidate), throwsA(isA<EmbyViewFailure>()));
    await fixture.downloading.future;
    fixture.playback.open(const PlayTarget(itemId: 'next'), 2);
    await obsolete;
    fixture.download!.complete(http.Response.bytes(utf8.encode(_srt), 200));
    expect(fixture.playback.rendered, isNull);

    fixture.lookup = Completer<SubtitleItem>();
    final oldAccount = expectLater(fixture.panel.search(null), throwsA(isA<EmbyViewFailure>()));
    await fixture.panel.close(); // The account adapter invokes this before installing the new user services.
    await oldAccount;
    expect(fixture.panel.snapshot.tracks, isEmpty);
  });

  test('a NAS pair restores AI attribution and dialogue onto an indexed track with auto-select off', () async {
    final fixture = await _Fixture.open();
    addTearDown(fixture.close);
    fixture.mount();
    fixture.autoSelect = false;
    final media = SubtitleMedia.fromPlayback(fixture.playback.subtitleSource, duration: const Duration(seconds: 10));
    final chinese = SubtitleDocument.parse(utf8.encode(_srt), format: 'srt');
    final original = SubtitleDocument.parse(utf8.encode(_srt.replaceFirst('中文字幕', '日本語')), format: 'srt');
    for (final (language, document) in [('zh', chinese), ('ja', original)]) {
      final track = await fixture.store.retain(
        media,
        document,
        language: language,
        origin: SubtitleOrigin.ai,
        pairId: 'pair',
        coverage: const [TimeRange(start: Duration.zero, end: Duration(seconds: 10))],
      );
      expect((await fixture.store.save(track)).state, SubtitleSaveState.saved);
    }
    fixture.streams = [
      {'Type': 'Subtitle', 'Index': 3, 'Path': '/mnt/media/movie.zh.srt'},
    ];
    fixture.documents[3] = chinese;
    final matched = fixture.panel.changes.firstWhere(
      (snapshot) => snapshot.tracks.any((track) => track.origin == SubtitleOrigin.ai),
    );
    fixture.playback.open(
      _movie,
      2,
      subtitles: [
        const PlaybackTrack(
          id: '2:3',
          name: 'Chinese',
          language: 'zh',
          source: PlaybackTrackSource.embyExternal,
          format: 'srt',
        ),
      ],
    );
    final state = await matched;
    expect(state.tracks.single.trackId, '2:3');
    expect(state.tracks.single.index, SubtitleIndexState.recognized);
    expect(state.selectedTrackId, isNull);
    expect(fixture.playback.rendered, isNull);

    await fixture.playback.selectSubtitle('2:3');
    final cue = fixture.panel.snapshot.cues!.single;
    expect(cue.text, '日本語');
    expect(cue.translation, '中文字幕');
  });

  test('normal playback end flushes a short final segment in the following mode', () async {
    final fixture = await _Fixture.open();
    addTearDown(fixture.close);
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('embyview/audio_control');
    final pcm = Uint8List(48000 * 4);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readIndependent');
      return [
        {'startUs': 0, 'sourceUs': 0, 'pcm': pcm},
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final catchingUp = fixture.panel.changes.firstWhere((state) => state.ai?.state == AiRunState.catchingUp);
    final run = fixture.panel.startAi();
    await fixture.playback.audioInput.started.future;
    await catchingUp;
    fixture.playback.audioInput.pcm.add(
      NativePcmPacket(
        sourceGeneration: 1,
        timelineGeneration: 0,
        sourceTime: Duration.zero,
        playbackTime: Duration.zero,
        pcm: pcm,
        discontinuity: false,
        dialogue: true,
      ),
    );
    fixture.playback.end();
    await run;
    expect(fixture.requestedAiKey, isTrue);
  });

  test('AI audio and its language follow the switched stream before the playback snapshot catches up', () async {
    final fixture = await _Fixture.open();
    addTearDown(fixture.close);
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('embyview/audio_control');
    final pcm = Uint8List(48000 * 4 * 12);
    int? streamIndex;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readIndependent');
      streamIndex = (call.arguments as Map)['streamIndex'] as int?;
      return [
        {'startUs': 0, 'sourceUs': 0, 'pcm': pcm},
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final requests = StreamController<(int?, String?)>();
    final heard = StreamIterator(requests.stream);
    final reply = Completer<http.Response>();
    fixture.aiRequest = (request) {
      final language = RegExp(r'name="language"\r\n\r\n([a-z]+)')
          .firstMatch(latin1.decode(request.bodyBytes))
          ?.group(1);
      requests.add((streamIndex, language));
      return reply.future;
    };
    addTearDown(() async {
      if (!reply.isCompleted) reply.complete(http.Response('', 503));
      await heard.cancel();
      await requests.close();
    });
    fixture.playback.open(
      _movie,
      2,
      duration: const Duration(seconds: 20),
      audio: const [
        PlaybackTrack(id: '2:1', name: 'Japanese', language: 'ja', source: PlaybackTrackSource.embedded),
        PlaybackTrack(id: '2:8', name: 'English', language: 'en', source: PlaybackTrackSource.embedded),
      ],
      selectedAudioId: '2:1',
    );
    final started = fixture.panel.startAi();
    expect(await heard.moveNext(), isTrue);
    expect(heard.current, (1, 'ja'));

    void switchedTo(int index) {
      for (final ready in [false, true]) {
        fixture.audioBoundaries.add((
          sourceGeneration: 2,
          kind: SubtitleAudioBoundaryKind.audioTrack,
          ready: ready,
          position: Duration.zero,
          streamIndex: ready ? index : null,
        ));
      }
    }

    switchedTo(8);
    expect(await heard.moveNext(), isTrue);
    expect(heard.current, (8, 'en'));
    switchedTo(99);
    expect(await heard.moveNext(), isTrue);
    expect(heard.current, (99, null));
    await fixture.panel.cancelAi();
    reply.complete(http.Response('', 503));
    await started;
  });
}

class _Fixture {
  _Fixture(this.root);
  final Directory root;
  final playback = _Playback()..open(_movie, 1);
  late final SubtitleSources sources;
  late final BoundSubtitlePanel panel;
  late final SubtitleStore store;
  List<Map<String, dynamic>> streams = [];
  final documents = <int, SubtitleDocument>{};
  final audioBoundaries = StreamController<SubtitleAudioBoundary>.broadcast(sync: true);
  Future<http.Response> Function(http.Request)? aiRequest;
  bool autoSelect = true;
  Completer<SubtitleItem>? lookup;
  Completer<http.Response>? download;
  final downloading = Completer<void>();
  bool requestedAiKey = false;
  MediaFolderStatus status = const MediaFolderStatus(state: MediaFolderState.unconfigured);

  static Future<_Fixture> open() async {
    final root = await Directory.current.createTemp('.subtitle-composition-');
    await File('${root.path}/movie.strm').writeAsString('https://example.test/media');
    final fixture = _Fixture(root);
    fixture.sources = SubtitleSources(readSecret: (_) async => null, client: MockClient(fixture.request));
    fixture.store = SubtitleStore(
      folderStatus: () async => fixture.status,
      localDirectory: () async => Directory('${root.path}/cache'),
    );
    fixture.panel = BoundSubtitlePanel(
      session: fixture.playback,
      input: fixture.playback,
      store: fixture.store,
      loadItem: (id, _) async =>
          fixture.lookup?.future ??
          (
            item: {'Name': id},
            source: fixture.playback.subtitleSource,
            streams: fixture.streams,
            duration: fixture.playback.snapshot.duration,
            audioIndex: null,
          ),
      loadDocument: (_, stream) async => fixture.documents[stream['Index']],
      sources: fixture.sources,
      processor: SubtitleAiProcessor(
        readSecret: (_) async {
          fixture.requestedAiKey = true;
          return fixture.aiRequest == null ? null : 'mock-key';
        },
        translationProvider: () => TranslationProvider.openAi,
        meter: <T>(_, invoke) async => (await invoke()).value,
        clientFactory: () => MockClient(fixture.aiRequest ?? (_) async => http.Response('', 503)),
      ),
      preferences: () => LocalPreferences(
        subtitleSources: const {SubtitleSource.xunlei},
        autoSelectChineseSubtitle: fixture.autoSelect,
      ),
      onClosed: () {},
      boundaries: fixture.audioBoundaries.stream,
    );
    return fixture;
  }

  Future<http.Response> request(http.Request request) async {
    if (request.url.host == 'api-shoulei-ssl.xunlei.com') {
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': [
            {
              'name': 'movie.srt',
              'languages': ['zh'],
              'ext': 'srt',
              'url': 'https://subtitle.v.geilijiasu.com/movie.srt',
            },
            {'name': 'movie.ttml', 'ext': 'ttml', 'url': 'https://subtitle.v.geilijiasu.com/movie.ttml'},
          ],
        }),
        200,
      );
    }
    expect(request.url.host, 'subtitle.v.geilijiasu.com');
    if (!downloading.isCompleted) downloading.complete();
    return download?.future ?? http.Response.bytes(utf8.encode(_srt), 200);
  }

  void mount() => status = MediaFolderStatus(state: MediaFolderState.authorized, localRoot: root.path, writable: true);
  Future<void> close() async {
    await panel.close();
    sources.close();
    await playback.events.close();
    await playback.audioInput.pcm.close();
    await audioBoundaries.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _Playback implements PlaybackSession, PlaybackSubtitleInput {
  final events = StreamController<PlaybackSnapshot>.broadcast(sync: true);
  @override
  Stream<PlaybackSnapshot> get changes => events.stream;
  @override
  Stream<PlaybackSubtitleSource?> get subtitleSources => const Stream.empty();
  @override
  late PlaybackSnapshot snapshot;
  @override
  late PlaybackSubtitleSource subtitleSource;
  @override
  final _Audio audioInput = _Audio();
  String? rendered;

  void open(
    PlayTarget target,
    int generation, {
    List<PlaybackTrack> subtitles = const [],
    List<PlaybackTrack> audio = const [],
    String? selectedAudioId,
    Duration duration = const Duration(seconds: 10),
  }) {
    subtitleSource = PlaybackSubtitleSource(
      generation: generation,
      target: target,
      mediaSourceId: 'source',
      address: Uri.https('example.test', '/media'),
      itemFilePath: '/mnt/media/${target.itemId}.strm',
      headers: const {},
      userAgent: 'Mozilla/5.0',
    );
    rendered = null;
    snapshot = PlaybackSnapshot(
      generation: generation,
      target: target,
      phase: PlaybackPhase.playing,
      duration: duration,
      subtitleTracks: subtitles,
      audioTracks: audio,
      selectedAudioId: selectedAudioId,
    );
    events.add(snapshot);
  }

  @override
  Future<void> selectSubtitle(String? trackId) async {
    snapshot = PlaybackSnapshot(
      generation: snapshot.generation,
      target: snapshot.target,
      phase: snapshot.phase,
      duration: snapshot.duration,
      subtitleTracks: snapshot.subtitleTracks,
      selectedSubtitleId: trackId,
    );
    events.add(snapshot);
  }

  void end() {
    snapshot = PlaybackSnapshot(generation: snapshot.generation, target: snapshot.target, phase: PlaybackPhase.ended);
    events.add(snapshot);
  }

  @override
  Future<String> loadExternalSubtitle(
    String url, {
    required int generation,
    String? title,
    String? language,
    String? codec,
    PlaybackTrackSource source = PlaybackTrackSource.online,
  }) async {
    final id = '$generation:external';
    rendered = await File.fromUri(Uri.parse(url)).readAsString();
    expect(generation, snapshot.generation);
    snapshot = PlaybackSnapshot(
      generation: generation,
      target: snapshot.target,
      phase: PlaybackPhase.playing,
      duration: snapshot.duration,
      selectedSubtitleId: id,
      subtitleTracks: [
        PlaybackTrack(id: id, name: title ?? 'subtitle', language: language, source: source, format: codec),
      ],
    );
    events.add(snapshot);
    return id;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Audio extends NativePlaybackAudioInput {
  final started = Completer<void>();
  final pcm = StreamController<NativePcmPacket>.broadcast(sync: true);
  @override
  Stream<NativePcmPacket> get packets => pcm.stream;
  @override
  Future<bool> start({bool dialogue = true}) async {
    if (!started.isCompleted) started.complete();
    return true;
  }

  @override
  Future<void> stop() async {}
}
