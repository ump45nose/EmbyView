import 'dart:async';

import 'package:flutter/services.dart';

import '../../playback/aether_backend.dart';
import '../contracts/playback.dart';

/// Native facts only. The playback session owns the intent-to-first-frame stopwatch.
class NativePlaybackSnapshot {
  const NativePlaybackSnapshot({
    this.sourceGeneration = 0,
    this.firstFrame = false,
    this.anime4k = const Anime4kSnapshot(),
    this.pictureInPictureSupported = false,
    this.pictureInPicture = false,
  });
  final int sourceGeneration;
  final bool firstFrame;
  final Anime4kSnapshot anime4k;
  final bool pictureInPictureSupported;
  final bool pictureInPicture;

  factory NativePlaybackSnapshot.fromWire(Map<dynamic, dynamic> wire) {
    T enumValue<T extends Enum>(List<T> values, dynamic name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    VideoSize? size(String prefix) {
      final w = wire['${prefix}Width'];
      final h = wire['${prefix}Height'];
      return w is num && h is num && w > 0 && h > 0
          ? VideoSize(width: w.toInt(), height: h.toInt())
          : null;
    }

    return NativePlaybackSnapshot(
      sourceGeneration: (wire['sourceGeneration'] as num?)?.toInt() ?? 0,
      firstFrame: wire['firstFrame'] == true,
      pictureInPictureSupported: wire['pictureInPictureSupported'] == true,
      pictureInPicture: wire['pictureInPicture'] == true,
      anime4k: Anime4kSnapshot(
        supported: wire['anime4kSupported'] == true,
        requested: wire['anime4kRequested'] == true,
        state: enumValue(
          Anime4kState.values,
          wire['anime4kState'],
          Anime4kState.unsupported,
        ),
        reason: wire['anime4kReason'] as String?,
        comparison: enumValue(
          ComparisonState.values,
          wire['comparisonState'],
          ComparisonState.unavailable,
        ),
        comparisonSplit: (wire['comparisonSplit'] as num?)?.toDouble(),
        originalSize: size('original'),
        enhancedSize: size('enhanced'),
      ),
    );
  }
}

class EmbyViewNativePlayback {
  EmbyViewNativePlayback(this.backend) {
    _subscription = backend.nativeEvents.listen((event) {
      if (event['event'] != 'nativePlayback' &&
          event['event'] != 'firstFrame') {
        return;
      }
      _snapshot = NativePlaybackSnapshot.fromWire(event);
      _changes.add(_snapshot);
    });
  }
  final AetherBackend backend;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  final _changes = StreamController<NativePlaybackSnapshot>.broadcast();
  NativePlaybackSnapshot _snapshot = const NativePlaybackSnapshot();
  NativePlaybackSnapshot get snapshot => _snapshot;
  Stream<NativePlaybackSnapshot> get changes => _changes.stream;
  void configureNextSource({
    required int sourceGeneration,
    int? sessionCacheByteBudget,
    bool anime4k = false,
  }) {
    _snapshot = NativePlaybackSnapshot(sourceGeneration: sourceGeneration);
    backend.configureNextNativeSource(
      sourceGeneration: sourceGeneration,
      sessionCacheByteBudget: sessionCacheByteBudget,
      anime4k: anime4k,
    );
  }

  Future<void> setAnime4k(bool enabled) =>
      backend.invokeNativeControl<void>('setAnime4k', {'enabled': enabled});
  Future<void> setAnime4kComparison(double? split) =>
      backend.invokeNativeControl<void>('setAnime4kComparison', {
        'split': split?.clamp(0.0, 1.0),
      });
  Future<void> setPictureInPicture(bool enabled) => backend
      .invokeNativeControl<void>('setPictureInPicture', {'enabled': enabled});
  Future<void> loadExternalSubtitle(
    String url, {
    String? title,
    String? language,
    String? codec,
    int? sourceGeneration,
  }) => backend.loadExternalSubtitle(
    url,
    title: title,
    language: language,
    codec: codec,
    sourceGeneration: sourceGeneration ?? _snapshot.sourceGeneration,
  );

