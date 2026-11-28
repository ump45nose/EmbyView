import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';

import '../../contracts/common.dart';
import 'subtitle_timing.dart';
import '../../playback/native_playback.dart';
import '../../playback/playback_subtitle_input.dart';

enum SubtitleAudioBoundaryKind { seek, audioTrack }

typedef SubtitleAudioBoundary = ({
  int sourceGeneration,
  SubtitleAudioBoundaryKind kind,
  bool ready,
  Duration? position,
  int? streamIndex,
});

/// Seek and audio-track changes are available even when the PCM tap is stopped.
final Stream<SubtitleAudioBoundary> subtitleAudioBoundaries = const EventChannel('embyview/audio_boundaries')
    .receiveBroadcastStream()
    .cast<Map>()
    .map((event) {
      final position = event['positionUs'] as int?;
      return (
        sourceGeneration: event['sourceGeneration'] as int,
        kind: SubtitleAudioBoundaryKind.values.byName(event['kind'] as String),
        ready: event['ready'] == true,
        position: position == null ? null : Duration(microseconds: position),
        streamIndex: event['streamIndex'] as int?,
      );
    });

bool isSubtitleStrm(PlaybackSubtitleSource source) =>
    [source.itemFilePath, source.mediaSourceFilePath].any((path) => path?.toLowerCase().endsWith('.strm') ?? false);

/// Match the native Aether serial-origin policy. A foreground tap consumes
/// already-buffered media without opening an additional origin connection.
bool usesSerialSubtitleOrigin(PlaybackSubtitleSource source) {
  final address = source.address;
  if (source.generation <= 0 || !const {'http', 'https'}.contains(address.scheme)) return false;
  final host = address.host.toLowerCase();
  return const ['115.com', '115cdn.net', '115cdn.com'].any((domain) => host == domain || host.endsWith('.$domain'));
}

const _sampleRate = 48000;
const _bytesPerFrame = 4;
const _maxWindow = Duration(seconds: 30);

double _frames(Duration duration) => duration.inMicroseconds * _sampleRate / 1000000;

Duration _elapsed(int frames) =>
    Duration(microseconds: (frames * Duration.microsecondsPerSecond / _sampleRate).round());

/// One continuous span of mono Float32LE PCM. [start] is on the playback clock,
/// [sourceStart] on the source PTS axis. An audio gap starts a new segment.
class SubtitleAudioSegment {
  const SubtitleAudioSegment({
    required this.start,
    required this.sourceStart,
    required this.pcm,
    required this.sourceGeneration,
    required this.timelineGeneration,
    required this.discontinuity,
  });

  final Duration start;
  final Duration sourceStart;
  final Uint8List pcm;
  final int sourceGeneration;
  final int timelineGeneration;
  final bool discontinuity;
  int get sampleRate => _sampleRate;
  Duration get duration => _elapsed(pcm.length ~/ _bytesPerFrame);
  Duration get end => start + duration;
  Duration get sourceEnd => sourceStart + duration;
}

const _tapUnavailable = EmbyViewFailure('当前播放无法提供随播音频。', retryable: true, code: 'subtitle_tap_unavailable');
const _tapInterrupted = EmbyViewFailure('随播音频已中断。', retryable: true, code: 'subtitle_tap_interrupted');

