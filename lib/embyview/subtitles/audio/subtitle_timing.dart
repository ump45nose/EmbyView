import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;

import '../../contracts/common.dart';

final _events = StreamController<SubtitleAiTiming>.broadcast();
Stream<SubtitleAiTiming> get subtitleAiTimings => _events.stream;

/// Media clock windows and elapsed wall time only. No source, dialogue or credentials.
final class SubtitleAiTiming {
  SubtitleAiTiming(
    this.stage,
    this.windows,
    this.elapsed,
    this.status, {
    this.batch,
    this.attempt,
    this.httpStatus,
    this.retryDelay,
    this.cues,
  }) : finishedAtUs = DateTime.now().microsecondsSinceEpoch;

  final String stage, status;
  final List<TimeRange> windows;
  final Duration elapsed;
  final int finishedAtUs;
  final int? batch, attempt, httpStatus, cues;
  final Duration? retryDelay;

  Map<String, Object?> toJson() => {
    'stage': stage,
    'windows': [
      for (final w in windows) [w.start.inMicroseconds, w.end.inMicroseconds],
    ],
    'elapsedUs': elapsed.inMicroseconds,
    'finishedAtUs': finishedAtUs,
    'status': status,
    if (batch != null) 'batch': batch,
    if (attempt != null) 'attempt': attempt,
    if (httpStatus != null) 'httpStatus': httpStatus,
    if (retryDelay != null) 'retryDelayMs': retryDelay!.inMilliseconds,
    if (cues != null) 'cues': cues,
  };

  void emit() {
    if (_events.hasListener) _events.add(this);
    if (const bool.fromEnvironment('EMBYVIEW_SUBTITLE_TIMINGS')) {
      debugPrintSynchronously('SUBTITLE_TIMING ${jsonEncode(toJson())}');
    }
  }
}
