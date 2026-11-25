import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../contracts/common.dart';
import '../../contracts/playback.dart';
import '../../contracts/preferences.dart';
import '../../contracts/subtitles.dart';
import '../../playback/playback_subtitle_input.dart';
import '../model/subtitle_document.dart';
import 'subtitle_media.dart';

export 'subtitle_media.dart' show SubtitleMedia;

abstract interface class SubtitleIndexPort {
  Future<void> notify(SubtitleMedia media, String embyPath);

  /// Use the item's current media-source index and verify the exact bytes that
  /// Emby can deliver, including on a replacement of an already indexed file.
  Future<bool> matches(SubtitleMedia media, String embyPath, SubtitleDocument document);
}

final class StoredSubtitle {
  StoredSubtitle._({
    required this.media,
    required this.document,
    required this.language,
    required this.origin,
    required this.coverage,
    required this.filename,
    this.candidateId,
    this.pairId,
    this.localFile,
    this.nasPath,
    this.isForced = false,
    this._owningSourceId,
  });

  final SubtitleMedia media;
  final SubtitleDocument document;
  final String language;
  final SubtitleOrigin origin;
  final List<TimeRange>? coverage;
  final String filename;
  final String? candidateId;
  final String? pairId;
  final File? localFile;
  final String? nasPath;
  final bool isForced;
  final String? _owningSourceId;

  late final String contentId = _hash(document.playbackBytes);
  String get registrationKey => '$language:$contentId';
  late final String id = _key([media.itemId, media.mediaSourceId, filename, contentId]);

  bool get isComplete => _complete(coverage, media.duration);
  bool get _isUnmanaged => _owningSourceId == null;
  bool get _differentSource => _owningSourceId != null && _owningSourceId != media.mediaSourceId;
}

final class SubtitleSaveResult {
  const SubtitleSaveResult({required this.state, this.index = SubtitleIndexState.unavailable, this.path, this.failure});

  final SubtitleSaveState state;
  final SubtitleIndexState index;
  final String? path;
  final EmbyViewFailure? failure;
}

final class SubtitleScan {
  const SubtitleScan({this.nasTracks = const [], this.failure});

  final List<StoredSubtitle> nasTracks;
  final EmbyViewFailure? failure;

  SubtitleAvailability availability({
    Iterable<String?> embeddedLanguages = const [],
    Iterable<String?> embyExternalLanguages = const [],
    bool mediaKnown = true,
  }) {
    final embedded = embeddedLanguages.any(isChineseSubtitle);
    final chinese = nasTracks.where(
      (track) =>
          isChineseSubtitle(track.language) && !track.isForced && (track.document.hasTimings || track.coverage != null),
    );
    // Emby may index an app-generated partial track. Let the matched NAS
    // document carry its coverage when preparing embyExternalLanguages.
    final complete =
        embedded || embyExternalLanguages.any(isChineseSubtitle) || chinese.any((track) => track.isComplete);
    final coverage = _mergeRanges(chinese.expand((track) => track.coverage ?? []));
    final known = failure == null && mediaKnown;
    final hasAi = chinese.any((track) => track.origin == SubtitleOrigin.ai);
    return SubtitleAvailability(
      chinese: switch ((complete, coverage.isNotEmpty, known)) {
        (true, _, _) => ChineseSubtitleState.complete,
        (_, true, _) => ChineseSubtitleState.partial,
        (_, _, true) => ChineseSubtitleState.canGenerate,
        _ => ChineseSubtitleState.unknown,
      },
      coverage: coverage,
      hasEmbeddedChinese: mediaKnown ? embedded : null,
      nasTrackCount: known ? nasTracks.length : null,
      hasAiChinese: known || hasAi ? hasAi : null,
      reason: failure?.reason,
    );
  }