/// Takes ownership of the tap. [finish] closes it and emits any collected tail.
Stream<SubtitleAudioSegment> playbackSubtitleAudio(
  NativePlaybackAudioInput input, {
  required int sourceGeneration,
  required Duration start,
  Duration segmentDuration = const Duration(seconds: 20),
  Future<void>? finish,
}) {
  if (start.isNegative || segmentDuration < const Duration(seconds: 1) || segmentDuration > _maxWindow) {
    throw ArgumentError('Invalid playback audio window');
  }
  final byteLimit = _frames(segmentDuration).floor() * _bytesPerFrame;
  final pcm = BytesBuilder(copy: false);
  final output = StreamController<SubtitleAudioSegment>();
  late StreamSubscription<NativePcmPacket> subscription;
  late Future<void> started;
  Future<void>? released;
  var playbackStart = Duration.zero;
  var sourceStart = Duration.zero;
  var timeline = -1;
  var discontinuity = true;
  final gather = Stopwatch();

  void emit() {
    if (pcm.isEmpty) return;
    SubtitleAiTiming(
      'read',
      [TimeRange(start: playbackStart, end: playbackStart + _elapsed(pcm.length ~/ _bytesPerFrame))],
      gather.elapsed,
      'ok',
    ).emit();
    output.add(
      SubtitleAudioSegment(
        start: playbackStart,
        sourceStart: sourceStart,
        pcm: pcm.takeBytes(),
        sourceGeneration: sourceGeneration,
        timelineGeneration: timeline,
        discontinuity: discontinuity,
      ),
    );
    discontinuity = false;
  }

  Future<void> release() => released ??= () async {
    pcm.clear();
    try {
      await subscription.cancel();
    } finally {
      await started;
      await input.stop();
    }
  }().catchError((Object _) {});

  void terminate({bool flush = true, Object? error, StackTrace? stack}) {
    if (output.isClosed || !output.hasListener) return;
    if (flush) emit();
    if (error != null) output.addError(error, stack);
    unawaited(output.close());
    unawaited(release());
  }

  void accept(NativePcmPacket packet) {
    if (output.isClosed || packet.sourceGeneration < sourceGeneration) return;
    if (packet.sourceGeneration > sourceGeneration) {
      terminate(flush: false);
      return;
    }
    final expected = sourceStart + _elapsed(pcm.length ~/ _bytesPerFrame);
    final gap = packet.discontinuity || (packet.sourceTime - expected).abs() > const Duration(milliseconds: 2);
    if (timeline != packet.timelineGeneration) {
      pcm.clear();
      timeline = packet.timelineGeneration;
      discontinuity = true;
    } else if (gap && (pcm.isNotEmpty || packet.discontinuity)) {
      emit();
      discontinuity = true;
    }

    var frame = _frames(start - packet.playbackTime).ceil().clamp(0, packet.frameCount);
    while (frame < packet.frameCount) {
      if (pcm.isEmpty) {
        gather
          ..reset()
          ..start();
        playbackStart = packet.playbackTime + _elapsed(frame);
        sourceStart = packet.sourceTime + _elapsed(frame);
      }
      final free = (byteLimit - pcm.length) ~/ _bytesPerFrame;
      final next = frame + free.clamp(0, packet.frameCount - frame);
      pcm.add(Uint8List.sublistView(packet.pcm, frame * _bytesPerFrame, next * _bytesPerFrame));
      frame = next;
      if (pcm.length == byteLimit) emit();
    }
  }

  output.onListen = () {
    subscription = input.packets.listen(
      accept,
      onError: (Object error, StackTrace stack) {
        final failure = switch (error) {
          PlatformException(code: 'audioTapUnavailable') => _tapUnavailable,
          PlatformException(code: 'audioTapInterrupted') => _tapInterrupted,
          _ => error,
        };
        terminate(error: failure, stack: stack);
      },
      onDone: terminate,
    );
    started = Future.sync(input.start).then<void>((available) {
      if (!available) terminate(flush: false, error: _tapUnavailable);
    }, onError: (Object error, StackTrace stack) => terminate(flush: false, error: error, stack: stack));
    unawaited(
      finish?.then<void>(
        (_) => terminate(),
        onError: (Object error, StackTrace stack) {
          terminate(error: error, stack: stack);
        },
      ),
    );
  };
  output.onPause = () => subscription.pause();
  output.onResume = () => subscription.resume();
  output.onCancel = release;
  return output.stream;
}

class SubtitleAudioCancelled implements Exception {
  const SubtitleAudioCancelled();
}

class SubtitleAudioCancellation {
  final _cancelled = ValueNotifier(false);
  bool get isCancelled => _cancelled.value;
  void cancel() => _cancelled.value = true;
}

class _ReadSlot {
  _ReadSlot(this.id, this.backgroundStrm);

  final int id;
  final bool backgroundStrm;
  bool preempted = false;
}

