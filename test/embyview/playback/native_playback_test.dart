import 'dart:async';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/playback/native_playback.dart';
import 'package:moonfin/embyview/contracts/playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native presentation preserves missing first frame and measured state',
    () {
      final pending = NativePlaybackSnapshot.fromWire({'sourceGeneration': 9});
      expect(pending.firstFrame, isFalse);
      expect(pending.anime4k.state, Anime4kState.unsupported);
      final active = NativePlaybackSnapshot.fromWire({
        'sourceGeneration': 9,
        'firstFrame': true,
        'anime4kSupported': true,
        'anime4kRequested': true,
        'anime4kState': 'degraded',
        'comparisonState': 'available',
        'comparisonSplit': .35,
        'originalWidth': 1920,
        'originalHeight': 1080,
        'enhancedWidth': 3840,
        'enhancedHeight': 2160,
      });
      expect(active.anime4k.state, Anime4kState.degraded);
      expect(active.anime4k.comparison, ComparisonState.available);
      expect(active.anime4k.originalSize!.width, 1920);
    },
  );
  test('PCM rejects malformed or excessive packets', () {
    expect(
      () => NativePcmPacket.fromWire({'pcm': Uint8List(3)}),
      throwsFormatException,
    );
    expect(
      () => NativePcmPacket.fromWire({'pcm': Uint8List(1024 * 1024)}),
      throwsFormatException,
    );
    final packet = NativePcmPacket.fromWire({
      'pcm': Uint8List(8),
      'sampleRate': 48000,
      'channels': 1,
      'sourceGeneration': 2,
      'timelineGeneration': 5,
      'sourceTimeUs': 1200000,
      'playbackTimeUs': 1000000,
      'discontinuity': true,
    });
    expect(packet.sourceGeneration, 2);
    expect(packet.timelineGeneration, 5);
    expect(packet.frameCount, 2);
    expect(packet.discontinuity, isTrue);
  });
  test('PCM acknowledgement waits for the paused consumer', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const control = MethodChannel('embyview/audio_control');
    const events = MethodChannel('embyview/audio_events');
    final listening = Completer<void>();
    final acknowledged = Completer<int>();
    messenger.setMockMethodCallHandler(control, (call) async {
      if (call.method == 'ack' && !acknowledged.isCompleted) {
        acknowledged.complete((call.arguments as Map)['sequence'] as int);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final received = <NativePcmPacket>[];
    late StreamSubscription<NativePcmPacket> subscription;
    subscription = NativePlaybackAudioInput().packets.listen((packet) {
      received.add(packet);
      if (received.length == 1) subscription.pause();
    });
    try {
      await listening.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('native stream did not listen'),
      );
      final packet = {
        'pcm': Uint8List(8),
        'sampleRate': 48000,
        'channels': 1,
        'sourceGeneration': 2,
        'timelineGeneration': 5,
        'discontinuity': true,
      };
      // Test injection into the same platform event queue used by EventChannel.
      // ignore: deprecated_member_use
      await messenger
          .handlePlatformMessage(
            'embyview/audio_events',
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'pcm',
              'sequence': 7,
              'buffers': [packet, packet],
            }),
            (_) {},
          )
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError('native event was not delivered'),
          );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, hasLength(1));
      expect(acknowledged.isCompleted, isFalse);
      subscription.resume();
      expect(await acknowledged.future.timeout(const Duration(seconds: 2)), 7);
      expect(received, hasLength(2));
    } finally {
      subscription.resume();
      await subscription.cancel().timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('native stream did not cancel'),
      );
      messenger.setMockMethodCallHandler(control, null);
      messenger.setMockMethodCallHandler(events, null);
    }
  });
  test('PCM accepts the next batch before the acknowledgement reply', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const control = MethodChannel('embyview/audio_control');
    const events = MethodChannel('embyview/audio_events');
    final listening = Completer<void>();
    final complete = Completer<void>();
    final received = <NativePcmPacket>[];
    Future<void> emit(int sequence) async {
      // ignore: deprecated_member_use
      await messenger.handlePlatformMessage(
        'embyview/audio_events',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'pcm',
          'sequence': sequence,
          'buffers': [
            {
              'pcm': Uint8List(8),
              'sampleRate': 48000,
              'channels': 1,
              'sourceGeneration': 2,
              'timelineGeneration': sequence,
            },
          ],
        }),
        (_) {},
      );
    }

    messenger.setMockMethodCallHandler(control, (call) async {
      if (call.method == 'ack') {
        if ((call.arguments as Map)['sequence'] == 7) {
          await emit(8);
        } else {
          complete.complete();
        }
      }
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final subscription = NativePlaybackAudioInput().packets.listen(
      received.add,
    );
    try {
      await listening.future.timeout(const Duration(seconds: 2));
      await emit(7);
      await complete.future.timeout(const Duration(seconds: 2));
      expect(received.map((p) => p.timelineGeneration), [7, 8]);
    } finally {
      await subscription.cancel().timeout(const Duration(seconds: 2));
      messenger.setMockMethodCallHandler(control, null);
      messenger.setMockMethodCallHandler(events, null);
    }
  });
}
