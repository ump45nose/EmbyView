import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/playback/native_playback.dart';
import 'package:moonfin/embyview/playback/playback_subtitle_input.dart';
import 'package:moonfin/embyview/subtitles/audio/subtitle_audio.dart';

const _start = Duration(minutes: 1);
const _end = Duration(seconds: 80);

class _Tap extends NativePlaybackAudioInput {
  _Tap({this.available = true});

  final bool available;
  final input = StreamController<NativePcmPacket>();
  final _stopped = Completer<void>();
  bool get stopped => _stopped.isCompleted;
  Future<void> get released => _stopped.future;

  @override
  Stream<NativePcmPacket> get packets => input.stream;
  @override
  Future<bool> start({bool dialogue = true}) async => available;
  @override
  Future<void> stop() async => _stopped.complete();

  void packet(int milliseconds, {int generation = 7, int timeline = 1, bool gap = false}) {
    input.add(
      NativePcmPacket(
        sourceGeneration: generation,
        timelineGeneration: timeline,
        sourceTime: Duration(milliseconds: milliseconds + 1000),
        playbackTime: Duration(milliseconds: milliseconds),
        pcm: Uint8List(4800 * 4),
        discontinuity: gap,
        dialogue: false,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('manual seek is separate from PCM and tap stops covering old audio at a boundary', () async {
    const boundaryChannel = MethodChannel('embyview/audio_boundaries');
    messenger.setMockMethodCallHandler(boundaryChannel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(boundaryChannel, null));
    final boundaries = subtitleAudioBoundaries.take(3).toList();
    final tap = _Tap();
    final segments = playbackSubtitleAudio(
      tap,
      sourceGeneration: 7,
      start: const Duration(milliseconds: 50),
      segmentDuration: const Duration(seconds: 1),
    ).toList();

    for (final event in [
      {'kind': 'seek', 'sourceGeneration': 7, 'ready': false},
      {'kind': 'seek', 'sourceGeneration': 7, 'ready': true, 'positionUs': 1000000},
      {'kind': 'audioTrack', 'sourceGeneration': 7, 'ready': true, 'streamIndex': 3},
    ]) {
      final message = const StandardMethodCodec().encodeSuccessEnvelope(event);
      await messenger.handlePlatformMessage(boundaryChannel.name, message, (_) {});
    }
    final events = await boundaries;
    expect(events.map((event) => (event.kind, event.ready)), [
      (SubtitleAudioBoundaryKind.seek, false),
      (SubtitleAudioBoundaryKind.seek, true),
      (SubtitleAudioBoundaryKind.audioTrack, true),
    ]);
    expect(events.every((event) => event.sourceGeneration == 7), isTrue);
    expect(events[1].position, const Duration(seconds: 1));
    expect(events.last.streamIndex, 3);
    expect(tap.stopped, isFalse);

    tap.packet(0, generation: 6);
    tap.packet(0);
    tap.packet(100);
    tap.packet(500, gap: true);
    for (var ms = 1000; ms <= 2000; ms += 100) {
      tap.packet(ms, timeline: 2);
    }
    tap.packet(2100, generation: 8);
    final audio = await segments;
    await tap.input.close();
    expect(tap.stopped, isTrue);
    expect(audio.map((part) => (part.start.inMilliseconds, part.end.inMilliseconds, part.timelineGeneration)), [
      (50, 200, 1),
      (1000, 2000, 2),
    ]);
    expect(audio.map((part) => part.sourceStart.inMilliseconds), [1050, 2000]);
  });

  test('playback end flushes the tail and releases the tap while output is paused', () async {
    final tap = _Tap();
    final finish = Completer<void>();
    final done = Completer<void>();
    final segments = <SubtitleAudioSegment>[];
    final subscription = playbackSubtitleAudio(
      tap,
      sourceGeneration: 7,
      start: Duration.zero,
      finish: finish.future,
    ).listen(segments.add, onDone: done.complete);
    tap.packet(500);
    await Future<void>.delayed(Duration.zero);
    subscription.pause();
    finish.complete();
    await tap.released;
    expect(done.isCompleted, isFalse);
    subscription.resume();
    await done.future;
    expect(segments.single.start, const Duration(milliseconds: 500));
    expect(segments.single.end, const Duration(milliseconds: 600));
    await tap.input.close();
  });

  test('an unavailable tap reports the start failure without waiting for PCM', () async {
    final tap = _Tap(available: false);
    final stream = playbackSubtitleAudio(tap, sourceGeneration: 7, start: Duration.zero);
    await expectLater(
      stream,
      emitsInOrder([
        emitsError(isA<EmbyViewFailure>().having((error) => error.code, 'code', 'subtitle_tap_unavailable')),
        emitsDone,
      ]),
    );
    await tap.released;
    await tap.input.close();
  });

  test('an interrupted tap exposes the failure after the collected tail', () async {
    final tap = _Tap();
    final stream = playbackSubtitleAudio(tap, sourceGeneration: 7, start: Duration.zero);
    final checked = expectLater(
      stream,
      emitsInOrder([
        isA<SubtitleAudioSegment>().having((segment) => segment.end, 'end', const Duration(milliseconds: 600)),
        emitsError(isA<EmbyViewFailure>().having((error) => error.code, 'code', 'subtitle_tap_interrupted')),
        emitsDone,
      ]),
    );
    tap.packet(500);
    tap.input.addError(PlatformException(code: 'audioTapInterrupted'));
    await checked;
    await tap.released;
    await tap.input.close();
  });

  test('a foreground strm yields the current background strm, allows local reads and then retries', () async {
    const channel = MethodChannel('test/subtitle-audio');
    final native = <int, Completer<Object?>>{};
    final requests = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map<Object?, Object?>;
      final id = args['requestId'] as int;
      if (call.method == 'cancelIndependent') {
        native.remove(id)!.completeError(PlatformException(code: 'audioInterrupted'));
        return null;
      }
      expect(native, isEmpty);
      requests.add(args);
      return (native[id] = Completer<Object?>()).future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final reader = SubtitleAudioReader(channel: channel);
    Future<List<SubtitleAudioSegment>> read(String item, {bool background = false, SubtitleAudioCancellation? token}) =>
        reader.read(
          PlaybackSubtitleSource(
            generation: 7,
            target: PlayTarget(itemId: item),
            mediaSourceId: item,
            address: Uri.https('example.org', '/$item'),
            headers: const {},
            userAgent: 'Mozilla/5.0',
            itemFilePath: '/mnt/media/$item',
          ),
          start: _start,
          end: _end,
          streamIndex: 3,
          background: background,
          cancellation: token,
        );

    final season = read('season.strm', background: true);
    reader.setForegroundStrm(true);
    final player = read('playing.strm');
    await Future<void>.delayed(Duration.zero);
    expect(requests.last['userAgent'], 'Mozilla/5.0');
    expect(requests.last['streamIndex'], 3);
    expect(requests.last['startUs'], _start.inMicroseconds);
    native.remove(native.keys.single)!.complete([
      {'startUs': _start.inMicroseconds, 'sourceUs': 61000000, 'pcm': Uint8List(48000 * 4)},
    ]);
    expect((await player).single.sourceEnd, const Duration(seconds: 62));
    expect(requests, hasLength(2));

    final token = SubtitleAudioCancellation();
    final local = expectLater(
      read('local.mkv', background: true, token: token),
      throwsA(isA<SubtitleAudioCancelled>()),
    );
    token.cancel();
    await local;
    expect(requests, hasLength(3));

    reader.setForegroundStrm(false);
    await Future<void>.delayed(Duration.zero);
    expect(requests.last['address'], requests.first['address']);
    native.remove(native.keys.single)!.complete([]);
    expect(await season, isEmpty);
  });
}
