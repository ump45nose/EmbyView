import 'dart:convert';
import 'dart:typed_data';

import '../../contracts/subtitles.dart';
import 'subtitle_encoding.dart';

/// An original file and its UTF-8 playback copy. Dialogue is a read-only
/// projection of the script, with times on the same timeline as playback.
final class SubtitleDocument {
  SubtitleDocument._(this.format, this.originalBytes, this.playbackBytes, this._text, this._events);

  factory SubtitleDocument.parse(List<int> bytes, {required String format, String? encoding, String? language}) {
    final codec = normalizeSubtitleFormat(format);
    final original = Uint8List.fromList(bytes).asUnmodifiableView();
    if (isGraphicSubtitleFormat(codec)) {
      return SubtitleDocument._(codec, original, original, null, null);
    }
    if (!textSubtitleFormats.contains(codec)) {
      throw FormatException('Unsupported subtitle format', format);
    }
    final decoded = decodeSubtitle(original, encoding: encoding, language: language);
    final text =
        decoded.unchanged && original.length >= 3 && original[0] == 0xef && original[1] == 0xbb && original[2] == 0xbf
        ? '\uFEFF${decoded.text}'
        : decoded.text;
    final playback = decoded.unchanged ? original : _utf8(text);
    final events = _isAss(codec) ? _assEvents(text) : _textEvents(text, vtt: codec == 'vtt');
    return SubtitleDocument._(codec, original, playback, text, events);
  }

  factory SubtitleDocument.srt(Iterable<SubtitleCue> cues) {
    final ordered = cues.toList()..sort(_compareCues);
    final out = StringBuffer();
    for (final (index, cue) in ordered.indexed) {
      _validateTiming(cue);
      out
        ..writeln(index + 1)
        ..writeln('${_timestamp(cue.start, 'srt')} --> ${_timestamp(cue.end, 'srt')}')
        ..writeln(cue.text.trim().replaceAll(_blankLine, '\n'))
        ..writeln();
    }
    return SubtitleDocument.parse(utf8.encode(out.toString()), format: 'srt');
  }

  final String format;
  final Uint8List originalBytes;
  final Uint8List playbackBytes;
  final String? _text;
  final List<_TimedCue>? _events;

  bool get hasTimings => _events?.isNotEmpty ?? false;

  late final List<SubtitleCue>? cues = _events == null
      ? null
      : List.unmodifiable(
          (_events.where((event) => event.cue.text.isNotEmpty).map((event) => event.cue).toList()..sort(_compareCues)),
        );

  /// Rewrite only timestamp fields, preserving styles, settings and other events.
  SubtitleDocument withTimings(Iterable<SubtitleCue> cues) {
    final events = _events ?? (throw StateError('Subtitle timings are unavailable'));
    final text = _text!;
    final byId = {for (final cue in cues) cue.id: cue};
    final out = StringBuffer();
    var position = 0;
    for (final event in events) {
      final cue = byId[event.cue.id];
      if (cue == null || (cue.start == event.cue.start && cue.end == event.cue.end)) {
        continue;
      }
      _validateTiming(cue);
      out
        ..write(text.substring(position, event.startOffset))
        ..write(_timestamp(cue.start, format))
        ..write(text.substring(event.afterStart, event.endOffset))
        ..write(_timestamp(cue.end, format));
      position = event.afterEnd;
    }
    if (position == 0) return this;
    out.write(text.substring(position));
    return SubtitleDocument.parse(utf8.encode(out.toString()), format: format);
  }
}

const textSubtitleFormats = {'srt', 'ass', 'ssa', 'vtt'};

String normalizeSubtitleFormat(String format) => switch (format.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '')) {
  'subrip' => 'srt',
  'webvtt' => 'vtt',
  'hdmv_pgs_subtitle' || 'pgssub' || 'pgs' => 'sup',
  'dvd_subtitle' || 'dvdsub' => 'vobsub',
  final value => value,
};

const _graphicFormats = {'sup', 'vobsub', 'idx', 'dvb_subtitle', 'dvbsub', 'xsub'};
bool isGraphicSubtitleFormat(String format) => _graphicFormats.contains(normalizeSubtitleFormat(format));
bool _isAss(String format) => format == 'ass' || format == 'ssa';
Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text)).asUnmodifiableView();

String? normalizeSubtitleLanguage(String? language) {
  final input = language?.trim().toLowerCase().replaceAll('_', '-');
  if (input == null || input.isEmpty || input == 'und') return null;
  final parts = input.split('-');
  final code = switch (parts.first) {
    'chi' || 'zho' || 'cmn' || 'chs' || 'cht' => 'zh',
    'jpn' => 'ja',
    'eng' => 'en',
    'kor' => 'ko',
    'fre' || 'fra' => 'fr',
    'ger' || 'deu' => 'de',
    'spa' => 'es',
    'ita' => 'it',
    'por' => 'pt',
    'rus' => 'ru',
    final value => value,
  };
  return [code, ...parts.skip(1)].join('-');
}

bool isChineseSubtitle(String? language) {
  final normalized = normalizeSubtitleLanguage(language);
  return normalized == 'zh' || (normalized?.startsWith('zh-') ?? false);
}

void _validateTiming(SubtitleCue cue) {
  if (cue.start.isNegative || cue.end <= cue.start) {
    throw ArgumentError.value(cue.id, 'cues', 'Invalid subtitle timing');
  }
}

int _compareCues(SubtitleCue a, SubtitleCue b) {
  final order = a.start.compareTo(b.start);
  return order == 0 ? a.id.compareTo(b.id) : order;
}

