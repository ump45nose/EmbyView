import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/home/ev_feature_spread.dart';
import 'package:moonfin/embyview/ui/home/ev_hero.dart';
import 'package:moonfin/embyview/ui/home/ev_zone_strip.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Complete EmbyView home page following `.spec/mockups/proto.js` section order
/// and coordinating with [EvStageController], [Immersion], and [EvShellController].
class EvHomePage extends StatefulWidget {
  const EvHomePage({super.key, this.enableAnimations = true});
  final bool enableAnimations;

  @override
  State<EvHomePage> createState() => _EvHomePageState();
}

class _EvHomePageState extends State<EvHomePage> {
  final ScrollController _scrollController = ScrollController();
  EvScope? _scope;
  EmbyViewData? _attachedData;
  String? _attachedSessionId;
  StreamSubscription<LocalPreferences>? _prefsSub;
  ShelfSort _seriesSort = ShelfSort.added;
  String _zonesSig = '';

  HomeData? _home;
  HomeRecommendation? _activeHero;
  MediaCard? _previewCard;
  String? _hoveredCardId;
  bool _loading = true;
  Object? _error;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context);
    final changed = _scope == null || !identical(_attachedData, scope.services.data) || _attachedSessionId != scope.services.sessionId;
    _scope = scope;
    if (!changed) return;
    _attachedData = scope.services.data;
    _attachedSessionId = scope.services.sessionId;
    _attachPreferences(scope.services.preferences);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scope.stage..setMode(EvStageMode.hero)..setScrollProgress(0.0);
      scope.shell.setScrollOffset(0.0);
    });
    unawaited(_loadHome());
  }

  void _attachPreferences(EmbyViewPreferences prefs) {
    unawaited(_prefsSub?.cancel());
    _seriesSort = prefs.current.seriesSort;
    _zonesSig = _zonesSignature(prefs.current.zones);
    _prefsSub = prefs.changes.listen((next) {
      if (!mounted) return;
      final nextSig = _zonesSignature(next.zones);
      final reload = next.seriesSort != _seriesSort || nextSig != _zonesSig;
      _seriesSort = next.seriesSort;
      _zonesSig = nextSig;
      if (reload) unawaited(_loadHome());
    });
  }

  static String _zonesSignature(List<ZonePreference> zones) => [
    for (final z in zones)
      '${z.id}:${z.name}:${z.iconKey}:${z.colorSlot}:${switch (z.rule) {
        LibraryZoneRule(:final libraryId) => 'l:$libraryId',
        GenreZoneRule(:final genreId) => 'g:$genreId',
        TechnologyZoneRule(:final technology) => 't:${technology.name}',
      }}',
  ].join('|');

  Future<void> _loadHome() async {
    final scope = _scope, data = scope?.services.data;
    if (scope == null || data == null) {
      if (mounted) setState(() { _loading = false; _home = null; });
      return;
    }
    final token = ++_loadToken;
    if (_home == null && mounted) setState(() { _loading = true; _error = null; });
    try {
      final result = await data.home(seriesSort: _seriesSort);
      if (!mounted || token != _loadToken) return;
      final initialHero = result.recommendations.firstOrNull;
      setState(() { _home = result; _activeHero = initialHero; _loading = false; _error = null; });
      if (initialHero != null) scope.stage.setBaseBackdrop(initialHero.card.art.stage);
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  bool get _isHeroVisible {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    final vh = pos.hasViewportDimension && pos.viewportDimension > 0 ? pos.viewportDimension : MediaQuery.sizeOf(context).height;
    return pos.pixels < vh * 0.2;
  }

  void _onScroll() {
    final scope = _scope;
    if (scope == null || !_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final vh = pos.hasViewportDimension && pos.viewportDimension > 0 ? pos.viewportDimension : 900.0;
    scope.shell.setScrollOffset(pos.pixels);
    scope.stage.setScrollProgress((pos.pixels / (vh * 0.5)).clamp(0.0, 1.0));
    if (!_isHeroVisible && _previewCard != null) setState(() => _previewCard = null);
  }

  void _onCardInteraction(MediaCard card, bool active) {
    final scope = _scope;
    if (scope == null) return;
    if (active) {
      _hoveredCardId = card.id;
      scope.immersion.onCardHoverStart(
        card, scrolledDown: !_isHeroVisible,
        onBackdropReady: () {
          if (mounted && _hoveredCardId == card.id && _isHeroVisible) setState(() => _previewCard = card);
        },
      );
      if (mounted) setState(() {});
    } else if (_hoveredCardId == card.id) {
      _hoveredCardId = null;
      scope.immersion.onCardHoverEnd(cardId: card.id);
      if (mounted) setState(() => _previewCard = null);
    }
  }

  void _openDetail(MediaCard card) => _scope?.shell.onOpenDetail?.call(card.id);

  void _play(PlayTarget target, CardArtwork art, {Rect? origin}) =>
      unawaited(EvPlayer.open(context, target, origin: origin, art: art));

  @override
  void dispose() {
    unawaited(_prefsSub?.cancel());
    if (_hoveredCardId != null) _scope?.immersion.onCardHoverEnd(cardId: _hoveredCardId);
    _scrollController..removeListener(_onScroll)..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), home = _home;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        key: const Key('ev_home_scroller'),
        controller: _scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading && home == null)
              SizedBox(height: math.max(0.0, scale.vh(100) - scale.peek))
            else
              EvHero(
                recommendations: home?.recommendations ?? const [],
                previewCard: _previewCard,
                defaultReasonLabel: '今日推荐',
                enableAutoRotate: widget.enableAnimations && _hoveredCardId == null,
                onActiveChanged: (rec) {
                  _activeHero = rec;
                  _scope?.stage.setBaseBackdrop(rec.card.art.stage);
                },
                onDetail: () {
                  final card = _previewCard ?? _activeHero?.card;
                  if (card != null) _openDetail(card);
                },
                onPlay: (rec, origin) => _play(rec.resume?.target ?? PlayTarget(itemId: rec.card.id), rec.card.art, origin: origin),
              ),
            Padding(
              padding: EdgeInsets.only(bottom: scale.rem(6.0)),
              child: _loading && home == null
                  ? const Column(
                      key: Key('ev_home_skeletons'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        EvShelfSkeleton(style: EvCardStyle.landscape, count: 5),
                        EvShelfSkeleton(style: EvCardStyle.poster, count: 9),
                        EvShelfSkeleton(style: EvCardStyle.poster, count: 9),
                      ],
                    )
                  : _error != null && home == null
                  ? Padding(
                      key: const Key('ev_home_error'),
                      padding: EdgeInsets.symmetric(horizontal: scale.gutter, vertical: scale.rem(4.0)),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('无法加载首页内容', style: theme.shelfStyle(scale.font(1.5))),
                          SizedBox(height: scale.rem(0.75)),
                          Text(_error.toString(), style: theme.bodyStyle(scale.font(0.9375), color: theme.ink3), textAlign: TextAlign.center),
                          SizedBox(height: scale.rem(1.5)),
                          EvButton.ghost(label: '重试', small: true, onPressed: () => unawaited(_loadHome())),
                        ],
                      ),
                    )
                  : _buildSections(theme, home!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSections(EvTheme theme, HomeData home) {
    final sortLabel = switch (_seriesSort) {
      ShelfSort.added => '最近添加',
      ShelfSort.score => '评分最高',
      ShelfSort.title => '按标题',
    };
    final resumeById = {for (final r in home.continueWatching) r.card.id: r};

    Widget shelf(Key key, HomeShelf s, EvCardStyle style, {String? title, String? badge}) {
      final resolvedTitle = title ?? (s.title.isNotEmpty ? s.title : '');
      return EvShelf(
        key: key, title: resolvedTitle, badge: badge, items: s.items, style: style,
        onMoreTap: s.more != null ? () => _scope?.shell.openWall(s.more!, title: s.title.isNotEmpty ? s.title : resolvedTitle) : null,
        onCardTap: _openDetail,
        onCardPlay: (c) => _play(PlayTarget(itemId: c.id), c.art),
        onCardHoverChanged: _onCardInteraction,
        onCardFocusChanged: _onCardInteraction,
      );
    }

    Widget feature(Key key, FeatureSpread sp, String title, Color accent, EvIconData doodle) => EvFeatureSpread(
      key: key, spread: sp, title: title, accentColor: accent, doodleIcon: doodle,
      enableAnimations: widget.enableAnimations,
      onTap: () => _scope?.shell.openWall(sp.query, title: title.replaceAll('\n', '')),
    );

    return Column(
      key: const Key('ev_home_sections'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (home.continueWatching.isNotEmpty)
          EvShelf(
            key: const Key('ev_home_section_continue'), title: '继续观看',
            resumeItems: home.continueWatching, style: EvCardStyle.landscape,
            onCardTap: _openDetail,
            onCardPlay: (c) => _play(resumeById[c.id]?.target ?? PlayTarget(itemId: c.id), c.art),
            onCardHoverChanged: _onCardInteraction,
            onCardFocusChanged: _onCardInteraction,
          ),
        if (home.zones.isNotEmpty)
          EvZoneStrip(
            key: const Key('ev_home_section_zones'), zones: home.zones,
            onZoneTap: (z) => _scope?.shell.openZone(z.id),
            onManageZones: () => _scope?.shell.onManageZones?.call(),
          ),
        if (home.shortHighRated != null && home.shortHighRated!.total > 0)
          feature(const Key('ev_home_section_short_feature'), home.shortHighRated!, '100 分钟以内\n的高分电影', theme.movie, EvIcons.illClock),
        if (home.recentMovies != null && home.recentMovies!.items.isNotEmpty)
          shelf(
            const Key('ev_home_section_recent'), home.recentMovies!, EvCardStyle.poster,
            title: '最近添加', badge: home.recentMovies!.title.isNotEmpty && home.recentMovies!.title != '最近添加' ? home.recentMovies!.title : '电影',
          ),
        if (home.anime != null && home.anime!.items.isNotEmpty)
          shelf(const Key('ev_home_section_anime'), home.anime!, EvCardStyle.poster, title: home.anime!.title.isNotEmpty ? home.anime!.title : '番剧', badge: sortLabel),
        if (home.uhdDolbyVision != null && home.uhdDolbyVision!.total > 0)
          feature(const Key('ev_home_section_dv_feature'), home.uhdDolbyVision!, '4K 杜比视界', theme.tv, EvIcons.illTv),
        if (home.series != null && home.series!.items.isNotEmpty)
          shelf(const Key('ev_home_section_series'), home.series!, EvCardStyle.poster, title: home.series!.title.isNotEmpty ? home.series!.title : '剧集', badge: sortLabel),
        if (home.collections != null && home.collections!.items.isNotEmpty)
          shelf(const Key('ev_home_section_collections'), home.collections!, EvCardStyle.collection, title: home.collections!.title.isNotEmpty ? home.collections!.title : '合集'),
        if (home.documentaries != null && home.documentaries!.items.isNotEmpty)
          shelf(const Key('ev_home_section_docs'), home.documentaries!, EvCardStyle.landscape, title: home.documentaries!.title.isNotEmpty ? home.documentaries!.title : '纪录片'),
      ],
    );
  }
}
