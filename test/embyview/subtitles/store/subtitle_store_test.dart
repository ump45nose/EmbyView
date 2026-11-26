import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/contracts/playback.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/contracts/subtitles.dart';
import 'package:moonfin/embyview/playback/playback_subtitle_input.dart';
import 'package:moonfin/embyview/subtitles/model/subtitle_document.dart';
import 'package:moonfin/embyview/subtitles/store/subtitle_store.dart';
import 'package:path/path.dart' as p;

const _duration = Duration(seconds: 20);
const _first = TimeRange(start: Duration.zero, end: Duration(seconds: 8));
const _later = TimeRange(start: Duration(seconds: 12), end: _duration);

SubtitleDocument _srt(String text) => SubtitleDocument.srt([
  SubtitleCue(id: 'line', start: const Duration(seconds: 2), end: const Duration(seconds: 4), text: text),
]);

final class _Input implements PlaybackSubtitleInput {
  _Input(this.subtitleSource);
  @override
  final PlaybackSubtitleSource subtitleSource;
  String? text;

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
    expect(generation, subtitleSource.generation);
    text = await File.fromUri(Uri.parse(url)).readAsString();
    return 'external';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Index implements SubtitleIndexPort {
  bool? recognized = false;
  bool notifyDenied = false;
  final paths = <String>[];

  @override
  Future<void> notify(SubtitleMedia media, String embyPath) async {
    paths.add(embyPath);
    if (notifyDenied) throw StateError('permission denied');
  }

  @override
  Future<bool> matches(SubtitleMedia media, String embyPath, SubtitleDocument document) async =>
      recognized ?? (throw StateError('index unavailable'));
}

void main() {
  late Directory work, mount, mediaFolder;
  late MediaFolderStatus status;
  late SubtitleStore store;
  late _Index index;

  const regular = SubtitleMedia(
    itemId: 'episode',
    mediaSourceId: 'selected',
    duration: _duration,
    itemFilePath: '/mnt/media/Series/E1.1080p.mkv',
    mediaSourceFilePath: '/mnt/media/Series/E1.4k.mkv',
  );
  const strm = SubtitleMedia(
    itemId: 'movie',
    mediaSourceId: 'remote',
    duration: _duration,
    itemFilePath: '/mnt/media/Series/电影.strm',
    mediaSourceFilePath: 'https://115.example/not-a-file.mkv',
  );

  File sidecar(String name) => File(p.join(mediaFolder.path, name));

  MediaFolderStatus mounted() =>
      MediaFolderStatus(state: MediaFolderState.authorized, localRoot: mount.path, writable: true);

  _Input inputFor(SubtitleMedia media) => _Input(
    PlaybackSubtitleSource(
      generation: 9,
      target: PlayTarget(itemId: media.itemId),
      mediaSourceId: media.mediaSourceId,
      address: Uri.parse('https://example.com/object'),
      headers: const {},
      userAgent: 'fixture',
      itemFilePath: media.itemFilePath,
      mediaSourceFilePath: media.mediaSourceFilePath,
    ),
  );

  Future<StoredSubtitle> retain(
    String text, {
    SubtitleMedia media = regular,
    String language = 'zh',
    List<TimeRange>? coverage,
    String? pairId,
    String? candidateId,
  }) => store.retain(
    media,
    _srt(text),
    language: language,
    origin: coverage == null ? SubtitleOrigin.online : SubtitleOrigin.ai,
    coverage: coverage,
    pairId: pairId,
    candidateId: candidateId,
  );

  setUp(() async {
    work = await Directory.current.createTemp('.subtitle-store-test-');
    mount = Directory(p.join(work.path, 'mount'));
    mediaFolder = await Directory(p.join(mount.path, 'Series')).create(recursive: true);
    for (final name in ['E1.1080p.mkv', 'E1.4k.mkv', '电影.strm']) {
      await sidecar(name).writeAsString('fixture');
    }
    status = mounted();
    index = _Index();
    store = SubtitleStore(
      folderStatus: () async => status,
      localDirectory: () async => Directory(p.join(work.path, 'retained')),
      index: index,
      indexDelays: const [Duration.zero],
    );
  });

  tearDown(() => work.delete(recursive: true));

  test('strm plays locally during an outage and can be saved and reopened', () async {
    final input = inputFor(strm);
    final media = SubtitleMedia.fromPlayback(input.subtitleSource, duration: _duration);
    status = const MediaFolderStatus(state: MediaFolderState.unmounted);
    final track = await retain('中文字幕', media: media, language: 'zho', candidateId: 'candidate');
    expect(await store.register(track, input, generation: 9), 'external');
    expect(input.text, contains('中文字幕'));
    await expectLater(store.register(track, input, generation: 8), throwsA(isA<EmbyViewFailure>()));
    expect((await store.save(track)).state, SubtitleSaveState.failed);
    expect(await track.localFile!.exists(), isTrue);
    final offline = (await store.scan(strm)).availability();
    expect((offline.chinese, offline.nasTrackCount, offline.hasAiChinese), (ChineseSubtitleState.unknown, null, null));

    status = mounted();
    SubtitleIndexState? committedIndex;
    final result = await store.save(track, onCommitted: (saved) => committedIndex = saved.index);
    expect(
      (result.state, committedIndex, result.index),
      (SubtitleSaveState.saved, SubtitleIndexState.checking, SubtitleIndexState.unrecognized),
    );
    expect(index.paths, ['/mnt/media/Series/电影.zh.srt']);
    expect(await sidecar('电影.zh.srt').readAsBytes(), track.document.playbackBytes);
    final scan = await store.scan(strm);
    final reopened = scan.nasTracks.single;
    expect((reopened.origin, reopened.candidateId), (SubtitleOrigin.online, 'candidate'));
    expect(scan.availability().chinese, ChineseSubtitleState.complete);
  });

  test('scanning uses the selected file and rejects escapes and stale Emby bytes', () async {
    await sidecar('E1.1080p.zh.srt').writeAsBytes(_srt('wrong').playbackBytes);
    final document = _srt('right');
    await sidecar('E1.4k.zh-CN.srt').writeAsBytes(document.playbackBytes);
    await sidecar('E1.4k.danmu.ass').writeAsString('[Events]\n');
    final outside = await File(p.join(work.path, 'movie.mkv')).writeAsString('');
    await Link(p.join(mount.path, 'escape')).create(work.path);
    await Link(sidecar('E1.4k.en.srt').path).create(outside.path);
    final scan = await store.scan(regular);
    final track = scan.nasTracks.single;
    expect((track.language, track.document.cues!.single.text), ('zh-cn', 'right'));
    expect(scan.matchExternal(language: 'zh', document: document)?.id, track.id);
    expect(scan.matchExternal(document: _srt('stale'), filename: track.filename), isNull);
    for (final path in [
      '/mnt/media/escape/movie.mkv',
      '/mnt/media/Series/../escape/movie.mkv',
      '/mnt/media-other/movie.mkv',
      'https://115.example/movie.mkv',
    ]) {
      final invalid = SubtitleMedia(itemId: 'invalid', mediaSourceId: 'test', mediaSourceFilePath: path);
      expect((await store.scan(invalid)).failure?.code, 'subtitle_path_outside_root');
    }
  });

  test('local-file ASS plays and keeps styles and timings across reopen', () async {
    const ass =
        '[V4+ Styles]\nStyle: Default,Arial,42,&H00FFFFFF\n'
        '[Events]\nDialogue: 0,0:00:03.45,0:00:04.50,Default,,0,0,0,,{\\i1}中文字幕\n';
    final document = SubtitleDocument.parse(utf8.encode(ass), format: 'ass');
    final track = await store.retain(regular, document, language: 'zh', origin: SubtitleOrigin.online);
    final input = inputFor(regular);
    expect(await store.register(track, input, generation: 9), 'external');
    expect(input.text, ass);
    final saved = await store.save(track);
    expect(p.basename(saved.path!), 'E1.4k.zh.ass');
    expect(await File(saved.path!).readAsString(), ass);
    final reopened = (await store.scan(regular)).nasTracks.single;
    expect(reopened.document.cues!.single.start, const Duration(milliseconds: 3450));
    expect(await store.register(reopened, input, generation: 9), 'external');
    expect(input.text, ass);
  });

  test('same-name media versions reopen their own generated tracks', () async {
    await sidecar('E1.4k.mp4').writeAsString('alternate fixture');
    const alternate = SubtitleMedia(
      itemId: 'episode',
      mediaSourceId: 'alternate',
      mediaSourceFilePath: '/mnt/media/Series/E1.4k.mp4',
    );
    final first = await store.save(await retain('原版'));
    final second = await store.save(await retain('新版', media: alternate));
    expect((first.state, second.state), (SubtitleSaveState.saved, SubtitleSaveState.saved));
    expect(first.path, isNot(second.path));
    for (final (media, text) in [(regular, '原版'), (alternate, '新版')]) {
      final track = (await store.scan(media)).nasTracks.single;
      expect(track.document.cues!.single.text, text);
    }
  });

  test('saving protects foreign files and longer coverage and records exact provenance', () async {
    final external = sidecar('E1.4k.zh.srt');
    final originalBytes = _srt('外部原件').playbackBytes;
    await external.writeAsBytes(originalBytes);
    const complete = TimeRange(start: Duration.zero, end: _duration);
    final full = await retain('完整', coverage: [complete]);
    final result = await store.save(full);
    expect(result.state, SubtitleSaveState.saved);
    expect(p.basename(result.path!), 'E1.4k.zh.embyview.srt');
    expect(await external.readAsBytes(), originalBytes);

    final partial = await retain('片段', coverage: [_first, _later]);
    final rejected = await store.save(partial);
    expect(rejected.failure?.code, 'subtitle_coverage_protected');
    final saved = File(result.path!);
    expect(await saved.readAsBytes(), full.document.playbackBytes);
    expect((await store.scan(regular)).availability().hasAiChinese, isTrue);
    await saved.writeAsBytes(_srt('different bytes').playbackBytes);
    expect((await store.scan(regular)).availability().hasAiChinese, isFalse);
  });

  test('paired AI files restore timed dialogue and the actual coverage gaps', () async {
    final ja = await retain('日本語', language: 'ja', coverage: [_later, _first], pairId: 'same');
    final zh = await retain('中文字幕', coverage: [_first, _later], pairId: 'same');
    final saved = await Future.wait([store.save(ja), store.save(zh)]);
    expect(saved.map((result) => result.state), everyElement(SubtitleSaveState.saved));
    final scan = await store.scan(regular);
    final availability = scan.availability();
    expect(availability.chinese, ChineseSubtitleState.partial);
    expect(availability.coverage.map((range) => (range.start, range.end)), [
      (_first.start, _first.end),
      (_later.start, _later.end),
    ]);
    final chinese = scan.nasTracks.singleWhere((track) => track.language == 'zh');
    final cue = scan.dialogue(chinese)!.single;
    expect((cue.text, cue.translation, cue.start), ('日本語', '中文字幕', const Duration(seconds: 2)));
    expect(await mediaFolder.list().where((file) => file.path.endsWith('.tmp')).isEmpty, isTrue);
  });

  test('notification, actual index and local save report independent results', () async {
    final track = await retain('字幕');
    index.notifyDenied = true;
    index.recognized = null;
    final saved = await store.save(track);
    expect((saved.state, saved.index), (SubtitleSaveState.saved, SubtitleIndexState.unavailable));
    index.recognized = true;
    expect((await store.save(track)).index, SubtitleIndexState.recognized);
  });
}
