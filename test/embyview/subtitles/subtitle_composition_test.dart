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

  test('a slow online subtitle download registers without overriding a later explicit off', () async {
    final f = await _Fixture.open();
    addTearDown(f.close);
    final candidate = (await f.panel.search(null)).first.candidates.single;
    final download = f.download = Completer<http.Response>();
    final saved = f.panel.changes.firstWhere((state) => state.tracks.any((t) => t.save == SubtitleSaveState.failed));
    final pending = f.panel.useCandidate(candidate);
    await f.downloading.future;
    await f.playback.selectSubtitle(null);
    download.complete(http.Response.bytes(utf8.encode(_srt), 200));
    await pending;
    await saved;
    expect(f.panel.snapshot.tracks, hasLength(1));
    expect(f.panel.snapshot.selectedTrackId, isNull);
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
      (snapshot) => snapshot.tracks.length == 2 && snapshot.tracks.every((track) => track.origin == SubtitleOrigin.ai),
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
    final indexed = state.tracks.singleWhere((track) => track.trackId == '2:3');
    expect(indexed.index, SubtitleIndexState.recognized);
    expect(state.selectedTrackId, isNull);
    expect(fixture.playback.rendered, isNull);

    await fixture.playback.selectSubtitle('2:3');
    final cue = fixture.panel.snapshot.cues!.single;
    expect(cue.text, '日本語');
    expect(cue.translation, '中文字幕');
  });

  test('start AI displays the missing key or unready model reason before acquiring audio', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fixture = await _Fixture.open();
    addTearDown(fixture.close);
    fixture.playback.open(
      _movie,
      2,
      subtitles: const [PlaybackTrack(id: '2:1', name: '原字幕', source: PlaybackTrackSource.embedded)],
    );
    await fixture.playback.selectSubtitle('2:1');
    await fixture.panel.startAi();
    expect(fixture.panel.snapshot.selectedTrackId, '2:1');
    expect(fixture.playback.snapshot.subtitleTracks, hasLength(1));
    expect(fixture.panel.snapshot.ai?.state, AiRunState.failed);
    expect(fixture.panel.snapshot.ai?.failure?.reason, contains('翻译密钥'));
    expect(fixture.playback.audioInput.started.isCompleted, isFalse);

    fixture.aiRequest = (_) async => throw StateError('No network request expected');
    const asr = MethodChannel('embyview/asr');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      asr,
      (_) async => {'state': 'notDownloaded', 'receivedBytes': 0, 'totalBytes': 50},
    );
    addTearDown(() => messenger.setMockMethodCallHandler(asr, null));
    await fixture.panel.startAi();
    expect(fixture.panel.snapshot.ai?.state, AiRunState.failed);
    expect(fixture.panel.snapshot.ai?.failure?.reason, contains('设置'));
    expect(fixture.playback.audioInput.started.isCompleted, isFalse);
  });

  for (final action in ['seek', 'cancel', 'next', 'old', 'off', 'reselect']) {
    test('the current choice owns subtitle registration after $action', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final f = await _Fixture.open();
      addTearDown(f.close);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const audio = MethodChannel('embyview/audio_control'), asr = MethodChannel('embyview/asr');
      messenger.setMockMethodCallHandler(
        audio,
        (_) async => [
          {'startUs': 0, 'sourceUs': 0, 'pcm': Uint8List(48000 * 4 * 20)},
        ],
      );
      messenger.setMockMethodCallHandler(
        asr,
        (call) async => call.method == 'modelStatus'
            ? {'state': 'ready', 'receivedBytes': 1, 'totalBytes': 1}
            : {
                'language': 'en',
                'segments': [
                  {'startUs': 0, 'endUs': 1000000, 'text': 'Hi'},
                ],
              },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(audio, null);
        messenger.setMockMethodCallHandler(asr, null);
      });
      f.aiRequest = (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {'content': '{"lines":[{"id":0,"text":"Hi"}]}'},
            },
          ],
        }),
        200,
      );
      f.playback.open(
        _movie,
        2,
        duration: const Duration(seconds: 20),
        subtitles: const [PlaybackTrack(id: '2:1', name: '旧字幕', source: PlaybackTrackSource.embedded)],
      );
      await f.playback.selectSubtitle('2:1');
      final gate = f.playback.registrationGate = Completer<void>();
      final pending = f.panel.startAi();
      final live = f.playback.snapshot.selectedSubtitleId!;
      expect(live, isNot('2:1'));
      expect(f.playback.snapshot.subtitleTracks.last.name, '简体中文 · AI 生成');
      expect(f.panel.snapshot.tracks.where((t) => t.active).single.trackId, live);
      await f.playback.registrationStarted.future;
      expect(f.panel.snapshot.cues?.single.text, 'Hi');
      if (action == 'seek') {
        f.audioBoundaries.add((
          sourceGeneration: 2,
          kind: SubtitleAudioBoundaryKind.seek,
          ready: false,
          position: const Duration(seconds: 9),
          streamIndex: null,
        ));
      } else if (action == 'next') {
        f.playback.open(const PlayTarget(itemId: 'next'), 3);
      } else if (action == 'cancel') {
        await f.panel.cancelAi();
      } else {
        await f.playback.selectSubtitle('2:1');
        expect(f.panel.snapshot.cues, isNull);
        await f.playback.selectSubtitle(null);
        expect(f.panel.snapshot.selectedTrackId, isNull);
        if (action == 'old') await f.playback.selectSubtitle('2:1');
        if (action == 'reselect') {
          await f.playback.selectSubtitle(live);
          expect(f.panel.snapshot.cues?.single.text, 'Hi');
        }
      }
      final aborted = ['seek', 'cancel', 'next'].contains(action);
      final save = aborted
          ? null
          : f.panel.changes.firstWhere((state) => state.tracks.any((t) => t.save == SubtitleSaveState.failed));
      gate.complete();
      await pending;
      if (aborted) {
        expect(f.playback.registered, isEmpty);
        expect(f.playback.rendered, isNull);
        expect(f.panel.snapshot.selectedTrackId, isNot(live));
      } else {
        expect(f.panel.snapshot.tracks.any((t) => t.trackId == live), isFalse);
        expect(f.playback.registered, hasLength(1));
        if (action == 'reselect') {
          expect(f.playback.rendered, contains('Hi'));
        } else {
          expect(f.panel.snapshot.selectedTrackId, action == 'old' ? '2:1' : null);
          expect(f.playback.rendered, isNull);
        }
        // The asynchronous NAS save can still have a local write in flight.
        await save;
      }
    });
  }

  test('normal playback end flushes a short final segment in the following mode', () async {
    final fixture = await _Fixture.open();
    addTearDown(fixture.close);
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('embyview/audio_control');
    final pcm = Uint8List(48000 * 4);
    fixture.aiRequest = (_) async => throw StateError('Unexpected translation for silence');
    const asr = MethodChannel('embyview/asr');
    var transcriptions = 0;
    messenger.setMockMethodCallHandler(asr, (call) async {
      if (call.method == 'modelStatus') return {'state': 'ready', 'receivedBytes': 1, 'totalBytes': 1};
      transcriptions++;
      return {'language': 'ja', 'segments': []};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(asr, null));
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
    expect(transcriptions, 1);
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
    const asr = MethodChannel('embyview/asr');
    messenger.setMockMethodCallHandler(
      asr,
      (call) async => call.method == 'modelStatus'
          ? {'state': 'ready', 'receivedBytes': 1, 'totalBytes': 1}
          : {
              'language': 'en',
              'segments': [
                {'startUs': 0, 'endUs': 100000, 'text': 'Hello'},
              ],
            },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(asr, null));
    final requests = StreamController<(int?, String?)>();
    final heard = StreamIterator(requests.stream);
    final replies = <Completer<http.Response>>[];
    fixture.aiRequest = (request) {
      final instructions = jsonDecode(request.body)['messages'][0]['content'] as String;
      final language = RegExp(r'原文语言：(ja|en)').firstMatch(instructions)?.group(1);
      requests.add((streamIndex, language));
      final reply = Completer<http.Response>();
      replies.add(reply);
      return reply.future;
    };
    addTearDown(() async {
      for (final reply in replies) {
        if (!reply.isCompleted) reply.complete(http.Response('', 400));
      }
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

    await fixture.playback.selectSubtitle(null);
    switchedTo(8);
    expect(await heard.moveNext(), isTrue);
    expect(heard.current, (8, 'en'));
    expect(fixture.playback.snapshot.selectedSubtitleId, isNull);
    switchedTo(99);
    expect(await heard.moveNext(), isTrue);
    expect(heard.current, (99, 'en')); // Falls back to the detected language.
    // The engine may reopen the same media to switch a burned-in track or
    // change audio. Work follows the new source without reclaiming subtitles.
    fixture.playback.open(_movie, 3, duration: const Duration(seconds: 20));
    // Let a cancelled request return its slot in the shared translation pool.
    replies[0].complete(http.Response('', 400));
    expect(await heard.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect(fixture.playback.snapshot.selectedSubtitleId, isNull);
    final live = fixture.playback.snapshot.subtitleTracks.single;
    expect(live.source, PlaybackTrackSource.ai);
    await fixture.playback.selectSubtitle(live.id);
    fixture.playback.open(_movie, 4, duration: const Duration(seconds: 20));
    replies[1].complete(http.Response('', 400));
    expect(await heard.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect(fixture.playback.snapshot.selectedSubtitleId, fixture.playback.snapshot.subtitleTracks.single.id);
    expect(fixture.playback.snapshot.selectedSubtitleId, isNot(live.id));
    await fixture.panel.cancelAi();
    for (final reply in replies) {
      if (!reply.isCompleted) reply.complete(http.Response('', 400));
    }
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
        readTranslationKey: (_) async {
          fixture.requestedAiKey = true;
          return fixture.aiRequest == null ? null : 'mock-key';
        },
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
  String? rendered, liveTrack, previousTrack;
  @override
  int subtitleSelectionRevision = 0;
  Completer<void>? registrationGate;
  final registrationStarted = Completer<void>();
  final registered = <String, String>{};

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
    liveTrack = null;
    previousTrack = null;
    registered.clear();
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

  void _publish(String? selected, List<PlaybackTrack> tracks) {
    rendered = registered[selected];
    snapshot = PlaybackSnapshot(
      generation: snapshot.generation,
      target: snapshot.target,
      phase: snapshot.phase,
      duration: snapshot.duration,
      position: snapshot.position,
      subtitleTracks: tracks,
      selectedSubtitleId: selected,
      subtitleOverlayId: selected == liveTrack ? liveTrack : null,
      audioTracks: snapshot.audioTracks,
      selectedAudioId: snapshot.selectedAudioId,
    );
    events.add(snapshot);
  }

  @override
  Future<void> selectSubtitle(String? trackId) async {
    subtitleSelectionRevision++;
    if (trackId != null && trackId == liveTrack && snapshot.selectedSubtitleId != liveTrack) {
      previousTrack = snapshot.selectedSubtitleId;
    }
    _publish(trackId, snapshot.subtitleTracks);
  }

  @override
  Future<void> setLiveSubtitle(String trackId, {required int generation, required bool select}) async {
    if (snapshot.generation != generation) throw const EmbyViewFailure('播放已变更。');
    final previous = liveTrack;
    if (select && (previous == null || previous != snapshot.selectedSubtitleId)) {
      previousTrack = snapshot.selectedSubtitleId;
    }
    liveTrack = trackId;
    final selected = select || previous != null && snapshot.selectedSubtitleId == previous;
    if (selected) subtitleSelectionRevision++;
    _publish(selected ? trackId : snapshot.selectedSubtitleId, [
      ...snapshot.subtitleTracks.where((t) => t.id != previous),
      PlaybackTrack(id: trackId, name: '简体中文 · AI 生成', language: 'zh', source: PlaybackTrackSource.ai),
    ]);
  }

  @override
  Future<void> endLiveSubtitle(String trackId, {String? replacementId}) async {
    if (trackId != liveTrack) return;
    liveTrack = null;
    _publish(
      snapshot.selectedSubtitleId == trackId ? replacementId ?? previousTrack : snapshot.selectedSubtitleId,
      snapshot.subtitleTracks.where((t) => t.id != trackId).toList(),
    );
  }

  void end() {
    snapshot = PlaybackSnapshot(generation: snapshot.generation, target: snapshot.target, phase: PlaybackPhase.ended);
    events.add(snapshot);
  }

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
  }) async {
    if (!registrationStarted.isCompleted) registrationStarted.complete();
    await registrationGate?.future;
    final id = '$generation:external${registered.length}';
    final text = await File.fromUri(Uri.parse(url)).readAsString();
    if (generation != snapshot.generation || liveTrackId != null && liveTrackId != liveTrack) {
      throw const EmbyViewFailure('播放或生成已变更。');
    }
    registered[id] = text;
    _publish(snapshot.selectedSubtitleId, [
      ...snapshot.subtitleTracks,
      PlaybackTrack(id: id, name: title ?? 'subtitle', language: language, source: source, format: codec),
    ]);
    return id;
  }

  @override
  Future<void> reconcileIndexedSubtitle({
    required int generation,
    required String indexedTrackId,
    required String contentKey,
  }) async {}

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
