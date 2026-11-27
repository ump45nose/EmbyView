import 'dart:async';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../data/diagnostics_exporter.dart';
import '../embyview.dart';
import '../playback/playback_subtitle_input.dart';
import '../playback/track_selection.dart';
import 'ai/subtitle_ai.dart';
import 'audio/subtitle_audio.dart';
import 'emby_subtitle_library.dart';
import 'jobs/subtitle_season_queue.dart' show missingSubtitleCoverage;
import 'model/subtitle_document.dart';
import 'sources/subtitle_sources.dart';
import 'store/subtitle_store.dart';

const _expired = EmbyViewFailure('字幕所属的播放或用户已变更。', retryable: true);
const _unreadable = EmbyViewFailure('此轨没有可取得的文本原文。', code: 'subtitle_text_unavailable');
const _window = Duration(seconds: 20);
const _minimumLead = Duration(seconds: 12);

typedef _RunCheckpoint = ({Duration start, int? audioIndex, SubtitleAiOutput? output});

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
  var _timeline = 0, _runNumber = 0, _resumeAfterBoundary = false;
  String? _audioId, _expectedAudioId, _liveTrackId;
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
      final previous = _scope?.source;
      final sameMedia =
          valid && previous?.target.itemId == source.target.itemId && previous?.mediaSourceId == source.mediaSourceId;
      final restoring = sameMedia && (_scope?.autoSelectionSettled == true || _scope?.userApplied == true);
      final resumeAi = sameMedia && (_liveTrackId != null || _scope?.resumeAi == true);
      final reselect = _liveTrackId != null
          ? snapshot.selectedTrackId == _liveTrackId
          : _scope?.reselectRevision == input.subtitleSelectionRevision;
      _RunCheckpoint? checkpoint;
      if (resumeAi && !_resumeAfterBoundary && source.subtitleSwitchFrom == previous?.generation) {
        final output = _ai.checkpoint ?? _scope?.checkpoint?.output;
        final start = _ai.run?.startedAt ?? _preparing?.startedAt ?? _scope?.checkpoint?.start;
        if (start != null) {
          checkpoint = (start: start, audioIndex: _scope?.runAudioIndex, output: output);
        }
      }
      _scope?.close();
      _scope = !valid ? null : _PanelScope(source, sources.openScope());
      _resumeAfterBoundary = false;
      _resetAudio();
      if (restoring) _scope!.userApplied = true;
      if (resumeAi) {
        _scope!.checkpoint = checkpoint;
        _scope!.runAudioIndex = checkpoint?.audioIndex;
        _scope!.resumeAi = true;
        _scope!.reselectRevision = reselect ? input.subtitleSelectionRevision : null;
      }
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
          _resetAudio(continueLive: true);
        }
      }
      if (!scope.scanning &&
          (play.phase == PlaybackPhase.playing ||
              play.phase == PlaybackPhase.paused ||
              play.phase == PlaybackPhase.buffering)) {
        scope.scanning = true;
        unawaited(_loadNas(scope, play.selectedSubtitleId));
      }
      if (scope.resumeAi &&
          !scope.aiResumeScheduled &&
          (play.phase == PlaybackPhase.playing || play.phase == PlaybackPhase.paused)) {
        scope.aiResumeScheduled = true;
        // Some engine track switches reopen the same file. Continue with
        // its new generation as soon as the new playhead is available.
        scheduleMicrotask(() {
          if (identical(scope, _scope) && scope.resumeAi) {
            unawaited(
              _startAi(
                resume: scope.reselectRevision != input.subtitleSelectionRevision,
                checkpoint: scope.checkpoint,
              ),
            );
          }
        });
      }
      for (final track in play.subtitleTracks) {
        if (track.id != _liveTrackId &&
            (track.id == play.selectedSubtitleId || scope.hasNas && track.source == PlaybackTrackSource.embyExternal) &&
            !scope.retained.containsKey(track.id) &&
            !scope.documents.containsKey(track.id)) {
          unawaited(_document(scope, track.id));
        }
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
    final run = _preparing ?? _ai.run;
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
      cues: selected != null && selected == _liveTrackId ? run?.cues ?? const [] : scope?.dialogue[selected],
      ai: scope == null ? null : run,
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

  Future<String> _translationContext(_PanelScope scope) async {
    try {
      return subtitleTranslationContext((await _item(scope)).item);
    } on EmbyViewFailure {
      // Cached audio and subtitle text remain usable when optional metadata is unavailable.
      _check(scope);
      return '';
    }
  }

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

  Future<SubtitleScan> _scan(_PanelScope scope) => scope.scan ??= _media(scope).then(store.scan);

  Future<void> _loadNas(_PanelScope scope, String? initiallySelected) async {
    final selection = input.subtitleSelectionRevision;
    try {
      final scan = await _scan(scope);
      _check(scope);
      scope.hasNas = scan.nasTracks.isNotEmpty;
      if (scope.hasNas) {
        await Future.wait([
          for (final track in session.snapshot.subtitleTracks)
            if (track.source == PlaybackTrackSource.embyExternal) _document(scope, track.id),
        ]);
      }
      _check(scope);
      final indexedIds = session.snapshot.subtitleTracks
          .where((track) => track.source == PlaybackTrackSource.embyExternal)
          .map((track) => track.id)
          .toSet();
      final indexed = <String, String>{
        for (final entry in scope.retained.entries)
          if (indexedIds.contains(entry.key)) entry.value.id: entry.key,
      };
      final available = <(StoredSubtitle, String)>[];
      // Keep Emby's playback ID for already indexed files. Register every
      // other sidecar independently of the automatic selection preference.
      // Reconcile before any native registration which may be waiting on a
      // source restoration; no duplicate logical track needs that RPC.
      for (final track in scan.nasTracks) {
        if (indexed[track.id] case final id?) {
          _check(scope);
          await input.reconcileIndexedSubtitle(
            generation: scope.source.generation,
            indexedTrackId: id,
            contentKey: track.registrationKey,
          );
        }
      }
      for (final track in scan.nasTracks) {
        _check(scope);
        if (indexed[track.id] case final id?) {
          available.add((track, id));
          continue;
        }
        try {
          final id = await _register(scope, track, cues: scan.dialogue(track));
          scope.saves[id] = const SubtitleSaveResult(state: SubtitleSaveState.saved);
          available.add((track, id));
          _emit();
        } catch (_) {
          _check(scope);
          // A single unreadable sidecar must not hide the remaining tracks.
        }
      }
      _check(scope);
      final play = session.snapshot;
      final prefs = preferences();
      if (prefs.subtitleAutoMode == SubtitleAutoMode.off ||
          scope.source.subtitlesExplicitlyDisabled ||
          play.selectedSubtitleId != initiallySelected ||
          selection != input.subtitleSelectionRevision ||
          scope.userApplied) {
        return;
      }
      if (prefs.subtitleAutoMode == SubtitleAutoMode.foreignOnly) {
        final activeAudio = play.audioTracks
            .where((track) => track.id == play.selectedAudioId)
            .firstOrNull;
        if (isNativeAudioForSubtitlePolicy(
          prefs: prefs,
          activeAudioLanguage: activeAudio?.language,
          activeAudioTitle: activeAudio?.name,
        )) {
          return;
        }
      }
      final preferredLanguages = prefs.subtitleLanguages;
      if (preferredLanguages.isEmpty) return;

      final currentTrack = initiallySelected == null
          ? null
          : play.subtitleTracks.where((track) => track.id == initiallySelected).firstOrNull;
      final currentComplete =
          currentTrack != null &&
          !currentTrack.isForced &&
          (scope.retained[currentTrack.id]?.isComplete ?? true);
      final currentRank = currentTrack == null
          ? null
          : rankTrackLanguage(
              preferredLanguages,
              language: currentTrack.language,
              title: currentTrack.name,
            );

      ({String id, TrackLanguageRank rank, bool complete, int sourcePriority})? best;
      void consider({
        required String id,
        required TrackLanguageRank? rank,
        required bool complete,
        required int sourcePriority,
      }) {
        if (rank == null) return;
        final current = best;
        if (current == null) {
          best = (id: id, rank: rank, complete: complete, sourcePriority: sourcePriority);
          return;
        }
        final byRank = compareTrackLanguageRank(rank, current.rank);
        if (byRank < 0 ||
            (byRank == 0 && complete != current.complete && complete) ||
            (byRank == 0 && complete == current.complete && sourcePriority < current.sourcePriority)) {
          best = (id: id, rank: rank, complete: complete, sourcePriority: sourcePriority);
        }
      }

      for (final (stored, id) in available) {
        if (stored.isForced) continue;
        consider(
          id: id,
          rank: rankTrackLanguage(
            preferredLanguages,
            language: stored.language,
            title: stored.filename,
          ),
          complete: stored.isComplete,
          sourcePriority: stored.isComplete ? 0 : 2,
        );
      }
      for (final track in play.subtitleTracks) {
        if (track.isForced) continue;
        if (track.source != PlaybackTrackSource.embedded &&
            track.source != PlaybackTrackSource.embyExternal) {
          continue;
        }
        final complete = scope.retained[track.id]?.isComplete ?? true;
        if (!complete) continue;
        consider(
          id: track.id,
          rank: rankTrackLanguage(
            preferredLanguages,
            language: track.language,
            title: track.name,
          ),
          complete: true,
          sourcePriority: 1,
        );
      }

      final chosen = best;
      String? preferred;
      if (chosen != null) {
        final alreadyOptimal =
            currentRank != null &&
            currentComplete &&
            compareTrackLanguageRank(chosen.rank, currentRank) >= 0;
        if (!alreadyOptimal && chosen.id != initiallySelected) {
          preferred = chosen.id;
        }
      }
      if (preferred != null) await session.selectSubtitle(preferred);
      EvDiagnosticsLog.instance.record(
        'subtitle',
        'load_nas',
        details: {
          'itemId': scope.source.target.itemId,
          'nasTracks': scan.nasTracks.length,
          'autoSelected': preferred != null,
        },
      );
    } catch (_) {
      // Missing NAS or a source change leaves the playback engine's track selected.
    } finally {
      scope.autoSelectionSettled = true;
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
        final scan = track.source == PlaybackTrackSource.embyExternal ? await _scan(scope) : null;
        _check(scope);
        final matched = scan?.matchExternal(
          language: track.language,
          filename: row['Path'] as String?,
          document: document,
        );
        if (matched != null) {
          scope.retained[id] = matched;
          scope.saves[id] = const SubtitleSaveResult(
            state: SubtitleSaveState.saved,
            index: SubtitleIndexState.recognized,
          );
          scope.dialogue[id] = scan!.dialogue(matched);
        } else {
          scope.dialogue[id] = document?.cues;
        }
        _emit();
        return matched?.document ?? document;
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
    final groups = await scope.search.search(
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
    var totalHits = 0;
    for (final g in groups) {
      totalHits += g.candidates.length;
    }
    EvDiagnosticsLog.instance.record(
      'subtitle',
      'online_search',
      details: {
        'itemId': scope.source.target.itemId,
        'groups': groups.length,
        'candidates': totalHits,
      },
    );
    return groups;
  }

  bool Function() _selectionRequest(_PanelScope scope) {
    scope.userApplied = true;
    final request = ++scope.selectionRequest, selection = input.subtitleSelectionRevision;
    return () => scope.selectionRequest == request && input.subtitleSelectionRevision == selection;
  }

  @override
  Future<void> useCandidate(SubtitleCandidate candidate) async {
    final scope = _active;
    final select = _selectionRequest(scope);
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
    await _use(scope, document, language, SubtitleOrigin.online, select: select, candidateId: candidate.id);
    EvDiagnosticsLog.instance.record(
      'subtitle',
      'online_applied',
      details: {
        'itemId': scope.source.target.itemId,
        'source': candidate.source.name,
        'lang': ?language,
      },
    );
  }

  Future<String> _register(
    _PanelScope scope,
    StoredSubtitle track, {
    List<SubtitleCue>? cues,
    String? liveTrackId,
  }) async {
    _check(scope);
    final id = await store.register(track, input, generation: scope.source.generation, liveTrackId: liveTrackId);
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
    required bool Function() select,
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
    final id = await _register(scope, track);
    if (select()) await session.selectSubtitle(id);
    _check(scope);
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
    final select = _selectionRequest(scope);
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
          : await processor.translate(
              document,
              cancellation: cancellation,
              mediaContext: await _translationContext(scope),
            );
      cancellation.check();
      if (identical(document, edited)) {
        throw const EmbyViewFailure('未找到足够一致的对白锚点，无法校正。', code: 'subtitle_alignment_unavailable');
      }
      final language = play.subtitleTracks.where((track) => track.id == id).firstOrNull?.language;
      final original = scope.retained[id], duration = play.duration;
      await _use(
        scope,
        edited,
        align ? language : 'zh',
        align ? (original?.origin ?? SubtitleOrigin.nas) : SubtitleOrigin.ai,
        select: select,
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

  // A tap can overlap a paid window after the engine reopens the file.
  // Cut PCM at sample boundaries before giving uncovered audio to the ASR.
  Iterable<SubtitleAudioSegment> _uncoveredPcm(SubtitleAudioSegment segment, List<TimeRange> covered) sync* {
    for (final gap in missingSubtitleCoverage(segment.end, [
      TimeRange(start: Duration.zero, end: segment.start),
      ...covered,
    ])) {
      if (gap.start == segment.start && gap.end == segment.end) {
        yield segment;
        continue;
      }
      int frame(Duration time) => ((time - segment.start).inMicroseconds * segment.sampleRate / 1000000).round().clamp(
        0,
        segment.pcm.length ~/ 4,
      );
      final first = frame(gap.start), last = frame(gap.end);
      if (last > first) {
        yield SubtitleAudioSegment(
          start: gap.start,
          sourceStart: segment.sourceStart + (gap.start - segment.start),
          pcm: Uint8List.sublistView(segment.pcm, first * 4, last * 4),
          sourceGeneration: segment.sourceGeneration,
          timelineGeneration: segment.timelineGeneration,
          discontinuity: true,
        );
      }
    }
  }

  Stream<SubtitleAudioSegment> _audio(
    PlaybackSubtitleSource source,
    Duration start,
    Duration? end,
    int? index,
    SubtitleAiCancellation cancellation, {
    List<TimeRange> covered = const [],
  }) async* {
    if (end == null || start >= end) return;
    final readerCancellation = SubtitleAudioCancellation();
    cancellation.addListener(readerCancellation.cancel);
    try {
      for (final gap in missingSubtitleCoverage(end, [TimeRange(start: Duration.zero, end: start), ...covered])) {
        for (var cursor = gap.start; cursor < gap.end;) {
          final next = cursor + _window < gap.end ? cursor + _window : gap.end;
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
      }
    } finally {
      cancellation.removeListener(readerCancellation.cancel);
    }
  }

  @override
  Future<void> startAi() => _startAi();

  Future<void> _startAi({Duration? position, int? streamIndex, bool resume = false, _RunCheckpoint? checkpoint}) async {
    final scope = _active;
    scope.resumeAi = false;
    ++_runNumber;
    final play = session.snapshot, timeline = _timeline;
    final index = streamIndex ?? int.tryParse(play.selectedAudioId?.split(':').last ?? '');
    scope.runAudioIndex = index;
    scope.checkpoint = checkpoint?.audioIndex == index ? checkpoint : null;
    final seed = scope.checkpoint;
    final start = seed?.start ?? position ?? play.position;
    final covered = seed?.output?.coverage ?? const <TimeRange>[];
    final language = play.audioTracks.where((track) => track.id == '${play.generation}:$index').firstOrNull?.language;
    _run?.cancel();
    _ai.invalidate();
    final liveId = _liveTrackId = resume && _liveTrackId != null
        ? _liveTrackId!
        : '${play.generation}:live-${const Uuid().v4()}';
    scope.userApplied = true;
    final cancellation = _run = SubtitleAiCancellation();
    final finished = _tapFinished = Completer<void>();
    bool current() => identical(_scope, scope) && timeline == _timeline && identical(_run, cancellation);
    _preparing = AiRun(
      generation: play.generation,
      state: AiRunState.preparing,
      startedAt: start,
      coverage: covered,
      cues: seed?.output?.cues ?? const [],
    );
    _emit();
    EvDiagnosticsLog.instance.record(
      'subtitle',
      'ai_start',
      details: {
        'itemId': scope.source.target.itemId,
        'gen': play.generation,
        'resume': resume,
        'startSec': start.inSeconds,
      },
    );
    final reader = StreamIterator(_audio(scope.source, start, play.duration, index, cancellation, covered: covered));
    var independent = false;
    try {
      await input.setLiveSubtitle(liveId, generation: play.generation, select: !resume);
      if (!current()) return;
      await (checkAi ?? processor.checkGeneration)();
      final mediaContext = await _translationContext(scope);
      if (!current()) return;
      var hasAudio = false;
      try {
        final measured = Stopwatch()..start();
        hasAudio = await reader.moveNext();
        independent = hasAudio
            ? seed != null ||
                  measured.elapsed <= _window - _minimumLead &&
                      reader.current.end - session.snapshot.position >= _minimumLead
            : seed != null &&
                  play.duration != null &&
                  missingSubtitleCoverage(play.duration!, [
                    TimeRange(start: Duration.zero, end: start),
                    ...covered,
                  ]).isEmpty;
      } catch (_) {
        // Unavailable independent audio uses the existing playback tap.
      }
      if (!independent) await reader.cancel();
      if (!current()) return;
      Stream<SubtitleAudioSegment> ahead() async* {
        if (!hasAudio) return;
        do {
          yield reader.current;
        } while (await reader.moveNext());
      }

      final audio = independent
          ? ahead()
          : playbackSubtitleAudio(
              input.audioInput,
              sourceGeneration: play.generation,
              start: start,
              finish: finished.future,
            );
      _preparing = null;
      final output = await _ai.start(
        generation: play.generation,
        timelineGeneration: timeline,
        position: start,
        initialOutput: seed?.output,
        audio: covered.isEmpty ? audio : audio.expand((segment) => _uncoveredPcm(segment, covered)),
        followsPlayhead: !independent,
        isCurrent: current,
        language: language,
        mediaContext: mediaContext,
        cancellation: cancellation,
      );
      if (output != null && current()) {
        await _persistAi(scope, output, current, liveId: session.snapshot.phase == PlaybackPhase.ended ? null : liveId);
        EvDiagnosticsLog.instance.record(
          'subtitle',
          'ai_completed',
          details: {
            'itemId': scope.source.target.itemId,
            'gen': play.generation,
            'cues': output.cues.length,
          },
        );
      }
    } catch (error) {
      if (current()) {
        final failure = error is EmbyViewFailure ? error : const EmbyViewFailure('无法启用此轮 AI 字幕。', retryable: true);
        EvDiagnosticsLog.instance.record(
          'subtitle',
          'ai_failed',
          level: 'WARN',
          details: {
            'itemId': scope.source.target.itemId,
            'gen': play.generation,
            'code': failure.code ?? 'ai_failed',
          },
        );
        _preparing = AiRun(generation: play.generation, state: AiRunState.failed, startedAt: start, failure: failure);
        _emit();
      }
    } finally {
      await reader.cancel();
      try {
        if (current() && _liveTrackId == liveId) await _retireLive(liveId);
      } finally {
        if (identical(_run, cancellation)) {
          _tapFinished = null;
          _run = null;
          if (session.snapshot.phase == PlaybackPhase.ended) _refresh();
        }
      }
    }
  }

  Future<void> _persistAi(_PanelScope scope, SubtitleAiOutput output, bool Function() current, {String? liveId}) async {
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
    if (liveId == null) {
      final saved = await store.save(original);
      if (saved.state == SubtitleSaveState.saved) await store.save(chinese);
      return;
    }
    final id = await _register(scope, chinese, cues: output.cues, liveTrackId: liveId);
    if (!current()) return;
    scope.originals[id] = original;
    unawaited(_save(scope, id, chinese, original: original));
    if (_ai.run?.state == AiRunState.completed) {
      await input.endLiveSubtitle(liveId, replacementId: id);
      if (_liveTrackId == liveId) _liveTrackId = null;
    }
  }

  @override
  Future<void> cancelAi() async {
    final scope = _scope, timeline = _timeline, runNumber = _runNumber;
    final seed = scope?.checkpoint?.output;
    final resuming = scope?.resumeAi == true || _run != null;
    final output = _ai.cancel() ?? (resuming && seed?.cues.isNotEmpty == true ? seed : null);
    if (scope != null) {
      scope.resumeAi = false;
      scope.checkpoint = null;
    }
    _resumeAfterBoundary = false;
    _run?.cancel();
    _run = null;
    _tapFinished = null;
    _preparing = null;
    final liveId = _liveTrackId;
    if (liveId != null) await _retireLive(liveId);
    _emit();
    EvDiagnosticsLog.instance.record(
      'subtitle',
      'ai_cancelled',
      details: {
        if (scope != null) 'itemId': scope.source.target.itemId,
        'persisted': output != null,
      },
    );
    bool current() => identical(scope, _scope) && timeline == _timeline && runNumber == _runNumber;
    if (scope != null && output != null) {
      await _persistAi(scope, output, current);
    }
  }

  Future<void> _retireLive(String id) {
    if (_liveTrackId == id) _liveTrackId = null;
    return input.endLiveSubtitle(id);
  }

  void _resetAudio({bool continueLive = false}) {
    ++_timeline;
    _alignment?.cancel();
    _run?.cancel();
    _tapFinished = null;
    _run = null;
    _preparing = null;
    _ai.invalidate();
    final liveId = _liveTrackId;
    if (liveId == null) return;
    if (continueLive && _scope != null) {
      // Keep the viewer's current choice through the seek/track-change gap.
      // A fresh ID invalidates pending registration, selection and old cues.
      final generation = _scope!.source.generation;
      final next = _liveTrackId = '$generation:live-${const Uuid().v4()}';
      unawaited(input.setLiveSubtitle(next, generation: generation, select: false).catchError((Object _) {}));
    } else {
      unawaited(_retireLive(liveId).catchError((Object _) {}));
    }
  }

  void _audioBoundary(SubtitleAudioBoundary boundary) {
    if (boundary.sourceGeneration != _scope?.source.generation || session.snapshot.phase == PlaybackPhase.ended) return;
    if (!boundary.ready) {
      _scope?.checkpoint = null;
      _resumeAfterBoundary |= _run != null;
      _resetAudio(continueLive: _resumeAfterBoundary);
      _emit();
    } else if (_resumeAfterBoundary) {
      _resumeAfterBoundary = false;
      _audioId = session.snapshot.selectedAudioId;
      if (boundary.streamIndex case final index?) {
        final expected = '${boundary.sourceGeneration}:$index';
        _expectedAudioId = expected == _audioId ? null : expected;
      }
      unawaited(
        _startAi(
          position: boundary.position,
          streamIndex: boundary.streamIndex,
          resume: true,
        ).catchError((Object _) {}),
      );
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
  Future<SubtitleScan>? scan;
  bool resumeAi = false;
  _RunCheckpoint? checkpoint;
  int? runAudioIndex;
  int? reselectRevision;
  var selectionRequest = 0;
  var scanning = false, aiResumeScheduled = false, userApplied = false, hasNas = false, autoSelectionSettled = false;

  Future<T> guard<T>(Future<T> work) => Future.any([work, _closed.future.then<T>((_) => throw _expired)]);
  void close() {
    _closed.complete();
    search.close();
    for (final edit in edits.toList()) {
      edit.cancel();
    }
  }
}
