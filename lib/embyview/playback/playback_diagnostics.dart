import 'dart:async';

/// Timings are measured from the user's current play intent. Preparing a detail
/// page records a separate sample and never starts the first-frame stopwatch.
class PlaybackTiming {
  const PlaybackTiming({
    required this.itemId,
    required this.generation,
    required this.event,
    required this.elapsed,
    this.cacheHit,
    this.navigation,
    this.playbackInfo,
    this.redirect,
    this.engineOpen,
    this.firstFrame,
    this.failure,
  });
  final String itemId;
  final int generation;
  final String event;
  final Duration elapsed;
  final bool? cacheHit;
  final Duration? navigation;
  final Duration? playbackInfo;
  final Duration? redirect;
  final Duration? engineOpen;
  final Duration? firstFrame;

  /// A bounded category, never an exception, signed address, or auth header.
  final String? failure;
}

class PlaybackDiagnostics {
  final _records = <PlaybackTiming>[];
  final _changes = StreamController<PlaybackTiming>.broadcast();
  List<PlaybackTiming> get records => List.unmodifiable(_records);
  Stream<PlaybackTiming> get changes => _changes.stream;
  void record(PlaybackTiming value) {
    if (_changes.isClosed) return;
    if (_records.length == 128) _records.removeAt(0);
    _records.add(value);
    _changes.add(value);
  }

  Future<void> close() => _changes.close();
}
