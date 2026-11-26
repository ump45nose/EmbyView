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
import 'package:moonfin/embyview/subtitles/audio/subtitle_timing.dart';
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

  test('parallel calls reserve paid headroom and merge unmetered responses without lost updates', () async {
    final usage = ledger();
    final gate = Completer<void>(), entered = Completer<void>();
    Future<void> charge(int estimate, String id) => usage.charge(estimate, () async {
      if (id == 'first') {
        entered.complete();
        await gate.future;
      }
      return SubtitleAiCharge(value: null, costMicros: estimate, requestId: id, unmetered: estimate == 0);
    });
    final paid = charge(12, 'first');
    await entered.future;
    final blocked = expectLater(charge(1, 'no-headroom'), throwsA(isA<SubtitleBudgetBlocked>()));
    await Future.wait([for (var i = 0; i < 3; i++) charge(0, 'free-$i')]);
    gate.complete();
    await Future.wait([paid, blocked]);
    final snapshot = await usage.usage();
    expect((snapshot.usedMicros, snapshot.unmeteredCalls), (12, 3));
  });

  test('failed middle batch keeps later translations on NAS and restart reads only the gap', () async {
    final timings = <SubtitleAiTiming>[];
    final sub = subtitleAiTimings.listen(timings.add);
    addTearDown(sub.cancel);
    final usage = ledger();
    final media = await File('${nas.path}/Episode.mkv').create();
    final store = SubtitleStore(
      folderStatus: () async => MediaFolderStatus(state: MediaFolderState.authorized, localRoot: nas.path),
      localDirectory: () async => scratch,
    );
    final context = SubtitleEpisodeContext(
      source: PlaybackSubtitleSource(
        generation: 1,
        target: const PlayTarget(itemId: '1'),
        mediaSourceId: 'source-1',
        address: media.uri,
        headers: const {},
        userAgent: 'test',
        itemFilePath: '/mnt/media/Episode.mkv',
      ),
      store: store,
      duration: const Duration(seconds: 150),
      authorizationId: 'root',
      availability: const SubtitleAvailability(chinese: ChineseSubtitleState.canGenerate),
    );
    const channel = MethodChannel('test/season-resume'), asr = MethodChannel('embyview/asr');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final reads = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final start = (call.arguments as Map)['startUs'] as int;
      reads.add(start ~/ 1000000);
      return [
        {'startUs': start, 'sourceUs': start, 'pcm': Uint8List(30 * 48000 * 4)..first = start ~/ 1000000},
      ];
    });
    messenger.setMockMethodCallHandler(asr, (call) async {
      final start = ((call.arguments as Map)['pcm'] as Uint8List).first;
      return {
        'language': 'ja',
        'segments': [
          for (var i = 0; i < 30; i++) {'startUs': i * 1000000, 'endUs': (i + 1) * 1000000, 'text': 'w$start:$i'},
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(asr, null));
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var fail = true, failedAttempts = 0;
    const prefs = LocalPreferences(translationBaseUrl: 'https://gateway.example/v1');
    final generator = SubtitleSeasonGenerator(
      reader: SubtitleAudioReader(channel: channel),
      processor: SubtitleAiProcessor(
        readTranslationKey: (_) async => 'fixture',
        meter: usage.charge,
        preferences: () => prefs,
        waitForRetry: (_) async {},
        clientFactory: () => MockClient((request) async {
          final data = jsonDecode(request.body) as Map;
          final lines = jsonDecode(data['messages'][1]['content'] as String) as List;
          if (fail && lines.first['text'] == 'w60:0') {
            failedAttempts++;
            return http.Response('', 503);
          }
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {
                    'content': jsonEncode({
                      'lines': [
                        for (final row in lines) {'id': row['id'], 'text': '译${row['text']}'},
                      ],
                    }),
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    Future<SubtitleSeasonQueue> open() => SubtitleSeasonQueue.open(
      localDirectory: scratch,
      ledger: usage,
      preferences: () => prefs,
      resolve: (_, _) async => context,
      generate: generator.generate,
    );
    final request = SubtitleSeasonRequest(
      accountId: 'a',
      seriesId: 's',
      seasonId: '1',
      seasonName: 'Season',
      episodes: const [SubtitleEpisodeRequest(episodeId: '1', name: 'episode')],
    );
    var queue = await open();
    await queue.queueSeason(request, await queue.quoteSeason(request));
    await queue.jobs.firstWhere((jobs) => jobs.first.episodes.first.state == EpisodeJobState.failed);
    await queue.close();
    final partial = (await store.scan(context.media)).nasTracks.singleWhere((t) => t.language == 'zh');
    expect(partial.coverage!.map((v) => (v.start.inSeconds, v.end.inSeconds)), [(0, 60), (120, 150)]);
    expect(partial.document.cues!.length, 90);
    expect(failedAttempts, 3);
    for (final stage in ['read', 'asr']) {
      expect(timings.where((e) => e.stage == stage && e.status == 'ok').map((e) => e.windows.single.start.inSeconds), [
        0,
        30,
        60,
        90,
        120,
      ]);
    }
    expect(timings.where((e) => e.httpStatus == 503).map((e) => e.windows.map((w) => w.start.inSeconds).toList()), [
      [60, 90],
      [60, 90],
      [60, 90],
    ]);
    reads.clear();
    fail = false;
    queue = await open();
    await queue.queueSeason(request, await queue.quoteSeason(request));
    await queue.jobs.firstWhere((jobs) => jobs.last.completedCount == 1);
    await queue.close();
    expect(reads, [60, 90]);
    expect(
      (await store.scan(context.media)).nasTracks.singleWhere((t) => t.language == 'zh').document.cues!.length,
      150,
    );
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
        final sent = Completer<void>();
        var asrCount = 0;
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
        messenger.setMockMethodCallHandler(asr, (_) async {
          if (++asrCount > 1) await sent.future;
          return {
            'language': 'ja',
            'segments': [
              for (var i = 0; i < 60; i++) {'startUs': i * 1000, 'endUs': (i + 1) * 1000, 'text': '元の台詞'},
            ],
          };
        });
        addTearDown(() => messenger.setMockMethodCallHandler(asr, null));
        var revoked = false;
        var paidRequests = 0;
        final generator = SubtitleSeasonGenerator(
          reader: _NextReadAfterRequest(channel, sent.future),
          processor: SubtitleAiProcessor(
            readTranslationKey: (_) async => 'fixture',
            meter: usage.charge,
            clientFactory: () => MockClient((_) async {
              paidRequests++;
              revoked = true;
              sent.complete();
              return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'finish_reason': 'stop',
                      'message': {
                        'content': jsonEncode({
                          'lines': [
                            for (var i = 0; i < 60; i++) {'id': i, 'text': '你好'},
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

// Hold the second read at the normal admission boundary until the test server
// revokes authorization. Earlier reads may legitimately overlap translation.
class _NextReadAfterRequest extends SubtitleAudioReader {
  _NextReadAfterRequest(MethodChannel channel, this.sent) : super(channel: channel);
  final Future<void> sent;

  @override
  Future<List<SubtitleAudioSegment>> read(
    PlaybackSubtitleSource source, {
    required Duration start,
    required Duration end,
    int? streamIndex,
    bool background = false,
    SubtitleAudioCancellation? cancellation,
    Future<void> Function()? beforeRead,
  }) async {
    if (start > Duration.zero) await sent;
    return super.read(
      source,
      start: start,
      end: end,
      streamIndex: streamIndex,
      background: background,
      cancellation: cancellation,
      beforeRead: beforeRead,
    );
  }
}