  /// Emby tracks retain their playback IDs. Content evidence takes precedence
  /// over a filename match when Emby supplied downloadable text.
  StoredSubtitle? matchExternal({String? language, String? filename, SubtitleDocument? document}) {
    final normalized = normalizeSubtitleLanguage(language);
    final name = filename == null ? null : p.basename(filename).toLowerCase();
    final contentId = document == null ? null : _hash(document.playbackBytes);
    for (final track in nasTracks) {
      if (normalized != null &&
          track.language != normalized &&
          !track.language.startsWith('$normalized-') &&
          !normalized.startsWith('${track.language}-')) {
        continue;
      }
      if (contentId != null ? track.contentId == contentId : track.filename.toLowerCase() == name) {
        return track;
      }
    }
    return null;
  }

  List<SubtitleCue>? dialogue(StoredSubtitle track) {
    final cues = track.document.cues;
    if (track.origin != SubtitleOrigin.ai || cues == null) return cues;
    final chinese = isChineseSubtitle(track.language);
    for (final other in nasTracks) {
      if (other.origin != SubtitleOrigin.ai ||
          isChineseSubtitle(other.language) == chinese ||
          !_samePair(track, other)) {
        continue;
      }
      final counterpart = other.document.cues;
      if (counterpart == null || counterpart.length != cues.length) continue;
      if (!cues.indexed.every((entry) => _sameTiming(entry.$2, counterpart[entry.$1]))) {
        continue;
      }
      return List.unmodifiable([
        for (final (index, cue) in cues.indexed)
          SubtitleCue(
            id: cue.id,
            start: cue.start,
            end: cue.end,
            text: chinese ? counterpart[index].text : cue.text,
            translation: chinese ? cue.text : counterpart[index].text,
          ),
      ]);
    }
    return cues;
  }
}

bool _sameTiming(SubtitleCue a, SubtitleCue b) => a.start == b.start && a.end == b.end;

bool _samePair(StoredSubtitle a, StoredSubtitle b) {
  if (a.pairId != null || b.pairId != null) {
    return a.pairId != null && a.pairId == b.pairId;
  }
  return a.coverage != null && b.coverage != null && _covers(a.coverage, b.coverage) && _covers(b.coverage, a.coverage);
}

final class SubtitleStore {
  SubtitleStore({
    required this.folderStatus,
    required this.localDirectory,
    this.index,
    this.indexDelays = const [Duration.zero, Duration(milliseconds: 500), Duration(seconds: 2)],
  });

  final Future<MediaFolderStatus> Function() folderStatus;
  final Future<Directory> Function() localDirectory;
  final SubtitleIndexPort? index;
  final List<Duration> indexDelays;
  static Future<void> _localWrites = Future.value();

  Future<StoredSubtitle> retain(
    SubtitleMedia media,
    SubtitleDocument document, {
    required String? language,
    required SubtitleOrigin origin,
    Iterable<TimeRange>? coverage,
    String? candidateId,
    String? pairId,
  }) async {
    final normalized = normalizeSubtitleLanguage(language) ?? 'und';
    if (!_languageTag.hasMatch(normalized) || !textSubtitleFormats.contains(document.format)) {
      throw const EmbyViewFailure('字幕的语言或格式不受支持。');
    }
    final base = media.embyFilePath;
    final stem = base == null ? '' : p.posix.basenameWithoutExtension(base);
    final filename = '$stem.$normalized.${document.format}';
    final file = await _localCopy(media, document, filename);
    return StoredSubtitle._(
      media: media,
      document: document,
      language: normalized,
      origin: origin,
      coverage: _trackCoverage(origin, coverage),
      filename: filename,
      candidateId: candidateId,
      pairId: pairId,
      localFile: file,
    );
  }

  Future<String> register(StoredSubtitle track, PlaybackSubtitleInput input, {required int generation}) async {
    final current = input.subtitleSource;
    if (current == null ||
        current.generation != generation ||
        current.target.itemId != track.media.itemId ||
        current.mediaSourceId != track.media.mediaSourceId) {
      throw const EmbyViewFailure('字幕所属的影片已变更。', retryable: true);
    }
    final local = track.localFile ?? await _localCopy(track.media, track.document, track.filename);
    final origin = PlaybackTrackSource.values.byName(track.origin.name);
    return input.registerExternalSubtitle(
      local.uri.toString(),
      generation: generation,
      language: track.language == 'und' ? null : track.language,
      title: track.filename,
      codec: track.document.format,
      contentKey: track.registrationKey,
      source: origin,
    );
  }

