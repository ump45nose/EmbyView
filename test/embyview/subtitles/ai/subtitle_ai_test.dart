import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/contracts/subtitles.dart';
import 'package:moonfin/embyview/subtitles/ai/subtitle_ai.dart';
import 'package:moonfin/embyview/subtitles/audio/subtitle_audio.dart';
import 'package:moonfin/embyview/subtitles/model/subtitle_document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const asr = MethodChannel('embyview/asr');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(
    () => messenger.setMockMethodCallHandler(
      asr,
      (call) async => switch (call.method) {
        'transcribe' => _transcript('new'),
        'modelStatus' => {'state': 'ready', 'receivedBytes': 1, 'totalBytes': 1},
        _ => null,
      },
    ),
  );
  tearDown(() => messenger.setMockMethodCallHandler(asr, null));

  test('sends raw PCM only to local ASR and translates just the text at the configured gateway', () async {
    final charges = <(String?, int)>[];
    final audio = _audio(24, length: 2);
    messenger.setMockMethodCallHandler(asr, (call) async {
      expect(call.method, 'transcribe');
      final args = call.arguments as Map;
      expect(args.keys, unorderedEquals(['pcm', 'sampleRate', 'requestId']));
      expect(args['sampleRate'], 48000);
      expect(args['pcm'], audio.pcm);
      expect(args['requestId'], isNotEmpty);
      return {
        'language': 'ja',
        'segments': [
          {'startUs': 125000, 'endUs': 2300000, 'text': 'こんにちは'},
        ],
      };
    });
    final ai = _processor(
      (request) async {
        expect(request.url.toString(), 'https://gateway.example/compatible/v1/chat/completions');
        expect(request.headers['authorization'], 'Bearer test-openAi');
        final body = jsonDecode(request.body) as Map;
        expect(body['model'], 'gpt-5.4-mini');
        expect(body, isNot(contains('store')));
        final instructions = body['messages'][0]['content'] as String;
        expect(instructions, contains('北斗神拳'));
        expect(instructions, contains('S01E02'));
        expect(instructions, contains('同音'));
        expect(body['messages'][1]['content'], contains('こんにちは'));
        return _openAiTranslation([
          {'id': 0, 'text': '你好'},
        ], id: 'gateway-one');
      },
      preferences: const LocalPreferences(translationBaseUrl: 'https://gateway.example/compatible/v1/'),
      charges: charges,
    );
    final result = await ai.process(
      audio,
      cancellation: SubtitleAiCancellation(),
      mediaContext: subtitleTranslationContext({
        'SeriesName': '北斗神拳',
        'Name': '第二集',
        'ParentIndexNumber': 1,
        'IndexNumber': 2,
      }),
    );
    final cue = result.cues.single;
    expect(cue.start, const Duration(milliseconds: 24125));
    expect(cue.end, const Duration(seconds: 26));
    expect((cue.text, cue.translation, result.language), ('こんにちは', '你好', 'ja'));
    expect(charges, [('gateway-one', 0)]);
  });

  test('checks the translation key before local ASR and explains each unready model state', () async {
    final ai = _processor((_) => throw StateError('unexpected HTTP'), key: null);
    await expectLater(
      ai.checkGeneration(),
      throwsA(isA<EmbyViewFailure>().having((e) => e.reason, 'reason', contains('翻译密钥'))),
    );
    final configured = _processor((_) => throw StateError('unexpected HTTP'));
    for (final (state, reason) in [('notDownloaded', '设置'), ('downloading', '下载'), ('failed', '校验')]) {
      messenger.setMockMethodCallHandler(
        asr,
        (_) async => {'state': state, 'receivedBytes': 30, 'totalBytes': 60, if (state == 'failed') 'error': '校验失败'},
      );
      await expectLater(
        configured.checkGeneration(),
        throwsA(isA<EmbyViewFailure>().having((e) => e.reason, 'reason', contains(reason))),
      );
    }
  });

  test('only known model prices at the official OpenAI endpoint contribute to quotes', () {
    const defaults = LocalPreferences();
    const episode = Duration(minutes: 24);
    expect(estimateSubtitleTranslationMicros(defaults, episode), 52200);
    for (final prefs in [
      const LocalPreferences(translationModel: 'unknown'),
      const LocalPreferences(translationBaseUrl: 'https://api.openai.com.example/v1'),
      const LocalPreferences(translationBaseUrl: 'http://api.openai.com/v1'),
      const LocalPreferences(translationBaseUrl: 'https://api.openai.com:444/v1'),
      const LocalPreferences(translationBaseUrl: 'https://api.openai.com/proxy'),
    ]) {
      expect(isSubtitleTranslationMetered(prefs), isFalse);
      expect(estimateSubtitleTranslationMicros(prefs, episode), 0);
    }
  });

  test('cancelling local ASR sends the matching request ID before translation', () async {
    final active = Completer<String>(), cancelled = Completer<String>();
    final response = Completer<Object?>();
    messenger.setMockMethodCallHandler(asr, (call) async {
      final id = (call.arguments as Map)['requestId'] as String;
      if (call.method == 'transcribe') {
        active.complete(id);
        return response.future;
      }
      expect(call.method, 'cancelTranscription');
      cancelled.complete(id);
      return null;
    });
    final token = SubtitleAiCancellation();
    final task = _processor((_) => throw StateError('unexpected HTTP')).process(_audio(1), cancellation: token);
    final expected = expectLater(task, throwsA(isA<SubtitleAiCancelled>()));
    final id = await active.future;
    token.cancel();
    expect(await cancelled.future, id);
    response.complete(_transcript('late'));
    await expected;
  });

  test('a settings change during key lookup cannot redirect that credential', () async {
    const official = LocalPreferences();
    const gateway = LocalPreferences(translationBaseUrl: 'https://gateway.example/v1');
    var current = official;
    final started = Completer<void>(), resume = Completer<void>();
    final calls = <(String, String?)>[];
    final ai = SubtitleAiProcessor(
      preferences: () => current,
      readTranslationKey: (base) async {
        if (!started.isCompleted) {
          started.complete();
          await resume.future;
        }
        return base.host;
      },
      meter: <T>(_, invoke) async => (await invoke()).value,
      clientFactory: () => MockClient((request) async {
        calls.add((request.url.host, request.headers['Authorization']));
        return _openAiTranslation([
          {'id': 0, 'text': '你好'},
        ]);
      }),
    );
    final first = ai.process(_audio(0), cancellation: SubtitleAiCancellation());
    await started.future;
    current = gateway;
    resume.complete();
    await first;
    await ai.process(_audio(1), cancellation: SubtitleAiCancellation());
    current = official;
    await ai.process(_audio(2), cancellation: SubtitleAiCancellation());
    expect(calls, [
      ('api.openai.com', 'Bearer api.openai.com'),
      ('gateway.example', 'Bearer gateway.example'),
      ('api.openai.com', 'Bearer api.openai.com'),
    ]);
  });

  test('translation uses the current provider, and IDs restore original line order', () async {
    final charges = <(String?, int)>[];
    final ai = _processor((request) async {
      expect(request.url.path, '/v1/chat/completions');
      final json = jsonDecode(request.body) as Map;
      expect(json['model'], 'gpt-5.4-mini');
      expect(json.containsKey('store'), false);
      return _openAiTranslation([
        {'id': 1, 'text': '再见'},
        {'id': 0, 'text': '你好'},
      ], id: 'two-lines');
    }, charges: charges);
    final source = _srt([2, 5]);
    final output = await ai.translate(source, cancellation: SubtitleAiCancellation());
    expect(output.cues!.map((cue) => (cue.start, cue.end)), source.cues!.map((cue) => (cue.start, cue.end)));
    expect(output.cues!.map((cue) => cue.text), ['你好', '再见']);
    expect(charges, [('two-lines', 59)]);
  });

  test('charges a completed call even when duplicate IDs make its result unusable', () async {
    final charges = <(String?, int)>[];
    final ai = _processor(
      (_) async => _openAiTranslation([
        {'id': 0, 'text': '你好'},
        {'id': 0, 'text': '再见'},
      ], id: 'invalid-lines'),
      charges: charges,
    );
    await expectLater(
      ai.translate(_srt([2, 5]), cancellation: SubtitleAiCancellation()),
      throwsA(isA<EmbyViewFailure>().having((error) => error.code, 'code', 'subtitle_ai_response')),
    );
    expect(charges, [('invalid-lines', 59)]);
  });

  test('seek invalidates a pending result and keeps its late charge', () async {
    final firstRequest = Completer<void>();
    final oldResponse = Completer<http.Response>();
    final charges = <(String?, int)>[];
    var requests = 0;
    final ai = _processor((request) async {
      if (requests++ == 0) {
        firstRequest.complete();
        return oldResponse.future;
      }
      return _openAiTranslation([
        {'id': 0, 'text': '新台词'},
      ]);
    }, charges: charges);
    final controller = SubtitleAiRunController(ai);
    addTearDown(controller.close);
    final old = controller.start(
      generation: 3,
      timelineGeneration: 412,
      position: const Duration(seconds: 5),
      audio: Stream.value(_audio(5, timeline: 11)),
      followsPlayhead: true,
      isCurrent: () => true,
    );
    await firstRequest.future;
    expect(controller.run!.state, AiRunState.catchingUp);
    controller.updatePosition(const Duration(seconds: 50), timelineGeneration: 413);
    expect(controller.run, isNull);

    final current = await controller.start(
      generation: 3,
      timelineGeneration: 413,
      position: const Duration(seconds: 50),
      audio: Stream.fromIterable([_audio(50, timeline: 218), _audio(53, timeline: 219)]),
      followsPlayhead: false,
      isCurrent: () => true,
    );
    expect(controller.run!.state, AiRunState.completed);
    expect(current!.cues.map((cue) => cue.start.inSeconds), [50, 53]);
    expect(
      current.original.cues!.map((cue) => (cue.id, cue.start, cue.end)),
      current.chinese.cues!.map((cue) => (cue.id, cue.start, cue.end)),
    );
    controller.updatePosition(const Duration(seconds: 52));
    expect(controller.run!.coverageEnd, isNull);
    controller.updatePosition(const Duration(seconds: 53));
    expect(controller.run!.coverageEnd, const Duration(seconds: 54));

    oldResponse.complete(
      _openAiTranslation([
        {'id': 0, 'text': '旧台词'},
      ], id: 'completed-late'),
    );
    expect(await old, isNull);
    expect(charges, contains(('completed-late', 59)));
    expect(controller.run!.cues.map((cue) => cue.text), ['new', 'new']);
  });

  test('tap changes its native timeline without reattaching old cues', () async {
    final firstRequest = Completer<void>();
    final oldResponse = Completer<http.Response>();
    final controller = SubtitleAiRunController(
      _processor((_) {
        firstRequest.complete();
        return oldResponse.future;
      }),
    );
    addTearDown(controller.close);
    final audio = StreamController<SubtitleAudioSegment>();
    final task = controller.start(
      generation: 3,
      timelineGeneration: 990,
      position: const Duration(seconds: 5),
      audio: audio.stream,
      followsPlayhead: true,
      isCurrent: () => true,
    );
    audio.add(_audio(5, timeline: 7));
    await firstRequest.future;
    final cleared = controller.changes.firstWhere((run) => run == null);
    audio.add(_audio(50, timeline: 8));
    await cleared;
    oldResponse.complete(
      _openAiTranslation([
        {'id': 0, 'text': '旧台词'},
      ]),
    );
    expect(await task, isNull);
    await audio.close();
    expect(controller.run, isNull);
  });

  test('cancellation clears the foreground run and releases waiting audio', () async {
    final controller = SubtitleAiRunController(_processor((_) async => throw StateError('Unexpected API call')));
    final released = Completer<void>();
    final listening = Completer<void>();
    final audio = StreamController<SubtitleAudioSegment>(onListen: listening.complete, onCancel: released.complete);
    final task = controller.start(
      generation: 3,
      timelineGeneration: 8,
      position: const Duration(seconds: 5),
      audio: audio.stream,
      followsPlayhead: true,
      isCurrent: () => true,
    );
    await listening.future;
    expect(controller.cancel(), isNull);
    expect(await task, isNull);
    expect(controller.run!.state, AiRunState.cancelled);
    await released.future;
    await audio.close();
    await controller.close();
  });

  test('live first window translates before the next arrives and later windows share requests', () async {
    final audio = StreamController<SubtitleAudioSegment>();
    final sizes = <int>[];
    final first = Completer<void>();
    final controller = SubtitleAiRunController(
      _processor((request) async {
        final lines = _lines(request);
        sizes.add(lines.length);
        if (!first.isCompleted) first.complete();
        return _openAiTranslation(lines);
      }),
    );
    addTearDown(controller.close);
    final result = controller.start(
      generation: 3,
      timelineGeneration: 1,
      position: Duration.zero,
      audio: audio.stream,
      followsPlayhead: false,
      isCurrent: () => true,
    );
    audio.add(_audio(0));
    await first.future;
    for (var i = 1; i < 6; i++) {
      audio.add(_audio(i));
    }
    await audio.close();
    expect((await result)!.cues.map((c) => c.start.inSeconds), [0, 1, 2, 3, 4, 5]);
    expect(sizes.first, 1);
    expect(sizes.skip(1).where((v) => v >= 2 && v <= 3).length, greaterThanOrEqualTo(2));
  });

  test('episode ASR overlaps three translations, preserving timelines on out-of-order completion', () async {
    final releases = List.generate(4, (_) => Completer<void>());
    final third = Completer<void>();
    var transcribed = 0, active = 0, peak = 0;
    final sizes = <int>[];
    messenger.setMockMethodCallHandler(asr, (_) async {
      transcribed++;
      return {
        'language': 'ja',
        'segments': [
          for (var i = 0; i < 20; i++) {'startUs': i * 40000, 'endUs': (i + 1) * 40000, 'text': 'line'},
        ],
      };
    });
    final controller = SubtitleAiRunController(
      _processor((request) async {
        final lines = _lines(request);
        final id = sizes.length;
        sizes.add(lines.length);
        peak = math.max(peak, ++active);
        if (id == 2) third.complete();
        await releases[id].future;
        active--;
        return _openAiTranslation(lines.reversed.toList());
      }),
    );
    addTearDown(controller.close);
    final pending = controller.start(
      generation: 3,
      timelineGeneration: 1,
      position: Duration.zero,
      audio: Stream.fromIterable(List.generate(12, (i) => _audio(i))),
      followsPlayhead: false,
      realtime: false,
      isCurrent: () => true,
    );
    await third.future;
    expect(transcribed, greaterThanOrEqualTo(9));
    for (final release in releases.reversed) {
      release.complete();
    }
    final output = (await pending)!;
    expect(peak, 3);
    expect(sizes, [60, 60, 60, 60]);
    expect(output.coverage.single.end, const Duration(seconds: 12));
    expect(output.cues.length, 240);
    expect(
      output.cues.map((c) => c.start.inMicroseconds).toList(),
      orderedEquals([
        for (var w = 0; w < 12; w++)
          for (var i = 0; i < 20; i++) w * 1000000 + i * 40000,
      ]),
    );
  });

  for (final status in [429, 503, 408]) {
    test('HTTP $status attempts twice more with backoff and records no content or credentials', () async {
      final events = <Map<String, Object?>>[];
      final sub = subtitleAiTimings.listen((e) => events.add(e.toJson()));
      addTearDown(sub.cancel);
      final waits = <Duration>[];
      var requests = 0;
      final processor = SubtitleAiProcessor(
        readTranslationKey: (_) async => 'secret-sentinel',
        meter: <T>(_, invoke) async => (await invoke()).value,
        waitForRetry: (d) async => waits.add(d),
        clientFactory: () => MockClient((request) async {
          if (++requests <= 2) return http.Response('private upstream response', status);
          return _openAiTranslation(_lines(request));
        }),
      );
      expect(processor.requestTimeout, const Duration(seconds: 120));
      await processor.process(_audio(1), cancellation: SubtitleAiCancellation());
      await Future<void>.delayed(Duration.zero);
      expect(waits, [const Duration(seconds: 1), const Duration(seconds: 2)]);
      final translations = events.where((e) => e['stage'] == 'translation').toList();
      expect(translations.map((e) => e['httpStatus']), [status, status, 200]);
      expect(translations.map((e) => e['attempt']), [1, 2, 3]);
      expect(translations.map((e) => e['batch']).toSet().length, 1);
      expect(translations.last['windows'], [
        [1000000, 2000000],
      ]);
      expect(
        jsonEncode(events),
        isNot(anyOf(contains('secret-sentinel'), contains('private upstream'), contains('new'))),
      );
    });
  }
  test('cancelling during backoff releases the run without submitting another request', () async {
    final token = SubtitleAiCancellation();
    final sleeping = Completer<void>();
    final resume = Completer<void>();
    var requests = 0;
    final ai = SubtitleAiProcessor(
      readTranslationKey: (_) async => 'fixture',
      meter: <T>(_, invoke) async => (await invoke()).value,
      waitForRetry: (_) {
        sleeping.complete();
        return resume.future;
      },
      clientFactory: () => MockClient((_) async {
        requests++;
        return http.Response('', 503);
      }),
    );
    final task = ai.process(_audio(0), cancellation: token);
    final expected = expectLater(task, throwsA(isA<SubtitleAiCancelled>()));
    await sleeping.future;
    token.cancel();
    await expected;
    resume.complete();
    expect(requests, 1);
  });

  test('wall-clock timeout retries twice and a permanent bad request is sent just once', () async {
    for (final timeout in [true, false]) {
      var requests = 0;
      final processor = SubtitleAiProcessor(
        readTranslationKey: (_) async => 'key',
        meter: <T>(_, invoke) async => (await invoke()).value,
        requestTimeout: const Duration(milliseconds: 5),
        waitForRetry: (_) async {},
        clientFactory: () => MockClient((_) async {
          requests++;
          if (timeout) return Completer<http.Response>().future;
          return http.Response('', 400);
        }),
      );
      await expectLater(
        processor.process(_audio(1), cancellation: SubtitleAiCancellation()),
        throwsA(isA<EmbyViewFailure>()),
      );
      expect(requests, timeout ? 3 : 1);
    }
  });

  test('alignment fits shift and drift, keeps unmatched cues on the shift and preserves ASS', () async {
    const onsets = [2, 4, 9, 12, 19, 22, 28, 34];
    const header = '[Script Info]\nScriptType: v4.00+\n[V4+ Styles]\nStyle: Test,Arial,25\n[Events]\n';
    String at(int secs) => '0:00:${secs.toString().padLeft(2, '0')}.00';
    String row(int atSeconds) => 'Dialogue: 0,${at(atSeconds)},${at(atSeconds + 1)},Test,,,,,,{\\i1}Hi{\\i0}';
    final input = SubtitleDocument.parse(
      utf8.encode(
        [
          header.trimRight(),
          for (final seconds in [...onsets, 15]..sort()) row(seconds),
          'Comment: 0,0:00:01.00,0:00:02.00,Test,,,,,,unchanged',
        ].join('\n'),
      ),
      format: 'ass',
    );
    final speech = [for (final time in onsets) time * 1.022 + 1.7];
    final candidate = await alignSubtitle(
      input,
      Stream.fromIterable([_audio(0, length: 20, voicedAt: speech), _audio(20, length: 20, voicedAt: speech)]),
      cancellation: SubtitleAiCancellation(),
    );
    final output = utf8.decode(candidate.playbackBytes);
    expect(candidate.format, 'ass');
    expect(output, startsWith(header));
    expect(output, contains(r'Test,,,,,,{\i1}Hi{\i0}'));
    expect(output, contains('Comment: 0,0:00:01.00,0:00:02.00,Test,,,,,,unchanged'));
    expect(candidate.cues!.first.start.inMilliseconds, closeTo(speech.first * 1000, 90));
    expect(candidate.cues!.last.start.inMilliseconds, closeTo(speech.last * 1000, 90));
    expect(candidate.cues![4].start.inMilliseconds, closeTo(16700, 110));
  });

  test('insufficient audio preserves the track and cancellation releases the input', () async {
    final input = _srt([2, 7, 12, 17]);
    final result = await alignSubtitle(
      input,
      Stream.value(_audio(0, length: 2)),
      cancellation: SubtitleAiCancellation(),
    );
    expect(result, same(input));

    final cancelled = SubtitleAiCancellation();
    final listening = Completer<void>();
    final audio = StreamController<SubtitleAudioSegment>(onListen: listening.complete);
    final pending = alignSubtitle(input, audio.stream, cancellation: cancelled);
    await listening.future;
    cancelled.cancel();
    await expectLater(pending, throwsA(isA<SubtitleAiCancelled>()));
    await audio.close();
  });
}

