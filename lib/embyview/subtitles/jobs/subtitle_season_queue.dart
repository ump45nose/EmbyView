import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../contracts/common.dart';
import '../../contracts/preferences.dart';
import '../../contracts/subtitles.dart';
import '../../playback/playback_subtitle_input.dart';
import '../ai/subtitle_ai_processor.dart';
import '../ai/subtitle_ai_types.dart';
import '../audio/subtitle_audio.dart';
import '../store/subtitle_store.dart';
import 'subtitle_job_files.dart';
import 'subtitle_usage_ledger.dart';

final class SubtitleSeasonRequest {
  SubtitleSeasonRequest({
    required this.accountId,
    required this.seriesId,
    required this.seasonId,
    required this.seasonName,
    required Iterable<SubtitleEpisodeRequest> episodes,
  }) : episodes = List.unmodifiable(episodes);

  final String accountId, seriesId, seasonId, seasonName;
  final List<SubtitleEpisodeRequest> episodes;
}

final class SubtitleEpisodeRequest {
  const SubtitleEpisodeRequest({
    required this.episodeId,
    required this.name,
    this.episodeNumber,
    this.mediaSourceId,
    this.authorizationId,
  });

  final String episodeId, name;
  final int? episodeNumber;
  final String? mediaSourceId, authorizationId;
}

final class SubtitleEpisodeContext {
  const SubtitleEpisodeContext({
    required this.source,
    required this.store,
    required this.duration,
    required this.availability,
    required this.authorizationId,
    this.language,
    this.mediaContext = '',
    this.streamIndex,
    this.checkAuthorization,
  });

  final PlaybackSubtitleSource source;
  final SubtitleStore store;
  final Duration duration;
  final SubtitleAvailability availability;
  final String authorizationId;
  final String? language;
  final String mediaContext;
  final int? streamIndex;
  final Future<void> Function()? checkAuthorization;

  SubtitleMedia get media => SubtitleMedia.fromPlayback(source, duration: duration);

  Future<void> verifyAuthorization() async {
    try {
      await checkAuthorization?.call();
    } on Exception catch (error) {
      throw _EpisodeAuthorizationBlocked(
        error is EmbyViewFailure ? error : const EmbyViewFailure('暂时无法确认此集的原账号和目录授权。', retryable: true),
      );
    }
  }
}

final class _EpisodeAuthorizationBlocked extends EmbyViewFailure {
  _EpisodeAuthorizationBlocked(EmbyViewFailure failure)
    : super(failure.reason, retryable: failure.retryable, code: failure.code ?? 'subtitle_job_authorization');
}

final class SubtitleEpisodeRun {
  SubtitleEpisodeRun._(this.cancellation, this.setStage);

  final SubtitleAiCancellation cancellation;
  final void Function(EpisodeJobState) setStage;
}

typedef SubtitleEpisodeResolver = Future<SubtitleEpisodeContext> Function(String, SubtitleEpisodeRequest);
typedef SubtitleEpisodeGenerator = Future<String> Function(SubtitleEpisodeContext context, SubtitleEpisodeRun run);

final class SubtitleSeasonQueue {
  SubtitleSeasonQueue._(this._file, this._entries, this._ledger, this._resolve, this._generate, this._preferences);

  static Future<SubtitleSeasonQueue> open({
    required Directory localDirectory,
    required SubtitleUsageLedger ledger,
    required SubtitleEpisodeResolver resolve,
    required SubtitleEpisodeGenerator generate,
    LocalPreferences Function()? preferences,
  }) async {
    await localDirectory.create(recursive: true);
    final file = File(p.join(localDirectory.path, 'seasons.json'));
    final saved = await readJobJson(file);
    final entries = saved == null ? <_Season>[] : (saved['jobs'] as List).map(_Season.fromJson).toList();
    final queue = SubtitleSeasonQueue._(file, entries, ledger, resolve, generate, preferences);
    queue.wake();
    return queue;
  }

