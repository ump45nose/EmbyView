import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Page;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Controls open/close state for [EvCommandPaletteHost].
class EvCommandPaletteController extends ChangeNotifier {
  bool _isOpen = false;
  bool get isOpen => _isOpen;
  void open() { if (!_isOpen) { _isOpen = true; notifyListeners(); } }
  void close() { if (_isOpen) { _isOpen = false; notifyListeners(); } }
  void toggle() { _isOpen = !_isOpen; notifyListeners(); }
}

/// Global ⌘K / Ctrl+K shortcut host wrapping page content and rendering
/// [EvCommandPaletteOverlay] above it while open.
class EvCommandPaletteHost extends StatefulWidget {
  const EvCommandPaletteHost({
    super.key, required this.child, this.controller, this.onBeforeOpen,
    this.onOpenDetail, this.onOpenSearch, this.onOpenSettings, this.onOpenUsers,
    this.onAddZone, this.onOpenZone, this.onPlayTarget,
  });

  final Widget child;
  final EvCommandPaletteController? controller;
  final VoidCallback? onBeforeOpen, onOpenSearch, onOpenSettings, onOpenUsers, onAddZone;
  final ValueChanged<String>? onOpenDetail, onOpenZone;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin)? onPlayTarget;

  @override
  State<EvCommandPaletteHost> createState() => _EvCommandPaletteHostState();
}

class _EvCommandPaletteHostState extends State<EvCommandPaletteHost> {
  late EvCommandPaletteController _controller;
  late bool _ownsController;
  bool _wasOpen = false;
  FocusNode? _previousFocus;

  @override
  void initState() { super.initState(); _attach(widget.controller); HardwareKeyboard.instance.addHandler(_onHardwareKey); }

  void _attach(EvCommandPaletteController? provided) {
    _ownsController = provided == null;
    _controller = (provided ?? EvCommandPaletteController())..addListener(_onChanged);
    _wasOpen = _controller.isOpen;
  }

  @override
  void didUpdateWidget(EvCommandPaletteHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
    _attach(widget.controller);
  }

  void _onChanged() {
    final open = _controller.isOpen;
    if (open == _wasOpen) return;
    _wasOpen = open;
    if (open) { _previousFocus = FocusManager.instance.primaryFocus; widget.onBeforeOpen?.call(); }
    else {
      final prev = _previousFocus; _previousFocus = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final cur = FocusManager.instance.primaryFocus;
        if (mounted && prev != null && prev.canRequestFocus && prev.context != null && (cur == null || cur is FocusScopeNode)) prev.requestFocus();
      });
    }
    if (mounted) setState(() {});
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent || (ModalRoute.of(context)?.isCurrent == false)) return false;
    final hw = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyK && (hw.isMetaPressed || hw.isControlPressed) && !hw.isAltPressed) { _controller.toggle(); return true; }
    if (_controller.isOpen && event.logicalKey == LogicalKeyboardKey.escape) { _controller.close(); return true; }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
    widget.child,
    if (_controller.isOpen)
      Positioned.fill(child: EvCommandPaletteOverlay(
        onClose: _controller.close, onOpenDetail: widget.onOpenDetail, onOpenSearch: widget.onOpenSearch,
        onOpenSettings: widget.onOpenSettings, onOpenUsers: widget.onOpenUsers,
        onAddZone: widget.onAddZone, onOpenZone: widget.onOpenZone, onPlayTarget: widget.onPlayTarget,
      )),
  ]);
}

/// Standalone ⌘K command palette overlay matching `.cmdk` and `.cmdk .box.glass`
/// from `.spec/mockups/proto.css` and `proto.js`.
class EvCommandPaletteOverlay extends StatefulWidget {
  const EvCommandPaletteOverlay({
    super.key, this.onClose, this.onOpenDetail, this.onOpenSearch, this.onOpenSettings,
    this.onOpenUsers, this.onAddZone, this.onOpenZone, this.onPlayTarget,
    this.debounceDuration = const Duration(milliseconds: 150),
  });

  final VoidCallback? onClose, onOpenSearch, onOpenSettings, onOpenUsers, onAddZone;
  final ValueChanged<String>? onOpenDetail, onOpenZone;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin)? onPlayTarget;
  final Duration debounceDuration;

  @override
  State<EvCommandPaletteOverlay> createState() => _EvCommandPaletteOverlayState();
}

