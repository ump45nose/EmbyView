import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_episodes.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_hero.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_sections.dart';
import 'package:moonfin/embyview/ui/detail/ev_theme_capsule.dart';
import 'package:moonfin/embyview/ui/detail/ev_version_popover.dart';
import 'package:moonfin/embyview/ui/kit.dart';

export 'ev_episode_card.dart';

/// Complete EmbyView movie & series detail page mirroring `vDetail`, `epCard`,
/// `themePlay`, and `themeStop` from `.spec/mockups/proto.js` & `proto.css`.
class EvDetailPage extends StatefulWidget {
  const EvDetailPage({
    super.key, required this.itemId, this.enableAnimations = true,
    this.openVersionPopoverOnMount = false,
    this.onOpenItem, this.onOpenCollection, this.onOpenPerson, this.onOpenPlaySettings,
    this.onPlayTarget,
  });
  final String itemId;
  final bool enableAnimations;
  final bool openVersionPopoverOnMount;
  final ValueChanged<String>? onOpenItem;
  final ValueChanged<String>? onOpenCollection;
  final void Function(String personId, {String? name, String? roleHint, MediaCard? sourceItem})? onOpenPerson;
  final VoidCallback? onOpenPlaySettings;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin)? onPlayTarget;
  @override State<EvDetailPage> createState() => _EvDetailPageState();
}

class _EvDetailPageState extends State<EvDetailPage> {
  final _scroll = ScrollController();
  final _versionBtnKey = GlobalKey();
  EvScope? _scope;
  StreamSubscription<EvPlaybackEnded>? _playbackEndedSub;
  Immersion? _attachedImmersion;
  EmbyViewData? _attachedData;
  String? _attachedSessionId, _subError, _actionError, _hoveredEpId;
  StreamSubscription<LocalPreferences>? _prefsSub;
  StreamSubscription<List<SeasonJob>>? _jobsSub;

  LocalPreferences _prefs = const LocalPreferences();
  int _playbackRefreshToken = 0;
  int _loadToken = 0, _seasonIdx = 0, _bdIdx = 0, _stillIdx = 0, _cdSec = 0, _cdTotal = 0;
  bool _loading = true, _loadingEps = false, _quoting = false, _trailerLive = false, _stillLive = false, _trailerStarting = false;
  bool _epHovering = false, _themeStarted = false, _ownsChrome = false;
  bool _favorite = false, _played = false, _savingFavorite = false, _savingPlayed = false;
  bool _versionPopoverOpen = false;
  bool _didAutoOpenVersionPopover = false;
  Rect? _versionAnchorRect;
  String? _selectedVersionId;
  Object? _error;

  MediaDetail? _detail;
  MediaQuality? _quality;
  SubtitleAvailability? _itemAvail;
  ThemeMedia _themeMedia = const ThemeMedia();
  List<PersonCredit> _people = const [];
  List<MediaCard> _similar = const [];
  List<SafeEpisodeStill> _safeStills = const [];
  List<SeasonSummary> _seasons = const [];
  List<SeasonJob> _jobs = const [];
  final Map<String, SeasonEpisodes> _epCache = {};
  final Map<String, SubtitleAvailability> _epAvail = {};
  final Set<String> _doneJobEpIds = {};
  Timer? _bdT, _cdT, _stillT, _epT, _actionErrT;

