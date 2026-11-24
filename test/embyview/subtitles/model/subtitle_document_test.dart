import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/contracts/subtitles.dart';
import 'package:moonfin/embyview/subtitles/model/subtitle_document.dart';

const ass =
    '[V4+ Styles]\r\nStyle: Default,Arial,42,&H00FFFFFF,&H00000000\r\n[Events]\r\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n'
    'Dialogue: 0,0:00:08.25,0:00:09.50,Default,,0,0,0,,{\\i1}Later, with comma\r\n'
    'Dialogue: 0,0:00:02.03,0:00:03.50,Default,,0,0,0,,你好\\N世界\r\n'
    'Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,{\\p1}m 0 0 l 4 4\r\n';

void main() {
  test('ASS script and style stay intact while dialogue uses file timings', () {
    final input = utf8.encode('\uFEFF$ass');
    final document = SubtitleDocument.parse(input, format: 'ass');
    expect(document.playbackBytes, input);
    final cues = document.cues!;
    expect(cues.map((cue) => cue.text), ['你好\n世界', 'Later, with comma']);
    expect((cues.first.start.inMilliseconds, cues.first.end.inMilliseconds), (2030, 3500));

    final shifted = document.withTimings([
      SubtitleCue(
        id: cues.first.id,
        start: const Duration(seconds: 3),
        end: const Duration(seconds: 4),
        text: cues.first.text,
      ),
    ]);
    expect((shifted.cues!.first.id, shifted.cues!.first.start.inSeconds), (cues.first.id, 3));
    final expected = ass.replaceFirst('0:00:02.03,0:00:03.50', '0:00:03.00,0:00:04.00');
    expect(shifted.playbackBytes, utf8.encode('\uFEFF$expected'));
  });

  test('legacy ASS converts encoding only and preserves the original bytes', () {
    const header = '[Events]\nDialogue: 0,0:00:02.03,0:00:03.50,Default,,0,0,0,,';
    final input = [...ascii.encode(header), 0xb2, 0xe2, 0xca, 0xd4];
    final document = SubtitleDocument.parse(input, format: 'ass', encoding: 'GBK');
    expect(document.originalBytes, input);
    expect(utf8.decode(document.playbackBytes), '$header测试');
    expect(document.cues!.first.text, '测试');
  });

  test('UTF-16 SRT, WebVTT settings and graphic dialogue are distinct', () {
    const srt = '1\r\n00:00:07,402 --> 00:00:08,100\r\n<i>句子</i>\r\n';
    final utf16 = [
      0xff,
      0xfe,
      for (final unit in srt.codeUnits) ...[unit & 0xff, unit >> 8],
    ];
    final document = SubtitleDocument.parse(utf16, format: 'subrip');
    expect(utf8.decode(document.playbackBytes), srt);
    expect(document.cues!.single.text, '句子');
    expect(document.cues!.single.start, const Duration(milliseconds: 7402));
    const text =
        'WEBVTT\n\nNOTE ignored\n00:01.000 --> 00:02.000\nFake text\n\n'
        '00:07.402 --> 00:08.100 align:start\n真实对白\n';
    final vtt = SubtitleDocument.parse(utf8.encode(text), format: 'webvtt');
    expect(vtt.cues!.single.text, '真实对白');
    expect(vtt.cues!.single.start, document.cues!.single.start);
    expect(SubtitleDocument.parse([80, 71], format: 'pgs').cues, isNull);
    expect(SubtitleDocument.parse([], format: 'srt').cues, isEmpty);
  });
}
