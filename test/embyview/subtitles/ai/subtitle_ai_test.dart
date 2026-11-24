import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

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
  test('writes PCM WAV, offsets Whisper times and meters Gemini separately', () async {
    final charges = <(String?, int)>[];
    final ai = _processor((request) async {
      if (request.url.host == 'api.openai.com') {
        expect(request.url.path, '/v1/audio/transcriptions');
        expect(request.headers['authorization'], 'Bearer test-openAi');
        final body = utf8.decode(request.bodyBytes, allowMalformed: true);
        expect(body, contains('name="timestamp_granularities[]"'));
        expect(body, contains('whisper-1'));
        expect(body, contains('RIFF'));
        return _json({
          'language': 'japanese',
          'segments': [
            {'start': 0.125, 'end': 2.3, 'text': 'こんにちは'},
          ],
        }, id: 'openai-one');
      }
      expect(request.url.path, '/v1beta/models/gemini-3.1-flash-lite:generateContent');
      expect(request.headers['x-goog-api-key'], 'test-gemini');
      expect(request.url.query, isEmpty);
      return _json({
        'responseId': 'gemini-one',
        'candidates': [
          {
            'finishReason': 'STOP',
            'content': {
              'parts': [
                {'thought': true, 'text': 'scratch work'},
                {'text': '{"lines":[{"id":0,"text":"你好"}]}'},
              ],
            },
          },
        ],
        'usageMetadata': {'promptTokenCount': 32, 'candidatesTokenCount': 4, 'thoughtsTokenCount': 2},
      });
    }, charges: charges);
    final result = await ai.process(_audio(24, length: 2), cancellation: SubtitleAiCancellation());
    final cue = result.cues.single;
    expect(cue.start, const Duration(milliseconds: 24125));
    expect(cue.end, const Duration(seconds: 26));
    expect(cue.text, 'こんにちは');
    expect(cue.translation, '你好');
    expect(result.language, 'ja');
    expect(charges, [('openai-one', 200), ('gemini-one', 17)]);
  });

  test('translation uses the current provider, and IDs restore original line order', () async {
    final charges = <(String?, int)>[];
    final ai = _processor(
      (request) async {
        expect(request.url.path, '/v1/chat/completions');
        final json = jsonDecode(request.body) as Map;
        expect(json['model'], 'gpt-6-luna');
        expect(json['store'], false);
        return _openAiTranslation([
          {'id': 1, 'text': '再见'},
          {'id': 0, 'text': '你好'},
        ], id: 'two-lines');
      },
      provider: TranslationProvider.openAi,
      charges: charges,
    );
    final source = _srt([2, 5]);
    final output = await ai.translate(source, cancellation: SubtitleAiCancellation());
    expect(output.cues!.map((cue) => (cue.start, cue.end)), source.cues!.map((cue) => (cue.start, cue.end)));
    expect(output.cues!.map((cue) => cue.text), ['你好', '再见']);
    expect(charges, [('two-lines', 7)]);
  });

  test('charges a completed call even when duplicate IDs make its result unusable', () async {
    final charges = <(String?, int)>[];
    final ai = _processor(
      (_) async => _openAiTranslation([
        {'id': 0, 'text': '你好'},
        {'id': 0, 'text': '再见'},
      ], id: 'invalid-lines'),
      provider: TranslationProvider.openAi,
      charges: charges,
    );
    await expectLater(
      ai.translate(_srt([2, 5]), cancellation: SubtitleAiCancellation()),
      throwsA(isA<EmbyViewFailure>().having((error) => error.code, 'code', 'subtitle_ai_response')),
    );
    expect(charges, [('invalid-lines', 7)]);
  });

  test('seek invalidates a pending result and keeps its late charge', () async {
    final firstRequest = Completer<void>();
    final oldResponse = Completer<http.Response>();
    final charges = <(String?, int)>[];
    var requests = 0;
    final ai = _processor(
      (request) async {
        if (request.url.path.endsWith('transcriptions')) {
          if (requests++ == 0) {
            firstRequest.complete();
            return oldResponse.future;
          }
          return _transcript('new');
        }
        return _openAiTranslation([
          {'id': 0, 'text': '新台词'},
        ]);
      },
      provider: TranslationProvider.openAi,
      charges: charges,
    );
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

    oldResponse.complete(_transcript('old', id: 'completed-late'));
    expect(await old, isNull);
    expect(charges, contains(('completed-late', 100)));
    expect(controller.run!.cues.map((cue) => cue.text), ['new', 'new']);
  });

  test('tap changes its native timeline without reattaching old cues', () async {
    final firstRequest = Completer<void>();
    final oldResponse = Completer<http.Response>();
    final controller = SubtitleAiRunController(
      _processor((_) {
        firstRequest.complete();
        return oldResponse.future;
      }, provider: TranslationProvider.openAi),
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
    oldResponse.complete(_transcript('old'));
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
  TranslationProvider provider = TranslationProvider.gemini,
  List<(String?, int)>? charges,
}) {
  Future<T> meter<T>(int estimate, Future<SubtitleAiCharge<T>> Function() invoke) async {
    expect(estimate, greaterThan(0));
    final result = await invoke();
    charges?.add((result.requestId, result.costMicros));
    return result.value;
  }

  return SubtitleAiProcessor(
    readSecret: (kind) async => 'test-${kind.name}',
    translationProvider: () => provider,
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

http.Response _transcript(String text, {String? id}) => _json({
  'language': 'english',
  'segments': [
    {'start': 0.1, 'end': 0.7, 'text': text},
  ],
}, id: id);

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