/// One independent input serves foreground AI, alignment and seasons. Season
/// reads interrupted by foreground strm release the slot and retry the window.
class SubtitleAudioReader {
  SubtitleAudioReader({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('embyview/audio_control');

  static final shared = SubtitleAudioReader();
  static int _nextNativeId = 0;
  final MethodChannel _channel;
  Completer<void> _slotChanged = Completer<void>();
  _ReadSlot? _active;
  bool _foregroundStrm = false;
  int _foregroundReads = 0;

  void setForegroundStrm(bool active) {
    _foregroundStrm = active;
    if (active) _preemptSeason();
    _wake();
  }

  /// Rechecks [beforeRead] after waiting for the slot and before each retry.
  Future<List<SubtitleAudioSegment>> read(
    PlaybackSubtitleSource source, {
    required Duration start,
    required Duration end,
    int? streamIndex,
    bool background = false,
    SubtitleAudioCancellation? cancellation,
    Future<void> Function()? beforeRead,
  }) async {
    if (start.isNegative || end <= start || end - start > _maxWindow || (streamIndex != null && streamIndex < 0)) {
      throw ArgumentError('Invalid independent audio window or stream index');
    }
    final strm = isSubtitleStrm(source);
    _ReadSlot? slot;
    bool waiting() => _active != null || background && (_foregroundReads > 0 || strm && _foregroundStrm);

    void checkCancelled() {
      if (cancellation?.isCancelled ?? false) throw const SubtitleAudioCancelled();
    }

    void cancel() {
      final reading = slot;
      if (reading != null && !reading.preempted) _interrupt(reading);
      _wake();
    }

    cancellation?._cancelled.addListener(cancel);
    if (!background) _foregroundReads++;
    try {
      checkCancelled();
      if (!background && strm) _preemptSeason();
      while (true) {
        while (waiting()) {
          await _slotChanged.future;
          checkCancelled();
        }
        if (beforeRead != null) {
          try {
            await beforeRead();
          } finally {
            checkCancelled();
          }
          if (waiting()) continue;
        }
        final reading = slot = _active = _ReadSlot(++_nextNativeId, background && strm);
        final elapsed = Stopwatch()..start();
        final window = [TimeRange(start: start, end: end)];
        var status = 'failed';
        try {
          final rows = await _channel.invokeListMethod<Map>('readIndependent', {
            'address': source.address.toString(),
            'headers': source.headers,
            'userAgent': source.userAgent,
            'startUs': start.inMicroseconds,
            'endUs': end.inMicroseconds,
            'streamIndex': streamIndex,
            'requestId': reading.id,
          });
          checkCancelled();
          if (!reading.preempted) {
            status = 'ok';
            return [
              for (final (index, row) in (rows ?? const <Map>[]).indexed)
                SubtitleAudioSegment(
                  start: Duration(microseconds: row['startUs'] as int),
                  sourceStart: Duration(microseconds: row['sourceUs'] as int),
                  pcm: row['pcm'] as Uint8List,
                  sourceGeneration: source.generation,
                  timelineGeneration: reading.id,
                  discontinuity: index != 0,
                ),
            ];
          }
        } on PlatformException catch (error) {
          checkCancelled();
          if (!reading.preempted) {
            throw EmbyViewFailure(
              error.code == 'audioHttp' && error.details is int ? '独立音频读取失败（HTTP ${error.details}）。' : '独立音频读取失败。',
              code: error.code,
              httpStatus: error.code == 'audioHttp' && error.details is int ? error.details as int : null,
              retryable: true,
            );
          }
        } catch (_) {
          checkCancelled();
          if (!reading.preempted) rethrow;
        } finally {
          SubtitleAiTiming(
            'read',
            window,
            elapsed.elapsed,
            cancellation?.isCancelled == true
                ? 'cancelled'
                : reading.preempted
                ? 'preempted'
                : status,
          ).emit();
          slot = _active = null;
          _wake();
        }
      }
    } finally {
      if (!background) {
        _foregroundReads--;
        _wake();
      }
      cancellation?._cancelled.removeListener(cancel);
    }
  }

  void _preemptSeason() {
    final current = _active;
    if (current == null || !current.backgroundStrm || current.preempted) return;
    current.preempted = true;
    _interrupt(current);
  }

  void _interrupt(_ReadSlot slot) {
    unawaited(_channel.invokeMethod<void>('cancelIndependent', {'requestId': slot.id}).catchError((Object _) {}));
  }

  void _wake() {
    final previous = _slotChanged;
    _slotChanged = Completer<void>();
    previous.complete();
  }
}
