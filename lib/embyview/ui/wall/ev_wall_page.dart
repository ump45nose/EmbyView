import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/wall/ev_alpha_bar.dart';
import 'package:moonfin/embyview/ui/wall/ev_wall_filter_popover.dart';

/// Deterministic grid geometry for [EvWallPage], shared by rendering, alpha-bar
/// jump offsets, and performance tests.
@immutable
class EvWallGridMetrics {
  const EvWallGridMetrics({
    required this.crossAxisCount, required this.itemWidth, required this.itemHeight,
    required this.crossAxisSpacing, required this.mainAxisSpacing, required this.gridTopOffset,
  });

  final int crossAxisCount;
  final double itemWidth, itemHeight, crossAxisSpacing, mainAxisSpacing, gridTopOffset;

  double get rowStride => itemHeight + mainAxisSpacing;

  /// Scroll offset aligning [itemIndex]'s row [leadOffset] below the viewport top.
  double scrollOffsetForIndex(int itemIndex, {double leadOffset = 0.0}) {
    if (itemIndex <= 0 || crossAxisCount <= 0) return 0.0;
    return math.max(0.0, gridTopOffset + (itemIndex ~/ crossAxisCount) * rowStride - leadOffset);
  }

  /// First item index in the row at [scrollOffset + probeOffset].
  int firstVisibleIndex(double scrollOffset, {double probeOffset = 0.0}) {
    final y = scrollOffset + probeOffset - gridTopOffset;
    return (y <= 0 || rowStride <= 0) ? 0 : (y / rowStride).floor() * crossAxisCount;
  }

  /// Mirrors `.grid` in `.spec/mockups/proto.css`:
  /// `grid-template-columns: repeat(auto-fill, minmax(10.5rem, 1fr))`, `gap: 2.25rem 1.5rem`.
  static EvWallGridMetrics compute({
    required double viewportWidth, required EvScale scale, required double gridTopOffset,
  }) {
    final crossGap = scale.rem(1.5), mainGap = scale.rem(2.25), minW = scale.rem(10.5);
    final contentW = math.max(minW, viewportWidth - scale.gutter * 2);
    final cols = math.max(1, ((contentW + crossGap) / (minW + crossGap)).floor());
    final itemW = (contentW - (cols - 1) * crossGap) / cols;
    return EvWallGridMetrics(
      crossAxisCount: cols, itemWidth: itemW, itemHeight: itemW * 1.5 + scale.rem(4.75),
      crossAxisSpacing: crossGap, mainAxisSpacing: mainGap, gridTopOffset: gridTopOffset,
    );
  }
}

/// Full-library poster wall supporting 10,000+ lazily paged items, dynamic
/// [WallFacets] sort/filter popover, empty state, and A–Z index bar.
class EvWallPage extends StatefulWidget {
  const EvWallPage({
    super.key, required this.initialQuery, this.title, this.unit,
    this.pageSize = defaultPageSize, this.maxCachedPages = defaultMaxCachedPages,
    this.scrollController, this.onOpenItem, this.onPlayItem,
  });

  /// Default page size (divisible by 2, 3, 4, 5, 6, 10, 12 grid columns).
  static const int defaultPageSize = 60;

  /// LRU page cache ceiling (~960 items at default page size) for bounded memory.
  static const int defaultMaxCachedPages = 16;

  final WallQuery initialQuery;
  final String? title, unit;
  final int pageSize, maxCachedPages;
  final ScrollController? scrollController;
  final ValueChanged<MediaCard>? onOpenItem, onPlayItem;

  @override
  State<EvWallPage> createState() => _EvWallPageState();
}

class _EvWallPageState extends State<EvWallPage> {
  static const int _maxConcurrentPages = 3;

  final GlobalKey _headerKey = GlobalKey();
  late ScrollController _scrollController;
  late bool _ownsScrollController;

  Timer? _scrollIdleTimer;
  Timer? _hoverDwellTimer;

  final ValueNotifier<String> _activeLetter = ValueNotifier<String>('');
  final ValueNotifier<bool> _scrolling = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _bannerError = ValueNotifier<String?>(null);

  EvScope? _scope;
  String? _boundSessionId;
  EmbyViewData? _boundData;

  late WallQuery _query;
  WallListing? _listing;
  WallFacets _facets = const WallFacets();
  bool _loadingWall = true, _loadingFacets = false;
  EmbyViewFailure? _error;

  int _generation = 0;
  final LinkedHashMap<int, List<MediaCard>> _pages = LinkedHashMap();
  final Map<int, _PageSignal> _pageNotifiers = {};
  final Set<int> _inFlightPages = {}, _pendingPages = {}, _failedPageIndices = {};
  final List<int> _pageQueue = [];
  bool _flushScheduled = false, _stageSeeded = false;
  bool _facetsFailed = false;
  String? _facetsErrorMessage, _pageErrorMessage;

