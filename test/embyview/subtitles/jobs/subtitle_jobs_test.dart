import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/contracts/subtitles.dart';
import 'package:moonfin/embyview/playback/playback_subtitle_input.dart';
import 'package:moonfin/embyview/subtitles/ai/subtitle_ai_types.dart';
import 'package:moonfin/embyview/subtitles/jobs/subtitle_jobs.dart';
import 'package:moonfin/embyview/subtitles/store/subtitle_store.dart';

void main() {
  late Directory scratch, nas;
  late bool mounted, credentials;
  late int limit;
  SubtitleUsageLedger ledger([String machine = 'mac-pro']) => SubtitleUsageLedger(
    localDirectory: Directory('${scratch.path}/$machine'),
    sharedRoot: () => mounted ? nas : null,
    machineName: machine,
    budgetMicros: () => limit,
    credentialsAvailable: () => credentials,
  );
  setUp(() async {
    scratch = await Directory('test/embyview/subtitles/jobs').createTemp('.check-');
    nas = await Directory('${scratch.path}/share').create();
    (mounted, credentials, limit) = (true, true, 10);
  });
  tearDown(() async => scratch.delete(recursive: true));

  test('merges two machines and keeps paid calls locally through an outage', () async {
    final a = ledger(), b = ledger('mac-air');
    Future<void> pay(SubtitleUsageLedger target, String id, int micros) =>
        target.charge(micros, () async => SubtitleAiCharge(value: null, costMicros: micros, requestId: id));
    await pay(a, 'same-request', 3);
    await pay(b, 'same-request', 3);
    await pay(b, 'other-request', 4);
    expect((await a.usage()).usedMicros, 7);
    await a.duringEpisode('episode', () async {
      await a.charge(4, () async {
        mounted = false;
        return const SubtitleAiCharge(value: null, costMicros: 4, requestId: 'episode-crossing');
      });
      expect((await a.episodeBudget()).$1, BudgetState.unknown);
      await expectLater(pay(a, 'blocked-offline', 1), throwsA(isA<SubtitleBudgetBlocked>()));
      await a.completeEpisode('episode');
    });
    expect((await a.usage()).state, AiUsageState.localOnly);
    mounted = true;
    final reopened = await ledger().usage();
    expect((reopened.usedMicros, reopened.completedEpisodes, reopened.averageEpisodeMicros), (11, 1, 4));
    expect((await b.episodeBudget()).$1, BudgetState.exceeded);
    await expectLater(pay(b, 'blocked', 1), throwsA(isA<EmbyViewFailure>()));
    credentials = false;
    expect((await a.episodeBudget()).$1, BudgetState.missingCredentials);
  });

  test('resumes through restart and budget pauses, retries twice, yields for strm and persists cancellation', () async {
    final usage = ledger();
    var authorization = 'original-mount';
    var segments = 0;
    final running = Completer<void>();
    var reopening = false;
    final attempts = <String>[];
    final store = SubtitleStore(
      folderStatus: () async => throw StateError('resolver supplies availability'),
      localDirectory: () async => scratch,
    );
    Future<SubtitleSeasonQueue> open() => SubtitleSeasonQueue.open(
      localDirectory: scratch,
      ledger: usage,
      resolve: (account, episode) async {
        expect(account, 'original-account');
        final id = episode.episodeId;
        return SubtitleEpisodeContext(
          source: PlaybackSubtitleSource(
            generation: 1,
            target: PlayTarget(itemId: id),
            mediaSourceId: 'source-$id',
            address: Uri.parse('https://test.invalid/$id'),
            headers: const {},
            userAgent: 'test',
            itemFilePath: id == '4' ? '/video.strm' : '/video.mkv',
          ),
          store: store,
          duration: const Duration(minutes: 1),
          authorizationId: authorization,
          availability: switch (id) {
            '1' => const SubtitleAvailability(chinese: ChineseSubtitleState.complete),
            '2' => const SubtitleAvailability(
              chinese: ChineseSubtitleState.partial,
              coverage: [TimeRange(start: Duration.zero, end: Duration(seconds: 30))],
            ),
            _ => const SubtitleAvailability(chinese: ChineseSubtitleState.canGenerate),
          },
        );
      },
      generate: (context, run) async {
        final id = context.source.target.itemId;
        attempts.add(id);
        if (!reopening) {
          running.complete();
          await run.cancellation.cancelled;
          run.cancellation.check();
        }
        while (id == '2' && segments < 2) {
          await usage.charge(
            11,
            () async => SubtitleAiCharge(value: null, costMicros: 11, requestId: 'segment-${segments++}'),
          );
        }
        if (id == '3') throw const EmbyViewFailure('temporary', retryable: true);
        return 'reopened-$id';
      },
    );
    var queue = await open();
    final request = SubtitleSeasonRequest(
      accountId: 'original-account',
      seriesId: 'series',
      seasonId: 'season',
      seasonName: 'Season',
      episodes: [
        for (final number in [4, 1, 3, 2])
          SubtitleEpisodeRequest(episodeId: '$number', name: 'Episode $number', episodeNumber: number),
      ],
    );
    final quote = await queue.quoteSeason(request);
    expect((quote.completedCount, quote.pendingCount, quote.estimatedCostMicros), (1, 3, 20000));
    final id = await queue.queueSeason(request, quote);
    await running.future;
    await queue.close();
    (reopening, authorization) = (true, 'different-mount');
    queue = await open();
    queue.setForegroundStrm(true);
    await queue.jobs.firstWhere((rows) => rows.single.episodes[1].waitingReason != null);
    expect(attempts, ['2']);
    authorization = 'original-mount';
    queue.wake();
    final paused = await queue.jobs.firstWhere((rows) => rows.single.episodes[1].waitingReason?.contains('预算') == true);
    expect((segments, (await usage.usage()).usedMicros, paused.single.completedCount), (1, 11, 1));
    limit = 30;
    queue.wake();
    final jobs = await queue.jobs.firstWhere((rows) => rows.single.episodes.last.waitingReason != null);
    expect(jobs.single.completedCount, 2);
    expect(jobs.single.episodes[2].state, EpisodeJobState.failed);
    expect((segments, (await usage.usage()).usedMicros), (2, 22));
    expect(attempts, ['2', '2', '2', '3', '3', '3']);
    await queue.cancelJob(id, episodeId: '4');
    await queue.close();
    queue = await open();
    expect((await queue.jobs.first).single.episodes.last.state, EpisodeJobState.cancelled);
    await queue.close();
  });
}