  final File _file;
  final List<_Season> _entries;
  final SubtitleUsageLedger _ledger;
  final SubtitleEpisodeResolver _resolve;
  final SubtitleEpisodeGenerator _generate;
  final LocalPreferences Function()? _preferences;
  final _mutations = SubtitleJobSerial();
  final _changes = StreamController<List<SeasonJob>>.broadcast();
  bool _foregroundStrm = false, _closed = false, _wakeRequested = false;
  Future<void>? _worker;
  Timer? _poll;
  _Episode? _active;
  SubtitleAiCancellation? _cancellation;

  Stream<List<SeasonJob>> get jobs => Stream.multi((controller) {
    controller.add(_snapshot());
    final sub = _changes.stream.listen(controller.add, onDone: controller.close);
    controller.onCancel = sub.cancel;
  }, isBroadcast: true);

  Future<AiUsage> usage() => _ledger.usage();
  Future<SeasonQuote> quoteSeason(SubtitleSeasonRequest request) async {
    final (_, quote) = await _prepare(request);
    return quote;
  }

  Future<String> queueSeason(SubtitleSeasonRequest request, SeasonQuote quote) async {
    final (season, fresh) = await _prepare(request);
    if (fresh.id != quote.id || fresh.estimatedCostMicros > quote.estimatedCostMicros) {
      throw const EmbyViewFailure('季、媒体源、授权或预估费用已变化，请重新估价。', code: 'subtitle_quote_changed');
    }
    if (fresh.budget != BudgetState.available) {
      throw EmbyViewFailure(fresh.reason!, retryable: true, code: 'subtitle_season_budget');
    }
    final id = await _mutations.run(() async {
      _checkOpen();
      for (final entry in _entries) {
        if (entry.quoteId == season.quoteId && entry.episodes.any((row) => row.pending)) return entry.id;
      }
      _entries.add(season);
      try {
        await _persist();
      } catch (_) {
        _entries.removeLast();
        rethrow;
      }
      return season.id;
    });
    wake();
    return id;
  }

  Future<(_Season, SeasonQuote)> _prepare(SubtitleSeasonRequest request) async {
    _checkOpen();
    final episodes = request.episodes.indexed.toList()
      ..sort((a, b) {
        final order = (a.$2.episodeNumber ?? 0x7fffffff).compareTo(b.$2.episodeNumber ?? 0x7fffffff);
        return order == 0 ? a.$1.compareTo(b.$1) : order;
      });
    final seen = <String>{};
    if ([request.accountId, request.seriesId, request.seasonId].any((id) => id.isEmpty) ||
        episodes.isEmpty ||
        episodes.any((row) => row.$2.episodeId.isEmpty || !seen.add(row.$2.episodeId))) {
      throw const EmbyViewFailure('该季没有可确定的剧集列表。', code: 'subtitle_season_episodes');
    }
    final rows = <_Episode>[];
    final prefs = _preferences?.call() ?? const LocalPreferences();
    var estimate = 0;
    for (final (_, episode) in episodes) {
      final context = await _authorized(request.accountId, episode);
      final alreadyComplete = context.availability.chinese == ChineseSubtitleState.complete;
      final reference = SubtitleEpisodeRequest(
        episodeId: episode.episodeId,
        name: episode.name,
        episodeNumber: episode.episodeNumber,
        mediaSourceId: context.source.mediaSourceId,
        authorizationId: context.authorizationId,
      );
      rows.add(_Episode(reference, completeId: alreadyComplete ? 'existing' : null));
      if (alreadyComplete) continue;
      final uncovered = missingSubtitleCoverage(context.duration, context.availability.coverage);
      final duration = uncovered.fold(Duration.zero, (sum, span) => sum + span.end - span.start);
      estimate += estimateSubtitleTranslationMicros(prefs, duration);
    }
    final identity = [
      request.accountId,
      request.seriesId,
      request.seasonId,
      for (final row in rows) [row.ref.episodeId, row.ref.mediaSourceId, row.ref.authorizationId],
    ];
    final quoteId = sha256.convert(utf8.encode(jsonEncode(identity))).toString();
    final season = _Season(
      const Uuid().v4(),
      quoteId,
      request.accountId,
      request.seriesId,
      request.seasonId,
      request.seasonName,
      rows,
    );
    final count = rows.where((row) => row.completeId != null).length;
    final (budget, reason) = count == rows.length ? (BudgetState.available, null) : await _ledger.episodeBudget();
    final quote = SeasonQuote(
      id: quoteId,
      seriesId: season.seriesId,
      seasonId: season.seasonId,
      seasonName: season.name,
      episodeIds: List.unmodifiable(rows.map((row) => row.ref.episodeId)),
      completedCount: count,
      pendingCount: rows.length - count,
      estimatedCostMicros: estimate,
      budget: budget,
      reason: reason,
    );
    return (season, quote);
  }