  bool _popoverOpen = false, _suppressScrollLetterSync = false;
  double? _measuredHeaderHeight, _lastViewportWidth;
  EvWallGridMetrics? _lastMetrics;
  double _lastLeadOffset = 0.0;
  MediaCard? _pendingHoverCard;
  List<MapEntry<String, int>> _sortedOffsets = const [];

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery;
    _ownsScrollController = widget.scrollController == null;
    _scrollController = widget.scrollController ?? ScrollController();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context);
    final first = _scope == null;
    final sessionChanged = _boundSessionId != scope.services.sessionId || !identical(_boundData, scope.services.data);
    _scope = scope;
    _boundSessionId = scope.services.sessionId;
    _boundData = scope.services.data;
    if (first) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        scope.immersion.onCardHoverEnd();
        scope.stage.setMode(EvStageMode.ambient);
        scope.stage.setScrollProgress(0.0);
        _syncShellChrome();
      });
      _reloadAll();
    } else if (sessionChanged) {
      _reloadAll();
    }
  }

  @override
  void didUpdateWidget(EvWallPage old) {
    super.didUpdateWidget(old);
    if (old.scrollController != widget.scrollController) {
      _scrollController.removeListener(_handleScroll);
      if (_ownsScrollController) _scrollController.dispose();
      _ownsScrollController = widget.scrollController == null;
      _scrollController = widget.scrollController ?? ScrollController();
      _scrollController.addListener(_handleScroll);
    }
    if (!evSameWallQuery(old.initialQuery, widget.initialQuery)) {
      _applyQuery(widget.initialQuery);
    } else if (old.title != widget.title || old.unit != widget.unit) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _syncShellChrome(); });
    }
  }

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    _hoverDwellTimer?.cancel();
    _scrollController.removeListener(_handleScroll);
    if (_ownsScrollController) _scrollController.dispose();
    _activeLetter.dispose();
    _scrolling.dispose();
    _bannerError.dispose();
    for (final n in _pageNotifiers.values) {
      n.dispose();
    }
    _pageNotifiers.clear();
    super.dispose();
  }

  ZoneTile? get _matchedZone {
    final s = _query.scope;
    if (s is! ZoneWallScope) return null;
    for (final z in _scope?.shell.zones ?? const <ZoneTile>[]) {
      if (z.id == s.zoneId) return z;
    }
    return null;
  }

  String get _resolvedTitle {
    if (widget.title != null && widget.title!.trim().isNotEmpty) return widget.title!.trim();
    final zone = _matchedZone;
    if (zone != null) return zone.name;
    return switch (_query.scope) {
      ZoneWallScope(:final zoneId) => zoneId,
      FeatureWallScope(:final feature) => feature == HomeFeature.shortHighRated ? '100 分钟以内的高分电影' : '4K 杜比视界',
    };
  }

  String get _resolvedUnit => widget.unit ?? _matchedZone?.unit ?? '部';
  int get _total => _listing?.info.total ?? 0;
  Map<String, int> get _letterOffsets => _listing?.info.letterOffsets ?? const {};
  bool get _showAlphaBar =>
      _query.sort == WallSort.title && !_loadingWall && _error == null && _total > 0 && _letterOffsets.isNotEmpty;

  void _syncShellChrome() {
    final scope = _scope;
    if (scope == null || !mounted) return;
    scope.shell.updateChrome(
      showBack: true,
      clearTitlePlate: true,
      rightActions: [
        _EvChromeFilterAction(
          key: const Key('ev_wall_chrome_filter_button'),
          filterCount: evWallActiveFilterCount(_query),
          onTap: _togglePopover,
        ),
      ],
    );
  }

  void _applyQuery(WallQuery next) {
    if (evSameWallQuery(_query, next)) return;
    setState(() { _query = next; _measuredHeaderHeight = null; });
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _suppressScrollLetterSync = true;
      _scrollController.jumpTo(0.0);
      _suppressScrollLetterSync = false;
    }
    _reloadAll();
    _syncShellChrome();
  }

  void _resetFilters() => _applyQuery((
    scope: _query.scope, sort: _query.sort, watched: WatchFilter.all,
    genreId: null, years: null, technology: null,
  ));

  void _syncBannerError() {
    _bannerError.value = _pageErrorMessage ?? _facetsErrorMessage;
  }

  _PageSignal _notifierForPage(int pageIndex) =>
      _pageNotifiers.putIfAbsent(pageIndex, _PageSignal.new);

  void _notifyPage(int pageIndex) {
    final n = _pageNotifiers[pageIndex];
    if (n != null) n.value++;
  }

  void _prunePageNotifiers() {
    if (!mounted) return;
    final stale = <int>[];
    _pageNotifiers.forEach((p, n) {
      if (!_pages.containsKey(p) && !n.active) stale.add(p);
    });
    for (final p in stale) {
      _pageNotifiers.remove(p)?.dispose();
    }
  }

  void _reloadAll() {
    final data = _boundData;
    final gen = ++_generation;
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = null;
    _hoverDwellTimer?.cancel();
    _hoverDwellTimer = null;
    _pendingHoverCard = null;
    _pages.clear();
    _inFlightPages.clear();
    _pendingPages.clear();
    _pageQueue.clear();
    _failedPageIndices.clear();
    _facetsFailed = false;
    _facetsErrorMessage = null;
    _pageErrorMessage = null;
    _bannerError.value = null;
    _stageSeeded = false;
    _listing = null;
    _facets = const WallFacets();
    _sortedOffsets = const [];
    _activeLetter.value = '';
    _scrolling.value = false;
    _error = null;
    _loadingWall = data != null;
    _loadingFacets = data != null;
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) => _prunePageNotifiers());
    }
    if (data == null) return;
    unawaited(_loadListing(data, _query, gen));
    unawaited(_loadFacets(data, _query, gen));
  }

  Future<void> _loadListing(EmbyViewData data, WallQuery query, int gen) async {
    try {
      final listing = await data.openWall(query);
      if (!mounted || gen != _generation) return;
      final offsets = listing.info.letterOffsets.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
      _activeLetter.value = offsets.isNotEmpty ? offsets.first.key : '';
      setState(() {
        _listing = listing;
        _sortedOffsets = offsets;
        _loadingWall = false;
        _error = null;
      });
      if (listing.info.total > 0) _enqueuePage(0, prefetchNeighbors: true);
    } on EmbyViewFailure catch (e) {
      if (mounted && gen == _generation) setState(() { _error = e; _loadingWall = false; });
    } catch (_) {
      if (mounted && gen == _generation) {
        setState(() { _error = const EmbyViewFailure('加载海报墙失败，请重试', retryable: true); _loadingWall = false; });
      }
    }
  }

  Future<void> _loadFacets(EmbyViewData data, WallQuery query, int gen) async {
    try {
      final facets = await data.wallFacets(query);
      if (!mounted || gen != _generation) return;
      _facetsFailed = false;
      _facetsErrorMessage = null;
      _syncBannerError();
      setState(() { _facets = facets; _loadingFacets = false; });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      _facetsFailed = true;
      _facetsErrorMessage = e is EmbyViewFailure ? e.reason : '筛选项加载失败，请重试';
      _syncBannerError();
      setState(() => _loadingFacets = false);
    }
  }

  (int firstPage, int lastPage) _visiblePageRange({double extraViewports = 1.0}) {
    final metrics = _lastMetrics;
    final total = _total;
    if (metrics == null || total <= 0) return (0, 0);
    final maxPage = (total - 1) ~/ widget.pageSize;
    if (!_scrollController.hasClients) return (0, math.min(maxPage, 1));
    final pos = _scrollController.position;
    final offset = pos.pixels;
    final vh = pos.hasViewportDimension && pos.viewportDimension > 0 ? pos.viewportDimension : 900.0;
    final pad = vh * extraViewports;
    final firstIdx = metrics.firstVisibleIndex(math.max(0.0, offset - pad));
    final lastIdx = metrics.firstVisibleIndex(offset + vh + pad) + metrics.crossAxisCount;
    return (
      (firstIdx ~/ widget.pageSize).clamp(0, maxPage),
      (lastIdx ~/ widget.pageSize).clamp(0, maxPage),
    );
  }

  bool _isNearVisible(int pageIndex) {
    final (firstP, lastP) = _visiblePageRange(extraViewports: 1.0);
    return pageIndex >= firstP - 1 && pageIndex <= lastP + 1;
  }

  void _schedulePageRequest(int pageIndex) {
    if (_pages.containsKey(pageIndex) || _inFlightPages.contains(pageIndex) || _failedPageIndices.contains(pageIndex)) return;
    _pendingPages.add(pageIndex);
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      if (!mounted || _pendingPages.isEmpty) return;
      final batch = _pendingPages.toList()..sort();
      _pendingPages.clear();
      for (final p in batch) {
        _enqueuePage(p, prefetchNeighbors: batch.length <= 2);
      }
    });
  }

  void _enqueuePage(int pageIndex, {bool prefetchNeighbors = false}) {
    final listing = _listing;
    if (listing == null || pageIndex < 0) return;
    final total = listing.info.total;
    if (pageIndex * widget.pageSize >= total) return;

    void addOne(int p) {
      if (p < 0 || p * widget.pageSize >= total) return;
      if (_pages.containsKey(p)) {
        _pages[p] = _pages.remove(p)!;
        return;
      }
      if (_inFlightPages.contains(p)) return;
      _pageQueue.remove(p);
      _pageQueue.add(p);
    }

    addOne(pageIndex);
    if (prefetchNeighbors) {
      addOne(pageIndex + 1);
      addOne(pageIndex - 1);
    }
    _drainPageQueue();
  }

  void _drainPageQueue() {
    final listing = _listing;
    if (listing == null || !mounted) return;
    final total = listing.info.total;

    _pageQueue.removeWhere((p) => _pages.containsKey(p) || _inFlightPages.contains(p) || !_isNearVisible(p));
    if (_pageQueue.isEmpty || _inFlightPages.length >= _maxConcurrentPages) return;

    final (firstP, lastP) = _visiblePageRange(extraViewports: 0.0);
    final centerP = (firstP + lastP) / 2.0;
    _pageQueue.sort((a, b) => (a - centerP).abs().compareTo((b - centerP).abs()));

    while (_inFlightPages.length < _maxConcurrentPages && _pageQueue.isNotEmpty) {
      final pageIndex = _pageQueue.removeAt(0);
      if (_pages.containsKey(pageIndex) || _inFlightPages.contains(pageIndex) || !_isNearVisible(pageIndex)) {
        continue;
      }
      final offset = pageIndex * widget.pageSize;
      if (offset >= total) continue;
      final gen = _generation;
      _inFlightPages.add(pageIndex);
      listing.page(offset: offset, limit: math.min(widget.pageSize, total - offset)).then((page) {
        if (!mounted || gen != _generation) return;
        _inFlightPages.remove(pageIndex);
        _failedPageIndices.remove(pageIndex);
        if (_failedPageIndices.isEmpty) _pageErrorMessage = null;
        _syncBannerError();

        if (_isNearVisible(pageIndex) || _pages.length < widget.maxCachedPages) {
          _pages.remove(pageIndex);
          _pages[pageIndex] = page.items;
          _evictExcessPages();
          _notifyPage(pageIndex);
        }
        if (!_stageSeeded) {
          for (final item in page.items) {
            if (item.art.stage.layers.isNotEmpty) {
              _stageSeeded = true;
              _scope?.stage.setBaseBackdrop(item.art.stage);
              break;
            }
          }
        }
        _drainPageQueue();
      }).catchError((Object e) {
        if (!mounted || gen != _generation) return;
        _inFlightPages.remove(pageIndex);
        if (_isNearVisible(pageIndex)) {
          _failedPageIndices.add(pageIndex);
          _pageErrorMessage = e is EmbyViewFailure ? e.reason : '部分内容加载失败，请重试';
          _syncBannerError();
        }
        _drainPageQueue();
      });
    }
  }

  void _evictExcessPages() {
    final (firstP, lastP) = _visiblePageRange(extraViewports: 1.0);
    while (_pages.length > widget.maxCachedPages) {
      final victim = _pages.keys.where((k) => k < firstP - 1 || k > lastP + 1).firstOrNull ?? _pages.keys.first;
      _pages.remove(victim);
    }
    _prunePageNotifiers();
  }

  void _retryBannerError() {
    final data = _boundData;
    if (_facetsFailed && data != null) {
      _facetsFailed = false;
      _facetsErrorMessage = null;
      _syncBannerError();
      setState(() => _loadingFacets = true);
      unawaited(_loadFacets(data, _query, _generation));
    }
    if (_failedPageIndices.isNotEmpty) {
      final pages = _failedPageIndices.toList()..sort();
      _failedPageIndices.clear();
      _pageErrorMessage = null;
      _syncBannerError();
      for (final p in pages) {
        _enqueuePage(p);
      }
    }
  }

  MediaCard? _cardAt(int index) {
    final items = _pages[index ~/ widget.pageSize];
    if (items == null) return null;
    final local = index % widget.pageSize;
    return local < items.length ? items[local] : null;
  }

  void _handleScroll() {
    if (!mounted || !_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    _scope?.shell.setScrollOffset(offset);
    if (_failedPageIndices.isNotEmpty) {
      _failedPageIndices.removeWhere((p) => !_isNearVisible(p));
      if (_failedPageIndices.isEmpty && _pageErrorMessage != null) {
        _pageErrorMessage = null;
        _syncBannerError();
      }
    }
    if (!_showAlphaBar) return;
    _markScrolling(const Duration(milliseconds: 900));
    if (_suppressScrollLetterSync) return;
    final metrics = _lastMetrics;
    if (metrics == null || _sortedOffsets.isEmpty) return;
    final next = offset <= 1.0
        ? _sortedOffsets.first.key
        : _letterForIndex(metrics.firstVisibleIndex(offset, probeOffset: _lastLeadOffset + metrics.rowStride * 0.35));
    if (next != _activeLetter.value) _activeLetter.value = next;
  }

  String _letterForIndex(int itemIndex) {
    var lo = 0, hi = _sortedOffsets.length - 1, best = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_sortedOffsets[mid].value <= itemIndex) { best = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return _sortedOffsets[best].key;
  }

  void _markScrolling(Duration hold) {
    if (!_scrolling.value) _scrolling.value = true;
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(hold, () {
      _scrollIdleTimer = null;
      if (mounted && _scrolling.value) _scrolling.value = false;
    });
  }

  void _jumpToLetter(String letter) {
    final idx = _letterOffsets[letter], metrics = _lastMetrics;
    if (idx == null || metrics == null || !_scrollController.hasClients) return;
    final target = metrics.scrollOffsetForIndex(idx, leadOffset: _lastLeadOffset)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _activeLetter.value = letter;
    _markScrolling(const Duration(milliseconds: 1200));
    _suppressScrollLetterSync = true;
    _scrollController.jumpTo(target);
    _suppressScrollLetterSync = false;
    _enqueuePage(idx ~/ widget.pageSize, prefetchNeighbors: true);
  }

  void _togglePopover() => setState(() => _popoverOpen = !_popoverOpen);
  void _closePopover() { if (_popoverOpen) setState(() => _popoverOpen = false); }

  void _onCardHover(MediaCard card, bool hovering) {
    if (hovering) {
      _pendingHoverCard = card;
      _hoverDwellTimer?.cancel();
      _hoverDwellTimer = Timer(const Duration(milliseconds: 500), () {
        _hoverDwellTimer = null;
        if (mounted && _pendingHoverCard != null) {
          _scope?.stage.setBaseBackdrop(_pendingHoverCard!.art.stage);
        }
      });
    } else if (_pendingHoverCard?.id == card.id) {
      _pendingHoverCard = null;
      _hoverDwellTimer?.cancel();
      _hoverDwellTimer = null;
    }
  }

  void _openCard(MediaCard card, Rect origin) {
    if (widget.onOpenItem != null) { widget.onOpenItem!(card); return; }
    final openDetail = _scope?.shell.onOpenDetail;
    if (openDetail != null) { openDetail(card.id); return; }
    _playCard(card, origin: origin);
  }

  void _playCard(MediaCard card, {Rect? origin}) {
    if (widget.onPlayItem != null) { widget.onPlayItem!(card); return; }
    unawaited(EvPlayer.open(context, PlayTarget(itemId: card.id), origin: origin, art: card.art));
  }

  String _sortLabel() =>
      _facets.sorts.where((o) => o.value == _query.sort).firstOrNull?.label ??
      const ['标题', '最近添加', '年份', '评分', '随机'][_query.sort.index];

  List<({String key, String label, VoidCallback remove})> _appliedChips() {
    WallQuery without({bool watched = false, bool genre = false, bool years = false, bool tech = false}) => (
      scope: _query.scope, sort: _query.sort,
      watched: watched ? WatchFilter.all : _query.watched,
      genreId: genre ? null : _query.genreId,
      years: years ? null : _query.years,
      technology: tech ? null : _query.technology,
    );
    return [
      if (_query.watched != WatchFilter.all) (
        key: 'watched',
        label: _facets.watched.where((o) => o.value == _query.watched).firstOrNull?.label ??
            const ['全部', '未看', '已看', '收藏'][_query.watched.index],
        remove: () => _applyQuery(without(watched: true)),
      ),
      if (_query.genreId != null) (
        key: 'genre',
        label: _facets.genres.where((o) => o.value == _query.genreId).firstOrNull?.label ?? _query.genreId!,
        remove: () => _applyQuery(without(genre: true)),
      ),
      if (_query.years != null) (
        key: 'years',
        label: _facets.years.where((o) => evSameYearRange(o.value, _query.years)).firstOrNull?.label ??
            (_query.years!.from == _query.years!.to ? '${_query.years!.from}' : '${_query.years!.from ?? ''}–${_query.years!.to ?? ''}'),
        remove: () => _applyQuery(without(years: true)),
      ),
      if (_query.technology != null) (
        key: 'technology',
        label: _facets.technologies.where((o) => o.value == _query.technology).firstOrNull?.label ??
            const ['4K', '杜比视界', 'HDR', '5.1'][_query.technology!.index],
        remove: () => _applyQuery(without(tech: true)),
      ),
    ];
  }

  String _cardSubtitle(MediaCard card) {
    if (card.kind == MediaKind.collection && card.childCount != null) return '${card.childCount} 部';
    return [
      if (card.year != null) '${card.year}',
      if (_query.sort == WallSort.score && card.score != null) '★ ${card.score!.toStringAsFixed(1)}'
      else if (card.genres.isNotEmpty) card.genres.first,
    ].join(' · ');
  }

  void _captureHeaderHeight() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.height > 0 &&
        (_measuredHeaderHeight == null || (_measuredHeaderHeight! - box.size.height).abs() > 0.5)) {
      setState(() => _measuredHeaderHeight = box.size.height);
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), gutter = scale.gutter;
    final filterCount = evWallActiveFilterCount(_query), applied = _appliedChips();
    final estHeader = scale.rem(applied.isEmpty ? 11.75 : 15.0);

    return CallbackShortcuts(
      bindings: {if (_popoverOpen) const SingleActivator(LogicalKeyboardKey.escape): _closePopover},
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vw = constraints.hasBoundedWidth && constraints.maxWidth > 0 ? constraints.maxWidth : scale.size.width;
          if (_lastViewportWidth != vw) { _lastViewportWidth = vw; _measuredHeaderHeight = null; }
          if (_measuredHeaderHeight == null) _captureHeaderHeight();
          final metrics = EvWallGridMetrics.compute(
            viewportWidth: vw, scale: scale, gridTopOffset: _measuredHeaderHeight ?? estHeader,
          );
          _lastMetrics = metrics;
          _lastLeadOffset = scale.rem(5.5);
          final scrolledPast = _scrollController.hasClients && _scrollController.offset > scale.rem(4.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              CustomScrollView(
                key: const Key('ev_wall_scroll_view'),
                controller: _scrollController,
                scrollCacheExtent: const ScrollCacheExtent.viewport(0.75),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      key: _headerKey,
                      padding: EdgeInsets.fromLTRB(gutter, scale.rem(6.5), gutter, scale.rem(1.0)),
                      child: Column(
                        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeaderRow(theme, scale, filterCount),
                          if (applied.isNotEmpty)
                            Padding(
                              padding: EdgeInsets.only(top: scale.rem(0.75), bottom: scale.rem(0.5)),
                              child: Wrap(
                                key: const Key('ev_wall_applied_filters'),
                                spacing: scale.rem(0.5), runSpacing: scale.rem(0.5),
                                children: [
                                  for (final c in applied)
                                    EvWallChip(key: Key('ev_wall_applied_${c.key}'), label: c.label, selected: true, removable: true, onTap: c.remove),
                                ],
                              ),
                            )
                          else
                            SizedBox(height: scale.rem(0.75)),
                        ],
                      ),
                    ),
                  ),
                  if (_loadingWall && _listing == null) _buildGrid(gutter, metrics, placeholderCount: math.min(24, metrics.crossAxisCount * 3))
                  else if (_error != null) SliverToBoxAdapter(child: _buildErrorState(theme, scale))
                  else if (_total == 0) SliverToBoxAdapter(child: _buildEmptyState(theme, scale, filterCount))
                  else _buildGrid(gutter, metrics),
                  SliverToBoxAdapter(child: SizedBox(height: scale.rem(6.0))),
                ],
              ),
              if (_showAlphaBar)
                Positioned(
                  right: scale.rem(1.125), top: 0, bottom: 0,
                  child: Center(
                    child: ListenableBuilder(
                      listenable: Listenable.merge([_activeLetter, _scrolling]),
                      builder: (_, _) => EvAlphaIndexBar(
                        letterOffsets: _letterOffsets, activeLetter: _activeLetter.value,
                        scrolling: _scrolling.value, onSelectLetter: _jumpToLetter,
                      ),
                    ),
                  ),
                ),
              ValueListenableBuilder<String?>(
                valueListenable: _bannerError,
                builder: (_, message, _) {
                  if (message == null || _error != null) return const SizedBox.shrink();
                  return Positioned(
                    left: gutter,
                    right: gutter,
                    top: scale.rem(5.0),
                    child: _buildErrorBanner(theme, scale, message),
                  );
                },
              ),
              if (_popoverOpen) ...[
                Positioned.fill(
                  child: GestureDetector(key: const Key('ev_wall_popover_scrim'), behavior: HitTestBehavior.translucent, onTap: _closePopover),
                ),
                Positioned(
                  right: gutter, top: scale.rem(scrolledPast ? 4.25 : 9.75),
                  child: EvWallFilterPopover(
                    current: _query, facets: _facets, totalCount: _listing?.info.total,
                    unit: _resolvedUnit, loading: _loadingFacets,
                    onChanged: _applyQuery, onReset: _resetFilters, onClose: _closePopover,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeaderRow(EvTheme theme, EvScale scale, int filterCount) {
    final totalText = _loadingWall && _listing == null ? '加载中…' : '${evFormatCount(_total)} $_resolvedUnit';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(_resolvedTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.displayStyle(scale.font(3.0), color: theme.ink, height: 1.0)),
              ),
              SizedBox(width: scale.rem(1.25)),
              Text(totalText, key: const Key('ev_wall_total_count'),
                  style: theme.bodyStyle(scale.font(1.0625), color: theme.ink3).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ),
        SizedBox(width: scale.rem(1.0)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _EvWallToolButton(
              key: const Key('ev_wall_sort_button'), icon: EvIcons.sort, label: _sortLabel(),
              trailing: EvIcon(EvIcons.down, size: scale.rem(0.75), color: theme.ink.withValues(alpha: 0.6)),
              onTap: _togglePopover,
            ),
            SizedBox(width: scale.rem(0.5)),
            _EvWallToolButton(
              key: const Key('ev_wall_filter_button'), icon: EvIcons.filter, label: '筛选',
              badgeCount: filterCount, onTap: _togglePopover,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGrid(double gutter, EvWallGridMetrics metrics, {int? placeholderCount}) {
    final isPlaceholder = placeholderCount != null;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: gutter),
      sliver: SliverGrid(
        key: isPlaceholder ? null : const Key('ev_wall_grid'),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: metrics.crossAxisCount, crossAxisSpacing: metrics.crossAxisSpacing,
          mainAxisSpacing: metrics.mainAxisSpacing, mainAxisExtent: metrics.itemHeight,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, index) {
            if (isPlaceholder) return RepaintBoundary(child: _WallCardPlaceholder(width: metrics.itemWidth));
            final pageIndex = index ~/ widget.pageSize;
            return RepaintBoundary(
              child: ValueListenableBuilder<int>(
                valueListenable: _notifierForPage(pageIndex),
                builder: (_, _, _) {
                  final card = _cardAt(index);
                  if (card == null) {
                    _schedulePageRequest(pageIndex);
                    return _WallCardPlaceholder(width: metrics.itemWidth);
                  }
                  return Align(
                    alignment: Alignment.topCenter,
                    child: EvCard(
                      key: ValueKey<String>('ev_wall_card_${card.id}'), card: card,
                      style: card.kind == MediaKind.collection ? EvCardStyle.collection : EvCardStyle.poster,
                      width: metrics.itemWidth, alwaysShowLabel: true, subtitle: _cardSubtitle(card),
                      onHoverChanged: (h) => _onCardHover(card, h), onFocusChanged: (f) => _onCardHover(card, f),
                      onTap: () {}, onActivateWithOrigin: (origin) => _openCard(card, origin),
                      onPlay: () => _playCard(card),
                    ),
                  );
                },
              ),
            );
          },
          childCount: placeholderCount ?? _total,
          addAutomaticKeepAlives: false, addRepaintBoundaries: false,
        ),
      ),
    );
  }

  Widget _buildErrorBanner(EvTheme theme, EvScale scale, String message) => EvGlass(
    key: const Key('ev_wall_error_banner'),
    solid: true,
    borderRadius: BorderRadius.circular(scale.rem(0.875)),
    padding: EdgeInsets.symmetric(horizontal: scale.rem(1.0), vertical: scale.rem(0.625)),
    child: Row(
      children: [
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.bodyStyle(scale.font(0.9375), color: theme.ink),
          ),
        ),
        SizedBox(width: scale.rem(0.75)),
        EvButton.ghost(
          key: const Key('ev_wall_error_banner_retry'),
          label: '重试',
          small: true,
          glass: false,
          onPressed: _retryBannerError,
        ),
      ],
    ),
  );

  Widget _buildEmptyState(EvTheme theme, EvScale scale, int filterCount) => Padding(
    key: const Key('ev_wall_empty_state'),
    padding: EdgeInsets.symmetric(vertical: scale.rem(5.0), horizontal: scale.gutter),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (theme.isPaper) EvIcon(EvIcons.illEmpty, size: scale.rem(9.0), color: theme.ink2)
        else Opacity(opacity: 0.55, child: EvIcon(EvIcons.search, size: scale.rem(3.0), color: theme.ink2)),
        SizedBox(height: scale.rem(1.25)),
        Text('没有符合条件的$_resolvedTitle', textAlign: TextAlign.center, style: theme.displayStyle(scale.font(1.625), color: theme.ink)),
        SizedBox(height: scale.rem(0.5)),
        Text(filterCount > 0 ? '试试放宽筛选条件' : '片库里暂时还没有内容', textAlign: TextAlign.center, style: theme.bodyStyle(scale.font(1.0), color: theme.ink3)),
        if (filterCount > 0) ...[
          SizedBox(height: scale.rem(1.5)),
          EvButton.ghost(key: const Key('ev_wall_clear_filters'), small: true, label: '清除全部筛选', onPressed: _resetFilters),
        ],
      ],
    ),
  );

  Widget _buildErrorState(EvTheme theme, EvScale scale) => Padding(
    key: const Key('ev_wall_error_state'),
    padding: EdgeInsets.symmetric(vertical: scale.rem(5.0), horizontal: scale.gutter),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_error?.reason ?? '加载失败', textAlign: TextAlign.center, style: theme.displayStyle(scale.font(1.5), color: theme.ink)),
        SizedBox(height: scale.rem(1.25)),
        EvButton.ghost(small: true, label: '重试', onPressed: _reloadAll),
      ],
    ),
  );
}

