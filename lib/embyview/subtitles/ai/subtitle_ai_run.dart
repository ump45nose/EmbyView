import 'dart:async';
import 'dart:collection';

import '../../contracts/common.dart';
import '../../contracts/subtitles.dart';
import '../audio/subtitle_audio.dart';
import 'subtitle_ai_processor.dart';
import 'subtitle_ai_types.dart';

final class SubtitleAiRunController {
  SubtitleAiRunController(this.processor);

  final SubtitleAiProcessor processor;
  final _changes = StreamController<AiRun?>.broadcast();
  AiRun? _run;
  _ActiveRun? _active;
  Future<void> _audioReleased = Future.value();
  Duration _position = Duration.zero;
  int? _timelineGeneration;
  bool _closed = false;

  AiRun? get run => _run;
  Stream<AiRun?> get changes => _changes.stream;

  /// [timelineGeneration] belongs to the caller's playback timeline. The audio
  /// tap has its own epoch, and independent reads have their own request IDs.
  Future<SubtitleAiOutput?> start({
    required int generation,
    required int timelineGeneration,
    required Duration position,
    required Stream<SubtitleAudioSegment> audio,
    required bool followsPlayhead,
    bool realtime = true,
    required bool Function() isCurrent,
    String? language,
    String mediaContext = '',
    SubtitleAiCancellation? cancellation,
  }) async {
    if (_closed) throw StateError('The subtitle run controller is closed');
    _active?.cancellation.cancel();
    final work = _ActiveRun(generation, position, isCurrent, cancellation ?? SubtitleAiCancellation());
    _active = work;
    _timelineGeneration = timelineGeneration;
    _position = position;
    _publish(work, AiRunState.preparing);

    await _audioReleased;
    if (!_current(work)) return null;
    _AudioBuffer? buffer;
    int? tapTimeline;
    try {
      buffer = _AudioBuffer(audio, work.cancellation, (segment) {
        if (!_current(work) || segment.sourceGeneration != generation) {
          return false;
        }
        if (followsPlayhead) {
          tapTimeline ??= segment.timelineGeneration;
          if (tapTimeline != segment.timelineGeneration) {
            invalidate();
            return false;
          }
        }
        return segment.end > segment.start;
      });
      _audioReleased = buffer.released;
      _publish(work, followsPlayhead ? AiRunState.catchingUp : AiRunState.generating);
      await processor.generate(
        next: buffer.next,
        cancellation: work.cancellation,
        realtime: realtime,
        language: language,
        mediaContext: mediaContext,
        onResult: (result) {
          if (!_current(work)) return;
          if (result.cues.isNotEmpty) work.language ??= result.language;
          work.coverage = mergeSubtitleAiCoverage([...work.coverage, result.coverage]);
          work.cues.addAll(result.cues);
          _publish(work, _run!.state);
        },
      );
      if (!_current(work)) return null;
      if (work.coverage.isEmpty) {
        throw const EmbyViewFailure('未读到可用于听写的音频。', retryable: true, code: 'subtitle_audio_empty');
      }
      _publish(work, AiRunState.completed);
      return work.output;
    } catch (error) {
      if (_current(work)) {
        final failure = error is EmbyViewFailure
            ? error
            : const EmbyViewFailure('无法继续生成字幕。', retryable: true, code: 'subtitle_ai_failed');
        _publish(work, AiRunState.failed, failure: failure);
        return work.output;
      }
      return null;
    } finally {
      if (identical(_active, work)) _active = null;
      work.cancellation.cancel();
      await buffer?.released;
    }
  }

  bool _current(_ActiveRun work) => identical(_active, work) && !work.cancellation.isCancelled && work.isCurrent();

  void updatePosition(Duration position, {int? timelineGeneration}) {
    if (timelineGeneration != null && timelineGeneration != _timelineGeneration) {
      invalidate();
    }
    _position = position;
    final run = _run;
    if (run == null) return;
    final range = _coverageAtPosition(run.coverage);
    if (range?.start == run.coverageStart && range?.end == run.coverageEnd) {
      return;
    }
    _emit(
      AiRun(
        generation: run.generation,
        state: run.state,
        startedAt: run.startedAt,
        coverageStart: range?.start,
        coverageEnd: range?.end,
        coverage: run.coverage,
        cues: run.cues,
        failure: run.failure,
      ),
    );
  }

