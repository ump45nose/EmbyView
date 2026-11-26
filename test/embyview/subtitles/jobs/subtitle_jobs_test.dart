import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/contracts/subtitles.dart';
import 'package:moonfin/embyview/playback/playback_subtitle_input.dart';
import 'package:moonfin/embyview/subtitles/ai/subtitle_ai_processor.dart';
import 'package:moonfin/embyview/subtitles/ai/subtitle_ai_types.dart';
import 'package:moonfin/embyview/subtitles/audio/subtitle_audio.dart';
import 'package:moonfin/embyview/subtitles/jobs/subtitle_jobs.dart';
import 'package:moonfin/embyview/subtitles/store/subtitle_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch, nas;
  late bool mounted, credentials;
  late int limit;
  SubtitleUsageLedger ledger([String machine = 'mac-pro']) => SubtitleUsageLedger(
    localDirectory: Directory('${scratch.path}/$machine'),
    sharedRoot: () => mounted ? nas : null,
    machineName: machine,
    budgetMicros: () => limit,
    checkGeneration: () async {
      if (!credentials) throw const EmbyViewFailure('请配置翻译密钥。', code: 'subtitle_ai_credentials');
    },
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

  test('unmetered calls survive merging with legacy records and cost no budget', () async {
    final a = ledger();
    await a.charge(5, () async => const SubtitleAiCharge(value: null, costMicros: 5, requestId: 'old'));
    limit = 0;
    mounted = false;
    await a.charge(
      0,
      () async => const SubtitleAiCharge(value: null, costMicros: 0, requestId: 'custom', unmetered: true),
    );
    expect((await a.usage()).unmeteredCalls, 1);
    mounted = true;
    final refreshed = await a.usage();
    final shared = Directory('${nas.path}/.embyview/usage/${refreshed.month}');
    final localRecord = jsonDecode(await File('${shared.path}/mac-pro.json').readAsString()) as Map;
    expect(localRecord.containsKey('unmetered'), isFalse);
    await File('${shared.path}/old-version.json').writeAsString(
      jsonEncode({
        'calls': {
          'unmetered:custom': [0, null],
        },
        'completed': [],
        'unmetered': ['unmetered:custom'],
      }),
    );
    final other = await ledger('mac-air').usage();
    expect([refreshed.usedMicros, refreshed.unmeteredCalls, other.usedMicros, other.unmeteredCalls], [5, 1, 5, 1]);
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
    expect((quote.completedCount, quote.pendingCount, quote.estimatedCostMicros), (1, 3, 5438));
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

  test('a zero quote pauses on a price increase mid-episode and after restart until confirmed', () async {
    var prefs = const LocalPreferences(translationBaseUrl: 'https://gateway.example/v1');
    final first = Completer<void>(), resume = Completer<void>();
    var windows = 0;
    final usage = ledger();
    Future<SubtitleSeasonQueue> open() => SubtitleSeasonQueue.open(
      localDirectory: scratch,
      ledger: usage,
      preferences: () => prefs,
      resolve: (_, ep) async => SubtitleEpisodeContext(
        source: PlaybackSubtitleSource(
          generation: 1,
          target: PlayTarget(itemId: ep.episodeId),
          mediaSourceId: 's',
          address: Uri.https('movie.example', '/m'),
          headers: const {},
          userAgent: 'test',
        ),
        store: SubtitleStore(folderStatus: () async => throw UnimplementedError(), localDirectory: () async => scratch),
        duration: const Duration(minutes: 1),
        availability: const SubtitleAvailability(chinese: ChineseSubtitleState.canGenerate),
        authorizationId: 'root',
      ),
      generate: (_, run) async {
        if (!first.isCompleted) {
          expect(run.translationPreferences().translationBaseUrl, prefs.translationBaseUrl);
          windows++;
          first.complete();
          await resume.future;
        }
        run.translationPreferences();
        windows++;
        return 'saved';
      },
    );
    final request = SubtitleSeasonRequest(
      accountId: 'account',
      seriesId: 'series',
      seasonId: 'season',
      seasonName: 'Season',
      episodes: const [SubtitleEpisodeRequest(episodeId: '1', name: 'Episode')],
    );
    var queue = await open();
    final free = await queue.quoteSeason(request);
    expect(free.estimatedCostMicros, 0);
    final id = await queue.queueSeason(request, free);
    await first.future;
    prefs = const LocalPreferences();
    resume.complete();
    Future<void> waiting() =>
        queue.jobs.firstWhere((rows) => rows.firstOrNull?.episodes.single.waitingReason?.contains('重新估价') == true);
    await waiting();
    expect(windows, 1);
    await queue.close();
    queue = await open();
    await waiting();
    expect(windows, 1);
    await expectLater(queue.queueSeason(request, free), throwsA(isA<EmbyViewFailure>()));
    final paid = await queue.quoteSeason(request);
    expect(paid.estimatedCostMicros, greaterThan(0));
    expect(await queue.queueSeason(request, paid), id);
    await queue.jobs.firstWhere((rows) => rows.single.completedCount == 1);
    expect(windows, 2);
    await queue.close();
  });

  for (final buffered in [false, true]) {
    test(
      'revoked authorization blocks ${buffered ? 'buffered subtitle translation' : 'the next native window'}',
      () async {
        limit = 1000;
        final usage = ledger();
        final mediaFile = await File('${nas.path}/Episode.mkv').create();
        final store = SubtitleStore(
          folderStatus: () async => MediaFolderStatus(state: MediaFolderState.authorized, localRoot: nas.path),
          localDirectory: () async => scratch,
        );
        const channel = MethodChannel('test/season-authorization');
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final windows = <int>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          final start = (call.arguments as Map)['startUs'] as int;
          windows.add(start);
          return [
            for (final offset in [0, if (buffered) 100000])
              {'startUs': start + offset, 'sourceUs': start + offset, 'pcm': Uint8List(4800 * 4)},
          ];
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        const asr = MethodChannel('embyview/asr');
        messenger.setMockMethodCallHandler(
          asr,
          (_) async => {
            'language': 'ja',
            'segments': [
              {'startUs': 0, 'endUs': 50000, 'text': '元の台詞'},
            ],
          },
        );
        addTearDown(() => messenger.setMockMethodCallHandler(asr, null));
        var revoked = false;
        var paidRequests = 0;
        final generator = SubtitleSeasonGenerator(
          reader: SubtitleAudioReader(channel: channel),
          processor: SubtitleAiProcessor(
            readTranslationKey: (_) async => 'fixture',
            meter: usage.charge,
            clientFactory: () => MockClient((_) async {
              paidRequests++;
              revoked = true;
              return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'finish_reason': 'stop',
                      'message': {
                        'content': jsonEncode({
                          'lines': [
                            {'id': 0, 'text': '你好'},
                          ],
                        }),
                      },
                    },
                  ],
                  'usage': {'prompt_tokens': 4, 'completion_tokens': 2},
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
          ),
        );
        final queue = await SubtitleSeasonQueue.open(
          localDirectory: scratch,
          ledger: usage,
          resolve: (_, _) async => SubtitleEpisodeContext(
            source: PlaybackSubtitleSource(
              generation: 1,
              target: const PlayTarget(itemId: '1'),
              mediaSourceId: 'source-1',
              address: mediaFile.uri,
              headers: const {},
              userAgent: 'test',
              itemFilePath: '/mnt/media/Episode.mkv',
            ),
            store: store,
            duration: const Duration(minutes: 1),
            authorizationId: 'original-root',
            availability: const SubtitleAvailability(chinese: ChineseSubtitleState.canGenerate),
            checkAuthorization: () async {
              if (revoked) throw const EmbyViewFailure('revoked', retryable: true);
            },
          ),
          generate: generator.generate,
        );
        addTearDown(queue.close);
        final request = SubtitleSeasonRequest(
          accountId: 'account',
          seriesId: 'series',
          seasonId: 'season',
          seasonName: 'Season',
          episodes: const [SubtitleEpisodeRequest(episodeId: '1', name: 'Episode')],
        );
        await queue.queueSeason(request, await queue.quoteSeason(request));
        final paused = await queue.jobs.firstWhere(
          (jobs) => jobs.firstOrNull?.episodes.single.waitingReason == 'revoked',
        );
        expect(paused.single.episodes.single.state, EpisodeJobState.queued);
        expect(windows, [0]);
        expect((paidRequests, (await usage.usage()).usedMicros), (1, 12));
      },
    );
  }
}
