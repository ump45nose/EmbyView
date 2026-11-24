import 'dart:async';

import 'package:uuid/uuid.dart';

import '../embyview.dart';
import '../playback/playback_subtitle_input.dart';
import 'ai/subtitle_ai.dart';
import 'audio/subtitle_audio.dart';
import 'emby_subtitle_library.dart';
import 'model/subtitle_document.dart';
import 'sources/subtitle_sources.dart';
import 'store/subtitle_store.dart';

const _expired = EmbyViewFailure('字幕所属的播放或用户已变更。', retryable: true);
const _unreadable = EmbyViewFailure('此轨没有可取得的文本原文。', code: 'subtitle_text_unavailable');
const _window = Duration(seconds: 20);
const _minimumLead = Duration(seconds: 12);

class BoundSubtitlePanel implements SubtitlePanel {
  BoundSubtitlePanel({
    required this.session,
    required this.input,
    required this.store,
    required this.loadItem,
    required this.loadDocument,
    required this.sources,
    required this.processor,
    required this.preferences,
    required this.onClosed,
    this.checkAi,
    Stream<SubtitleAudioBoundary>? boundaries,
  }) : _ai = SubtitleAiRunController(processor) {
    _subscriptions.addAll([
      session.changes.listen((_) => _refresh()),
      input.subtitleSources.listen((_) => _refresh()),
      _ai.changes.listen((_) => _emit()),
      (boundaries ?? subtitleAudioBoundaries).listen(_audioBoundary, onError: (Object _) {}),
    ]);
    _refresh();
  }

  final PlaybackSession session;
  final PlaybackSubtitleInput input;
  final SubtitleStore store;
  final Future<SubtitleItem> Function(String, String?) loadItem;
  final Future<SubtitleDocument?> Function(SubtitleItem, Map<String, dynamic>) loadDocument;
  final SubtitleSources sources;
  final SubtitleAiProcessor processor;
  final LocalPreferences Function() preferences;
  final void Function() onClosed;
  final Future<void> Function()? checkAi;
  final SubtitleAiRunController _ai;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _changes = StreamController<SubtitleSnapshot>.broadcast();
  _PanelScope? _scope;
  SubtitleAiCancellation? _run, _alignment;
  Completer<void>? _tapFinished;
  AiRun? _preparing;
  Future<void>? _closing;
  var _timeline = 0, _resumeAfterBoundary = false;
  String? _audioId, _expectedAudioId;
  @override
  SubtitleSnapshot snapshot = const SubtitleSnapshot(generation: 0);
  @override
  Stream<SubtitleSnapshot> get changes => _changes.stream;

  void _refresh() {
    if (_closing != null) return;
    final play = session.snapshot;
    final source = input.subtitleSource;
    if (play.phase == PlaybackPhase.ended && _run != null && _scope?.source.generation == play.generation) {
      final finished = _tapFinished;
      if (finished != null && !finished.isCompleted) finished.complete();
      _emit();
      return;
    }
    final valid =
        source != null &&
        source.generation == play.generation &&
        source.target.itemId == play.target.itemId &&
        play.phase != PlaybackPhase.ended &&
        play.phase != PlaybackPhase.failed;
    if (!identical(_scope?.source, valid ? source : null)) {
      _scope?.close();
      _resetAudio();
      _resumeAfterBoundary = false;
      _scope = !valid ? null : _PanelScope(source, sources.openScope());
      _audioId = play.selectedAudioId;
      _expectedAudioId = null;
    }
    final scope = _scope;
    if (scope != null) {
      if (_audioId != play.selectedAudioId && play.selectedAudioId != null) {
        _audioId = play.selectedAudioId;
        if (_expectedAudioId == _audioId) {
          _expectedAudioId = null;
        } else if (_run != null) {
          _resumeAfterBoundary = true;
          _resetAudio();
        }
      }
      if (!scope.scanning && (play.phase == PlaybackPhase.playing || play.phase == PlaybackPhase.paused)) {
        scope.scanning = true;
        unawaited(_loadNas(scope, play.selectedSubtitleId));
      }
      final track = play.selectedSubtitleId;
      if (track != null && !scope.retained.containsKey(track) && !scope.documents.containsKey(track)) {
        unawaited(_document(scope, track).then<void>((_) => _emit(), onError: (Object _) {}));
      }
      _ai.updatePosition(play.position, timelineGeneration: _timeline);
    }
    _emit();
  }