class _EvCommandPaletteOverlayState extends State<EvCommandPaletteOverlay>
    with SingleTickerProviderStateMixin {
  final _queryController = TextEditingController();
  final _inputFocus = FocusNode(debugLabel: 'ev_palette_input');
  final _overlayScope = FocusScopeNode(debugLabel: 'ev_palette_scope');
  final _scrollController = ScrollController();
  final Map<String, GlobalKey> _itemKeys = {};

  late final AnimationController _enterController;
  late final CurvedAnimation _fadeAnim, _springAnim;
  EvScope? _scope;
  EmbyViewData? _boundData;
  StreamSubscription<LocalPreferences>? _prefsSub;
  LocalPreferences _prefs = const LocalPreferences();

  Timer? _debounceTimer;
  int _searchGen = 0, _initGen = 0, _selectedIndex = 0;
  bool _searchPending = false;
  List<ResumeCard> _resumeItems = const [];
  List<ZoneTile> _fetchedZones = const [];
  List<({MediaCard card, String? groupName})> _movieHits = const [];
  List<_PaletteItem> _flatItems = const [];

  bool get _isComposing => _queryController.value.composing.isValid && !_queryController.value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    _enterController = AnimationController(vsync: this, duration: EvDurations.medium)..forward();
    _fadeAnim = CurvedAnimation(parent: _enterController, curve: const Interval(0.0, 0.56, curve: EvCurves.soft));
    _springAnim = CurvedAnimation(parent: _enterController, curve: EvCurves.spring);
    _inputFocus.onKeyEvent = (_, event) => _handleKeyEvent(event);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _inputFocus.requestFocus(); });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) _enterController.value = 1.0;
    final scope = EvScope.maybeOf(context);
    if (identical(scope, _scope) && identical(scope?.services.data, _boundData)) return;
    _scope?.shell.removeListener(_onShellChanged);
    unawaited(_prefsSub?.cancel());
    _scope = scope;
    _boundData = scope?.services.data;
    if (scope != null) {
      scope.shell.addListener(_onShellChanged);
      _prefs = scope.services.preferences.current;
      _prefsSub = scope.services.preferences.changes.listen((next) { if (mounted) setState(() => _prefs = next); });
      unawaited(_loadInitial(scope));
    }
  }

  void _onShellChanged() { if (mounted) setState(() {}); }

  Future<void> _loadInitial(EvScope scope) async {
    final data = scope.services.data;
    if (data == null) return;
    final gen = ++_initGen;
    final (resumes, zones) = await (
      data.continueWatching(limit: 4).then((p) => p.items, onError: (_) => const <ResumeCard>[]),
      scope.shell.zones.isEmpty ? data.zones().then((z) => z, onError: (_) => const <ZoneTile>[]) : Future.value(const <ZoneTile>[]),
    ).wait;
    if (!mounted || gen != _initGen) return;
    setState(() { _resumeItems = resumes.take(4).toList(); if (zones.isNotEmpty) _fetchedZones = zones; });
  }

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    final term = value.trim();
    if (term.isEmpty) {
      _searchGen++;
      setState(() { _movieHits = const []; _searchPending = false; _selectedIndex = 0; });
      return;
    }
    setState(() { _searchPending = _boundData != null; _selectedIndex = 0; });
    if (_boundData != null) _debounceTimer = Timer(widget.debounceDuration, () => unawaited(_executeSearch(term)));
  }

  Future<void> _executeSearch(String term) async {
    final data = _boundData;
    if (data == null) return;
    final gen = ++_searchGen;
    try {
      final res = await data.search(term, limit: 6);
      if (!mounted || gen != _searchGen) return;
      final hits = <({MediaCard card, String? groupName})>[];
      final seen = <String>{};
      if (res.bestMatch case final best? when seen.add(best.id)) {
        hits.add((card: best, groupName: _groupNameFor(res, best.libraryId)));
      }
      for (final g in res.groups) {
        for (final c in g.items) {
          if (hits.length >= 6) break;
          if (seen.add(c.id)) hits.add((card: c, groupName: g.name));
        }
        if (hits.length >= 6) break;
      }
      setState(() { _movieHits = hits; _searchPending = false; });
    } catch (_) {
      if (mounted && gen == _searchGen) setState(() { _movieHits = const []; _searchPending = false; });
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose?.call();
      return KeyEventResult.handled;
    }
    if (_isComposing) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) { _moveSelection(1); return KeyEventResult.handled; }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) { _moveSelection(-1); return KeyEventResult.handled; }
    }
    if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      if (_flatItems.isNotEmpty) _flatItems[_selectedIndex.clamp(0, _flatItems.length - 1)].run();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveSelection(int delta) {
    if (_flatItems.isEmpty) return;
    final len = _flatItems.length;
    final next = ((_selectedIndex + delta) % len + len) % len;
    setState(() => _selectedIndex = next);
    final key = _itemKeys[_flatItems[next].id];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key?.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(ctx, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd, duration: Duration.zero);
      Scrollable.ensureVisible(ctx, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart, duration: Duration.zero);
    });
  }

  VoidCallback _closeThen(VoidCallback? fn) => () { widget.onClose?.call(); fn?.call(); };

  List<_PaletteGroup> _buildGroups(BuildContext context, EvTheme theme) {
    final scope = _scope;
    final zones = scope != null && scope.shell.zones.isNotEmpty ? scope.shell.zones : _fetchedZones;
    final cmds = _buildCommands(scope, theme, zones);
    final q = _queryController.text.trim().toLowerCase();
    if (q.isEmpty) {
      return [
        if (_resumeItems.isNotEmpty)
          ('继续观看', [
            for (final r in _resumeItems)
              _PaletteItem(
                id: 'resume_${r.card.id}', title: r.card.title, hint: EvCard.resumeSubtitle(r),
                icon: EvIcons.film, poster: r.card.art.poster.layers.isNotEmpty ? r.card.art.poster : null,
                run: () => _runResume(context, r),
              ),
          ]),
        ('命令', cmds),
      ];
    }
    final movies = [
      for (final hit in _movieHits)
        _PaletteItem(
          id: 'movie_${hit.card.id}', title: hit.card.title, hint: _formatMovieSubtitle(hit.card, hit.groupName),
          icon: EvIcons.film, poster: hit.card.art.poster.layers.isNotEmpty ? hit.card.art.poster : null,
          run: _closeThen(() => (widget.onOpenDetail ?? scope?.shell.onOpenDetail)?.call(hit.card.id)),
        ),
    ];
    final matched = cmds.where((c) => c.matches(q)).toList();
    return [if (movies.isNotEmpty) ('影片', movies), if (matched.isNotEmpty) ('命令', matched)];
  }

  List<_PaletteItem> _buildCommands(EvScope? scope, EvTheme theme, List<ZoneTile> zones) {
    final nextNav = _nextNavigationStyle(_prefs.navigation);
    final nextTheme = theme.isPaper ? ThemeMode.cinema : ThemeMode.paper;
    _PaletteItem cmd(String id, String title, EvIconData icon, VoidCallback run, {String? hint, String kw = ''}) =>
        _PaletteItem(id: id, title: title, icon: icon, hint: hint, keywords: kw, run: run);
    return [
      cmd('cmd_theme', theme.isPaper ? '换成影院主题' : '换成纸面主题', EvIcons.palette, hint: '外观',
        kw: '换主题 主题 外观 影院 纸面 zhuti huanzhuti zt yingyuan zhimian theme paper cinema',
        _closeThen(() { if (scope != null) unawaited(scope.services.preferences.update(_copyPreferences(scope.services.preferences.current, theme: nextTheme))); })),
      cmd('cmd_add_zone', '添加分区', EvIcons.zones, hint: '分区',
        kw: '添加分区 分区 管理 tianjiafenqu fenqu tjfq fq zone add',
        _closeThen(widget.onAddZone ?? scope?.shell.onManageZones)),
      cmd('cmd_nav', '导航样式改为「${_navLabel(nextNav)}」', EvIcons.grid, hint: '外观',
        kw: '导航样式 顶栏 导航 外观 图标 文字 daohangyangshi daohang dhys dh nav',
        _closeThen(() { if (scope != null) unawaited(scope.services.preferences.update(_copyPreferences(scope.services.preferences.current, navigation: nextNav))); })),
      cmd('cmd_search', '搜索片库', EvIcons.search, hint: '⌘ F',
        kw: '搜索片库 搜索 找片 sousuo ss search', _closeThen(widget.onOpenSearch ?? scope?.shell.onOpenSearch)),
      cmd('cmd_settings', '打开设置', EvIcons.gear, hint: '⌘ ,',
        kw: '打开设置 设置 偏好 shezhi dksz sz settings', _closeThen(widget.onOpenSettings ?? scope?.shell.onOpenSettings)),
      cmd('cmd_users', '切换用户', EvIcons.users,
        kw: '切换用户 用户 账号 谁在看 qiehuanyonghu yonghu qhyh yh user profile', _closeThen(widget.onOpenUsers ?? scope?.shell.onOpenUsers)),
      cmd('cmd_random', '随便看一部', EvIcons.shuffle,
        kw: '随便看一部 随便看看 随机 suibian suiji sbkyb sj random shuffle', () => _runRandom(scope, zones)),
      for (final z in zones)
        cmd('cmd_zone_${z.id}', '前往${z.name}', EvIcons.byKey(z.iconKey),
          kw: '前往${z.name} ${z.name} ${z.id} qianwang qw ${_zoneKeywords(z)}',
          _closeThen(() => widget.onOpenZone != null ? widget.onOpenZone!(z.id) : scope?.shell.openZone(z.id))),
    ];
  }

  void _runResume(BuildContext context, ResumeCard resume) {
    if (widget.onPlayTarget != null) {
      widget.onClose?.call();
      widget.onPlayTarget!(resume.target, resume.card.art, null);
      return;
    }
    unawaited(EvPlayer.open(context, resume.target, art: resume.card.art));
    widget.onClose?.call();
  }

  void _runRandom(EvScope? scope, List<ZoneTile> zones) {
    final data = scope?.services.data, openDetail = widget.onOpenDetail ?? scope?.shell.onOpenDetail;
    final capturedSessionId = scope?.services.accounts.snapshot.sessionId;
    widget.onClose?.call();
    if (data == null || openDetail == null || capturedSessionId == null) return;
    unawaited(() async {
      try {
        final candidates = zones.isNotEmpty ? zones : await data.zones();
        if (candidates.isEmpty) return;
        final card = await data.randomInZone(_pickRandomZone(candidates).id);
        final snap = scope?.services.accounts.snapshot;
        if (card == null || snap == null || snap.sessionId != capturedSessionId || snap.phase != AccountPhase.signedIn) return;
        openDetail(card.id);
      } catch (_) {}
    }());
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _scope?.shell.removeListener(_onShellChanged);
    unawaited(_prefsSub?.cancel());
    _fadeAnim.dispose(); _springAnim.dispose(); _enterController.dispose();
    _queryController.dispose(); _inputFocus.dispose(); _overlayScope.dispose(); _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final groups = _buildGroups(context, t);
    final flat = [for (final g in groups) ...g.$2];
    _flatItems = flat;
    final selected = flat.isEmpty ? -1 : _selectedIndex.clamp(0, flat.length - 1);
    final activeIds = {for (final item in flat) item.id};
    _itemKeys.removeWhere((k, _) => !activeIds.contains(k));
    final topPad = math.min(s.vh(16), math.max(s.rem(2.0), s.size.height * 0.16));
    final boxWidth = math.min(s.rem(42.0), s.size.width * 0.9);
    final boxMaxHeight = math.min(s.rem(32.0), math.max(s.rem(12.0), s.size.height - topPad - s.rem(2.0)));
    final scrimColor = t.isPaper ? const Color.fromRGBO(250, 249, 245, 0.60) : const Color.fromRGBO(0, 0, 0, 0.35);

    return FocusScope(
      node: _overlayScope, onKeyEvent: (_, event) => _handleKeyEvent(event),
      child: FadeTransition(opacity: _fadeAnim, child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: GestureDetector(
          key: const Key('ev_palette_scrim'), behavior: HitTestBehavior.opaque, onTap: widget.onClose,
          child: ColoredBox(color: scrimColor),
        )),
        Align(alignment: Alignment.topCenter, child: Padding(padding: EdgeInsets.only(top: topPad), child: AnimatedBuilder(
          animation: _springAnim,
          builder: (_, child) => Transform.translate(
            offset: Offset(0, s.rem(-0.75) * (1.0 - _springAnim.value)),
            child: Transform.scale(scale: 0.97 + 0.03 * _springAnim.value, child: child),
          ),
          child: Container(
            width: boxWidth, constraints: BoxConstraints(maxHeight: boxMaxHeight),
            child: EvGlass(
              key: const Key('ev_palette_box'), borderRadius: BorderRadius.circular(s.rem(1.25)),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _buildInputRow(t, s), Flexible(child: _buildList(t, s, groups, selected)),
              ]),
            ),
          ),
        ))),
      ])),
    );
  }

  Widget _buildInputRow(EvTheme t, EvScale s) => Container(
    height: s.rem(4.0), padding: EdgeInsets.symmetric(horizontal: s.rem(1.25)),
    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line, width: 1))),
    child: Row(children: [
      EvIcon(EvIcons.search, size: s.rem(1.25), color: t.ink.withValues(alpha: 0.65)),
      SizedBox(width: s.rem(0.875)),
      Expanded(child: GestureDetector(
        behavior: HitTestBehavior.translucent, onTap: _inputFocus.requestFocus,
        child: Stack(alignment: Alignment.centerLeft, children: [
          if (_queryController.text.isEmpty)
            IgnorePointer(child: Text(
              '搜影片，或输入命令（主题、设置、切换用户…）', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: t.bodyStyle(s.font(1.1875), color: t.ink3),
            )),
          EditableText(
            key: const Key('ev_palette_input'), controller: _queryController, focusNode: _inputFocus,
            autofocus: true, maxLines: 1, textInputAction: TextInputAction.done,
            onChanged: _onQueryChanged,
            onSubmitted: (_) { if (_flatItems.isNotEmpty) _flatItems[_selectedIndex.clamp(0, _flatItems.length - 1)].run(); },
            style: t.bodyStyle(s.font(1.1875), color: t.ink),
            cursorColor: t.isPaper ? t.brand : t.ink, backgroundCursorColor: t.ink4,
            selectionColor: (t.isPaper ? t.brand : t.accent).withValues(alpha: 0.28),
          ),
        ]),
      )),
      SizedBox(width: s.rem(0.75)),
      Semantics(button: true, label: '关闭命令面板', child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const Key('ev_palette_esc'), behavior: HitTestBehavior.opaque, onTap: widget.onClose,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: s.rem(0.5), vertical: s.rem(0.2)),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(s.rem(0.375)), border: Border.all(color: t.fill3)),
            child: Text('esc', maxLines: 1, softWrap: false, style: t.bodyStyle(s.font(0.8125), color: t.ink3)),
          ),
        ),
      )),
    ]),
  );

  Widget _buildList(EvTheme t, EvScale s, List<_PaletteGroup> groups, int selected) {
    if (groups.isEmpty) {
      return Padding(
        key: const Key('ev_palette_empty'),
        padding: EdgeInsets.symmetric(horizontal: s.rem(1.25), vertical: s.rem(1.5)),
        child: Text(_searchPending ? '正在搜索…' : '没有匹配的影片或命令',
          style: t.bodyStyle(s.font(0.8125), fontWeight: FontWeight.w600, color: t.ink3)),
      );
    }
    var flatIndex = 0;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        key: const Key('ev_palette_list'), controller: _scrollController, padding: EdgeInsets.all(s.rem(0.5)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          for (final g in groups) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(s.rem(0.75), s.rem(0.625), s.rem(0.75), s.rem(0.25)),
              child: Text(g.$1, style: t.bodyStyle(s.font(0.8125), fontWeight: FontWeight.w600, color: t.ink3)),
            ),
            for (final item in g.$2) _buildRow(t, s, item, flatIndex, flatIndex++ == selected),
          ],
        ]),
      ),
    );
  }

  Widget _buildRow(EvTheme t, EvScale s, _PaletteItem item, int index, bool isSelected) {
    final rowKey = _itemKeys.putIfAbsent(item.id, () => GlobalKey(debugLabel: 'ev_palette_${item.id}'));
    final leading = item.poster != null
        ? EvArtwork(
            plan: item.poster!, width: s.rem(2.0), height: s.rem(3.0), borderRadius: BorderRadius.circular(s.rem(0.25)),
            overrideFit: BoxFit.cover, showFallbackTitle: false, animateFade: false, decodeWidth: s.rem(4.0),
          )
        : Container(
            width: s.rem(2.0), height: s.rem(2.0), alignment: Alignment.center,
            decoration: BoxDecoration(color: t.fill2, borderRadius: BorderRadius.circular(s.rem(0.5))),
            child: EvIcon(item.icon, size: s.rem(1.125), color: t.ink),
          );

    return KeyedSubtree(
      key: rowKey,
      child: Semantics(button: true, selected: isSelected, label: item.title, child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onHover: (_) { if (_selectedIndex != index) setState(() => _selectedIndex = index); },
        onEnter: (_) { if (_selectedIndex != index) setState(() => _selectedIndex = index); },
        child: GestureDetector(
          key: ValueKey<String>('ev_palette_item_${item.id}'), behavior: HitTestBehavior.opaque, onTap: item.run,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: s.rem(0.75), vertical: s.rem(0.5)),
            decoration: BoxDecoration(color: isSelected ? t.fill2 : const Color(0x00000000), borderRadius: BorderRadius.circular(s.rem(0.75))),
            child: Row(children: [
              leading,
              SizedBox(width: s.rem(0.875)),
              Expanded(child: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(1.0), color: t.ink))),
              if (item.hint != null && item.hint!.isNotEmpty) ...[
                SizedBox(width: s.rem(0.75)),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: s.rem(14.0)),
                  child: Text(item.hint!, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.875), color: t.ink3)),
                ),
              ],
            ]),
          ),
        ),
      )),
    );
  }
}

