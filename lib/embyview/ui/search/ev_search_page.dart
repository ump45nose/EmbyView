import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/search/ev_search_top_match.dart';

/// Instant search page aligned with `.spec/mockups/proto.js` (`vSearch`) and `proto.css`.
class EvSearchPage extends StatefulWidget {
  const EvSearchPage({
    super.key, this.initialQuery, this.zoneId, this.onOpenItem, this.onOpenPalette, this.onPlayTarget,
  });

  final String? initialQuery, zoneId;
  final ValueChanged<String>? onOpenItem;
  final VoidCallback? onOpenPalette;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin)? onPlayTarget;

  @override
  State<EvSearchPage> createState() => _EvSearchPageState();
}

class _EvSearchPageState extends State<EvSearchPage> {
  static const _debounceDelay = Duration(milliseconds: 180);
  static const _pageSize = 20;

  late final _controller = TextEditingController(text: widget.initialQuery ?? '');
  final _inputFocus = FocusNode(debugLabel: 'ev_search_input');
  final _scrollController = ScrollController();

  EvScope? _scope;
  String? _boundSessionId, _landingError, _searchError;
  EmbyViewData? _boundData;
  Timer? _debounceTimer;
  int _landingGen = 0, _searchGen = 0;

  SearchLanding? _landing;
  SearchResults? _results;
  String _activeQuery = '';
  bool _loadingLanding = false, _searchedSinceLanding = false, _searching = false, _loadingMore = false, _inputFocused = false;