class _PageSignal extends ValueNotifier<int> {
  _PageSignal() : super(0);
  bool get active => hasListeners;
}

/// Static, zero-ticker placeholder tile for unpaged grid cells during fast scrolling.
class _WallCardPlaceholder extends StatelessWidget {
  const _WallCardPlaceholder({required this.width});
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: width, height: width * 1.5,
          decoration: BoxDecoration(
            color: theme.fill2, borderRadius: BorderRadius.circular(scale.rem(theme.posterRadius)),
            border: Border.all(color: theme.line, width: 1),
          ),
        ),
        SizedBox(height: scale.rem(0.875)),
        Container(width: width * 0.72, height: scale.rem(0.875),
            decoration: BoxDecoration(color: theme.fill2, borderRadius: BorderRadius.circular(scale.rem(0.4375)))),
        SizedBox(height: scale.rem(0.375)),
        Container(width: width * 0.44, height: scale.rem(0.75),
            decoration: BoxDecoration(color: theme.fill, borderRadius: BorderRadius.circular(scale.rem(0.375)))),
      ],
    );
  }
}

/// Pill tool button mirroring `.tool.glass` in `.spec/mockups/proto.css`.
class _EvWallToolButton extends StatefulWidget {
  const _EvWallToolButton({
    super.key, required this.icon, required this.label, this.trailing, this.badgeCount = 0, required this.onTap,
  });
  final EvIconData icon;
  final String label;
  final Widget? trailing;
  final int badgeCount;
  final VoidCallback onTap;

