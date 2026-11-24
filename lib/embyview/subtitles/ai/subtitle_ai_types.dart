import 'dart:async';

import '../../contracts/common.dart';
import '../../contracts/subtitles.dart';
import '../model/subtitle_document.dart';

typedef SubtitleAiMeter = Future<T> Function<T>(int estimatedCostMicros, Future<SubtitleAiCharge<T>> Function() invoke);

/// A successful HTTP call can be charged even when its content is unusable.
final class SubtitleAiCharge<T> {
  const SubtitleAiCharge({required this.value, required this.costMicros, this.requestId});

  final T value;
  final int costMicros;
  final String? requestId;
}

final class SubtitleAiCancellation {
  final _signal = Completer<void>();
  final _listeners = <void Function()>{};

  bool get isCancelled => _signal.isCompleted;
  Future<void> get cancelled => _signal.future;

  void cancel() {
    if (isCancelled) return;
    _signal.complete();
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void check() {
    if (isCancelled) throw const SubtitleAiCancelled();
  }

  void addListener(void Function() listener) {
    if (isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

final class SubtitleAiCancelled implements Exception {
  const SubtitleAiCancelled();
}

final class SubtitleAiSegment {
  const SubtitleAiSegment({required this.coverage, required this.cues, this.language});

  final TimeRange coverage;
  final List<SubtitleCue> cues;
  final String? language;
}

final class SubtitleAiOutput {
  SubtitleAiOutput({required Iterable<TimeRange> coverage, required Iterable<SubtitleCue> cues, this.language})
    : coverage = mergeSubtitleAiCoverage(coverage),
      cues = List.unmodifiable(cues.toList()..sort(_byTime));

  final List<TimeRange> coverage;
  final List<SubtitleCue> cues;
  final String? language;

  late final SubtitleDocument original = SubtitleDocument.srt(cues);
  late final SubtitleDocument chinese = SubtitleDocument.srt([
    for (final cue in cues) SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: cue.translation ?? cue.text),
  ]);
}

int _byTime(SubtitleCue a, SubtitleCue b) {
  final result = a.start.compareTo(b.start);
  return result == 0 ? a.id.compareTo(b.id) : result;
}

List<TimeRange> mergeSubtitleAiCoverage(Iterable<TimeRange> ranges) {
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