SubtitleAiProcessor _processor(
  Future<http.Response> Function(http.Request) decide, {
  LocalPreferences preferences = const LocalPreferences(),
  String? key = 'test-openAi',
  List<(String?, int)>? charges,
}) {
  Future<T> meter<T>(int estimate, Future<SubtitleAiCharge<T>> Function() invoke) async {
    expect(estimate, greaterThanOrEqualTo(0));
    final result = await invoke();
    charges?.add((result.requestId, result.costMicros));
    return result.value;
  }

  return SubtitleAiProcessor(
    readTranslationKey: (_) async => key,
    preferences: () => preferences,
    meter: meter,
    clientFactory: () => MockClient(decide),
  );
}

SubtitleAudioSegment _audio(int start, {int length = 1, int timeline = 0, List<double> voicedAt = const []}) {
  const rate = 48000;
  final pcm = ByteData(rate * length * 4);
  for (final at in voicedAt) {
    final first = math.max(0, ((at - start) * rate).round());
    final end = math.min(length * rate, ((at - start + 0.55) * rate).round());
    for (var i = first; i < end; i++) {
      pcm.setFloat32(i * 4, math.sin(i * 1200 * math.pi / rate) * 0.25, Endian.little);
    }
  }
  return SubtitleAudioSegment(
    start: Duration(seconds: start),
    sourceStart: Duration(seconds: start + 10),
    pcm: pcm.buffer.asUint8List(),
    sourceGeneration: 3,
    timelineGeneration: timeline,
    discontinuity: true,
  );
}

SubtitleDocument _srt(List<int> times) => SubtitleDocument.srt([
  for (final (id, time) in times.indexed)
    SubtitleCue(
      id: '$id',
      start: Duration(seconds: time),
      end: Duration(seconds: time + 1),
      text: 'Line $id',
    ),
]);

Map<String, Object> _transcript(String text) => {
  'language': 'en',
  'segments': [
    {'startUs': 100000, 'endUs': 700000, 'text': text},
  ],
};

http.Response _openAiTranslation(List<Map<String, Object>> lines, {String? id}) => _json({
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {
        'content': jsonEncode({'lines': lines}),
      },
    },
  ],
  'usage': {'prompt_tokens': 30, 'completion_tokens': 8},
}, id: id);

http.Response _json(Object value, {String? id}) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8', 'x-request-id': ?id},
);

List<Map<String, Object>> _lines(http.Request request) {
  final body = jsonDecode(request.body) as Map;
  final lines = jsonDecode(body['messages'][1]['content'] as String) as List;
  return [
    for (final line in lines) {'id': line['id'] as int, 'text': '译文'},
  ];
}