  bool get _isQueryMode => _controller.text.trim().isNotEmpty || _activeQuery.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onInputFocus);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _inputFocus.requestFocus(); });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context), first = _scope == null;
    final switched = _boundSessionId != scope.services.sessionId || !identical(_boundData, scope.services.data);
    _scope = scope; _boundSessionId = scope.services.sessionId; _boundData = scope.services.data;
    if (first) {
      _syncStageAndChrome(scope);
      final q = _controller.text.trim();
      unawaited(q.isNotEmpty ? _executeSearch(q) : _loadLanding());
    } else if (switched) {
      _debounceTimer?.cancel();
      _searchGen++; _landingGen++; _controller.clear();
      setState(() { _clearSearchFields(); _landing = null; _landingError = null; _searchedSinceLanding = false; });
      _syncStageAndChrome(scope);
      unawaited(_loadLanding());
    }
  }

  @override
  void didUpdateWidget(EvSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoneId == widget.zoneId) return;
    _debounceTimer?.cancel();
    _landing = null; _results = null; _searchError = null; _landingError = null;
    final q = _controller.text.trim();
    unawaited(q.isNotEmpty ? _executeSearch(q) : _loadLanding());
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _inputFocus..removeListener(_onInputFocus)..dispose();
    _scrollController..removeListener(_onScroll)..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _clearSearchFields() { _activeQuery = ''; _results = null; _searching = false; _loadingMore = false; _searchError = null; }
  void _onInputFocus() { if (mounted && _inputFocused != _inputFocus.hasFocus) setState(() => _inputFocused = _inputFocus.hasFocus); }
  void _onScroll() { if (_scrollController.hasClients) _scope?.shell.setScrollOffset(_scrollController.offset); }

  void _syncStageAndChrome(EvScope scope) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    scope.immersion.onCardHoverEnd();
    scope.stage..setMode(EvStageMode.ambient)..setScrollProgress(0.4)..setVeilLifted(false)..setAmbientColor(null);
    scope.shell..updateChrome(clearTitlePlate: true, rightActions: const [], hideTabs: false, hideAvatar: false)..setScrollOffset(0.0);
  });

  Future<void> _loadLanding({bool silent = false}) async {
    final data = _boundData;
    if (data == null) return;
    final gen = ++_landingGen;
    if (!silent) setState(() { _loadingLanding = true; _landingError = null; });
    try {
      final landing = await data.searchLanding(zoneId: widget.zoneId);
      if (!mounted || gen != _landingGen) return;
      setState(() { _landing = landing; _loadingLanding = false; _landingError = null; _searchedSinceLanding = false; });
    } catch (e) {
      if (!mounted || gen != _landingGen) return;
      setState(() { _loadingLanding = false; if (!silent) _landingError = e is EmbyViewFailure ? e.reason : '无法加载推荐内容，请重试。'; });
    }
  }

  void _returnToLanding() {
    _searchGen++;
    setState(_clearSearchFields);
    if (_landing == null && !_loadingLanding) { unawaited(_loadLanding()); }
    else if (_searchedSinceLanding) { unawaited(_loadLanding(silent: true)); }
  }

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    final term = value.trim();
    if (term.isEmpty) { _returnToLanding(); return; }
    setState(() {});
    _debounceTimer = Timer(_debounceDelay, () => unawaited(_executeSearch(term)));
  }

  void _submitNow([String? overrideTerm]) {
    _debounceTimer?.cancel();
    final term = (overrideTerm ?? _controller.text).trim();
    term.isEmpty ? _clearQuery() : unawaited(_executeSearch(term));
  }

  void _pickRecentTerm(String term) {
    _controller.value = TextEditingValue(text: term, selection: TextSelection.collapsed(offset: term.length));
    _submitNow(term);
  }

  void _clearQuery() { _debounceTimer?.cancel(); _controller.clear(); _returnToLanding(); _inputFocus.requestFocus(); }

  Future<void> _executeSearch(String term) async {
    final data = _boundData;
    if (data == null) return;
    final gen = ++_searchGen;
    setState(() { _activeQuery = term; _searching = true; _loadingMore = false; _searchError = null; });
    try {
      final res = await data.search(term, zoneId: widget.zoneId, offset: 0, limit: _pageSize);
      if (!mounted || gen != _searchGen) return;
      setState(() { _results = res; _searching = false; _searchedSinceLanding = true; });
    } catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() { _searching = false; _searchError = e is EmbyViewFailure ? e.reason : '搜索失败，请重试。'; });
    }
  }

  Future<void> _loadMore(int nextOffset) async {
    final data = _boundData, cur = _results;
    if (data == null || cur == null || _loadingMore || _activeQuery.isEmpty) return;
    final gen = _searchGen;
    setState(() => _loadingMore = true);
    try {
      final more = await data.search(_activeQuery, zoneId: widget.zoneId, offset: nextOffset, limit: _pageSize);
      if (!mounted || gen != _searchGen) return;
      SearchGroup makeGroup(String id, String name, List<MediaCard> items, int total, int? next) =>
          SearchGroup(libraryId: id, name: name, items: items, total: total, nextOffset: items.length < total ? next : null);
      final byLib = <String, SearchGroup>{for (final g in cur.groups) g.libraryId: makeGroup(g.libraryId, g.name, g.items, g.total, more.nextOffset)};
      final order = <String>[for (final g in cur.groups) g.libraryId];
      for (final inc in more.groups) {
        final ex = byLib[inc.libraryId], next = inc.nextOffset ?? more.nextOffset;
        if (ex == null) { byLib[inc.libraryId] = makeGroup(inc.libraryId, inc.name, inc.items, inc.total, next); order.add(inc.libraryId); continue; }
        final seen = {for (final c in ex.items) c.id};
        final merged = [...ex.items, for (final c in inc.items) if (seen.add(c.id)) c];
        byLib[inc.libraryId] = makeGroup(ex.libraryId, ex.name.isNotEmpty ? ex.name : inc.name, merged, math.max(ex.total, inc.total), next);
      }
      setState(() {
        _results = SearchResults(bestMatch: cur.bestMatch ?? more.bestMatch,
            groups: [for (final id in order) byLib[id]!], total: math.max(cur.total, more.total), nextOffset: more.nextOffset);
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted && gen == _searchGen) setState(() => _loadingMore = false);
    }
  }

  void _openItem(String id) => widget.onOpenItem != null ? widget.onOpenItem!(id) : EvScope.of(context).shell.onOpenDetail?.call(id);
  void _playTarget(PlayTarget target, CardArtwork art, {Rect? origin}) => widget.onPlayTarget != null
      ? widget.onPlayTarget!(target, art, origin) : unawaited(EvPlayer.open(context, target, origin: origin, art: art));
  void _playCard(MediaCard card) => _playTarget(PlayTarget(itemId: card.id), card.art);

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        key: const Key('ev_search_scroller'), controller: _scrollController, padding: EdgeInsets.only(top: s.rem(7.0), bottom: s.rem(6.0)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: EdgeInsets.symmetric(horizontal: s.gutter), child: _buildSearchField(t, s)),
          _isQueryMode ? _buildResults(t, s) : _buildLanding(t, s),
        ]),
      ),
    );
  }

  Widget _buildSearchField(EvTheme t, EvScale s) {
    final hasText = _controller.text.isNotEmpty;
    return Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: s.rem(46.0)), child: GestureDetector(
      behavior: HitTestBehavior.opaque, onTap: _inputFocus.requestFocus,
      child: EvGlass(
        key: const Key('ev_search_field'), borderRadius: BorderRadius.circular(999),
        borderColor: _inputFocused ? t.focusColor : null, padding: EdgeInsets.symmetric(horizontal: s.rem(1.5)),
        child: SizedBox(height: s.rem(4.25), child: Row(children: [
          EvIcon(EvIcons.search, size: s.rem(1.5), color: t.ink.withValues(alpha: 0.65)),
          SizedBox(width: s.rem(1.0)),
          Expanded(child: Stack(alignment: Alignment.centerLeft, children: [
            if (!hasText) IgnorePointer(child: Text('电影、剧集、番剧、演员', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: t.bodyStyle(s.font(1.5), fontWeight: FontWeight.w500, color: t.ink3))),
            EditableText(
              key: const Key('ev_search_input'), controller: _controller, focusNode: _inputFocus, autofocus: true,
              maxLines: 1, textInputAction: TextInputAction.search, onChanged: _onQueryChanged, onSubmitted: (_) => _submitNow(),
              style: t.bodyStyle(s.font(1.5), fontWeight: FontWeight.w500, color: t.ink),
              cursorColor: t.isPaper ? t.brand : t.ink, backgroundCursorColor: t.ink4,
              selectionColor: (t.isPaper ? t.brand : t.accent).withValues(alpha: 0.28),
            ),
          ])),
          if (hasText) ...[
            SizedBox(width: s.rem(0.5)),
            _EvSearchAction(key: const Key('ev_search_clear'), label: '清除搜索', onTap: _clearQuery, builder: (_, hi, _, _) =>
              AnimatedContainer(duration: EvDurations.fast, curve: EvCurves.soft, width: s.rem(2.0), height: s.rem(2.0),
                decoration: BoxDecoration(shape: BoxShape.circle, color: hi ? t.fill2 : const Color(0x00000000)),
                alignment: Alignment.center, child: EvIcon(EvIcons.x, size: s.rem(1.0), color: hi ? t.ink : t.ink2))),
          ],
          SizedBox(width: s.rem(0.75)),
          _EvSearchAction(key: const Key('ev_search_palette_kbd'), label: '命令面板', onTap: widget.onOpenPalette, builder: (_, hi, _, _) =>
            AnimatedContainer(duration: EvDurations.fast, curve: EvCurves.soft, padding: EdgeInsets.symmetric(horizontal: s.rem(0.5), vertical: s.rem(0.2)),
              decoration: BoxDecoration(color: hi ? t.fill2 : const Color(0x00000000), borderRadius: BorderRadius.circular(s.rem(0.375)), border: Border.all(color: hi ? t.ink3 : t.fill3)),
              child: Text('⌘ K 命令', maxLines: 1, softWrap: false, style: t.bodyStyle(s.font(0.8125), color: hi ? t.ink : t.ink3)))),
        ])),
      ),
    )));
  }

  Widget _buildLanding(EvTheme t, EvScale s) {
    if (_loadingLanding && _landing == null) return Padding(padding: EdgeInsets.only(top: s.rem(3.0)), child: const EvShelf(title: '', loading: true));
    if (_landingError != null && _landing == null) return _buildMessage(t, s, title: _landingError!, subtitle: '检查服务器连接后重试', actionLabel: '重试', onAction: () => unawaited(_loadLanding()));
    final landing = _landing;
    if (landing == null) return const SizedBox.shrink();
    return Column(key: const Key('ev_search_landing'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (landing.recentTerms.isNotEmpty)
        Padding(padding: EdgeInsets.fromLTRB(s.gutter, s.rem(1.5), s.gutter, s.rem(2.5)), child: Wrap(
          key: const Key('ev_search_recent_terms'), alignment: WrapAlignment.center, spacing: s.rem(0.5), runSpacing: s.rem(0.5),
          children: [for (var i = 0; i < landing.recentTerms.length; i++) _buildRecentChip(t, s, i, landing.recentTerms[i])],
        ))
      else SizedBox(height: s.rem(2.5)),
      for (final sh in landing.shelves.where((sh) => sh.items.isNotEmpty))
        EvShelf(key: ValueKey<String>('ev_search_landing_shelf_${sh.id}'), title: sh.title,
          badge: sh.total != null ? '${sh.total}' : null, items: sh.items, onCardTap: (c) => _openItem(c.id), onCardPlay: _playCard),
    ]);
  }

  Widget _buildRecentChip(EvTheme t, EvScale s, int i, String term) => _EvSearchAction(
    key: Key('ev_search_recent_$i'), label: term, onTap: () => _pickRecentTerm(term),
    builder: (_, hi, focused, pressed) => AnimatedScale(scale: pressed ? 0.95 : 1.0, duration: EvDurations.normal, curve: EvCurves.spring,
      child: AnimatedContainer(
        duration: EvDurations.fast, curve: EvCurves.soft, height: s.rem(2.375), padding: EdgeInsets.symmetric(horizontal: s.rem(1.0625)),
        decoration: BoxDecoration(color: hi ? t.fill2 : (t.isPaper ? const Color(0xFFFFFFFF) : t.fill),
          borderRadius: BorderRadius.circular(999), border: Border.all(color: focused ? t.focusColor : t.line, width: focused ? 1.5 : 1.0)),
        alignment: Alignment.center,
        child: Text(term, maxLines: 1, softWrap: false, style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w500, color: hi ? t.ink : t.ink2)),
      )),
  );

  Widget _buildResults(EvTheme t, EvScale s) {
    if (_searching && _results == null) return Padding(padding: EdgeInsets.only(top: s.rem(2.5)), child: const EvShelf(title: '', loading: true));
    if (_searchError != null && _results == null) return _buildMessage(t, s, title: _searchError!, subtitle: '请稍后重试', actionLabel: '重试', onAction: () => _submitNow(_activeQuery));
    final res = _results;
    if (res == null) return const SizedBox.shrink();
    final groups = res.groups.where((g) => g.items.isNotEmpty).toList();
    if (res.bestMatch == null && groups.isEmpty) {
      return _buildMessage(t, s, key: const Key('ev_search_empty'), title: '没有找到“$_activeQuery”', subtitle: '换个片名、原名或演员试试');
    }
    return Padding(
      key: const Key('ev_search_results'), padding: EdgeInsets.symmetric(horizontal: s.gutter),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (res.bestMatch != null) ...[
          _heading(t, s, '最佳匹配'),
          EvSearchTopMatch(card: res.bestMatch!, query: _activeQuery,
            onPlay: (target, art, origin) => _playTarget(target, art, origin: origin), onOpenDetail: () => _openItem(res.bestMatch!.id)),
        ],
        for (final g in groups) ...[
          _heading(t, s, g.name, count: g.total),
          _buildGroupGrid(s, g),
          if (g.items.length < g.total && g.nextOffset != null)
            Padding(padding: EdgeInsets.only(top: s.rem(1.5)), child: Align(alignment: Alignment.centerLeft, child: EvButton.ghost(
              key: Key('ev_search_more_${g.libraryId}'), small: true, glass: true,
              label: _loadingMore ? '正在加载…' : '加载更多', onPressed: _loadingMore ? null : () => unawaited(_loadMore(g.nextOffset!)),
            ))),
        ],
      ]),
    );
  }

  Widget _heading(EvTheme t, EvScale s, String title, {int? count}) => Padding(
    padding: EdgeInsets.only(top: s.rem(2.5), bottom: s.rem(1.0)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
      Text(title, style: t.shelfStyle(s.font(1.5))),
      if (count != null) ...[
        SizedBox(width: s.rem(0.75)),
        Text('$count', style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w500, color: t.ink3).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    ]),
  );

  Widget _buildGroupGrid(EvScale s, SearchGroup group) {
    final gap = s.rem(1.25), runGap = s.rem(1.75), minW = s.rem(10.5);
    return LayoutBuilder(key: Key('ev_search_group_${group.libraryId}'), builder: (_, c) {
      final avail = c.maxWidth > 0 ? c.maxWidth : s.size.width - s.gutter * 2;
      final cols = math.max(1, ((avail + gap) / (minW + gap)).floor());
      final cardW = math.max(1.0, (avail - (cols - 1) * gap) / cols);
      return Wrap(spacing: gap, runSpacing: runGap, children: [
        for (final card in group.items)
          EvCard(
            key: ValueKey<String>('ev_search_card_${group.libraryId}_${card.id}'), card: card,
            style: card.kind == MediaKind.collection ? EvCardStyle.collection : EvCardStyle.poster,
            width: cardW, posterHeight: cardW * 1.5, alwaysShowLabel: true,
            onTap: () => _openItem(card.id), onPlay: () => _playCard(card),
          ),
      ]);
    });
  }

  Widget _buildMessage(EvTheme t, EvScale s, {Key? key, required String title, required String subtitle, String? actionLabel, VoidCallback? onAction}) =>
      Padding(key: key, padding: EdgeInsets.symmetric(horizontal: s.gutter, vertical: s.rem(5.0)), child: Column(mainAxisSize: MainAxisSize.min, children: [
        EvIcon(EvIcons.illEmpty, size: s.rem(9.0), color: t.ink2),
        SizedBox(height: s.rem(1.25)),
        Text(title, textAlign: TextAlign.center, style: t.displayStyle(s.font(1.625), color: t.ink)),
        SizedBox(height: s.rem(0.5)),
        Text(subtitle, textAlign: TextAlign.center, style: t.bodyStyle(s.font(1.0), color: t.ink3)),
        if (actionLabel != null && onAction != null) ...[SizedBox(height: s.rem(1.5)), EvButton.ghost(small: true, glass: true, label: actionLabel, onPressed: onAction)],
      ]));
}

class _EvSearchAction extends StatefulWidget {
  const _EvSearchAction({super.key, required this.label, required this.onTap, required this.builder});
  final String label; final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool highlighted, bool focused, bool pressed) builder;
  @override State<_EvSearchAction> createState() => _EvSearchActionState();
}

class _EvSearchActionState extends State<_EvSearchAction> {
  bool _hovered = false, _focused = false, _pressed = false;
  bool get _enabled => widget.onTap != null;
  @override
  Widget build(BuildContext context) => Semantics(button: true, enabled: _enabled, focused: _focused, label: widget.label,
    child: Focus(canRequestFocus: _enabled, onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (_, e) { if (!_enabled || !evIsActivateKey(e)) return KeyEventResult.ignored; widget.onTap!(); return KeyEventResult.handled; },
      child: MouseRegion(cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          child: widget.builder(context, _enabled && (_hovered || _focused), _focused, _pressed)))));
}