final _timePattern = RegExp(r'^(?:(\d+):)?(\d{2}):(\d{2})[.,](\d{1,3})$');

Duration? _time(String value) {
  final match = _timePattern.firstMatch(value);
  if (match == null) return null;
  final minutes = int.parse(match[2]!);
  final seconds = int.parse(match[3]!);
  if (seconds >= 60 || (match[1] != null && minutes >= 60)) return null;
  return Duration(
    hours: int.parse(match[1] ?? '0'),
    minutes: minutes,
    seconds: seconds,
    milliseconds: int.parse(match[4]!.padRight(3, '0')),
  );
}

String _timestamp(Duration time, String format) {
  final ass = _isAss(format);
  final hours = ass ? '${time.inHours}' : time.inHours.toString().padLeft(2, '0');
  final minutes = (time.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (time.inSeconds % 60).toString().padLeft(2, '0');
  final milliseconds = time.inMilliseconds % 1000;
  final fraction = ass ? (milliseconds ~/ 10).toString().padLeft(2, '0') : milliseconds.toString().padLeft(3, '0');
  return '$hours:$minutes:$seconds${format == 'srt' ? ',' : '.'}$fraction';
}

typedef _TimedCue = ({SubtitleCue cue, int startOffset, int afterStart, int endOffset, int afterEnd});

void _addCue(List<_TimedCue> cues, (String, int) first, (String, int) last, String text) {
  final (startText, startOffset) = first;
  final (endText, endOffset) = last;
  final start = _time(startText);
  final end = _time(endText);
  if (start == null || end == null || end <= start) return;
  cues.add((
    cue: SubtitleCue(id: '${cues.length + 1}', start: start, end: end, text: text),
    startOffset: startOffset,
    afterStart: startOffset + startText.length,
    endOffset: endOffset,
    afterEnd: endOffset + endText.length,
  ));
}

final _linePattern = RegExp(r'[^\r\n]*(?:\r\n|\n|\r|$)');
final _blankLine = RegExp(r'\r?\n(?:[ \t]*\r?\n)+');
final _timedLine = RegExp(r'^\s*([\d:.,]+)\s*-->\s*([\d:.,]+)(?:\s|$)');
final _htmlTag = RegExp(r'</?(?:[a-zA-Z][^<>]*|[\d:.]+)>');
final _vttBlock = RegExp(r'^(?:NOTE(?:\s|$)|STYLE\s*$|REGION\s*$)');

List<_TimedCue> _textEvents(String text, {required bool vtt}) {
  final lines = _linePattern.allMatches(text).where((m) => m.end > m.start).toList();
  final result = <_TimedCue>[];
  for (var i = 0; i < lines.length;) {
    final line = lines[i++];
    final content = line[0]!;
    final timing = _timedLine.firstMatch(content);
    if (timing == null && !(vtt && _vttBlock.hasMatch(content))) continue;
    final bodyStart = i;
    while (i < lines.length && lines[i][0]!.trim().isNotEmpty) {
      i++;
    }
    if (timing == null) continue;
    final start = timing[1]!;
    final end = timing[2]!;
    final body = lines.getRange(bodyStart, i).map((line) => line[0]!.trimRight()).join('\n');
    _addCue(
      result,
      (start, line.start + content.indexOf(start)),
      (end, line.start + content.indexOf(end, content.indexOf('-->') + 3)),
      body.replaceAll(_htmlTag, '').trim(),
    );
  }
  return result;
}

const _assDefault = 'layer,start,end,style,name,marginl,marginr,marginv,effect,text';
final _assDialogue = RegExp(r'^\s*Dialogue:\s*', caseSensitive: false);
final _assField = RegExp(r'([^,\r\n]*),');
final _overrides = RegExp(r'\{[^}]*\}');
final _drawingMode = RegExp(r'\\p(\d+)');

List<_TimedCue> _assEvents(String script) {
  final result = <_TimedCue>[];
  var events = false;
  var columns = _assDefault.split(',');
  for (final line in _linePattern.allMatches(script)) {
    final raw = line[0]!;
    final lower = raw.trim().toLowerCase();
    if (lower.startsWith('[')) events = lower == '[events]';
    if (!events) continue;
    if (lower.startsWith('format:')) {
      columns = lower.substring(7).split(',').map((part) => part.trim()).toList();
      continue;
    }
    final dialogue = _assDialogue.firstMatch(raw);
    final startColumn = columns.indexOf('start');
    final endColumn = columns.indexOf('end');
    if (dialogue == null || columns.last != 'text' || startColumn < 0 || endColumn <= startColumn) {
      continue;
    }
    final fields = _assField.allMatches(raw, dialogue.end).take(columns.length - 1).toList();
    if (fields.length != columns.length - 1) continue;
    (String, int) timestamp(int index) {
      final field = fields[index];
      final trimmed = field[1]!.trim();
      return (trimmed, line.start + field.start + field[1]!.indexOf(trimmed));
    }

    _addCue(result, timestamp(startColumn), timestamp(endColumn), _assText(raw.substring(fields.last.end)));
  }
  return result;
}

String _assText(String raw) {
  final out = StringBuffer();
  var offset = 0;
  var drawing = false;
  for (final override in _overrides.allMatches(raw)) {
    if (!drawing) out.write(raw.substring(offset, override.start));
    final mode = _drawingMode.allMatches(override[0]!).lastOrNull;
    if (mode != null) drawing = mode[1] != '0';
    offset = override.end;
  }
  if (!drawing) out.write(raw.substring(offset));
  return out.toString().replaceAll(r'\N', '\n').replaceAll(r'\n', '\n').replaceAll(r'\h', ' ').trim();
}