  void _emit() {
    if (_changes.isClosed) return;
    final play = session.snapshot;
    final scope = _scope?.source.generation == play.generation ? _scope : null;
    final selected = scope == null ? null : play.selectedSubtitleId;
    snapshot = SubtitleSnapshot(
      generation: play.generation,
      selectedTrackId: selected,
      tracks: scope == null
          ? const []
          : [
              for (final track in play.subtitleTracks)
                SubtitleTrackState(
                  trackId: track.id,
                  origin: scope.retained[track.id]?.origin ?? SubtitleOrigin.values.byName(track.source.name),
                  active: selected == track.id,
                  save: scope.saves[track.id]?.state ?? SubtitleSaveState.notRequired,
                  index:
                      scope.saves[track.id]?.index ??
                      (track.source == PlaybackTrackSource.embyExternal
                          ? SubtitleIndexState.recognized
                          : SubtitleIndexState.unavailable),
                  failure: scope.saves[track.id]?.failure,
                  candidateId: scope.retained[track.id]?.candidateId,
                ),
            ],
      cues: scope?.dialogue[selected],
      ai: scope == null ? null : _preparing ?? _ai.run,
    );
    _changes.add(snapshot);
  }

  void _check(_PanelScope scope) {
    if (!identical(scope, _scope) ||
        !identical(input.subtitleSource, scope.source) ||
        session.snapshot.generation != scope.source.generation ||
        session.snapshot.phase == PlaybackPhase.ended ||
        session.snapshot.phase == PlaybackPhase.failed) {
      throw _expired;
    }
  }

  _PanelScope get _active {
    final scope = _scope;
    if (scope == null) throw _expired;
    _check(scope);
    return scope;
  }

  Future<SubtitleItem> _item(_PanelScope scope) => scope.item ??= scope.guard(
    loadItem(scope.source.target.itemId, scope.source.mediaSourceId).then(
      (item) {
        if (item.source.mediaSourceId != scope.source.mediaSourceId) {
          throw _expired;
        }
        return item;
      },
      onError: (Object error) {
        scope.item = null;
        throw error is EmbyViewFailure ? error : const EmbyViewFailure('暂时无法读取当前媒体源。', retryable: true);
      },
    ),
  );

  Future<SubtitleMedia> _media(_PanelScope scope) async {
    final media = SubtitleMedia.fromPlayback(scope.source, duration: session.snapshot.duration);
    if (media.embyFilePath != null) return media;
    try {
      final item = await _item(scope);
      return SubtitleMedia.fromPlayback(item.source, duration: media.duration ?? item.duration);
    } on EmbyViewFailure {
      return media;
    }
  }

  Future<void> _loadNas(_PanelScope scope, String? initiallySelected) async {
    try {
      final play = session.snapshot;
      if (!preferences().autoSelectChineseSubtitle ||
          play.subtitleTracks.any((track) => track.id == initiallySelected && isChineseSubtitle(track.language))) {
        return;
      }
      final scan = await store.scan(await _media(scope));
      _check(scope);
      if (session.snapshot.selectedSubtitleId != initiallySelected || scope.userApplied) {
        return;
      }
      final available = scan.nasTracks.where((track) => isChineseSubtitle(track.language) && !track.isForced);
      final preferred = available.where((track) => track.isComplete).firstOrNull ?? available.firstOrNull;
      if (preferred == null) return;
      final id = await _apply(scope, preferred, cues: scan.dialogue(preferred));
      scope.saves[id] = const SubtitleSaveResult(state: SubtitleSaveState.saved);
      _emit();
    } catch (_) {
      // Missing NAS or a source change leaves the playback engine's track selected.
    }
  }