  Future<SubtitleEpisodeContext> _authorized(String accountId, SubtitleEpisodeRequest ref) async {
    final context = await _resolve(accountId, ref);
    if (context.source.target.itemId != ref.episodeId ||
        context.source.mediaSourceId.isEmpty ||
        context.authorizationId.isEmpty ||
        ref.mediaSourceId != null && ref.mediaSourceId != context.source.mediaSourceId ||
        ref.authorizationId != null && ref.authorizationId != context.authorizationId) {
      throw const EmbyViewFailure('此集原媒体源或目录授权已经变更。', retryable: true, code: 'subtitle_job_authorization');
    }
    if (context.availability.chinese != ChineseSubtitleState.complete &&
        (context.duration <= Duration.zero || context.availability.chinese == ChineseSubtitleState.unknown)) {
      throw EmbyViewFailure(
        context.availability.reason ?? '暂时无法确认此集的媒体时长和字幕。',
        retryable: true,
        code: 'subtitle_job_media_unknown',
      );
    }
    return context;
  }

  void setForegroundStrm(bool active) {
    if (_closed || _foregroundStrm == active) return;
    _foregroundStrm = active;
    SubtitleAudioReader.shared.setForegroundStrm(active);
    _publish();
    wake();
  }

  void wake() {
    if (_closed) return;
    if (_worker != null) {
      _wakeRequested = true;
      return;
    }
    _poll?.cancel();
    _worker = _drain()
        .then<void>(
          (_) {},
          onError: (Object _) {
            _changes.addError(const EmbyViewFailure('无法更新本机字幕队列。', retryable: true));
          },
        )
        .whenComplete(() {
          _worker = null;
          if (_wakeRequested) {
            _wakeRequested = false;
            wake();
          } else if (!_closed && _entries.any((season) => season.episodes.any((row) => row.pending))) {
            _poll = Timer(const Duration(seconds: 30), wake);
          }
        });
  }

  Future<void> _drain() async {
    while (!_closed) {
      var advanced = false;
      for (final season in _entries.toList()) {
        if (_closed) return;
        final episode = season.episodes.where((row) => row.pending).firstOrNull;
        if (episode != null && await _tryEpisode(season, episode)) {
          advanced = true;
          break;
        }
      }
      if (!advanced) return;
    }
  }