  Future<File> _localCopy(SubtitleMedia media, SubtitleDocument document, String filename) async {
    final root = await (await localDirectory()).create(recursive: true);
    final key = _key([media.itemId, media.mediaSourceId, filename, _hash(document.originalBytes)]);
    final path = await Directory(p.join(root.path, 'subtitle-$key')).create();
    final file = File(p.join(path.path, 'subtitle.${document.format}'));
    if (!identical(document.originalBytes, document.playbackBytes)) {
      final original = File(p.join(path.path, 'original.${document.format}'));
      if (!await original.exists()) {
        await _atomicWrite(original, document.originalBytes);
      }
    }
    if (!await file.exists()) await _atomicWrite(file, document.playbackBytes);
    return file;
  }

  Future<SubtitleScan> scan(SubtitleMedia media) async {
    final tracks = <StoredSubtitle>[];
    EmbyViewFailure? failure;
    try {
      final mapped = await mapMedia(media, await folderStatus());
      final entries = Directory(mapped.directory).list(followLinks: false);
      await for (final entry in entries) {
        if (entry is! File) continue;
        final track = await _read(media, mapped, entry);
        if (track != null && !track._differentSource) tracks.add(track);
      }
    } on EmbyViewFailure catch (error) {
      failure = error;
    } on FileSystemException {
      failure = const EmbyViewFailure('无法读取媒体目录中的字幕。', retryable: true);
    }
    tracks.sort((a, b) {
      if (a.isComplete != b.isComplete) return a.isComplete ? -1 : 1;
      if (a.isForced != b.isForced) return a.isForced ? 1 : -1;
      final aIsAi = a.origin == SubtitleOrigin.ai;
      if (aIsAi != (b.origin == SubtitleOrigin.ai)) return aIsAi ? -1 : 1;
      return a.filename.compareTo(b.filename);
    });
    final seen = <(String, String)>{};
    return SubtitleScan(
      nasTracks: List.unmodifiable(tracks.where((t) => seen.add((t.language, t.contentId)))),
      failure: failure,
    );
  }

  Future<SubtitleSaveResult> save(
    StoredSubtitle track, {
    bool replaceExisting = false,
    void Function(SubtitleSaveResult result)? onCommitted,
  }) async {
    final (String, String) saved;
    try {
      final pending = _localWrites.then((_) async {
        final mapped = await mapMedia(track.media, await folderStatus(), writing: true);
        final lock = File(p.join(mapped.directory, '.embyview-subtitles.lock'));
        await _checkRegularOrMissing(lock);
        final handle = await lock.open(mode: FileMode.append);
        try {
          await handle.lock(FileLock.blockingExclusive);
          await verifyMappedDirectory(mapped);
          return await _saveUnderLock(track, mapped, replaceExisting);
        } finally {
          await handle.close();
        }
      });
      _localWrites = pending.then<void>((_) {}, onError: (Object _) {});
      saved = await pending;
    } on EmbyViewFailure catch (failure) {
      return SubtitleSaveResult(state: SubtitleSaveState.failed, failure: failure);
    } on FileSystemException {
      return const SubtitleSaveResult(
        state: SubtitleSaveState.failed,
        failure: EmbyViewFailure('字幕留在本机，暂时无法保存到媒体目录。', retryable: true),
      );
    }
    final (localPath, embyPath) = saved;
    SubtitleSaveResult result(SubtitleIndexState index) =>
        SubtitleSaveResult(state: SubtitleSaveState.saved, path: localPath, index: index);
    final port = index;
    onCommitted?.call(result(port == null ? SubtitleIndexState.unavailable : SubtitleIndexState.checking));
    return result(port == null ? SubtitleIndexState.unavailable : await _checkIndex(port, track, embyPath));
  }