typedef _PaletteGroup = (String, List<_PaletteItem>);

class _PaletteItem {
  const _PaletteItem({required this.id, required this.title, required this.icon, required this.run, this.hint, this.poster, this.keywords = ''});
  final String id, title, keywords;
  final String? hint;
  final EvIconData icon;
  final ArtworkPlan? poster;
  final VoidCallback run;
  bool matches(String q) => title.toLowerCase().contains(q) || keywords.toLowerCase().contains(q) || (hint?.toLowerCase().contains(q) ?? false);
}

NavigationStyle _nextNavigationStyle(NavigationStyle c) =>
    c == NavigationStyle.icon ? NavigationStyle.iconAndText : c == NavigationStyle.iconAndText ? NavigationStyle.text : NavigationStyle.icon;

String _navLabel(NavigationStyle s) => switch (s) {
  NavigationStyle.icon => '图标', NavigationStyle.iconAndText => '图标 + 文字', NavigationStyle.text => '文字',
};

ZoneTile _pickRandomZone(List<ZoneTile> zones) => zones.firstWhere(
  (z) => const {'movie', 'movies'}.contains(z.id.toLowerCase()) || const {'nav_movie', 'movie'}.contains(z.iconKey.toLowerCase()) || z.name == '电影',
  orElse: () => zones.first,
);