  Future<bool> _tryEpisode(_Season season, _Episode row) async {
    final key = '${season.id}:${row.ref.episodeId}';
    final SubtitleEpisodeContext context;
    try {
      context = await _authorized(season.accountId, row.ref);
    } catch (error) {
      final failure = _failure(error);
      await _update(row, () {
        if (failure.retryable) {
          row.waiting = failure.reason;
        } else {
          row.failure = failure;
        }
      });
      return !failure.retryable;
    }
    if (_closed || !row.pending) return false;
    if (context.availability.chinese == ChineseSubtitleState.complete) {
      if (row.started) await _ledger.completeEpisode(key);
      await _update(row, () => row.completeId = 'existing');
      return true;
    }
    final strm = isSubtitleStrm(context.source);
    if (strm && _foregroundStrm) {
      await _update(row, () => row.waiting = _foregroundWait);
      return false;
    }
    final (budget, reason) = await _ledger.episodeBudget();
    if (budget != BudgetState.available) {
      await _update(row, () => row.waiting = reason);
      return false;
    }
    await _update(row, () {
      row.started = true;
      row.waiting = null;
      row.stage = EpisodeJobState.reading;
    });
    if (_closed || !row.pending) return false;
    final cancellation = SubtitleAiCancellation();
    _active = row;
    _cancellation = cancellation;
    row.strm = strm;
    final run = SubtitleEpisodeRun._(cancellation, (state) {
      if (cancellation.isCancelled || !row.pending) return;
      row.stage = state;
      _publish();
    });
    try {
      final contentId = await _ledger.duringEpisode(
        key,
        () => _generate(context, run),
        checkAuthorization: context.checkAuthorization == null ? null : context.verifyAuthorization,
      );
      if (contentId.isEmpty) throw StateError('Episode generator returned no durable content ID');
      cancellation.check();
      await _ledger.completeEpisode(key);
      await _update(row, () => row.completeId = contentId);
    } catch (error) {
      if (cancellation.isCancelled) return true;
      final failure = _failure(error);
      final waiting = failure is SubtitleBudgetBlocked || failure is _EpisodeAuthorizationBlocked && failure.retryable;
      await _update(row, () {
        row.stage = EpisodeJobState.queued;
        if (waiting) {
          row.waiting = failure.reason;
        } else {
          row.failures++;
          if (row.failures >= 3 || !failure.retryable) row.failure = failure;
        }
      });
      return !waiting;
    } finally {
      _active = null;
      _cancellation = null;
    }
    return true;
  }

  Future<void> cancelJob(String jobId, {String? episodeId}) => _mutations.run(() async {
    _checkOpen();
    final season = _entries.where((entry) => entry.id == jobId).firstOrNull;
    if (season == null) return;
    final rows = season.episodes
        .where((row) => row.pending && (episodeId == null || row.ref.episodeId == episodeId))
        .toList();
    if (rows.isEmpty) return;
    for (final row in rows) {
      row.cancelled = true;
    }
    try {
      await _persist();
    } catch (_) {
      for (final row in rows) {
        row.cancelled = false;
      }
      rethrow;
    }
    if (rows.contains(_active)) _cancellation?.cancel();
    wake();
  });

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    _cancellation?.cancel();
    if (_foregroundStrm) SubtitleAudioReader.shared.setForegroundStrm(false);
    await _worker;
    await _mutations.run(() async {});
    await _changes.close();
  }

  Future<void> _update(_Episode row, void Function() change) => _mutations.run(() async {
    if (_closed || !row.pending) return;
    final old = row.toJson();
    final stage = row.stage;
    change();
    if (stage == row.stage && jsonEncode(old) == jsonEncode(row.toJson())) return;
    try {
      await _persist();
    } catch (_) {
      row.restore(old);
      row.stage = stage;
      rethrow;
    }
  });

  Future<void> _persist() async {
    await writeJobJson(_file, {'jobs': _entries.map((entry) => entry.toJson()).toList()});
    _publish();
  }

  void _publish() => _changes.add(_snapshot());
  List<SeasonJob> _snapshot() => List.unmodifiable(
    _entries.map((entry) {
      final rows = List<EpisodeJob>.unmodifiable(entry.episodes.map((row) => row.snapshot(_foregroundStrm)));
      return SeasonJob(
        id: entry.id,
        seriesId: entry.seriesId,
        seasonId: entry.seasonId,
        seasonName: entry.name,
        episodes: rows,
        total: rows.length,
        completedCount: rows.where((row) => row.state == EpisodeJobState.completed).length,
      );
    }),
  );

  void _checkOpen() {
    if (_closed) throw StateError('Subtitle season queue is closed');
  }
}

EmbyViewFailure _failure(Object error) => error is EmbyViewFailure
    ? error
    : const EmbyViewFailure('此集的字幕处理失败。', retryable: true, code: 'subtitle_job_failed');