  Future<SubtitleIndexState> _checkIndex(SubtitleIndexPort port, StoredSubtitle track, String path) async {
    var notified = false;
    var checked = false;
    try {
      await port.notify(track.media, path);
      notified = true;
    } catch (_) {
      // A permission failure does not exclude a pre-existing matching index.
    }
    for (final wait in indexDelays) {
      if (notified && wait > Duration.zero) await Future<void>.delayed(wait);
      try {
        if (await port.matches(track.media, path, track.document)) {
          return SubtitleIndexState.recognized;
        }
        checked = true;
      } catch (_) {
        // Preserve a usable local/NAS track when the index cannot be read.
      }
      if (!notified) break;
    }
    return notified && checked ? SubtitleIndexState.unrecognized : SubtitleIndexState.unavailable;
  }

  Future<(String, String)> _saveUnderLock(
    StoredSubtitle track,
    MappedSubtitleMedia mapped,
    bool replaceExisting,
  ) async {
    final extension = track.document.format;
    final stem = '${mapped.baseName}.${track.language}';
    File sidecar([String suffix = '']) => File(p.join(mapped.directory, '$stem$suffix.$extension'));
    var target = sidecar();
    var existing = await _read(track.media, mapped, target);
    String? suffix;
    if (existing?._differentSource == true) {
      final sourceTag = _hash(utf8.encode(track.media.mediaSourceId)).substring(0, 12);
      suffix = '.embyview-$sourceTag';
    } else if (existing?._isUnmanaged == true && existing?.contentId != track.contentId && !replaceExisting) {
      suffix = '.embyview';
    }
    if (suffix != null) {
      target = sidecar(suffix);
      existing = await _read(track.media, mapped, target);
    }
    await _checkRegularOrMissing(target);
    if (existing?._differentSource == true || (existing == null && await target.exists())) throw _protected;
    final sameContent = existing?.contentId == track.contentId;
    if (existing != null && !sameContent) {
      if (existing._isUnmanaged && !replaceExisting) throw _protected;
      if (!track.isComplete && !_covers(track.coverage, existing.coverage)) {
        throw const EmbyViewFailure('现有字幕的覆盖范围更完整，已保留原文件。', code: 'subtitle_coverage_protected');
      }
    }
    final filename = p.basename(target.path);
    final embyPath = p.posix.join(mapped.embyDirectory, filename);
    // Identical external files remain externally authored, including their
    // original encoding and provenance.
    if (existing?._isUnmanaged == true && sameContent) return (target.path, embyPath);
    final effective = sameContent && !_covers(track.coverage, existing?.coverage) ? existing! : track;
    final marker = _marker(mapped, filename, track.contentId);
    await _checkRegularOrMissing(marker);
    final record = {
      'source': track.media.mediaSourceId,
      'origin': effective.origin.name,
      'coverage': effective.coverage?.map(_rangeRecord).toList(),
      'candidateId': effective.candidateId,
      'pairId': effective.pairId,
    };
    await _atomicWrite(marker, utf8.encode(jsonEncode(record)));
    if (!sameContent) await _atomicWrite(target, track.document.playbackBytes);
    return (target.path, embyPath);
  }

  Future<StoredSubtitle?> _read(SubtitleMedia media, MappedSubtitleMedia mapped, File file) async {
    final filename = p.basename(file.path);
    final parts = _nameParts(mapped.baseName, filename);
    if (parts == null || await _type(file) != FileSystemEntityType.file) return null;
    final (language, format, forced) = parts;
    try {
      final document = SubtitleDocument.parse(await file.readAsBytes(), format: format, language: language);
      final marker = _marker(mapped, filename, _hash(document.originalBytes));
      final record = await _readMarker(marker);
      return StoredSubtitle._(
        media: media,
        document: document,
        language: language,
        origin: record?.$1 ?? SubtitleOrigin.nas,
        coverage: record?.$2,
        candidateId: record?.$3,
        pairId: record?.$4,
        filename: filename,
        nasPath: file.path,
        isForced: forced,
        owningSourceId: record?.$5,
      );
    } on FormatException {
      return null;
    }
  }
}

const _protected = EmbyViewFailure('此处已有其他字幕文件，已保留原文件。', code: 'subtitle_file_protected');

final _languageTag = RegExp(r'^(?:[a-z]{2,3})(?:-[a-z0-9]{2,8})*$');
const _qualifiers = {'default', 'forced', 'sdh', 'hi', 'cc', 'embyview'};
final _versionQualifier = RegExp(r'^embyview-[a-f0-9]{12}$');

