import 'dart:async';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/embyview/playback/native_playback.dart';
import 'package:moonfin/embyview/contracts/playback.dart';
import 'package:moonfin/playback/aether_backend.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native sidecar registration preserves pending embedded choice', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const control = MethodChannel('moonfin/ios_aether_control');
    const events = MethodChannel('moonfin/ios_aether_events');
    final calls = <MethodCall>[];
    var refuseExternal = false;
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call);
      if (call.method == 'loadExternalSubtitle') {
        if (refuseExternal) throw PlatformException(code: 'registration_failed');
        if (call.arguments['select'] == true) {
          return {
            'sourceGeneration': call.arguments['sourceGeneration'],
            'requestID': call.arguments['requestID'],
            'outcome': 'selected',
          };
        }
      }
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    final prefs = UserPreferences(store);
    final backend = AetherBackend(prefs);
    final native = EmbyViewNativePlayback(backend);
    try {
      await Future<void>.delayed(Duration.zero);
      await backend.setSubtitleTrack(2);
      expect(backend.activeSubtitleTrackIndex, 2);
      await native.loadExternalSubtitle('file:///subtitle.srt', select: false);
      expect(calls.last.arguments['select'], isFalse);
      expect(backend.activeSubtitleTrackIndex, 2);
      // The previously requested embedded subtitle must still be selected
      // when its tracks arrive.
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({'event': 'tracksChanged', 'textTrackCount': 2}),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'setSubtitleTrack').single.arguments['index'], 2);
      await native.loadExternalSubtitle('file:///subtitle.srt');
      expect(calls.last.arguments['select'], isTrue);
      expect(backend.activeSubtitleTrackIndex, 0);
      native.configureNextSource(sourceGeneration: 17);
      await backend.play({'url': 'file:///video.mkv'});
      await messenger.handlePlatformMessage(events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({'event': 'tracksChanged', 'textTrackCount': 2}), (_) {});
      await Future<void>.delayed(Duration.zero);
      await backend.setSubtitleTrack(1);
      refuseExternal = true;
      await expectLater(backend.addExternalSubtitle('file:///bad.srt'), throwsA(isA<PlatformException>()));
      await expectLater(backend.setSubtitleTrack(2, isExternalSubtitle: true,
          externalSubtitleUrl: 'file:///bad.srt'), throwsA(isA<PlatformException>()));
      expect(backend.activeSubtitleTrackIndex, 1);
      refuseExternal = false;
      await backend.setSubtitleTrack(2, isExternalSubtitle: true, externalSubtitleUrl: 'file:///good.srt');
      expect(calls.last.method, 'loadExternalSubtitle');
      expect(calls.last.arguments['sourceGeneration'], 17);
      expect(calls.last.arguments['url'], 'file:///good.srt');
      final sourceCalls = calls.where((call) => call.method == 'setSource').length;
      final primaryTrack = backend.activeSubtitleTrackIndex;
      await backend.setSecondarySubtitle(embeddedTrackId: 2);
      expect(calls.last.method, 'setSecondarySubtitle');
      expect(calls.last.arguments, {'embeddedTrackId': 2, 'url': null});
      await backend.setSecondarySubtitle(url: 'file:///secondary.srt');
      expect(calls.last.arguments, {'embeddedTrackId': null, 'url': 'file:///secondary.srt'});
      await backend.setSecondarySubtitle(url: 'http://127.0.0.1/secondary.vtt');
      expect(calls.last.arguments, {'embeddedTrackId': null, 'url': 'http://127.0.0.1/secondary.vtt'});
      await backend.setSecondarySubtitle();
      expect(calls.last.arguments, {'embeddedTrackId': null, 'url': null});
      expect(calls.where((call) => call.method == 'setSource'), hasLength(sourceCalls));
      expect(backend.activeSubtitleTrackIndex, primaryTrack);
    } finally {
      await native.dispose();
      backend.dispose();
      prefs.dispose();
      messenger.setMockMethodCallHandler(control, null);
      messenger.setMockMethodCallHandler(events, null);
    }
  });
  test('external selection accepts only the matching successful receipt', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const control = MethodChannel('moonfin/ios_aether_control');
    const events = MethodChannel('moonfin/ios_aether_events');
    final replies = <Completer<Map<String, dynamic>>>[];
    final requests = <Map<dynamic, dynamic>>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      if (call.method != 'loadExternalSubtitle' || call.arguments['select'] != true) return null;
      requests.add(call.arguments as Map);
      final completer = Completer<Map<String, dynamic>>();
      replies.add(completer);
      return completer.future;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    final prefs = UserPreferences(store);
    final backend = AetherBackend(prefs);
    Map<String, dynamic> reply(int i, String outcome, {int? generation}) => {
      'sourceGeneration': generation ?? requests[i]['sourceGeneration'],
      'requestID': requests[i]['requestID'],
      'outcome': outcome,
    };
    try {
      backend.configureNextNativeSource(sourceGeneration: 10);
      await backend.play({'url': 'file:///video.mkv'});
      await backend.setSubtitleTrack(1);
      final failed = expectLater(backend.loadExternalSubtitle('http://127.0.0.1/bad.srt'),
          throwsA(isA<ExternalSubtitleSelectionFailed>()));
      await pumpEventQueue();
      replies[0].complete(reply(0, 'failed'));
      await failed;
      expect(backend.activeSubtitleTrackIndex, 1);
      final old = expectLater(backend.loadExternalSubtitle('http://127.0.0.1/old.sup'),
          throwsA(isA<PlatformException>()));
      await pumpEventQueue();
      await backend.supersedeExternalSubtitleSelection();
      final latest = backend.loadExternalSubtitle('http://127.0.0.1/new.srt');
      await pumpEventQueue();
      replies[2].complete(reply(2, 'selected'));
      await latest;
      replies[1].complete(reply(1, 'failed'));
      await old;
      expect(backend.activeSubtitleTrackIndex, 0);
      final stale = expectLater(backend.loadExternalSubtitle('http://127.0.0.1/stale.srt'),
          throwsA(isA<PlatformException>()));
      await pumpEventQueue();
      replies[3].complete(reply(3, 'selected', generation: 9));
      await stale;
      expect(backend.activeSubtitleTrackIndex, 0);
    } finally {
      backend.dispose();
      prefs.dispose();
      messenger.setMockMethodCallHandler(control, null);
      messenger.setMockMethodCallHandler(events, null);
    }
  });
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