  @override
  State<_EvWallToolButton> createState() => _EvWallToolButtonState();
}

class _EvWallToolButtonState extends State<_EvWallToolButton> {
  bool _hovered = false, _focused = false, _pressed = false;
  bool get _hi => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final badgeBg = theme.isPaper ? theme.priBg : theme.accent;
    final badgeFg = theme.isPaper ? const Color(0xFFFFFFFF) : theme.bg;
    return Semantics(
      button: true, focused: _focused, label: widget.label,
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!evIsActivateKey(e)) return KeyEventResult.ignored;
          widget.onTap();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _pressed ? 0.95 : 1.0, duration: const Duration(milliseconds: 300), curve: EvCurves.spring,
              child: EvGlass(
                borderRadius: BorderRadius.circular(999),
                color: _hi ? theme.fill3 : null,
                borderColor: _focused ? theme.focusColor : null,
                child: SizedBox(
                  height: scale.rem(2.375),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: scale.rem(0.9375)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        EvIcon(widget.icon, size: scale.rem(1.0625), color: theme.ink.withValues(alpha: 0.9)),
                        SizedBox(width: scale.rem(0.5)),
                        Text(widget.label, style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w500, color: theme.ink)),
                        if (widget.badgeCount > 0) ...[
                          SizedBox(width: scale.rem(0.5)),
                          Container(
                            key: const Key('ev_wall_filter_badge'),
                            constraints: BoxConstraints(minWidth: scale.rem(1.25)), height: scale.rem(1.25),
                            padding: EdgeInsets.symmetric(horizontal: scale.rem(0.3)),
                            decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(999)),
                            alignment: Alignment.center,
                            child: Text('${widget.badgeCount}', style: theme.bodyStyle(scale.rem(0.75), fontWeight: FontWeight.w700, color: badgeFg, height: 1.0)),
                          ),
                        ],
                        if (widget.trailing != null) ...[SizedBox(width: scale.rem(0.375)), widget.trailing!],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact top-bar sort/filter trigger placed in `EvShellController.rightActions`.
class _EvChromeFilterAction extends StatelessWidget {
  const _EvChromeFilterAction({super.key, required this.filterCount, required this.onTap});
  final int filterCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final badgeBg = theme.isPaper && !theme.onImage ? theme.priBg : theme.accent;
    final badgeFg = theme.isPaper && !theme.onImage ? const Color(0xFFFFFFFF) : theme.bg;
    return EvButton.ghost(
      small: true, round: filterCount == 0, tooltip: '排序与筛选', onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          EvIcon(EvIcons.filter, size: scale.rem(1.0625), color: theme.ink),
          if (filterCount > 0) ...[
            SizedBox(width: scale.rem(0.375)),
            Container(
              constraints: BoxConstraints(minWidth: scale.rem(1.125)), height: scale.rem(1.125),
              padding: EdgeInsets.symmetric(horizontal: scale.rem(0.25)),
              decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(999)),
              alignment: Alignment.center,
              child: Text('$filterCount', style: theme.bodyStyle(scale.rem(0.75), fontWeight: FontWeight.w700, color: badgeFg, height: 1.0)),
            ),
          ],
        ],
      ),
    );
  }
}