const _foregroundWait = '等待前台 115 播放结束后读取。';

final class _Season {
  _Season(this.id, this.quoteId, this.accountId, this.seriesId, this.seasonId, this.name, this.episodes);

  factory _Season.fromJson(dynamic row) => _Season(
    row['id'] as String,
    row['quote'] as String,
    row['account'] as String,
    row['series'] as String,
    row['season'] as String,
    row['name'] as String,
    (row['episodes'] as List).map(_Episode.fromJson).toList(),
  );

  final String id, quoteId, accountId, seriesId, seasonId, name;
  final List<_Episode> episodes;

  Map<String, dynamic> toJson() => {
    'id': id,
    'quote': quoteId,
    'account': accountId,
    'series': seriesId,
    'season': seasonId,
    'name': name,
    'episodes': episodes.map((row) => row.toJson()).toList(),
  };
}

final class _Episode {
  _Episode(this.ref, {this.completeId});

  factory _Episode.fromJson(dynamic row) => _Episode(
    SubtitleEpisodeRequest(
      episodeId: row['id'] as String,
      name: row['name'] as String,
      episodeNumber: row['number'] as int?,
      mediaSourceId: row['source'] as String,
      authorizationId: row['authorization'] as String,
    ),
  )..restore(row as Map<String, dynamic>);

  final SubtitleEpisodeRequest ref;
  int failures = 0;
  bool cancelled = false, started = false, strm = false;
  String? completeId, waiting;
  EmbyViewFailure? failure;
  EpisodeJobState stage = EpisodeJobState.queued;
  bool get pending => !cancelled && completeId == null && failure == null;

  EpisodeJob snapshot(bool foregroundStrm) {
    final yielding = foregroundStrm && strm && stage == EpisodeJobState.reading;
    return EpisodeJob(
      episodeId: ref.episodeId,
      name: ref.name,
      episodeNumber: ref.episodeNumber,
      state: switch ((cancelled, completeId, failure, yielding)) {
        (true, _, _, _) => EpisodeJobState.cancelled,
        (_, String(), _, _) => EpisodeJobState.completed,
        (_, _, EmbyViewFailure(), _) => EpisodeJobState.failed,
        (_, _, _, true) => EpisodeJobState.queued,
        _ => stage,
      },
      waitingReason: pending ? (yielding ? _foregroundWait : waiting) : null,
      failure: failure,
    );
  }

  void restore(Map<String, dynamic> row) {
    failures = row['failures'] as int;
    cancelled = row['cancelled'] as bool;
    started = row['started'] as bool;
    completeId = row['complete'] as String?;
    waiting = row['waiting'] as String?;
    final reason = row['failure'] as String?;
    failure = reason == null
        ? null
        : EmbyViewFailure(reason, code: row['failureCode'] as String?, retryable: row['retryable'] == true);
  }

  Map<String, dynamic> toJson() => {
    'id': ref.episodeId,
    'name': ref.name,
    'number': ref.episodeNumber,
    'source': ref.mediaSourceId,
    'authorization': ref.authorizationId,
    'failures': failures,
    'cancelled': cancelled,
    'started': started,
    'complete': completeId,
    'waiting': waiting,
    'failure': failure?.reason,
    'failureCode': failure?.code,
    'retryable': failure?.retryable,
  };
}

List<TimeRange> missingSubtitleCoverage(Duration duration, Iterable<TimeRange> coverage) {
  final gaps = <TimeRange>[];
  var cursor = Duration.zero;
  for (final span in mergeSubtitleAiCoverage(coverage)) {
    final end = span.start < duration ? span.start : duration;
    if (end > cursor) gaps.add(TimeRange(start: cursor, end: end));
    if (span.end > cursor) cursor = span.end;
    if (cursor >= duration) break;
  }
  if (cursor < duration) gaps.add(TimeRange(start: cursor, end: duration));
  return gaps;
}
