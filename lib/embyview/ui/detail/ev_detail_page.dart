import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_episodes.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_hero.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_sections.dart';
import 'package:moonfin/embyview/ui/detail/ev_theme_capsule.dart';
import 'package:moonfin/embyview/ui/kit.dart';

export 'ev_episode_card.dart';

/// Complete EmbyView movie & series detail page mirroring `vDetail`, `epCard`,
/// `themePlay`, and `themeStop` from `.spec/mockups/proto.js` & `proto.css`.
class EvDetailPage extends StatefulWidget {
  const EvDetailPage({super.key, required this.itemId, this.enableAnimations = true, this.onOpenItem, this.onPlayTarget});
  final String itemId;
  final bool enableAnimations;
  final ValueChanged<String>? onOpenItem;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin)? onPlayTarget;
  @override State<EvDetailPage> createState() => _EvDetailPageState();
}

class _EvDetailPageState extends State<EvDetailPage> {
  final _scroll = ScrollController();
  EvScope? _scope;
  EmbyViewData? _attachedData;
  String? _attachedSessionId, _subError, _hoveredEpId;
  StreamSubscription<LocalPreferences>? _prefsSub;
  StreamSubscription<List<SeasonJob>>? _jobsSub;

  LocalPreferences _prefs = const LocalPreferences();
  int _loadToken = 0, _seasonIdx = 0, _bdIdx = 0, _stillIdx = 0, _cdSec = 0, _cdTotal = 0;
  bool _loading = true, _loadingEps = false, _quoting = false, _trailerLive = false, _stillLive = false;
  bool _epHovering = false, _themeStarted = false, _ownsChrome = false;
  Object? _error;

  MediaDetail? _detail;
  MediaQuality? _quality;
  SubtitleAvailability? _itemAvail;
  ThemeMedia _themeMedia = const ThemeMedia();
  List<PersonCredit> _people = const [];
  List<MediaCard> _similar = const [];
  List<ArtworkRef> _safeStills = const [];
  List<SeasonSummary> _seasons = const [];
  List<SeasonJob> _jobs = const [];
  final Map<String, SeasonEpisodes> _epCache = {};
  final Map<String, SubtitleAvailability> _epAvail = {};
  final Set<String> _doneJobEpIds = {};
  Timer? _bdT, _cdT, _stillT, _epT;

