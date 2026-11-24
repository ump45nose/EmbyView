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
}

class _Fixture {
  _Fixture(this.root);
  final Directory root;
  final playback = _Playback()..open(_movie, 1);
  late final SubtitleSources sources;
  late final BoundSubtitlePanel panel;
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
    fixture.panel = BoundSubtitlePanel(
      session: fixture.playback,
      input: fixture.playback,
      store: SubtitleStore(
        folderStatus: () async => fixture.status,
        localDirectory: () async => Directory('${root.path}/cache'),
      ),
      loadItem: (id, _) async =>
          fixture.lookup?.future ??
          (
            item: {'Name': id},
            source: fixture.playback.subtitleSource,
            streams: <Map<String, dynamic>>[],
            duration: fixture.playback.snapshot.duration,
            audioIndex: null,
          ),
      loadDocument: (_, _) async => null,
      sources: fixture.sources,
      processor: SubtitleAiProcessor(
        readSecret: (_) async {
          fixture.requestedAiKey = true;
          return null;
        },
        translationProvider: () => TranslationProvider.openAi,
        meter: <T>(_, invoke) async => (await invoke()).value,
      ),
      preferences: () => const LocalPreferences(subtitleSources: {SubtitleSource.xunlei}),
      onClosed: () {},
      boundaries: const Stream<SubtitleAudioBoundary>.empty(),
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

  void open(PlayTarget target, int generation) {
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
      duration: const Duration(seconds: 10),
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