  Future<SubtitleDocument?> _document(_PanelScope scope, String id) async {
    if (scope.retained[id] case final track?) return track.document;
    return scope.documents.putIfAbsent(id, () async {
      final track = session.snapshot.subtitleTracks.where((track) => track.id == id).firstOrNull;
      final index = int.tryParse(id.split(':').last);
      if (track == null || index == null || isGraphicSubtitleFormat(track.format ?? '')) {
        return null;
      }
      try {
        final item = await _item(scope);
        final row = item.streams.where((row) => row['Type'] == 'Subtitle' && row['Index'] == index).firstOrNull;
        if (row == null) return null;
        final document = await scope.guard(loadDocument(item, row));
        _check(scope);
        scope.dialogue[id] = document?.cues;
        return document;
      } catch (_) {
        return null;
      }
    });
  }

  @override
  Future<List<SubtitleSearchGroup>> search(String? text) async {
    final scope = _active;
    final item = (await _item(scope)).item;
    _check(scope);
    return scope.search.search(
      SubtitleQuery(
        title: (item['SeriesName'] ?? item['Name'] ?? '').toString(),
        originalTitle: item['Type'] == 'Episode' ? null : item['OriginalTitle'] as String?,
        text: text,
        year: (item['ProductionYear'] as num?)?.toInt(),
        season: (item['ParentIndexNumber'] as num?)?.toInt(),
        episode: (item['IndexNumber'] as num?)?.toInt(),
        languages: preferences().subtitleLanguages,
      ),
      enabledSources: preferences().subtitleSources,
    );
  }

  @override
  Future<void> useCandidate(SubtitleCandidate candidate) async {
    final scope = _active;
    scope.userApplied = true;
    final data = await scope.search.download(candidate);
    final language = data.language ?? candidate.language;
    final SubtitleDocument document;
    try {
      document = SubtitleDocument.parse(
        data.bytes,
        format: data.format ?? candidate.format ?? 'srt',
        language: language,
      );
    } on FormatException {
      throw const EmbyViewFailure('下载的字幕无法读取。');
    }
    await _use(scope, document, language, SubtitleOrigin.online, candidateId: candidate.id);
  }

  Future<String> _apply(_PanelScope scope, StoredSubtitle track, {List<SubtitleCue>? cues}) async {
    _check(scope);
    final id = await store.apply(track, input, generation: scope.source.generation);
    _check(scope);
    scope.retained[id] = track;
    scope.dialogue[id] = cues ?? track.document.cues;
    return id;
  }

  Future<void> _use(
    _PanelScope scope,
    SubtitleDocument document,
    String? language,
    SubtitleOrigin origin, {
    String? candidateId,
    Iterable<TimeRange>? coverage,
  }) async {
    _check(scope);
    final track = await store.retain(
      await _media(scope),
      document,
      language: language,
      origin: origin,
      candidateId: candidateId,
      coverage: coverage,
    );
    final id = await _apply(scope, track);
    unawaited(_save(scope, id, track));
  }

  Future<void> _save(_PanelScope scope, String id, StoredSubtitle track, {StoredSubtitle? original}) async {
    if (scope.saves[id]?.state == SubtitleSaveState.saving) return;
    scope.saves[id] = const SubtitleSaveResult(state: SubtitleSaveState.saving);
    _emit();
    void update(SubtitleSaveResult state) {
      scope.saves[id] = state;
      if (identical(scope, _scope)) _emit();
    }

    try {
      if (original != null) {
        final result = await store.save(original);
        if (result.state == SubtitleSaveState.failed) return update(result);
      }
      update(await store.save(track, onCommitted: update));
    } catch (_) {
      update(
        const SubtitleSaveResult(
          state: SubtitleSaveState.failed,
          failure: EmbyViewFailure('字幕留在本机，请重试保存。', retryable: true),
        ),
      );
    }
  }

  @override
  Future<void> retrySave(String trackId) async {
    final scope = _active;
    final track = scope.retained[trackId];
    if (track == null || scope.saves[trackId]?.state != SubtitleSaveState.failed) {
      return;
    }
    await _save(scope, trackId, track, original: scope.originals[trackId]);
  }

  @override
  Future<void> translate(String trackId) => _edit(trackId, align: false);
  @override
  Future<void> align(String trackId) => _edit(trackId, align: true);