String _zoneKeywords(ZoneTile z) => switch (z.id.toLowerCase()) {
  'anime' => 'fanju fj 番剧', 'movie' || 'movies' => 'dianying dy 电影',
  'tv' || 'series' => 'juji jj 剧集', 'doc' || 'documentary' => 'jilupian jlp 纪录片',
  'box' || 'boxset' || 'collections' => 'heji hj 合集', _ => '',
};

String? _groupNameFor(SearchResults res, String? libraryId) =>
    libraryId == null ? null : res.groups.where((g) => g.libraryId == libraryId && g.name.isNotEmpty).firstOrNull?.name;

String? _formatMovieSubtitle(MediaCard card, String? groupName) {
  final kind = card.genres.isNotEmpty ? card.genres.first : (groupName?.isNotEmpty == true ? groupName! : switch (card.kind) {
    MediaKind.movie => '电影', MediaKind.series => '剧集', MediaKind.episode => '单集', MediaKind.collection => '合集',
  });
  return [if (card.year != null) '${card.year}', kind].join(' · ');
}

LocalPreferences _copyPreferences(LocalPreferences b, {ThemeMode? theme, NavigationStyle? navigation}) => LocalPreferences(
  theme: theme ?? b.theme, navigation: navigation ?? b.navigation, seriesSort: b.seriesSort,
  chooseUserOnStartup: b.chooseUserOnStartup, onboardingDismissed: b.onboardingDismissed,
  autoSwitchServerAddress: b.autoSwitchServerAddress, serverAddresses: b.serverAddresses,
  backgroundVideo: b.backgroundVideo, backgroundVideoDelay: b.backgroundVideoDelay,
  detailTrailerDelay: b.detailTrailerDelay, themeMusic: b.themeMusic, themeVolume: b.themeVolume, quickLook: b.quickLook,
  hideUnwatchedOverview: b.hideUnwatchedOverview, preResolve115: b.preResolve115, readAheadBytes: b.readAheadBytes,
  autoPlayNext: b.autoPlayNext, anime4kForAnime: b.anime4kForAnime, anime4kForOther: b.anime4kForOther,
  subtitleLanguages: b.subtitleLanguages, autoSelectChineseSubtitle: b.autoSelectChineseSubtitle,
  subtitleSources: b.subtitleSources, translationBaseUrl: b.translationBaseUrl, translationModel: b.translationModel,
  monthlyBudgetMicros: b.monthlyBudgetMicros, mediaFolder: b.mediaFolder, zones: b.zones,
);