(String, String, bool)? _nameParts(String mediaBase, String subtitleName) {
  final name = subtitleName.toLowerCase();
  final base = mediaBase.toLowerCase();
  if (!name.startsWith('$base.')) return null;
  final suffix = name.substring(base.length + 1).split('.');
  final format = suffix.removeLast();
  if (!textSubtitleFormats.contains(format)) return null;
  var language = 'und';
  if (suffix.isNotEmpty && !_qualifiers.contains(suffix.first)) {
    final tag = suffix.removeAt(0).replaceAll('_', '-');
    if (!_languageTag.hasMatch(tag)) return null;
    language = normalizeSubtitleLanguage(tag) ?? 'und';
  }
  if (!suffix.every((part) => _qualifiers.contains(part) || _versionQualifier.hasMatch(part))) {
    return null;
  }
  return (language, format, suffix.contains('forced'));
}

File _marker(MappedSubtitleMedia mapped, String filename, String content) {
  final key = _key([filename.toLowerCase(), content]);
  return File(p.join(mapped.directory, '.embyview-subtitle-$key.json'));
}

Future<(SubtitleOrigin, List<TimeRange>?, String?, String?, String?)?> _readMarker(File file) async {
  if (await _type(file) != FileSystemEntityType.file) return null;
  try {
    final record = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final origin = SubtitleOrigin.values.byName(record['origin'] as String);
    final values = record['coverage'] as List<dynamic>?;
    return (
      origin,
      _trackCoverage(origin, values?.map(_rangeFromRecord)),
      record['candidateId'] as String?,
      record['pairId'] as String?,
      record['source'] as String?,
    );
  } catch (error) {
    if (error is FormatException || error is TypeError || error is ArgumentError) return null;
    rethrow;
  }
}

List<int> _rangeRecord(TimeRange range) => [range.start.inMicroseconds, range.end.inMicroseconds];

TimeRange _rangeFromRecord(dynamic value) {
  final range = value as List<dynamic>;
  return TimeRange(
    start: Duration(microseconds: range[0] as int),
    end: Duration(microseconds: range[1] as int),
  );
}

String _hash(List<int> bytes) => sha256.convert(bytes).toString();
String _key(List<String> parts) => _hash(utf8.encode(jsonEncode(parts)));

Future<FileSystemEntityType> _type(File file) => FileSystemEntity.type(file.path, followLinks: false);

Future<void> _checkRegularOrMissing(File file) async {
  final type = await _type(file);
  if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) {
    throw _protected;
  }
}

Future<void> _atomicWrite(File file, List<int> bytes) async {
  final temporary = File(
    p.join(p.dirname(file.path), '.embyview-$pid-${DateTime.now().microsecondsSinceEpoch}-${_writeSequence++}.tmp'),
  );
  await temporary.create(exclusive: true);
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

int _writeSequence = 0;

List<TimeRange>? _trackCoverage(SubtitleOrigin origin, Iterable<TimeRange>? ranges) =>
    ranges == null && origin != SubtitleOrigin.ai ? null : _mergeRanges(ranges ?? []);

List<TimeRange> _mergeRanges(Iterable<TimeRange> ranges) {
  final sorted = ranges.where((range) => !range.start.isNegative && range.end > range.start).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final result = <TimeRange>[];
  for (final range in sorted) {
    if (result.isEmpty || range.start > result.last.end) {
      result.add(range);
    } else if (range.end > result.last.end) {
      result.last = TimeRange(start: result.last.start, end: range.end);
    }
  }
  return List.unmodifiable(result);
}

bool _covers(List<TimeRange>? incoming, List<TimeRange>? previous) {
  if (incoming == null) return true;
  if (previous == null) return false;
  return previous.every((range) => incoming.any((other) => other.start <= range.start && other.end >= range.end));
}

bool _complete(List<TimeRange>? coverage, Duration? duration) {
  if (coverage == null) return true;
  final first = coverage.firstOrNull;
  if (first == null || duration == null || duration <= Duration.zero) return false;
  return first.start == Duration.zero && first.end >= duration;
}