  Future<void> _edit(String id, {required bool align}) async {
    final scope = _active;
    final cancellation = SubtitleAiCancellation();
    scope.edits.add(cancellation);
    if (align) {
      _alignment?.cancel();
      _alignment = cancellation;
    }
    try {
      final document = await _document(scope, id);
      _check(scope);
      if (document == null || document.cues?.isNotEmpty != true) {
        throw _unreadable;
      }
      final play = session.snapshot;
      final audioIndex = int.tryParse(play.selectedAudioId?.split(':').last ?? '');
      final edited = align
          ? await alignSubtitle(
              document,
              _audio(scope.source, Duration.zero, play.duration, audioIndex, cancellation),
              cancellation: cancellation,
            )
          : await processor.translate(document, cancellation: cancellation);
      cancellation.check();
      if (identical(document, edited)) {
        throw const EmbyViewFailure('未找到足够一致的对白锚点，无法校正。', code: 'subtitle_alignment_unavailable');
      }
      scope.userApplied = true;
      final language = play.subtitleTracks.where((track) => track.id == id).firstOrNull?.language;
      final original = scope.retained[id], duration = play.duration;
      await _use(
        scope,
        edited,
        align ? language : 'zh',
        align ? (original?.origin ?? SubtitleOrigin.nas) : SubtitleOrigin.ai,
        coverage:
            original?.coverage ?? (align || duration == null ? null : [TimeRange(start: Duration.zero, end: duration)]),
      );
    } on SubtitleAiCancelled {
      throw _expired;
    } finally {
      scope.edits.remove(cancellation);
      if (identical(_alignment, cancellation)) _alignment = null;
    }
  }

  Stream<SubtitleAudioSegment> _audio(
    PlaybackSubtitleSource source,
    Duration start,
    Duration? end,
    int? index,
    SubtitleAiCancellation cancellation,
  ) async* {
    if (end == null || start >= end) return;
    final readerCancellation = SubtitleAudioCancellation();
    cancellation.addListener(readerCancellation.cancel);
    try {
      for (var cursor = start; cursor < end;) {
        final next = cursor + _window < end ? cursor + _window : end;
        final segments = await SubtitleAudioReader.shared.read(
          source,
          start: cursor,
          end: next,
          streamIndex: index,
          cancellation: readerCancellation,
        );
        for (final segment in segments) {
          yield segment;
        }
        cursor = next;
      }
    } finally {
      cancellation.removeListener(readerCancellation.cancel);
    }
  }

  @override
  Future<void> startAi() => _startAi();

  Future<void> _startAi({Duration? position, int? streamIndex}) async {
    final scope = _active;
    final play = session.snapshot, timeline = _timeline;
    final start = position ?? play.position;
    final index = streamIndex ?? int.tryParse(play.selectedAudioId?.split(':').last ?? '');
    final language = play.audioTracks.where((track) => track.id == play.selectedAudioId).firstOrNull?.language;
    _run?.cancel();
    _ai.invalidate();
    final cancellation = _run = SubtitleAiCancellation();
    final finished = _tapFinished = Completer<void>();
    bool current() => identical(_scope, scope) && timeline == _timeline && identical(_run, cancellation);
    _preparing = AiRun(generation: play.generation, state: AiRunState.preparing, startedAt: start);
    _emit();
    final reader = StreamIterator(_audio(scope.source, start, play.duration, index, cancellation));
    var independent = false;
    try {
      await checkAi?.call();
      if (!current()) return;
      try {
        final measured = Stopwatch()..start();
        independent =
            await reader.moveNext() &&
            measured.elapsed <= _window - _minimumLead &&
            reader.current.end - session.snapshot.position >= _minimumLead;
      } catch (_) {
        // Unavailable independent audio uses the existing playback tap.
      }
      if (!independent) await reader.cancel();
      if (!current()) return;
      Stream<SubtitleAudioSegment> ahead() async* {
        do {
          yield reader.current;
        } while (await reader.moveNext());
      }

      _preparing = null;
      final output = await _ai.start(
        generation: play.generation,
        timelineGeneration: timeline,
        position: start,
        audio: independent
            ? ahead()
            : playbackSubtitleAudio(
                input.audioInput,
                sourceGeneration: play.generation,
                start: start,
                finish: finished.future,
              ),
        followsPlayhead: !independent,
        isCurrent: current,
        language: language,
        cancellation: cancellation,
      );
      if (output != null && current()) {
        await _persistAi(scope, output, current, apply: session.snapshot.phase != PlaybackPhase.ended);
      }
    } on EmbyViewFailure catch (failure) {
      if (current()) {
        _preparing = AiRun(generation: play.generation, state: AiRunState.failed, startedAt: start, failure: failure);
        _emit();
      }
    } finally {
      await reader.cancel();
      if (identical(_run, cancellation)) {
        _tapFinished = null;
        _run = null;
        if (session.snapshot.phase == PlaybackPhase.ended) _refresh();
      }
    }
  }

