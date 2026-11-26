part of 'subtitle_ai_processor.dart';

/// All other windows have been processed. A subsequent run can fill the gaps.
final class SubtitleTranslationBatchFailure extends EmbyViewFailure {
  SubtitleTranslationBatchFailure(int count, EmbyViewFailure cause)
    : super('有 $count 批翻译未完成。${cause.reason}', retryable: true, code: 'subtitle_translation_gaps');
}

extension SubtitleAiPipeline on SubtitleAiProcessor {
  /// Reads and transcribes in media order. Only transcripts (never PCM) wait
  /// for translation. Each completed batch is published independently.
  Future<void> generate({
    required Future<SubtitleAudioSegment?> Function() next,
    required SubtitleAiCancellation cancellation,
    required bool realtime,
    required void Function(SubtitleAiSegment) onResult,
    LocalPreferences Function()? translationPreferences,
    void Function(EpisodeJobState)? onStage,
    String? language,
    String mediaContext = '',
  }) async {
    var pending = <SubtitleAiSegment>[];
    var cueCount = 0, failedBatches = 0;
    var liveWindowCount = 0, liveBatchSize = 1;
    final inFlight = <Future<void>>{};
    final stopped = Completer<void>();
    Object? fatal;
    StackTrace? fatalStack;
    EmbyViewFailure? batchError;

    Future<void> translateBatch(List<SubtitleAiSegment> pieces) async {
      try {
        final config = await _translation((translationPreferences ?? preferences)());
        final source = [for (final piece in pieces) ...piece.cues];
        final translated = await _translateCues(
          source,
          config,
          cancellation,
          mediaContext,
          language: pieces.first.language,
          windows: [for (final p in pieces) p.coverage],
        );
        cancellation.check();
        var offset = 0;
        for (final piece in pieces) {
          final end = offset + piece.cues.length;
          onResult(
            SubtitleAiSegment(
              coverage: piece.coverage,
              cues: translated.sublist(offset, end),
              language: piece.language,
            ),
          );
          offset = end;
        }
      } catch (error, stack) {
        if (error is EmbyViewFailure &&
            const {
              'subtitle_ai_http',
              'subtitle_ai_timeout',
              'subtitle_ai_network',
              'subtitle_ai_response',
            }.contains(error.code)) {
          failedBatches++;
          batchError ??= error;
        } else if (!stopped.isCompleted) {
          fatal = error;
          fatalStack = stack;
          stopped.complete();
        }
      }
    }

    Future<void> flush() async {
      if (pending.isEmpty || stopped.isCompleted) return;
      while (inFlight.length >= _maxRequests) {
        await Future.any(inFlight);
        if (stopped.isCompleted) return;
      }
      cancellation.check();
      final pieces = pending;
      pending = [];
      cueCount = 0;
      onStage?.call(EpisodeJobState.translating);
      late final Future<void> task;
      task = translateBatch(pieces).whenComplete(() => inFlight.remove(task));
      inFlight.add(task);
    }

    // A fatal authorization/budget change or an external cancellation also
    // wakes a run waiting for another packet from a paused playback tap.
    final stopReading = stopped.future.then<SubtitleAudioSegment?>((_) => null);
    final cancelled = cancellation.cancelled.then<SubtitleAudioSegment?>((_) => null);
    try {
      while (!stopped.isCompleted) {
        cancellation.check();
        final segment = await Future.any([next(), stopReading, cancelled]);
        if (segment == null || stopped.isCompleted) break;
        onStage?.call(EpisodeJobState.transcribing);
        final piece = await _transcribe(segment, cancellation, language);
        if (piece.cues.isEmpty) {
          onResult(piece);
        } else {
          // Keep complete windows together, picking the side closest to 60 lines.
          final remaining = _cueBatch - cueCount;
          if (!realtime && cueCount > 0 && piece.cues.length - remaining > remaining) {
            await flush();
          }
          pending.add(piece);
          cueCount += piece.cues.length;
        }
        if (realtime) {
          if (++liveWindowCount >= liveBatchSize) {
            // Silent windows contribute to the deadline, but need no request.
            if (pending.isNotEmpty) liveBatchSize = 2;
            await flush();
            liveWindowCount = 0;
          }
        } else if (cueCount >= _cueBatch) {
          await flush();
        }
      }
      cancellation.check();
      await flush();
    } finally {
      await Future.wait(inFlight.toList());
    }
    cancellation.check();
    if (fatal != null) Error.throwWithStackTrace(fatal!, fatalStack!);
    if (batchError != null) throw SubtitleTranslationBatchFailure(failedBatches, batchError!);
  }
}