  @override void initState() { super.initState(); _scroll.addListener(_onScroll); }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context);
    final changed = _scope == null || !identical(_attachedData, scope.services.data) || _attachedSessionId != scope.services.sessionId;
    _scope = scope;
    if (!changed) return;
    _attachedData = scope.services.data; _attachedSessionId = scope.services.sessionId;
    _attachServices(scope);
    _ownsChrome = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scope.shell.updateChrome(hideTabs: true, hideAvatar: true, showBack: true, clearTitlePlate: true, rightActions: const [], topFade: 0, scrolled: false);
      scope.stage..setMode(EvStageMode.detail, detailNoBlur: false)..setScrollProgress(0)..setVeilLifted(false)..clearPreviewBackdrop();
    });
    unawaited(_loadAll());
  }

  @override
  void didUpdateWidget(EvDetailPage old) {
    super.didUpdateWidget(old);
    if (old.itemId == widget.itemId) return;
    _stopTimers(stopMedia: true);
    if (_scroll.hasClients && _scroll.offset != 0) _scroll.jumpTo(0);
    unawaited(_loadAll());
  }

  void _attachServices(EvScope scope) {
    unawaited(_prefsSub?.cancel()); unawaited(_jobsSub?.cancel());
    _prefs = scope.services.preferences.current;
    _prefsSub = scope.services.preferences.changes.listen((next) {
      if (!mounted) return;
      final prev = _prefs; _prefs = next;
      if (prev.detailTrailerDelay != next.detailTrailerDelay) _resetCountdown();
      if (!prev.themeMusic && next.themeMusic && _themeMedia.songs.isNotEmpty) _startThemeIfEnabled();
      if (prev.themeMusic && !next.themeMusic) { _themeStarted = false; unawaited(_scope?.immersion.stopTheme()); }
      setState(() {});
    });
    final subs = scope.services.subtitles;
    _jobsSub = subs?.jobs.listen((jobs) {
      if (!mounted) return;
      final done = <String>[];
      for (final j in jobs) {
        if (j.seriesId != widget.itemId) continue;
        for (final ep in j.episodes) {
          if (ep.state == EpisodeJobState.completed && _doneJobEpIds.add(ep.episodeId)) done.add(ep.episodeId);
        }
      }
      setState(() => _jobs = jobs);
      for (final id in done) { unawaited(_loadEpAvail(id, force: true)); }
    });
    if (subs == null) _jobs = const [];
  }

  List<ArtworkRef> get _backdrops => _detail?.card.art.backdrops ?? const [];
  ArtworkPlan _bdPlan(int i) {
    final d = _detail;
    if (d == null) return const ArtworkPlan();
    return _backdrops.isEmpty ? d.card.art.stage
        : ArtworkPlan(layers: [ArtworkLayer(source: _backdrops[i.clamp(0, _backdrops.length - 1)], fit: ArtworkFit.cover)], fallbackTitle: d.card.title);
  }

  Future<void> _loadAll() async {
    final scope = _scope, data = scope?.services.data, id = widget.itemId, token = ++_loadToken;
    _stopTimers(stopMedia: false);
    _detail = null; _quality = null; _itemAvail = null; _subError = null;
    _people = const []; _similar = const []; _themeMedia = const ThemeMedia(); _safeStills = const []; _seasons = const [];
    _epCache.clear(); _epAvail.clear(); _doneJobEpIds.clear();
    _seasonIdx = _bdIdx = 0; _themeStarted = false;

    if (scope == null || data == null) { if (mounted) setState(() { _loading = false; _error = null; }); return; }
    if (scope.services.playback != null) unawaited(_safe(() => scope.services.playback!.prepare(id), null));
    if (mounted) setState(() { _loading = true; _error = null; });

    final detailF = data.detail(id);
    final peopleF = _safe(() => data.people(id), const <PersonCredit>[]);
    final simF = _safe(() => data.similar(id, limit: 16), const <MediaCard>[]);
    final themeF = _safe(() => data.themeMedia(id), const ThemeMedia());
    final qualF = _safe<MediaQuality?>(() => data.quality(id), null);

    late final MediaDetail detail;
    try { detail = await detailF; } catch (e) { if (mounted && token == _loadToken) setState(() { _error = e; _loading = false; }); return; }
    if (!mounted || token != _loadToken) return;

    final isSeries = detail.card.kind == MediaKind.series;
    setState(() { _detail = detail; _quality = detail.card.quality; _loading = false; _error = null; _loadingEps = isSeries; });
    scope.stage..setMode(EvStageMode.detail, detailNoBlur: isSeries)..setScrollProgress(0)..setVeilLifted(false)..clearPreviewBackdrop()..setBaseBackdrop(_bdPlan(0));
    _startBdRotation();

    if (scope.services.subtitles != null) {
      unawaited(_safe<SubtitleAvailability?>(() => scope.services.subtitles!.availability(id), null).then((av) {
        if (mounted && token == _loadToken && av != null) setState(() => _itemAvail = av);
      }));
    }

    final (people, sim, tm, qual) = (await peopleF, await simF, await themeF, await qualF);
    if (!mounted || token != _loadToken) return;
    setState(() { _people = people; _similar = sim; _themeMedia = tm; _quality = _detail?.card.quality ?? qual; });
    _startThemeIfEnabled();

    if (isSeries) await _loadSeries(data, id, token);
    if (mounted && token == _loadToken) _resetCountdown();
  }

  Future<void> _loadSeries(EmbyViewData data, String seriesId, int token) async {
    final (seasons, stills) = (await _safe(() => data.seasons(seriesId), const <SeasonSummary>[]), await _safe(() => data.safeEpisodeStills(seriesId), const <ArtworkRef>[]));
    if (!mounted || token != _loadToken) return;
    setState(() { _seasons = seasons; _safeStills = stills; });
    if (seasons.isEmpty) { setState(() => _loadingEps = false); return; }

    var chosen = 0;
    for (var i = 0; i < seasons.length; i++) {
      final se = await _safe<SeasonEpisodes?>(() => data.episodes(seriesId, seasons[i].id), null);
      if (!mounted || token != _loadToken) return;
      if (se != null) { _epCache[seasons[i].id] = se; if (se.episodes.any((e) => e.played != true)) { chosen = i; break; } }
    }
    if (!mounted || token != _loadToken) return;
    setState(() { _seasonIdx = chosen; _loadingEps = false; });
    _querySeasonAvail();
  }

  Future<void> _selectSeason(int idx) async {
    if (idx < 0 || idx >= _seasons.length || idx == _seasonIdx) return;
    setState(() { _seasonIdx = idx; _subError = null; });
    final s = _seasons[idx];
    if (_epCache.containsKey(s.id)) { _querySeasonAvail(); return; }
    final data = _scope?.services.data;
    if (data == null) return;
    final token = _loadToken;
    setState(() => _loadingEps = true);
    final se = await _safe<SeasonEpisodes?>(() => data.episodes(widget.itemId, s.id), null);
    if (!mounted || token != _loadToken) return;
    setState(() { if (se != null) _epCache[s.id] = se; _loadingEps = false; });
    _querySeasonAvail();
  }

  SeasonSummary? get _curSeason => _seasons.isNotEmpty ? _seasons[_seasonIdx.clamp(0, _seasons.length - 1)] : null;
  SeasonEpisodes? get _curEps => _curSeason == null ? null : _epCache[_curSeason!.id];
  SeasonJob? get _curJob {
    final s = _curSeason;
    if (s == null) return null;
    SeasonJob? last;
    for (final j in _jobs) { if (j.seriesId == widget.itemId && j.seasonId == s.id) { if (EvDetailEpisodesSection.isJobActive(j)) return j; last = j; } }
    return last;
  }

  void _querySeasonAvail() {
    if (_scope?.services.subtitles == null || _curEps == null) return;
    for (final ep in _curEps!.episodes) { unawaited(_loadEpAvail(ep.card.id)); }
  }

  Future<void> _loadEpAvail(String epId, {bool force = false}) async {
    final subs = _scope?.services.subtitles;
    if (subs == null || (!force && _epAvail.containsKey(epId))) return;
    final token = _loadToken;
    try { final av = await subs.availability(epId); if (mounted && token == _loadToken) setState(() => _epAvail[epId] = av); } catch (_) {}
  }

  Future<void> _requestQuote() async {
    final subs = _scope?.services.subtitles, s = _curSeason;
    if (subs == null || s == null || _quoting) return;
    setState(() { _quoting = true; _subError = null; });
    final token = _loadToken;
    try {
      final q = await subs.quoteSeason(widget.itemId, s.id);
      if (!mounted || token != _loadToken) return;
      setState(() => _quoting = false);
      await showGeneralDialog<bool>(
        context: context, barrierDismissible: true, barrierLabel: '关闭费用估算', transitionDuration: EvDurations.fast,
        barrierColor: EvTheme.of(context).isPaper ? const Color.fromRGBO(250, 249, 245, 0.65) : const Color.fromRGBO(0, 0, 0, 0.55),
        pageBuilder: (_, _, _) => EvSeasonQuoteDialog(quote: q, onConfirm: (quote) async { await subs.queueSeason(quote); }),
      );
    } catch (e) {
      if (mounted && token == _loadToken) setState(() { _quoting = false; _subError = e is EmbyViewFailure ? e.reason : '暂时无法估算整季费用：$e'; });
    }
  }

  Future<void> _cancelJob(String jobId, {String? epId}) async {
    try { await _scope?.services.subtitles?.cancelJob(jobId, episodeId: epId); }
    catch (e) { if (mounted) setState(() => _subError = e is EmbyViewFailure ? e.reason : '取消失败：$e'); }
  }

  void _startThemeIfEnabled() {
    if (_themeMedia.songs.isEmpty || !_prefs.themeMusic || _scope == null) return;
    _themeStarted = true;
    unawaited(_scope!.immersion.playTheme(_themeMedia.songs.first));
  }

  void _startBdRotation() {
    _bdT?.cancel();
    if (_backdrops.length < 2) return;
    _bdT = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted || _trailerLive || _epHovering || _backdrops.length < 2) return;
      setState(() => _bdIdx = (_bdIdx + 1) % _backdrops.length);
      _scope?.stage.setBaseBackdrop(_bdPlan(_bdIdx));
    });
  }

  void _selectBd(int i) {
    if (i < 0 || i >= _backdrops.length) return;
    if (_trailerLive) _stopLive();
    setState(() => _bdIdx = i);
    _scope?.stage.setBaseBackdrop(_bdPlan(i));
    _startBdRotation();
  }

  bool get _hasTrailer => _themeMedia.trailer != null;
  bool get _hasSafeStills => !_hasTrailer && _detail?.card.kind == MediaKind.series && _safeStills.length >= 3;
  bool get _canTrailer => (_prefs.detailTrailerDelay ?? Duration.zero) > Duration.zero && (_hasTrailer || _hasSafeStills);

  void _resetCountdown() {
    _cdT?.cancel(); _cdT = null;
    if (_trailerLive) _stopLive();
    final delay = _prefs.detailTrailerDelay;
    if (!_canTrailer || delay == null) { if (mounted) setState(() { _cdSec = _cdTotal = 0; }); return; }
    final total = math.max(1, delay.inSeconds);
    if (mounted) setState(() { _cdTotal = _cdSec = total; });
    _cdT = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _trailerLive || _epHovering || (_scope?.immersion.isPlayerActive ?? false)) return;
      if (_scroll.hasClients && _scroll.position.pixels > (_scroll.position.hasViewportDimension ? _scroll.position.viewportDimension : 900.0) * 0.3) return;
      if (_cdSec <= 1) { _startLive(); } else { setState(() => _cdSec--); }
    });
  }

  void _startLive() {
    if (!_canTrailer) return;
    _cdT?.cancel(); _cdT = null;
    if (_hasTrailer) {
      setState(() { _trailerLive = true; _stillLive = false; _cdSec = 0; });
      unawaited(_scope?.immersion.showMutedVideo(_themeMedia.trailer, label: '预告片 · 静音'));
      return;
    }
    _stillIdx = 0; setState(() { _trailerLive = _stillLive = true; _cdSec = 0; });
    void show() => _scope?.stage.setBaseBackdrop(ArtworkPlan(layers: [ArtworkLayer(source: _safeStills[_stillIdx % _safeStills.length], fit: ArtworkFit.cover)], fallbackTitle: _detail?.card.title ?? ''));
    show();
    _stillT?.cancel();
    _stillT = Timer.periodic(const Duration(milliseconds: 3200), (_) { if (mounted && _stillLive && _safeStills.isNotEmpty) { _stillIdx = (_stillIdx + 1) % _safeStills.length; show(); } });
  }

  void _stopLive() {
    _stillT?.cancel(); _stillT = null;
    final wasLive = _trailerLive, wasStill = _stillLive;
    _trailerLive = _stillLive = false;
    final d = _prefs.detailTrailerDelay;
    if (d != null && d > Duration.zero) _cdSec = _cdTotal = d.inSeconds;
    if (wasLive) { if (!wasStill) unawaited(_scope?.immersion.stopVideo()); _scope?.stage.setBaseBackdrop(_bdPlan(_bdIdx)); if (mounted) setState(() {}); }
  }

  void _onScroll() {
    final s = _scope;
    if (s == null || !_scroll.hasClients) return;
    final p = _scroll.position, vh = p.hasViewportDimension && p.viewportDimension > 0 ? p.viewportDimension : 900.0;
    s.shell.setScrollOffset(p.pixels); s.stage.setScrollProgress((p.pixels / (vh * 0.6)).clamp(0.0, 1.0));
  }

  void _onEpHover(EpisodeCard ep, bool active) {
    _epT?.cancel(); _epT = null;
    if (active) {
      _hoveredEpId = ep.card.id;
      _epT = Timer(const Duration(milliseconds: 350), () {
        if (!mounted || _hoveredEpId != ep.card.id) return;
        _epHovering = true; if (_trailerLive) _stopLive();
        final st = _scope?.stage;
        if (st != null) {
          final plan = ep.still.layers.isNotEmpty ? ArtworkPlan(layers: [ArtworkLayer(source: ep.still.layers.first.source, fit: ArtworkFit.cover)], fallbackTitle: ep.card.title) : _bdPlan(_bdIdx);
          st..setDetailNoBlur(true)..setVeilLifted(true)..setPreviewBackdrop(plan);
        }
      });
    } else if (_hoveredEpId == ep.card.id) {
      _hoveredEpId = null;
      _epT = Timer(const Duration(milliseconds: 900), () {
        if (!mounted || _hoveredEpId != null) return;
        _epHovering = false;
        final st = _scope?.stage;
        if (st != null) st..setVeilLifted(false)..clearPreviewBackdrop();
      });
    }
  }

  void _playTarget(PlayTarget target, CardArtwork art, Rect? origin) {
    _stopLive();
    final im = _scope?.immersion;
    if (im != null) { unawaited(im.stopTheme()); unawaited(im.stopVideo()); }
    if (widget.onPlayTarget != null) { widget.onPlayTarget!(target, art, origin); return; }
    unawaited(EvPlayer.open(context, target, origin: origin, art: art));
  }

  void _stopTimers({required bool stopMedia}) {
    _bdT?.cancel(); _cdT?.cancel(); _stillT?.cancel(); _epT?.cancel();
    _bdT = _cdT = _stillT = _epT = null;
    _trailerLive = _stillLive = _epHovering = false; _hoveredEpId = null;
    if (stopMedia) { _themeStarted = false; unawaited(_scope?.immersion.stopTheme()); unawaited(_scope?.immersion.stopVideo()); }
  }

  @override
  void dispose() {
    unawaited(_prefsSub?.cancel()); unawaited(_jobsSub?.cancel());
    _stopTimers(stopMedia: false);
    _scroll..removeListener(_onScroll)..dispose();
    final scope = _scope, restore = _ownsChrome;
    if (scope != null) {
      unawaited(scope.immersion.stopTheme());
      scheduleMicrotask(() {
        try { unawaited(scope.immersion.stopVideo()); } catch (_) {}
        try { scope.stage..setVeilLifted(false)..clearPreviewBackdrop(); } catch (_) {}
        if (restore) { try { scope.shell.updateChrome(hideTabs: false, hideAvatar: false, clearShowBack: true); } catch (_) {} }
      });
    }
    super.dispose();
  }

  static Future<T> _safe<T>(Future<T> Function() fn, T fb) async { try { return await fn(); } catch (_) { return fb; } }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), scope = _scope, d = _detail;
    final showTheme = d != null && _themeStarted && _themeMedia.songs.isNotEmpty && _prefs.themeMusic && scope != null;

    return Stack(key: const Key('ev_detail_page'), fit: StackFit.expand, children: [
      ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(key: const Key('ev_detail_scroller'), controller: _scroll, child: _buildBody(t, s, d))),
      if (_stillLive)
        Positioned(left: 0, right: 0, top: s.rem(1.25), child: IgnorePointer(child: Center(child: ClipRRect(
          key: const Key('ev_detail_safe_still_label'), borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16), child: Container(
            height: s.rem(2), padding: EdgeInsets.symmetric(horizontal: s.rem(0.875)), color: const Color.fromRGBO(0, 0, 0, 0.42),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              EvIcon(EvIcons.film, size: s.rem(0.875), color: const Color(0xFFFFFFFF)), SizedBox(width: s.rem(0.5)),
              Text('正片片段', style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: const Color(0xFFFFFFFF))),
            ]),
          )),
        )))),
      if (showTheme)
        Positioned(right: s.rem(1.25), top: s.rem(0.875), child: ListenableBuilder(listenable: scope.immersion, builder: (_, _) {
          final snap = scope.immersion.snapshot;
          return snap.theme == PreviewState.failed ? const SizedBox.shrink()
              : EvThemeCapsule(title: d.card.title, snapshot: snap, enableAnimations: widget.enableAnimations, onToggleMute: () => unawaited(scope.immersion.setThemeMuted(!snap.themeMuted)));
        })),
    ]);
  }

  Widget _buildBody(EvTheme t, EvScale s, MediaDetail? d) {
    if (_error != null && d == null) {
      return SizedBox(height: math.max(0.0, s.vh(100)), child: Center(child: Padding(
        key: const Key('ev_detail_error'), padding: EdgeInsets.symmetric(horizontal: s.gutter),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('无法加载详情', style: t.shelfStyle(s.font(1.5))), SizedBox(height: s.rem(0.75)),
          Text(_error is EmbyViewFailure ? (_error as EmbyViewFailure).reason : '$_error', style: t.bodyStyle(s.font(0.9375), color: t.ink3), textAlign: TextAlign.center),
          SizedBox(height: s.rem(1.5)),
          EvButton.ghost(key: const Key('ev_detail_retry_btn'), label: '重试', small: true, onPressed: () => unawaited(_loadAll())),
        ]),
      )));
    }
    if (_loading && d == null) {
      return Column(key: const Key('ev_detail_loading'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: math.max(0.0, s.vh(100) - s.peek)), const EvShelfSkeleton(style: EvCardStyle.poster, count: 6),
      ]);
    }
    if (d == null) return SizedBox(height: math.max(0.0, s.vh(100)), child: Center(child: Text('未找到条目信息', style: t.shelfStyle(s.font(1.25)))));

    final subsOn = _scope?.services.subtitles != null;
    void open(MediaCard c) => (widget.onOpenItem ?? _scope?.shell.onOpenDetail)?.call(c.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EvDetailHero(
        detail: d, people: _people, seasonsCount: _seasons.isNotEmpty ? _seasons.length : d.card.childCount,
        quality: _quality ?? d.card.quality, backdropCount: _backdrops.length, backdropIndex: _bdIdx,
        onSelectBackdrop: _selectBd, canTrailer: _canTrailer, isTrailerClip: _hasTrailer, trailerLive: _trailerLive,
        countdownSeconds: _cdSec, countdownTotalSeconds: _cdTotal, onToggleTrailer: () => _trailerLive ? _stopLive() : _startLive(), onPlay: _playTarget,
      ),
      if (d.card.kind == MediaKind.series && (_seasons.isNotEmpty || _loadingEps))
        EvDetailEpisodesSection(
          seriesId: widget.itemId, seriesTitle: d.card.title, seasons: _seasons, selectedSeasonIndex: _seasonIdx,
          seasonEpisodes: _curEps, loadingEpisodes: _loadingEps, hideUnwatchedOverview: _prefs.hideUnwatchedOverview,
          navigationStyle: _prefs.navigation, subtitlesEnabled: subsOn, availabilityByEpisode: _epAvail, activeSeasonJob: _curJob,
          completedJobEpisodeIds: _doneJobEpIds, quotingSeason: _quoting, subtitleError: _subError,
          onDismissSubtitleError: () => setState(() => _subError = null),
          onSelectSeason: (i) => unawaited(_selectSeason(i)), onRequestSeasonQuote: () => unawaited(_requestQuote()),
          onCancelSeasonJob: (id) => unawaited(_cancelJob(id)), onCancelEpisodeJob: (j, e) => unawaited(_cancelJob(j, epId: e)),
          onPlayEpisode: (ep, o) => _playTarget(PlayTarget(itemId: ep.card.id, startAt: ep.resumePosition, seriesId: widget.itemId, seasonId: _curSeason?.id, episodeNumber: ep.episodeNumber), ep.card.art, o),
          onEpisodeHoverChanged: _onEpHover, onEpisodeFocusChanged: _onEpHover,
        ),
      if (d.collectionItems.isNotEmpty)
        EvShelf(key: const Key('ev_detail_collection_shelf'), title: '合集内容', badge: '${d.collectionItems.length} 部', items: d.collectionItems, style: EvCardStyle.poster, onCardTap: open, onCardPlay: (c) => _playTarget(PlayTarget(itemId: c.id), c.art, null)),
      if (_similar.isNotEmpty)
        EvShelf(key: const Key('ev_detail_similar_shelf'), title: '相似推荐', items: _similar, style: EvCardStyle.poster, onCardTap: open, onCardPlay: (c) => _playTarget(PlayTarget(itemId: c.id), c.art, null)),
      EvDetailPeopleShelf(people: _people),
      EvDetailFactsSection(detail: d, seasons: _seasons, quality: _quality ?? d.card.quality, subtitlesEnabled: subsOn, subtitleAvailability: _itemAvail),
    ]);
  }
}