  @override void initState() { super.initState(); _scroll.addListener(_onScroll); }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context);
    final changed = _scope == null || !identical(_attachedData, scope.services.data) || _attachedSessionId != scope.services.sessionId;
    if (!identical(_scope?.shell, scope.shell)) {
      unawaited(_playbackEndedSub?.cancel());
      _playbackEndedSub = scope.shell.playbackEnded.listen((event) {
        final services = _scope?.services;
        if (!mounted || services == null || !event.matches(services)) return;
        unawaited(_refreshPlaybackProgress(event));
      });
    }
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
    _attachedImmersion?.removeListener(_onImmersionChanged);
    _attachedImmersion = scope.immersion..addListener(_onImmersionChanged);
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

  Future<void> _refreshPlaybackProgress(EvPlaybackEnded event) async {
    final data = _attachedData, id = widget.itemId, token = _loadToken;
    final current = _detail;
    if (data == null) return;
    if (!event.targets.any((target) =>
        target.itemId == id || target.seriesId == id ||
        target.itemId == current?.playTarget?.itemId ||
        (current?.collectionItems.any((card) => card.id == target.itemId) ?? false))) {
      return;
    }
    if (current == null) {
      await _loadAll();
      return;
    }

    final refresh = ++_playbackRefreshToken;
    bool isCurrent() => mounted && token == _loadToken && refresh == _playbackRefreshToken;
    final updated = await _safe<MediaDetail?>(() => data.detail(id), null);
    if (!isCurrent()) return;
    if (updated != null) {
      setState(() {
        _detail = updated;
        if (!_savingPlayed) _played = updated.card.played == true;
      });
    }
    if (current.card.kind == MediaKind.series) {
      final seasons = await _safe(() => data.seasons(id), _seasons);
      if (!isCurrent()) return;
      final cachedIds = {..._epCache.keys, if (_curSeason != null) _curSeason!.id};
      final refreshed = await Future.wait([
        for (final season in seasons.where((s) => cachedIds.contains(s.id)))
          _safe<SeasonEpisodes?>(() => data.episodes(id, season.id), null),
      ]);
      if (!isCurrent()) return;
      setState(() {
        final selectedId = _curSeason?.id;
        _seasons = seasons;
        for (final episodes in refreshed.whereType<SeasonEpisodes>()) {
          _epCache[episodes.season.id] = episodes;
        }
        final index = seasons.indexWhere((s) => s.id == selectedId);
        _seasonIdx = index >= 0 ? index : 0;
      });
    }
  }

  Future<void> _loadAll() async {
    final scope = _scope, data = scope?.services.data, id = widget.itemId, token = ++_loadToken;
    _stopTimers(stopMedia: false);
    _detail = null; _quality = null; _itemAvail = null; _subError = null; _actionError = null;
    _favorite = false; _played = false; _savingFavorite = false; _savingPlayed = false;
    _versionPopoverOpen = false; _versionAnchorRect = null; _selectedVersionId = null;
    _people = const []; _similar = const []; _themeMedia = const ThemeMedia(); _safeStills = const []; _seasons = const [];
    _epCache.clear(); _epAvail.clear(); _doneJobEpIds.clear();
    _seasonIdx = _bdIdx = 0; _themeStarted = false;

    if (scope == null || data == null) { if (mounted) setState(() { _loading = false; _error = null; }); return; }
    if (mounted) setState(() { _loading = true; _error = null; });

    final detailF = data.detail(id), peopleF = _safe(() => data.people(id), const <PersonCredit>[]),
        simF = _safe(() => data.similar(id, limit: 16), const <MediaCard>[]),
        themeF = _safe(() => data.themeMedia(id), const ThemeMedia()), qualF = _safe<MediaQuality?>(() => data.quality(id), null);

    late final MediaDetail detail;
    try { detail = await detailF; } catch (e) { if (mounted && token == _loadToken) setState(() { _error = e; _loading = false; }); return; }
    if (!mounted || token != _loadToken) return;

    final isSeries = detail.card.kind == MediaKind.series;
    final initialVersion = _resolveActiveVersion(detail, null);
    if (scope.services.playback != null) {
      unawaited(_safe(() => scope.services.playback!.prepare(id, mediaSourceId: initialVersion?.id), null));
    }
    setState(() {
      _detail = detail;
      _quality = initialVersion?.toQuality() ?? detail.card.quality;
      _favorite = detail.card.favorite == true;
      _played = detail.card.played == true;
      _loading = false;
      _error = null;
      _loadingEps = isSeries;
    });
    if (widget.openVersionPopoverOnMount && !_didAutoOpenVersionPopover && detail.versions.length > 1) {
      _didAutoOpenVersionPopover = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || token != _loadToken) return;
        final box = _versionBtnKey.currentContext?.findRenderObject() as RenderBox?;
        final s = EvScale.of(context);
        final rect = box != null && box.hasSize
            ? (box.localToGlobal(Offset.zero) & box.size)
            : Rect.fromLTWH(s.gutter + s.rem(8), s.vh(68), s.rem(14), s.rem(3.25));
        setState(() {
          _versionAnchorRect = rect;
          _versionPopoverOpen = true;
        });
      });
    }
    scope.stage..setMode(EvStageMode.detail, detailNoBlur: isSeries)..setScrollProgress(0)..setVeilLifted(false)..clearPreviewBackdrop()..setBaseBackdrop(_bdPlan(0));
    _startBdRotation();

    if (scope.services.subtitles != null) {
      unawaited(_safe<SubtitleAvailability?>(() => scope.services.subtitles!.availability(id), null).then((av) {
        if (mounted && token == _loadToken && av != null) setState(() => _itemAvail = av);
      }));
    }

    final (people, sim, tm, qual) = await (peopleF, simF, themeF, qualF).wait;
    if (!mounted || token != _loadToken) return;
    setState(() { _people = people; _similar = sim; _themeMedia = tm; _quality = _mergeQuality(_detail?.card.quality, qual); });
    _startThemeIfEnabled();

    if (isSeries) await _loadSeries(data, id, token);
    if (mounted && token == _loadToken) _resetCountdown();
  }

  Future<void> _loadSeries(EmbyViewData data, String seriesId, int token) async {
    final (seasons, stills) = await (_safe(() => data.seasons(seriesId), const <SeasonSummary>[]), _safe(() => data.safeEpisodeStills(seriesId), const <SafeEpisodeStill>[])).wait;
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
    if (_trailerLive) _stopLive(restartCountdown: false);
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
      final token = _loadToken;
      setState(() { _trailerLive = true; _stillLive = false; _trailerStarting = true; _cdSec = 0; });
      unawaited((_scope?.immersion.showMutedVideo(_themeMedia.trailer, label: '预告片 · 静音') ?? Future<void>.value()).whenComplete(() {
        _trailerStarting = false;
        if (mounted && token == _loadToken) _onImmersionChanged();
      }));
      return;
    }
    _stillIdx = 0; setState(() { _trailerLive = _stillLive = true; _cdSec = 0; });
    void show() => _scope?.stage.setBaseBackdrop(ArtworkPlan(layers: [ArtworkLayer(source: _safeStills[_stillIdx % _safeStills.length].image, fit: ArtworkFit.cover)], fallbackTitle: _detail?.card.title ?? ''));
    show();
    _stillT?.cancel();
    _stillT = Timer.periodic(const Duration(milliseconds: 3200), (_) {
      if (!mounted || !_stillLive || _safeStills.isEmpty) return;
      setState(() => _stillIdx = (_stillIdx + 1) % _safeStills.length);
      show();
    });
  }

  String _safeStillLabel() {
    if (_safeStills.isEmpty) return '正片片段';
    final still = _safeStills[_stillIdx % _safeStills.length];
    final sn = still.seasonNumber, ep = still.episodeNumber;
    if (sn != null && ep != null) return '正片片段 · 第 $sn 季 第 $ep 集';
    final rawName = still.seasonName?.trim();
    if (rawName != null && rawName.isNotEmpty && ep != null) {
      return '正片片段 · ${EvDetailEpisodesSection.formatSeasonName(SeasonSummary(id: '', name: rawName, total: 0))} 第 $ep 集';
    }
    if (ep != null) return '正片片段 · 第 $ep 集';
    return '正片片段';
  }

  void _stopLive({bool restartCountdown = true}) {
    _stillT?.cancel(); _stillT = null;
    final wasLive = _trailerLive, wasStill = _stillLive;
    _trailerLive = _stillLive = _trailerStarting = false;
    if (wasLive) { if (!wasStill) unawaited(_scope?.immersion.stopVideo()); _scope?.stage.setBaseBackdrop(_bdPlan(_bdIdx)); }
    if (restartCountdown) { _resetCountdown(); } else if (wasLive && mounted) { setState(() {}); }
  }

  void _onImmersionChanged() {
    if (!mounted || !_trailerLive || _stillLive || _trailerStarting) return;
    final im = _scope?.immersion;
    if (im != null && (!im.isVideoVisible || im.snapshot.video == PreviewState.idle || im.snapshot.video == PreviewState.failed)) _stopLive();
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
      _epT = Timer(const Duration(milliseconds: 100), () {
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

  void _showActionError(String message) {
    _actionErrT?.cancel();
    setState(() => _actionError = message);
    _actionErrT = Timer(const Duration(seconds: 5), () {
      if (mounted && _actionError == message) setState(() => _actionError = null);
    });
  }

  Future<void> _toggleFavorite() async {
    final data = _scope?.services.data, d = _detail;
    if (data == null || d == null || _savingFavorite) return;
    final token = _loadToken, prev = _favorite, next = !prev;
    _actionErrT?.cancel();
    setState(() { _favorite = next; _savingFavorite = true; _actionError = null; });
    try {
      await data.setFavorite(widget.itemId, next);
      if (!mounted || token != _loadToken) return;
      setState(() => _savingFavorite = false);
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() { _favorite = prev; _savingFavorite = false; });
      final reason = e is EmbyViewFailure ? e.reason : '请稍后重试';
      _showActionError(next ? '加入片单失败：$reason' : '移出片单失败：$reason');
    }
  }

  Future<void> _togglePlayed() async {
    final data = _scope?.services.data, d = _detail;
    if (data == null || d == null || _savingPlayed) return;
    final token = _loadToken, prev = _played, next = !prev;
    _actionErrT?.cancel();
    setState(() { _played = next; _savingPlayed = true; _actionError = null; });
    try {
      await data.setPlayed(widget.itemId, next);
      if (!mounted || token != _loadToken) return;
      setState(() => _savingPlayed = false);
      if (d.card.kind == MediaKind.series) {
        await _refreshSeriesAfterPlayed(data, widget.itemId, token);
      }
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() { _played = prev; _savingPlayed = false; });
      final reason = e is EmbyViewFailure ? e.reason : '请稍后重试';
      _showActionError(next ? '标为已看失败：$reason' : '取消已看失败：$reason');
    }
  }

  Future<void> _refreshSeriesAfterPlayed(EmbyViewData data, String seriesId, int token) async {
    final curSeasonId = _curSeason?.id;
    final (seasons, stills) = await (
      _safe(() => data.seasons(seriesId), _seasons),
      _safe(() => data.safeEpisodeStills(seriesId), _safeStills),
    ).wait;
    if (!mounted || token != _loadToken) return;
    _epCache.clear();
    var nextIdx = _seasonIdx;
    if (curSeasonId != null) {
      final found = seasons.indexWhere((s) => s.id == curSeasonId);
      if (found >= 0) nextIdx = found;
    }
    if (seasons.isNotEmpty) {
      nextIdx = nextIdx.clamp(0, seasons.length - 1);
      final se = await _safe<SeasonEpisodes?>(() => data.episodes(seriesId, seasons[nextIdx].id), null);
      if (!mounted || token != _loadToken) return;
      if (se != null) _epCache[seasons[nextIdx].id] = se;
    }
    setState(() { _seasons = seasons; _safeStills = stills; _seasonIdx = nextIdx; });
    _querySeasonAvail();
  }

  void _stopTimers({required bool stopMedia}) {
    _bdT?.cancel(); _cdT?.cancel(); _stillT?.cancel(); _epT?.cancel(); _actionErrT?.cancel();
    _bdT = _cdT = _stillT = _epT = _actionErrT = null;
    _trailerLive = _stillLive = _trailerStarting = _epHovering = false; _hoveredEpId = null;
    if (stopMedia) { _themeStarted = false; unawaited(_scope?.immersion.stopTheme()); unawaited(_scope?.immersion.stopVideo()); }
  }

  @override
  void dispose() {
    unawaited(_playbackEndedSub?.cancel());
    _attachedImmersion?.removeListener(_onImmersionChanged); _attachedImmersion = null;
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

  static MediaQuality? _mergeQuality(MediaQuality? base, MediaQuality? fetched) => fetched == null ? base : base == null ? fetched : MediaQuality(
    resolution: fetched.resolution ?? base.resolution, videoRange: fetched.videoRange ?? base.videoRange,
    audioLabel: fetched.audioLabel ?? base.audioLabel, origin: fetched.origin ?? base.origin,
  );
  static Future<T> _safe<T>(Future<T> Function() fn, T fb) async { try { return await fn(); } catch (_) { return fb; } }

  MediaVersion? _resolveActiveVersion(MediaDetail? d, String? overrideId) {
    if (d == null || d.versions.length <= 1) return null;
    return selectDefaultMediaVersion(
      d.versions,
      ruleName: _prefs.defaultVersionRule.name,
      rememberedId: overrideId ?? d.rememberedVersionId,
      lastTaste: d.lastVersionTaste,
    );
  }

  MediaVersion? get _activeVersion => _resolveActiveVersion(_detail, _selectedVersionId);

  void _toggleVersionPopover(Rect anchorRect) {
    setState(() {
      if (_versionPopoverOpen) {
        _versionPopoverOpen = false;
      } else {
        _versionAnchorRect = anchorRect;
        _versionPopoverOpen = true;
      }
    });
  }

  void _selectVersion(MediaVersion version) {
    final data = _scope?.services.data, playback = _scope?.services.playback;
    setState(() {
      _selectedVersionId = version.id;
      _quality = version.toQuality();
      _versionPopoverOpen = false;
    });
    if (data != null) {
      unawaited(_safe(() => data.rememberMediaVersion(widget.itemId, version), null));
    }
    if (playback != null) {
      unawaited(_safe(() => playback.prepare(widget.itemId, mediaSourceId: version.id), null));
    }
  }

  void _openPlaySettings() {
    setState(() => _versionPopoverOpen = false);
    if (widget.onOpenPlaySettings != null) {
      widget.onOpenPlaySettings!();
      return;
    }
    final shell = _scope?.shell;
    if (shell?.onOpenPlaySettings != null) {
      shell!.onOpenPlaySettings!();
    } else {
      shell?.onOpenSettings?.call();
    }
  }

  void _openCollection(String collectionId) {
    if (widget.onOpenCollection != null) {
      widget.onOpenCollection!(collectionId);
      return;
    }
    _scope?.shell.onOpenCollection?.call(collectionId);
  }

  void _openPerson(PersonCredit credit) {
    final source = _detail?.card;
    if (widget.onOpenPerson != null) {
      widget.onOpenPerson!(credit.id, name: credit.name, roleHint: credit.role, sourceItem: source);
      return;
    }
    _scope?.shell.onOpenPerson?.call(credit.id, name: credit.name, roleHint: credit.role, sourceItem: source);
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), scope = _scope, d = _detail;
    final showTheme = d != null && _themeStarted && _themeMedia.songs.isNotEmpty && _prefs.themeMusic && scope != null;
    final activeVer = _activeVersion;

    return Stack(key: const Key('ev_detail_page'), fit: StackFit.expand, children: [
      ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(key: const Key('ev_detail_scroller'), controller: _scroll, child: _buildBody(t, s, d))),
      if (_stillLive)
        Positioned(left: 0, right: 0, top: s.rem(4.75), child: IgnorePointer(child: Center(child: ClipRRect(
          key: const Key('ev_detail_safe_still_label'), borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16), child: Container(
            height: s.rem(2), padding: EdgeInsets.symmetric(horizontal: s.rem(0.875)), color: const Color.fromRGBO(0, 0, 0, 0.42),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              EvIcon(EvIcons.film, size: s.rem(0.875), color: const Color(0xFFFFFFFF)), SizedBox(width: s.rem(0.5)),
              Text(_safeStillLabel(), style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: const Color(0xFFFFFFFF))),
            ]),
          )),
        )))),
      if (showTheme)
        Positioned(right: s.rem(1.25), top: s.rem(0.875), child: ListenableBuilder(listenable: scope.immersion, builder: (_, _) {
          final snap = scope.immersion.snapshot;
          return snap.theme == PreviewState.failed ? const SizedBox.shrink()
              : EvThemeCapsule(title: d.card.title, snapshot: snap, enableAnimations: widget.enableAnimations, onToggleMute: () => unawaited(scope.immersion.setThemeMuted(!snap.themeMuted)));
        })),
      if (_versionPopoverOpen && d != null && d.versions.length > 1 && activeVer != null && _versionAnchorRect != null)
        Positioned.fill(
          child: EvVersionPopover(
            versions: d.versions,
            activeVersion: activeVer,
            defaultRule: _prefs.defaultVersionRule,
            warnHighBitrate: _prefs.warnHighBitrateOnExternalNetwork,
            anchorRect: _versionAnchorRect!,
            onSelect: _selectVersion,
            onOpenPlaySettings: _openPlaySettings,
            onDismiss: () => setState(() => _versionPopoverOpen = false),
          ),
        ),
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
    final activeVer = _activeVersion;
    final effectiveQuality = activeVer?.toQuality() ?? _quality ?? d.card.quality;
    void open(MediaCard c) {
      if (c.kind == MediaKind.collection && (widget.onOpenCollection != null || _scope?.shell.onOpenCollection != null)) {
        _openCollection(c.id);
        return;
      }
      (widget.onOpenItem ?? _scope?.shell.onOpenDetail)?.call(c.id);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EvDetailHero(
        detail: d, people: _people, seasonsCount: _seasons.isNotEmpty ? _seasons.length : d.card.childCount,
        quality: effectiveQuality, backdropCount: _backdrops.length, backdropIndex: _bdIdx,
        onSelectBackdrop: _selectBd, canTrailer: _canTrailer, isTrailerClip: _hasTrailer, trailerLive: _trailerLive,
        countdownSeconds: _cdSec, countdownTotalSeconds: _cdTotal, onToggleTrailer: () => _trailerLive ? _stopLive() : _startLive(), onPlay: _playTarget,
        isFavorite: _favorite, isPlayed: _played, favoriteBusy: _savingFavorite, playedBusy: _savingPlayed,
        actionError: _actionError,
        onDismissActionError: () { _actionErrT?.cancel(); setState(() => _actionError = null); },
        onToggleFavorite: () => unawaited(_toggleFavorite()),
        onTogglePlayed: () => unawaited(_togglePlayed()),
        activeVersion: activeVer,
        versionCount: d.versions.length,
        versionButtonKey: _versionBtnKey,
        onOpenVersionPicker: _toggleVersionPopover,
        onOpenCollection: _openCollection,
        onOpenPerson: _openPerson,
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
      if (d.collection != null && d.collection!.items.isNotEmpty)
        EvDetailCollectionStrip(
          membership: d.collection!,
          currentItemId: d.card.id,
          onOpenItem: open,
          onOpenCollection: () => _openCollection(d.collection!.id),
          onPlayItem: (c) => _playTarget(PlayTarget(itemId: c.id), c.art, null),
        ),
      if (d.collectionItems.isNotEmpty)
        EvShelf(key: const Key('ev_detail_collection_shelf'), title: '合集内容', badge: '${d.collectionItems.length} 部', items: d.collectionItems, style: EvCardStyle.poster, onCardTap: open, onCardPlay: (c) => _playTarget(PlayTarget(itemId: c.id), c.art, null)),
      if (_similar.isNotEmpty)
        EvShelf(key: const Key('ev_detail_similar_shelf'), title: '相似推荐', items: _similar, style: EvCardStyle.poster, onCardTap: open, onCardPlay: (c) => _playTarget(PlayTarget(itemId: c.id), c.art, null)),
      EvDetailPeopleShelf(people: _people, onOpenPerson: _openPerson),
      EvDetailFactsSection(
        detail: d, seasons: _seasons, quality: effectiveQuality,
        subtitlesEnabled: subsOn, subtitleAvailability: _itemAvail, activeVersion: activeVer,
      ),
    ]);
  }
}
