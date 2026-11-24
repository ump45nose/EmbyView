import 'package:uuid/uuid.dart';

import '../../contracts/common.dart';
import '../../contracts/subtitles.dart';
import '../ai/subtitle_ai_processor.dart';
import '../ai/subtitle_ai_types.dart';
import '../audio/subtitle_audio.dart';
import '../model/subtitle_document.dart';
import '../store/subtitle_store.dart';
import 'subtitle_season_queue.dart';

final class SubtitleSeasonGenerator {
  SubtitleSeasonGenerator({required this.processor, SubtitleAudioReader? reader})
    : _reader = reader ?? SubtitleAudioReader.shared;

  final SubtitleAiProcessor processor;
  final SubtitleAudioReader _reader;

  Future<String> generate(SubtitleEpisodeContext context, SubtitleEpisodeRun run) async {
    final store = context.store;
    final media = context.media;
    final scan = await store.scan(media);
    if (scan.failure case final failure?) throw failure;
    run.cancellation.check();
    final previous = scan.nasTracks.where(
      (track) => isChineseSubtitle(track.language) && !track.isForced && track.origin == SubtitleOrigin.ai,
    );
    final existing = previous.where((track) => track.isComplete).firstOrNull;
    if (existing != null) return existing.contentId;

    var language = context.language;
    final originalTracks = scan.nasTracks.where(
      (track) => !isChineseSubtitle(track.language) && track.origin == SubtitleOrigin.ai,
    );
    final originals = <(Duration, Duration), SubtitleCue>{
      for (final track in originalTracks)
        for (final cue in track.document.cues ?? const <SubtitleCue>[]) (cue.start, cue.end): cue,
    };
    final cues = <(Duration, Duration, String), SubtitleCue>{};
    final coverage = <TimeRange>[];
    for (final track in previous) {
      coverage.addAll(track.coverage ?? []);
      final paired = originalTracks.where((other) => other.pairId != null && other.pairId == track.pairId).firstOrNull;
      language ??= paired?.language;
      for (final cue in scan.dialogue(track) ?? const <SubtitleCue>[]) {
        final original = originals[(cue.start, cue.end)];
        if (cue.translation == null && original == null) {
          throw const EmbyViewFailure('已保存的片段缺少可配对的原文字幕。', code: 'subtitle_episode_pair_missing');
        }
        cues[(cue.start, cue.end, cue.translation ?? cue.text)] = cue.translation != null
            ? cue
            : SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: original!.text, translation: cue.text);
      }
    }

    final audioCancellation = SubtitleAudioCancellation();
    final cancelAudio = audioCancellation.cancel;
    run.cancellation.addListener(cancelAudio);
    var progressed = false;
    try {
      for (final gap in missingSubtitleCoverage(context.duration, coverage)) {
        for (var start = gap.start; start < gap.end;) {
          final next = start + const Duration(seconds: 30);
          final end = next < gap.end ? next : gap.end;
          run.setStage(EpisodeJobState.reading);
          final audio = await _reader.read(
            context.source,
            start: start,
            end: end,
            streamIndex: context.streamIndex,
            background: true,
            cancellation: audioCancellation,
          );
          for (final segment in audio) {
            if (segment.end <= segment.start) continue;
            final piece = await processor.process(
              segment,
              cancellation: run.cancellation,
              language: language,
              onStage: run.setStage,
            );
            language ??= piece.language;
            // The native 48 kHz reader rounds seek boundaries to a sample.
            const sample = Duration(microseconds: 22);
            coverage.add(
              TimeRange(
                start: piece.coverage.start - start <= sample ? start : piece.coverage.start,
                end: end - piece.coverage.end <= sample ? end : piece.coverage.end,
              ),
            );
            for (final cue in piece.cues) {
              cues[(cue.start, cue.end, cue.translation ?? cue.text)] = cue;
            }
            progressed = true;
          }
          start = end;
        }
      }
    } finally {
      run.cancellation.removeListener(cancelAudio);
    }
    if (!progressed && missingSubtitleCoverage(context.duration, coverage).isNotEmpty) {
      throw const EmbyViewFailure('未读到此集缺失区间的音频。', retryable: true, code: 'subtitle_episode_audio_empty');
    }
    return _save(context, run, coverage, cues.values, language);
  }

  Future<String> _save(
    SubtitleEpisodeContext context,
    SubtitleEpisodeRun run,
    List<TimeRange> coverage,
    Iterable<SubtitleCue> cues,
    String? language,
  ) async {
    final store = context.store;
    final media = context.media;
    final output = SubtitleAiOutput(coverage: coverage, cues: cues);
    final pair = const Uuid().v4();
    final sourceLanguage = isChineseSubtitle(language) ? null : language;
    Future<StoredSubtitle> write(SubtitleDocument document, String? language) async {
      run.cancellation.check();
      final track = await store.retain(
        media,
        document,
        language: language,
        origin: SubtitleOrigin.ai,
        coverage: output.coverage,
        pairId: pair,
      );
      run.cancellation.check();
      final saved = await store.save(track);
      if (saved.state != SubtitleSaveState.saved) throw saved.failure ?? _reopenFailed;
      return track;
    }

    final original = await write(output.original, sourceLanguage);
    final chinese = await write(output.chinese, 'zh');
    run.cancellation.check();
    final scan = await store.scan(media);
    if (scan.failure case final failure?) throw failure;
    bool readable(StoredSubtitle expected) => scan.nasTracks.any(
      (track) =>
          track.pairId == pair &&
          track.language == expected.language &&
          track.isComplete &&
          track.contentId == expected.contentId,
    );
    if (!readable(original) || !readable(chinese)) throw _reopenFailed;
    return chinese.contentId;
  }
}

const _reopenFailed = EmbyViewFailure('NAS 中的字幕尚未达到完整覆盖或暂时无法重新读取。', retryable: true, code: 'subtitle_episode_reopen');
