import 'common.dart';
import 'playback.dart';

enum ChineseSubtitleState { complete, partial, canGenerate, unknown }

enum SubtitleSource { xunlei, assrt, openSubtitles, anime }

enum SubtitleOrigin { embedded, embyExternal, nas, online, ai }

enum SubtitleSaveState { notRequired, saving, saved, failed }

enum SubtitleIndexState { checking, recognized, unrecognized, unavailable }

enum AiRunState {
  preparing,
  generating,
  catchingUp,
  completed,
  failed,
  cancelled,
}

enum BudgetState { available, exceeded, unknown, missingCredentials }

enum EpisodeJobState {
  queued,
  reading,
  transcribing,
  translating,
  completed,
  failed,
  cancelled,
}

enum AiUsageState { available, localOnly, unavailable }

class SubtitleAvailability {
  const SubtitleAvailability({
    this.chinese = ChineseSubtitleState.unknown,
    this.coverage = const [],
    this.hasEmbeddedChinese,
    this.nasTrackCount,
    this.hasAiChinese,
    this.reason,
  });

  final ChineseSubtitleState chinese;
  final List<TimeRange> coverage;
  final bool? hasEmbeddedChinese;
  final int? nasTrackCount;
  final bool? hasAiChinese;
  final String? reason;
}

class SubtitleCue {
  const SubtitleCue({
    required this.id,
    required this.start,
    required this.end,
    required this.text,
    this.translation,
  });

  final String id;
  final Duration start;
  final Duration end;
  final String text;
  final String? translation;
}

class SubtitleCandidate {
  const SubtitleCandidate({
    required this.id,
    required this.source,
    required this.name,
    this.language,
    this.format,
    this.releaseGroup,
  });

  final String id;
  final SubtitleSource source;
  final String name;
  final String? language;
  final String? format;
  final String? releaseGroup;
}

class SubtitleSearchGroup {
  const SubtitleSearchGroup({
    required this.source,
    this.candidates = const [],
    this.failure,
  });

  final SubtitleSource source;
  final List<SubtitleCandidate> candidates;
  final EmbyViewFailure? failure;
}

class SubtitleTrackState {
  const SubtitleTrackState({
    required this.trackId,
    required this.origin,
    this.active = false,
    this.save = SubtitleSaveState.notRequired,
    this.index = SubtitleIndexState.unavailable,
    this.candidateId,
    this.failure,
  });

  final String trackId;
  final SubtitleOrigin origin;
  final bool active;
  final SubtitleSaveState save;
  final SubtitleIndexState index;
  final String? candidateId;
  final EmbyViewFailure? failure;
}

class AiRun {
  const AiRun({
    required this.generation,
    required this.state,
    required this.startedAt,
    this.coverageStart,
    this.coverageEnd,
    this.coverage = const [],
    this.cues = const [],
    this.failure,
  });

  final int generation;
  final AiRunState state;
  final Duration startedAt;
  final Duration? coverageStart;
  final Duration? coverageEnd;

  /// Real coverage only; gaps after seeking must remain gaps.
  final List<TimeRange> coverage;
  final List<SubtitleCue> cues;
  final EmbyViewFailure? failure;
}

class SubtitleSnapshot {
  const SubtitleSnapshot({
    required this.generation,
    this.selectedTrackId,
    this.tracks = const [],
    this.cues,
    this.ai,
  });

  final int generation;
  final String? selectedTrackId;
  final List<SubtitleTrackState> tracks;

  /// Null means the current track cannot supply dialogue; empty means no cues yet.
  final List<SubtitleCue>? cues;
  final AiRun? ai;
}

class SeasonQuote {
  const SeasonQuote({
    required this.id,
    required this.seriesId,
    required this.seasonId,
    required this.seasonName,
    required this.episodeIds,
    required this.completedCount,
    required this.pendingCount,
    required this.estimatedCostMicros,
    required this.budget,
    this.reason,
  });

  final String id;
  final String seriesId;
  final String seasonId;
  final String seasonName;
  final List<String> episodeIds;
  final int completedCount;
  final int pendingCount;
  final int estimatedCostMicros;
  final BudgetState budget;
  final String? reason;
}

class EpisodeJob {
  const EpisodeJob({
    required this.episodeId,
    required this.name,
    required this.state,
    this.episodeNumber,
    this.waitingReason,
    this.failure,
  });

  final String episodeId;
  final String name;
  final EpisodeJobState state;
  final int? episodeNumber;
  final String? waitingReason;
  final EmbyViewFailure? failure;
}

class SeasonJob {
  const SeasonJob({
    required this.id,
    required this.seriesId,
    required this.seasonId,
    required this.seasonName,
    required this.episodes,
    required this.completedCount,
    required this.total,
    this.failure,
  });

  final String id;
  final String seriesId;
  final String seasonId;
  final String seasonName;
  final List<EpisodeJob> episodes;
  final int completedCount;
  final int total;
  final EmbyViewFailure? failure;
}

class AiUsage {
  const AiUsage({
    required this.month,
    this.state = AiUsageState.unavailable,
    this.usedMicros,
    this.budgetMicros = 30000000,
    this.completedEpisodes = 0,
    this.averageEpisodeMicros,
    this.reason,
  });

  final String month;
  final AiUsageState state;
  final int? usedMicros;
  final int budgetMicros;
  final int completedEpisodes;
  final int? averageEpisodeMicros;
  final String? reason;
}

abstract interface class EmbyViewSubtitles {
  Future<SubtitleAvailability> availability(String itemId);
  SubtitlePanel bind(PlaybackSession session);
  Future<SeasonQuote> quoteSeason(String seriesId, String seasonId);
  Future<String> queueSeason(SeasonQuote quote);
  Future<AiUsage> usage();
  Stream<List<SeasonJob>> get jobs;
  Future<void> cancelJob(String jobId, {String? episodeId});
}

abstract interface class SubtitlePanel {
  SubtitleSnapshot get snapshot;
  Stream<SubtitleSnapshot> get changes;
  Future<List<SubtitleSearchGroup>> search(String? text);
  Future<void> useCandidate(SubtitleCandidate candidate);
  Future<void> startAi();
  Future<void> cancelAi();
  Future<void> translate(String trackId);
  Future<void> align(String trackId);
  Future<void> retrySave(String trackId);
  Future<void> close();
}