  SubtitleAiOutput? cancel() {
    final work = _active;
    if (work == null) return null;
    final output = _current(work) ? work.output : null;
    _active = null;
    work.cancellation.cancel();
    _emit(AiRun(generation: work.generation, state: AiRunState.cancelled, startedAt: work.startedAt));
    return output;
  }

  void invalidate() {
    _active?.cancellation.cancel();
    _active = null;
    _timelineGeneration = null;
    _emit(null);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    invalidate();
    await _audioReleased;
    await _changes.close();
  }

  TimeRange? _coverageAtPosition(List<TimeRange> coverage) {
    for (final range in coverage) {
      if (range.start <= _position && _position < range.end) return range;
      if (range.start > _position) break;
    }
    return null;
  }

  void _publish(_ActiveRun work, AiRunState state, {EmbyViewFailure? failure}) {
    final range = _coverageAtPosition(work.coverage);
    _emit(
      AiRun(
        generation: work.generation,
        state: state,
        startedAt: work.startedAt,
        coverageStart: range?.start,
        coverageEnd: range?.end,
        coverage: work.coverage,
        cues: work.output?.cues ?? const [],
        failure: failure,
      ),
    );
  }

  void _emit(AiRun? next) {
    if (next == _run) return;
    _run = next;
    _changes.add(next);
  }
}

final class _ActiveRun {
  _ActiveRun(this.generation, this.startedAt, this.isCurrent, this.cancellation);

  final int generation;
  final Duration startedAt;
  final bool Function() isCurrent;
  final SubtitleAiCancellation cancellation;
  final cues = <SubtitleCue>[];
  List<TimeRange> coverage = const [];
  String? language;

  SubtitleAiOutput? get output =>
      cues.isEmpty ? null : SubtitleAiOutput(coverage: coverage, cues: cues, language: language);
}

/// Load up to three windows while the current window is in the cloud. Bound
/// the reader's lookahead and keep acknowledging playback PCM between calls.
final class _AudioBuffer {
  _AudioBuffer(Stream<SubtitleAudioSegment> audio, this._cancellation, bool Function(SubtitleAudioSegment) accept) {
    _subscription = audio.listen(
      (segment) {
        if (!accept(segment)) return;
        _pending.addLast(segment);
        if (_pending.length == _maxBuffered) _subscription.pause();
        _wake();
      },
      onError: (Object error, StackTrace stack) {
        _error = error;
        _stack = stack;
        _ended = true;
        _wake();
      },
      onDone: () {
        _ended = true;
        _wake();
      },
      cancelOnError: true,
    );
    _cancellation.addListener(_stop);
  }

  static const _maxBuffered = 3;
  final SubtitleAiCancellation _cancellation;
  final _pending = Queue<SubtitleAudioSegment>();
  final _released = Completer<void>();
  late final StreamSubscription<SubtitleAudioSegment> _subscription;
  Completer<void>? _signal;
  Object? _error;
  StackTrace? _stack;
  bool _ended = false;
  Future<void> get released => _released.future;

  Future<SubtitleAudioSegment?> next() async {
    while (_pending.isEmpty && !_ended) {
      await (_signal ??= Completer<void>()).future;
    }
    if (_pending.isNotEmpty) {
      final segment = _pending.removeFirst();
      if (_subscription.isPaused) _subscription.resume();
      return segment;
    }
    if (_error case final error?) Error.throwWithStackTrace(error, _stack!);
    return null;
  }

  void _wake() {
    final signal = _signal;
    _signal = null;
    signal?.complete();
  }

  void _stop() {
    _ended = true;
    _pending.clear();
    _wake();
    _cancellation.removeListener(_stop);
    _subscription.cancel().then((_) => _released.complete(), onError: (Object _) => _released.complete());
  }
}
