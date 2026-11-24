import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/home/ev_hero.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/zone/ev_zone_all_section.dart';

/// Unified zone page shared by the 5 default library zones and all custom zones,
/// mirroring `.ptitle`, `.pacts`, `.hero`, and zone shelves from `.spec/mockups/proto.js`.
class EvZonePage extends StatefulWidget {
  const EvZonePage({super.key, required this.zoneId, this.enableAnimations = true});
  final String zoneId;
  final bool enableAnimations;

  @override
  State<EvZonePage> createState() => _EvZonePageState();
}

class _EvZonePageState extends State<EvZonePage> {
  final ScrollController _scrollController = ScrollController();

  EvScope? _scope;
  EmbyViewData? _attachedData;
  String? _attachedSessionId;
  StreamSubscription<LocalPreferences>? _prefsSub;
  String _zonePrefSig = '';

  ZoneData? _zoneData;
  HomeRecommendation? _activeHero;
  MediaCard? _previewCard;
  String? _hoveredCardId;
  bool _loading = true, _openingRandom = false;
  Object? _error;
  int _loadToken = 0;

  EvChromeTitlePlate? _appliedTitlePlate;
  Color? _appliedAmbientColor;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context), theme = EvTheme.of(context);
    final changed = _scope == null ||
        !identical(_attachedData, scope.services.data) ||
        _attachedSessionId != scope.services.sessionId;
    _scope = scope;

    if (changed) {
      _attachedData = scope.services.data;
      _attachedSessionId = scope.services.sessionId;
      _zoneData = _activeHero = _previewCard = _hoveredCardId = null;
      _attachPreferences(scope.services.preferences);
      _resetStageAndScroll(scope);
      unawaited(_loadZone());
      return;
    }

    final data = _zoneData;
    if (data != null) {
      final nextAmbient = theme.zoneColor(data.zone.colorSlot);
      if (nextAmbient != _appliedAmbientColor) {
        _appliedAmbientColor = nextAmbient;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scope?.stage.setAmbientColor(nextAmbient);
        });
      }
    }
  }

  @override
  void didUpdateWidget(EvZonePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoneId == widget.zoneId) return;
    if (_hoveredCardId != null) {
      _scope?.immersion.onCardHoverEnd(cardId: _hoveredCardId);
      _hoveredCardId = null;
    }
    _zoneData = _activeHero = _previewCard = _error = null;
    _loading = true;
    if (_scope != null) {
      _zonePrefSig = _prefSignature(_scope!.services.preferences.current.zones, widget.zoneId);
      _resetStageAndScroll(_scope!);
    }
    if (_scrollController.hasClients && _scrollController.offset != 0.0) _scrollController.jumpTo(0.0);
    unawaited(_loadZone());
  }

  void _resetStageAndScroll(EvScope scope) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scope.stage..setMode(EvStageMode.hero)..setScrollProgress(0.0);
      scope.shell.setScrollOffset(0.0);
    });
  }

  void _attachPreferences(EmbyViewPreferences prefs) {
    unawaited(_prefsSub?.cancel());
    _zonePrefSig = _prefSignature(prefs.current.zones, widget.zoneId);
    _prefsSub = prefs.changes.listen((next) {
      if (!mounted) return;
      final sig = _prefSignature(next.zones, widget.zoneId);
      if (sig == _zonePrefSig) return;
      _zonePrefSig = sig;
      unawaited(_loadZone());
    });
  }

  static String _prefSignature(List<ZonePreference> zones, String zoneId) {
    for (final z in zones) {
      if (z.id != zoneId) continue;
      final r = switch (z.rule) {
        LibraryZoneRule(:final libraryId) => 'l:$libraryId',
        GenreZoneRule(:final genreId) => 'g:$genreId',
        TechnologyZoneRule(:final technology) => 't:${technology.name}',
      };
      return '${z.id}:${z.name}:${z.iconKey}:${z.colorSlot}:$r';
    }
    return '';
  }

  Future<void> _loadZone() async {
    final scope = _scope, dataService = scope?.services.data, expectedZoneId = widget.zoneId;
    if (scope == null || dataService == null) {
      if (mounted) setState(() { _loading = false; _zoneData = null; });
      return;
    }
    final token = ++_loadToken;
    if (_zoneData == null && mounted) setState(() { _loading = true; _error = null; });

    try {
      final result = await dataService.zone(expectedZoneId);
      if (!mounted || token != _loadToken || widget.zoneId != expectedZoneId) return;

      final recs = _resolveRecommendations(result), initialHero = recs.firstOrNull;
      final ambient = EvTheme.of(context).zoneColor(result.zone.colorSlot);
      final plate = EvChromeTitlePlate(
        iconKey: result.zone.iconKey, title: result.zone.name, colorSlot: result.zone.colorSlot,
        total: result.zone.total, unit: result.zone.unit, addedThisMonth: result.addedThisMonth,
      );
      _appliedTitlePlate = plate;
      _appliedAmbientColor = ambient;

      setState(() { _zoneData = result; _activeHero = initialHero; _previewCard = null; _loading = false; _error = null; });
      scope.stage..setMode(EvStageMode.hero)..setAmbientColor(ambient)..setBaseBackdrop(initialHero?.card.art.stage);
      scope.shell.updateChrome(titlePlate: plate, rightActions: _buildRightActions(result));
    } catch (e) {
      if (!mounted || token != _loadToken || widget.zoneId != expectedZoneId) return;
      final plate = _appliedTitlePlate;
      _appliedTitlePlate = null;
      if (plate != null && scope.shell.titlePlate == plate) {
        scope.shell.updateChrome(clearTitlePlate: true, rightActions: const []);
      }
      setState(() { _error = e; _loading = false; });
    }
  }

  List<Widget> _buildRightActions(ZoneData data) => [
    EvButton.ghost(key: const Key('ev_zone_action_all'), small: true, glass: true, icon: EvIcons.grid, label: '浏览全部', onPressed: () => _openAll(data)),
    EvButton.ghost(key: const Key('ev_zone_action_random'), small: true, glass: true, icon: EvIcons.shuffle, label: '随便看看', onPressed: _openRandom),
    EvButton.ghost(key: const Key('ev_zone_action_search'), small: true, round: true, glass: true, icon: EvIcons.search, tooltip: '搜索 ⌘F', onPressed: () => _scope?.shell.onOpenSearch?.call()),
  ];

  void _openAll(ZoneData data) => _scope?.shell.openWall(data.all, title: data.zone.name);

  Future<void> _openRandom() async {
    if (_openingRandom) return;
    final scope = _scope, dataService = scope?.services.data, expectedZoneId = widget.zoneId;
    if (scope == null || dataService == null) return;
    _openingRandom = true;
    try {
      final card = await dataService.randomInZone(expectedZoneId);
      if (!mounted || card == null || widget.zoneId != expectedZoneId) return;
      if (scope.shell.onOpenDetail != null) {
        scope.shell.onOpenDetail!(card.id);
      } else {
        unawaited(EvPlayer.open(context, PlayTarget(itemId: card.id), art: card.art));
      }
    } catch (_) {} finally {
      _openingRandom = false;
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
        onBackdropReady: () { if (mounted && _hoveredCardId == card.id && _isHeroVisible) setState(() => _previewCard = card); },
      );
      if (mounted) setState(() {});
    } else if (_hoveredCardId == card.id) {
      _hoveredCardId = null;
      scope.immersion.onCardHoverEnd(cardId: card.id);
      if (mounted) setState(() => _previewCard = null);
    }
  }

  void _openDetail(MediaCard card) => _scope?.shell.onOpenDetail?.call(card.id);
  void _play(PlayTarget target, CardArtwork art, {Rect? origin}) => unawaited(EvPlayer.open(context, target, origin: origin, art: art));

  @override
  void dispose() {
    unawaited(_prefsSub?.cancel());
    if (_hoveredCardId != null) _scope?.immersion.onCardHoverEnd(cardId: _hoveredCardId);
    _scrollController..removeListener(_onScroll)..dispose();
    final scope = _scope, plate = _appliedTitlePlate, ambient = _appliedAmbientColor;
    if (scope != null && (plate != null || ambient != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try { if (plate != null && scope.shell.titlePlate == plate) scope.shell.updateChrome(clearTitlePlate: true, rightActions: const []); } catch (_) {}
        try { if (ambient != null && scope.stage.ambientColor == ambient) scope.stage.setAmbientColor(null); } catch (_) {}
      });
    }
    super.dispose();
  }

  static List<HomeRecommendation> _resolveRecommendations(ZoneData data) {
    if (data.recommendations.isNotEmpty) return data.recommendations;
    if (data.continueWatching.isNotEmpty) {
      final r = data.continueWatching.first;
      return [HomeRecommendation(card: r.card, reason: RecommendationReason.continueWatching, resume: r)];
    }
    final fallback = data.latest?.items.firstOrNull ?? data.highRated?.items.firstOrNull ?? data.genres.expand((g) => g.items).firstOrNull;
    return fallback != null ? [HomeRecommendation(card: fallback, reason: RecommendationReason.daily)] : const [];
  }

  static bool _isAnime(ZoneTile z) => z.id.toLowerCase() == 'anime' || z.iconKey == 'nav_anime';
  static bool _isDoc(ZoneTile z) => z.id.toLowerCase() == 'doc' || z.id.toLowerCase() == 'documentary' || z.iconKey == 'nav_doc';
  static bool _isBox(ZoneTile z) => z.id.toLowerCase() == 'box' || z.id.toLowerCase() == 'boxset' || z.id.toLowerCase() == 'collections' || z.iconKey == 'nav_box';

  static EvCardStyle _cardStyleFor(ZoneTile zone, HomeShelf shelf) {
    if (_isBox(zone) || (shelf.items.isNotEmpty && shelf.items.every((c) => c.kind == MediaKind.collection))) return EvCardStyle.collection;
    return _isDoc(zone) ? EvCardStyle.landscape : EvCardStyle.poster;
  }

  static EvCardStyle _skeletonStyleFor(String zoneId) => switch (zoneId.toLowerCase()) {
    'doc' || 'documentary' => EvCardStyle.landscape,
    'box' || 'boxset' || 'collections' => EvCardStyle.collection,
    _ => EvCardStyle.poster,
  };

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), data = _zoneData;
    final recs = data != null ? _resolveRecommendations(data) : const <HomeRecommendation>[];

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        key: const Key('ev_zone_scroller'),
        controller: _scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null && data == null)
              SizedBox(height: math.max(0.0, scale.vh(100)), child: Center(child: _buildError(theme, scale)))
            else ...[
              if (_loading && data == null)
                SizedBox(height: math.max(0.0, scale.vh(100) - scale.peek))
              else
                EvHero(
                  key: ValueKey<String>('ev_zone_hero_${data?.zone.id ?? widget.zoneId}'),
                  recommendations: recs,
                  previewCard: _previewCard,
                  defaultReasonLabel: data != null ? '${data.zone.name}精选' : '分区精选',
                  enableAutoRotate: widget.enableAnimations && _hoveredCardId == null,
                  onActiveChanged: (rec) { _activeHero = rec; _scope?.stage.setBaseBackdrop(rec.card.art.stage); },
                  onDetail: () { final card = _previewCard ?? _activeHero?.card; if (card != null) _openDetail(card); },
                  onPlay: (rec, origin) => _play(rec.resume?.target ?? PlayTarget(itemId: rec.card.id), rec.card.art, origin: origin),
                ),
              Padding(
                padding: EdgeInsets.only(bottom: scale.rem(6.0)),
                child: _loading && data == null
                    ? _buildSkeletons()
                    : data != null
                    ? _buildSections(theme, scale, data)
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletons() {
    final style = _skeletonStyleFor(widget.zoneId);
    final count = style == EvCardStyle.landscape ? 5 : 9;
    return Column(
      key: const Key('ev_zone_skeletons'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [EvShelfSkeleton(style: style, count: count), EvShelfSkeleton(style: style, count: count)],
    );
  }

  Widget _buildError(EvTheme theme, EvScale scale) => Padding(
    key: const Key('ev_zone_error'),
    padding: EdgeInsets.symmetric(horizontal: scale.gutter, vertical: scale.rem(4.0)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('无法加载分区内容', style: theme.shelfStyle(scale.font(1.5))),
        SizedBox(height: scale.rem(0.75)),
        Text(_error.toString(), style: theme.bodyStyle(scale.font(0.9375), color: theme.ink3), textAlign: TextAlign.center),
        SizedBox(height: scale.rem(1.5)),
        EvButton.ghost(key: const Key('ev_zone_retry_btn'), label: '重试', small: true, onPressed: () => unawaited(_loadZone())),
      ],
    ),
  );

  Widget _buildSections(EvTheme theme, EvScale scale, ZoneData data) {
    final unit = data.zone.unit.isNotEmpty ? data.zone.unit : '部';
    final resumeById = {for (final r in data.continueWatching) r.card.id: r};

    Widget shelf(Key key, HomeShelf s, {required String fallbackTitle, String? badge}) {
      final title = s.title.isNotEmpty ? s.title : fallbackTitle;
      final total = s.total;
      return EvShelf(
        key: key, title: title, badge: badge, items: s.items, style: _cardStyleFor(data.zone, s),
        moreLabel: s.more != null ? (total != null && total > 0 ? '看看这 $total $unit' : '查看全部 ›') : null,
        onMoreTap: s.more != null ? () => _scope?.shell.openWall(s.more!, title: title) : null,
        onCardTap: _openDetail, onCardPlay: (c) => _play(PlayTarget(itemId: c.id), c.art),
        onCardHoverChanged: _onCardInteraction, onCardFocusChanged: _onCardInteraction,
      );
    }

    final genreShelves = [
      for (final g in data.genres)
        if (g.items.isNotEmpty)
          shelf(Key('ev_zone_section_genre_${g.id}'), g, fallbackTitle: g.id, badge: g.total != null && g.total! > 0 ? '${g.total} $unit' : null),
    ];

    final hasAll = data.zone.total > 0 || data.genreCounts.isNotEmpty || data.collage.isNotEmpty;
    final hasAny = data.continueWatching.isNotEmpty ||
        (data.latest?.items.isNotEmpty ?? false) ||
        (data.highRated?.items.isNotEmpty ?? false) ||
        genreShelves.isNotEmpty ||
        hasAll;

    if (!hasAny) {
      return Padding(
        key: const Key('ev_zone_empty'),
        padding: EdgeInsets.symmetric(horizontal: scale.gutter, vertical: scale.rem(5.0)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EvIcon(theme.isPaper ? EvIcons.illEmpty : EvIcons.search, size: scale.rem(theme.isPaper ? 9.0 : 3.0), color: theme.ink2),
            SizedBox(height: scale.rem(1.25)),
            Text('${data.zone.name}还没有内容', style: theme.displayStyle(scale.font(1.625))),
            SizedBox(height: scale.rem(0.5)),
            Text('向片库添加影片后会在这里展示', style: theme.bodyStyle(scale.font(1.0), color: theme.ink3)),
          ],
        ),
      );
    }

    return Column(
      key: const Key('ev_zone_sections'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.continueWatching.isNotEmpty)
          EvShelf(
            key: const Key('ev_zone_section_continue'),
            title: _isAnime(data.zone) ? '继续追番' : '继续观看',
            resumeItems: data.continueWatching,
            style: EvCardStyle.landscape,
            onCardTap: _openDetail,
            onCardPlay: (c) => _play(resumeById[c.id]?.target ?? PlayTarget(itemId: c.id), c.art),
            onCardHoverChanged: _onCardInteraction,
            onCardFocusChanged: _onCardInteraction,
          ),
        if (data.latest != null && data.latest!.items.isNotEmpty)
          shelf(const Key('ev_zone_section_latest'), data.latest!, fallbackTitle: '最近添加'),
        if (data.highRated != null && data.highRated!.items.isNotEmpty)
          shelf(const Key('ev_zone_section_high_rated'), data.highRated!, fallbackTitle: '高分精选'),
        ...genreShelves,
        if (hasAll)
          EvZoneAllSection(
            key: const Key('ev_zone_section_all'),
            zone: data.zone,
            genreCounts: data.genreCounts,
            collage: data.collage,
            onGenreTap: (o) => _scope?.shell.openWall(
              (scope: data.all.scope, sort: data.all.sort, watched: data.all.watched, genreId: o.value, years: data.all.years, technology: data.all.technology),
              title: '${data.zone.name} · ${o.label}',
            ),
            onBrowseAll: () => _openAll(data),
          ),
      ],
    );
  }
}