  Future<void> dispose() async {
    await _subscription.cancel();
    await _changes.close();
  }
}

class NativePcmPacket {
  const NativePcmPacket({
    required this.sourceGeneration,
    required this.timelineGeneration,
    required this.sourceTime,
    required this.playbackTime,
    required this.pcm,
    required this.discontinuity,
    required this.dialogue,
  });
  final int sourceGeneration;
  final int timelineGeneration;
  final Duration sourceTime;
  final Duration playbackTime;
  final Uint8List pcm;
  final bool discontinuity;
  final bool dialogue;
  int get sampleRate => 48000;
  int get channels => 1;
  int get frameCount => pcm.length ~/ 4;
  factory NativePcmPacket.fromWire(Map<dynamic, dynamic> wire) {
    final pcm = wire['pcm'];
    if (pcm is! Uint8List ||
        pcm.isEmpty ||
        pcm.length % 4 != 0 ||
        pcm.length > 32768 ||
        wire['sampleRate'] != 48000 ||
        wire['channels'] != 1) {
      throw const FormatException('Invalid native PCM packet');
    }
    int number(String key) => (wire[key] as num?)?.toInt() ?? 0;
    return NativePcmPacket(
      sourceGeneration: number('sourceGeneration'),
      timelineGeneration: number('timelineGeneration'),
      sourceTime: Duration(microseconds: number('sourceTimeUs')),
      playbackTime: Duration(microseconds: number('playbackTimeUs')),
      pcm: pcm,
      discontinuity: wire['discontinuity'] == true,
      dialogue: wire['dialogue'] == true,
    );
  }
}

/// Single-consumer, acknowledgement-driven stream. At most one batch is in flight;
/// the native ring drops old PCM and marks the next packet when a consumer falls behind.
class NativePlaybackAudioInput {
  static const _control = MethodChannel('embyview/audio_control');
  static const _events = EventChannel('embyview/audio_events');
  Future<bool> start({bool dialogue = true}) async =>
      await _control.invokeMethod<bool>('start', {'dialogue': dialogue}) ??
      false;
  Future<void> stop() => _control.invokeMethod<void>('stop');
  Future<({bool available, String? reason})> aheadAvailability() async {
    final wire = await _control.invokeMapMethod<String, dynamic>(
      'aheadAvailability',
    );
    return (
      available: wire?['available'] == true,
      reason: wire?['reason'] as String?,
    );
  }

  Stream<NativePcmPacket> get packets {
    late StreamController<NativePcmPacket> output;
    StreamSubscription<dynamic>? native;
    final pending = <NativePcmPacket>[];
    int? sequence;
    var paused = false;
    var draining = false;
    var cancelled = false;
    Future<void> drain() async {
      if (draining || cancelled) return;
      draining = true;
      try {
        while (!paused && pending.isNotEmpty && !cancelled) {
          output.add(pending.removeAt(0));
        }
        if (!paused && pending.isEmpty && sequence != null && !cancelled) {
          final acknowledged = sequence;
          sequence = null;
          await _control.invokeMethod<void>('ack', {'sequence': acknowledged});
        }
      } catch (error, stack) {
        if (!cancelled) output.addError(error, stack);
      } finally {
        draining = false;
        // The native ack can release the next batch before its RPC reply arrives.
        if (pending.isNotEmpty && !paused && !cancelled) unawaited(drain());
      }
    }

    output = StreamController<NativePcmPacket>(
      sync: true,
      onListen: () {
        native = _events.receiveBroadcastStream().listen(
          (raw) {
            if (raw is! Map || raw['event'] != 'pcm' || cancelled) return;
            try {
              final buffers = raw['buffers'];
              if (buffers is! List ||
                  buffers.isEmpty ||
                  buffers.length > 4 ||
                  sequence != null) {
                throw const FormatException('Invalid native PCM batch');
              }
              sequence = (raw['sequence'] as num).toInt();
              pending.addAll(
                buffers.map(
                  (packet) => NativePcmPacket.fromWire(packet as Map),
                ),
              );
              unawaited(drain());
            } catch (error, stack) {
              output.addError(error, stack);
            }
          },
          onError: output.addError,
          onDone: output.close,
        );
      },
      onPause: () {
        paused = true;
        native?.pause();
      },
      onResume: () {
        paused = false;
        native?.resume();
        unawaited(drain());
      },
      onCancel: () async {
        cancelled = true;
        pending.clear();
        await native?.cancel();
      },
    );
    return output.stream;
  }
}