  Future<void> _persistAi(
    _PanelScope scope,
    SubtitleAiOutput output,
    bool Function() current, {
    bool apply = true,
  }) async {
    final pair = const Uuid().v4(), media = await _media(scope);
    Future<StoredSubtitle> retain(SubtitleDocument document, String? language) => store.retain(
      media,
      document,
      language: language,
      origin: SubtitleOrigin.ai,
      coverage: output.coverage,
      pairId: pair,
    );
    final original = await retain(output.original, isChineseSubtitle(output.language) ? null : output.language);
    final chinese = await retain(output.chinese, 'zh');
    if (!current()) return;
    if (!apply) {
      final saved = await store.save(original);
      if (saved.state == SubtitleSaveState.saved) await store.save(chinese);
      return;
    }
    scope.userApplied = true;
    final id = await _apply(scope, chinese, cues: output.cues);
    scope.originals[id] = original;
    unawaited(_save(scope, id, chinese, original: original));
  }

  @override
  Future<void> cancelAi() async {
    final scope = _scope, timeline = _timeline;
    final output = _ai.cancel();
    _resumeAfterBoundary = false;
    _run?.cancel();
    _run = null;
    _tapFinished = null;
    _preparing = null;
    _emit();
    bool current() => identical(scope, _scope) && timeline == _timeline && _run == null;
    if (scope != null && output != null) {
      await _persistAi(scope, output, current, apply: false);
    }
  }

  void _resetAudio() {
    ++_timeline;
    _alignment?.cancel();
    _run?.cancel();
    _tapFinished = null;
    _run = null;
    _preparing = null;
    _ai.invalidate();
  }

  void _audioBoundary(SubtitleAudioBoundary boundary) {
    if (boundary.sourceGeneration != _scope?.source.generation || session.snapshot.phase == PlaybackPhase.ended) return;
    if (!boundary.ready) {
      _resumeAfterBoundary |= _run != null;
      _resetAudio();
      _emit();
    } else if (_resumeAfterBoundary) {
      _resumeAfterBoundary = false;
      _audioId = session.snapshot.selectedAudioId;
      if (boundary.streamIndex case final index?) {
        final expected = '${boundary.sourceGeneration}:$index';
        _expectedAudioId = expected == _audioId ? null : expected;
      }
      unawaited(_startAi(position: boundary.position, streamIndex: boundary.streamIndex).catchError((Object _) {}));
    }
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _scope?.close();
    _scope = null;
    _resetAudio();
    onClosed();
    _emit();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _ai.close();
    await _changes.close();
  }
}

class _PanelScope {
  _PanelScope(this.source, this.search);
  final PlaybackSubtitleSource source;
  final SubtitleSearchScope search;
  final _closed = Completer<void>();
  final retained = <String, StoredSubtitle>{}, originals = <String, StoredSubtitle>{};
  final dialogue = <String, List<SubtitleCue>?>{};
  final saves = <String, SubtitleSaveResult>{};
  final documents = <String, Future<SubtitleDocument?>>{};
  final edits = <SubtitleAiCancellation>{};
  Future<SubtitleItem>? item;
  var scanning = false, userApplied = false;

  Future<T> guard<T>(Future<T> work) => Future.any([work, _closed.future.then<T>((_) => throw _expired)]);
  void close() {
    _closed.complete();
    search.close();
    for (final edit in edits.toList()) {
      edit.cancel();
    }
  }
}
