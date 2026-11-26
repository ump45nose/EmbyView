import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/shell/ev_avatar_menu.dart';
import 'package:moonfin/embyview/ui/shell/ev_scope.dart';
import 'package:moonfin/embyview/ui/stage/ev_stage_controller.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

class _NavItem {
  const _NavItem(this.id, this.label, this.icon, {this.hint});
  final String id, label;
  final EvIconData icon;
  final String? hint;
}

/// Top navigation bar mirroring `.chrome`, `.tabs`, `.back`, `.ptitle`,
/// `.pacts`, and `.me` from `.spec/mockups/proto.css` and `proto.js`.
class EvTopBar extends StatefulWidget {
  const EvTopBar({
    super.key, required this.zones, this.activeTabId = 'home',
    this.navigationStyle = NavigationStyle.icon,
    this.autoTuck = false,
    this.tuckDelay = const Duration(milliseconds: 1400),
    this.tuckLeaveDelay = const Duration(milliseconds: 700),
    this.scrolled = false, this.topFade = 0.0, this.onImageBackdrop, this.showBack = false,
    this.titlePlate, this.rightActions = const [],
    this.hideTabs = false, this.hideAvatar = false, this.showSearchTab = false,
    this.currentProfile, this.avatarMenuOpen = false, this.enableWindowDrag = true,
    this.windowDragBuilder,
    this.onSelectTab, this.onBack, this.onAvatarTap,
  });

  final List<ZoneTile> zones;
  final String? activeTabId;
  final NavigationStyle navigationStyle;
  final bool autoTuck, scrolled, showBack, hideTabs, hideAvatar, showSearchTab, avatarMenuOpen, enableWindowDrag;
  final bool? onImageBackdrop;
  final Duration tuckDelay, tuckLeaveDelay;
  final double topFade;
  final EvChromeTitlePlate? titlePlate;
  final List<Widget> rightActions;
  final AccountProfile? currentProfile;
  final WidgetBuilder? windowDragBuilder;
  final ValueChanged<String>? onSelectTab;
  final VoidCallback? onBack, onAvatarTap;

  @override
  State<EvTopBar> createState() => _EvTopBarState();
}

class _EvTopBarState extends State<EvTopBar> with SingleTickerProviderStateMixin {
  final _tabsRowKey = GlobalKey();
  final _tabKeys = <String, GlobalKey>{};
  final _tabFocus = <String, FocusNode>{};

  late final _indCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  late final _indCurve = CurvedAnimation(parent: _indCtrl, curve: EvCurves.spring);

  double _fromLeft = 0.0, _fromW = 0.0, _toLeft = 0.0, _toW = 0.0;
  bool _measured = false, _tucked = false, _hovered = false, _focused = false;
  Timer? _tuckTimer;
  String? _hoveredTabId;

  List<_NavItem> get _items => [
    const _NavItem('home', '首页', EvIcons.navHome),
    for (final z in widget.zones) _NavItem(z.id, z.name, EvIcons.byKey(z.iconKey)),
    if (widget.showSearchTab) const _NavItem('search', '搜索', EvIcons.navSearch, hint: '⌘F'),
  ];

  GlobalKey _keyFor(String id) => _tabKeys.putIfAbsent(id, GlobalKey.new);
  FocusNode _focusFor(String id) => _tabFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'ev_tab_$id'));

  @override
  void initState() {
    super.initState();
    _armTuck(widget.tuckDelay);
    _scheduleMeasure(instant: true);
  }

  @override
  void didUpdateWidget(EvTopBar old) {
    super.didUpdateWidget(old);
    final wasTucked = _tucked;
    final tabChanged = old.activeTabId != widget.activeTabId;
    final styleChanged = old.navigationStyle != widget.navigationStyle;
    final zonesChanged = old.zones.length != widget.zones.length ||
        old.showSearchTab != widget.showSearchTab ||
        Iterable.generate(old.zones.length).any((i) => old.zones[i].id != widget.zones[i].id || old.zones[i].name != widget.zones[i].name);

    if (zonesChanged) {
      final activeIds = {for (final item in _items) item.id};
      _tabKeys.removeWhere((id, _) => !activeIds.contains(id));
      for (final id in _tabFocus.keys.where((id) => !activeIds.contains(id)).toList()) {
        _tabFocus.remove(id)?.dispose();
      }
      if (_hoveredTabId != null && !activeIds.contains(_hoveredTabId)) _hoveredTabId = null;
    }
    if (!widget.autoTuck) {
      _cancelTuck();
      _tucked = false;
    } else if (!old.autoTuck || tabChanged) {
      _tucked = false;
      _armTuck(widget.tuckDelay);
    }
    if (tabChanged || styleChanged || zonesChanged || (wasTucked && !_tucked)) {
      _scheduleMeasure(instant: styleChanged || zonesChanged || wasTucked);
    }
  }

  @override
  void dispose() {
    _cancelTuck();
    _indCurve.dispose();
    _indCtrl.dispose();
    for (final n in _tabFocus.values) { n.dispose(); }
    super.dispose();
  }

  void _cancelTuck() { _tuckTimer?.cancel(); _tuckTimer = null; }

  void _armTuck(Duration delay) {
    _cancelTuck();
    if (!widget.autoTuck) return;
    _tuckTimer = Timer(delay, () {
      _tuckTimer = null;
      if (!mounted || !widget.autoTuck || _hovered || _focused) return;
      setState(() { _tucked = true; _hoveredTabId = null; });
    });
  }

  void _expandTabs({bool focusActive = false}) {
    _cancelTuck();
    if (_tucked) { setState(() => _tucked = false); _scheduleMeasure(instant: true); }
    if (focusActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tabFocus[widget.activeTabId ?? 'home']?.requestFocus();
      });
    }
  }

  void _scheduleMeasure({bool instant = false}) =>
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _measure(instant: instant); });

  double get _curLeft => ui.lerpDouble(_fromLeft, _toLeft, _indCurve.value) ?? _toLeft;
  double get _curW => (ui.lerpDouble(_fromW, _toW, _indCurve.value) ?? _toW).clamp(0.0, double.infinity);

  void _measure({bool instant = false}) {
    if (_tucked || widget.hideTabs) return;
    final id = widget.activeTabId;
    if (id == null) { if (_measured) setState(() => _measured = false); return; }
    final rowBox = _tabsRowKey.currentContext?.findRenderObject() as RenderBox?;
    final tabBox = _tabKeys[id]?.currentContext?.findRenderObject() as RenderBox?;
    if (rowBox == null || tabBox == null || !rowBox.hasSize || !tabBox.hasSize) return;

    final nextL = tabBox.localToGlobal(Offset.zero, ancestor: rowBox).dx, nextW = tabBox.size.width;
    if (!_measured || instant) {
      setState(() { _fromLeft = _toLeft = nextL; _fromW = _toW = nextW; _measured = true; });
      _indCtrl.value = 1.0;
      return;
    }
    if ((_toLeft - nextL).abs() < 0.5 && (_toW - nextW).abs() < 0.5) return;
    _fromLeft = _curLeft; _fromW = _curW; _toLeft = nextL; _toW = nextW;
    _indCtrl.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final barOpacity = widget.topFade > 0.005 ? widget.topFade.clamp(0.0, 1.0) : (widget.scrolled ? 1.0 : 0.0);
    final hasBackdrop = widget.onImageBackdrop ?? (EvScope.maybeOf(context)?.stage.mode != EvStageMode.ambient);
    final onImage = hasBackdrop && widget.topFade < 0.75;

    return SizedBox(
      height: scale.rem(4.75),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0, right: 0, top: 0, bottom: -scale.rem(0.75),
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: const Key('ev_topbar_frosted_bar'),
                opacity: barOpacity, duration: const Duration(milliseconds: 300), curve: EvCurves.soft,
                child: barOpacity > 0.0
                    ? ClipRect(
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter, end: Alignment.bottomCenter, stops: const [0.0, 0.70, 1.0],
                                colors: [
                                  theme.bg.withValues(alpha: theme.isPaper ? 0.85 : 0.68),
                                  theme.bg.withValues(alpha: theme.isPaper ? 0.72 : 0.52),
                                  theme.bg.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          if (widget.enableWindowDrag && widget.windowDragBuilder != null)
            Positioned.fill(child: widget.windowDragBuilder!(context)),
          if (widget.showBack)
            Positioned(left: scale.rem(5.75), top: scale.rem(0.875), child: _EvBackButton(onTap: widget.onBack))
          else if (widget.titlePlate != null)
            Positioned(left: scale.rem(5.75), top: scale.rem(0.875),
                child: IgnorePointer(child: EvOnImage(enabled: onImage, child: _EvTitlePlate(plate: widget.titlePlate!)))),
          Positioned.fill(
            child: Center(
              child: IgnorePointer(
                ignoring: widget.hideTabs,
                child: AnimatedSlide(
                  offset: widget.hideTabs ? const Offset(0, -0.3) : Offset.zero,
                  duration: const Duration(milliseconds: 500), curve: EvCurves.out,
                  child: AnimatedOpacity(
                    opacity: widget.hideTabs ? 0.0 : 1.0, duration: const Duration(milliseconds: 400), curve: EvCurves.soft,
                    child: _buildTabsPill(theme, scale),
                  ),
                ),
              ),
            ),
          ),
          if (!widget.hideAvatar || widget.rightActions.isNotEmpty)
            Positioned(
              right: scale.rem(1.5), top: scale.rem(0.875),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.rightActions.isNotEmpty)
                    EvOnImage(
                      enabled: onImage,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (var i = 0; i < widget.rightActions.length; i++) ...[
                          if (i > 0) SizedBox(width: scale.rem(0.5)),
                          widget.rightActions[i],
                        ],
                      ]),
                    ),
                  if (widget.rightActions.isNotEmpty && !widget.hideAvatar) SizedBox(width: scale.rem(1.0)),
                  if (!widget.hideAvatar)
                    EvAvatarButton(key: const Key('ev_topbar_avatar'), profile: widget.currentProfile, menuOpen: widget.avatarMenuOpen, onTap: widget.onAvatarTap),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTabsPill(EvTheme theme, EvScale scale) {
    final pad = scale.rem(0.3125), itemH = scale.rem(2.5), items = _items;
    final showTip = !_tucked && widget.navigationStyle == NavigationStyle.icon && _hoveredTabId != null && _hoveredTabId != widget.activeTabId;

    return Focus(
      skipTraversal: true,
      onFocusChange: (f) {
        if (_focused == f) return;
        _focused = f;
        if (f) { _expandTabs(); } else if (widget.autoTuck && !_hovered) { _armTuck(widget.tuckLeaveDelay); }
      },
      child: MouseRegion(
        key: const Key('ev_topbar_tabs_region'),
        onEnter: (_) { _hovered = true; _expandTabs(); },
        onExit: (_) {
          _hovered = false; _hoveredTabId = null;
          if (widget.autoTuck && !_focused) _armTuck(widget.tuckLeaveDelay);
          if (mounted) setState(() {});
        },
        child: Stack(
          clipBehavior: Clip.none, alignment: Alignment.topCenter,
          children: [
            EvGlass(
              key: const Key('ev_topbar_tabs_pill'), borderRadius: BorderRadius.circular(999), padding: EdgeInsets.all(pad),
              borderColor: theme.isPaper ? const Color(0xFFE8E6DC) : null,
              shadows: theme.isPaper ? const [BoxShadow(offset: Offset(0, 1), blurRadius: 2, color: Color.fromRGBO(20, 20, 19, 0.05))] : null,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 350), curve: EvCurves.out, alignment: Alignment.center,
                child: _tucked
                    ? Focus(
                        key: const Key('ev_topbar_tucked_capsule'),
                        onFocusChange: (f) { if (f) _expandTabs(focusActive: true); },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque, onTap: () => _expandTabs(),
                            child: Container(
                              height: itemH, padding: EdgeInsets.symmetric(horizontal: scale.rem(0.875)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                EvIcon(EvIcons.zones, size: scale.rem(1.25), color: theme.ink),
                                SizedBox(width: scale.rem(0.375)),
                                Text('切换', style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w500, color: theme.ink)),
                                SizedBox(width: scale.rem(0.375)),
                                EvIcon(EvIcons.down, size: scale.rem(0.75), color: theme.ink.withValues(alpha: 0.55)),
                              ]),
                            ),
                          ),
                        ),
                      )
                    : NotificationListener<SizeChangedLayoutNotification>(
                        onNotification: (_) { _scheduleMeasure(); return false; },
                        child: SizeChangedLayoutNotifier(
                          child: Stack(
                            key: _tabsRowKey, clipBehavior: Clip.none,
                            children: [
                              if (_measured && widget.activeTabId != null)
                                AnimatedBuilder(
                                  animation: _indCurve,
                                  builder: (_, _) => Positioned(
                                    left: _curLeft, top: 0, width: _curW, height: itemH,
                                    child: DecoratedBox(
                                      key: const Key('ev_topbar_indicator'),
                                      decoration: BoxDecoration(color: theme.indBg, borderRadius: BorderRadius.circular(999)),
                                    ),
                                  ),
                                ),
                              Row(mainAxisSize: MainAxisSize.min, children: [
                                for (var i = 0; i < items.length; i++) ...[
                                  if (i > 0) SizedBox(width: scale.rem(0.125)),
                                  _EvTabButton(
                                    key: _keyFor(items[i].id), item: items[i],
                                    selected: widget.activeTabId == items[i].id, style: widget.navigationStyle,
                                    height: itemH, focusNode: _focusFor(items[i].id),
                                    onHover: (h) { if (mounted) setState(() => _hoveredTabId = h ? items[i].id : (_hoveredTabId == items[i].id ? null : _hoveredTabId)); },
                                    onTap: () => widget.onSelectTab?.call(items[i].id),
                                  ),
                                ],
                              ]),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
            if (showTip) _buildTooltip(theme, scale, items, _hoveredTabId!, pad),
          ],
        ),
      ),
    );
  }

  Widget _buildTooltip(EvTheme theme, EvScale scale, List<_NavItem> items, String tabId, double pad) {
    final match = items.where((i) => i.id == tabId).firstOrNull;
    if (match == null) return const SizedBox.shrink();
    double? cx;
    final rowBox = _tabsRowKey.currentContext?.findRenderObject() as RenderBox?;
    final tabBox = _tabKeys[tabId]?.currentContext?.findRenderObject() as RenderBox?;
    if (rowBox != null && tabBox != null && rowBox.hasSize && tabBox.hasSize) {
      cx = pad + tabBox.localToGlobal(Offset.zero, ancestor: rowBox).dx + tabBox.size.width / 2;
    }
    final bubble = IgnorePointer(
      child: Container(
        key: Key('ev_topbar_tip_$tabId'),
        padding: EdgeInsets.symmetric(horizontal: scale.rem(0.625), vertical: scale.rem(0.375)),
        decoration: BoxDecoration(
          color: theme.isPaper ? const Color(0xFF141413) : theme.glassSolid,
          borderRadius: BorderRadius.circular(scale.rem(0.5)),
          border: theme.isPaper ? null : Border.all(color: theme.glassBorder),
          boxShadow: theme.isPaper ? null : theme.glassShadow,
        ),
        child: Text(match.hint != null ? '${match.label}　${match.hint}' : match.label,
            style: theme.bodyStyle(scale.font(0.8125), fontWeight: FontWeight.w500, color: theme.isPaper ? const Color(0xFFFAF9F5) : theme.ink)),
      ),
    );
    final top = scale.rem(2.5) + pad * 2 + scale.rem(0.625);
    return cx != null ? Positioned(top: top, left: cx - scale.rem(4.0), width: scale.rem(8.0), child: Center(child: bubble)) : Positioned(top: top, child: bubble);
  }
}

class _EvTabButton extends StatefulWidget {
  const _EvTabButton({super.key, required this.item, required this.selected, required this.style, required this.height, required this.focusNode, required this.onHover, required this.onTap});
  final _NavItem item;
  final bool selected;
  final NavigationStyle style;
  final double height;
  final FocusNode focusNode;
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;
  @override State<_EvTabButton> createState() => _EvTabButtonState();
}

class _EvTabButtonState extends State<_EvTabButton> {
  bool _hovered = false, _focused = false;
  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final showIcon = widget.style != NavigationStyle.text;
    final showLabel = widget.style != NavigationStyle.icon || widget.selected;
    final hi = _hovered || _focused;
    final fg = widget.selected ? theme.indFg : (hi ? theme.ink : theme.ink2);
    return Semantics(
      key: Key('ev_topbar_tab_${widget.item.id}'), button: true, selected: widget.selected, focused: _focused, label: widget.item.label,
      child: Focus(
        focusNode: widget.focusNode, onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) { if (!evIsActivateKey(e)) return KeyEventResult.ignored; widget.onTap(); return KeyEventResult.handled; },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) { setState(() => _hovered = true); widget.onHover(true); },
          onExit: (_) { setState(() => _hovered = false); widget.onHover(false); },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: widget.onTap,
            child: AnimatedContainer(
              duration: EvDurations.fast, curve: EvCurves.soft, height: widget.height,
              padding: EdgeInsets.symmetric(horizontal: scale.rem(widget.style == NavigationStyle.text ? 1.0625 : 0.8125)),
              decoration: BoxDecoration(color: !widget.selected && hi ? theme.fill : const Color(0x00000000), borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (showIcon) AnimatedScale(scale: _hovered ? 1.08 : 1.0, duration: EvDurations.medium, curve: EvCurves.spring,
                    child: EvIcon(widget.item.icon, size: scale.rem(1.375), color: fg, active: widget.selected || hi)),
                if (showIcon && showLabel) SizedBox(width: scale.rem(0.5)),
                if (showLabel) Text(widget.item.label, maxLines: 1, softWrap: false, style: theme.bodyStyle(scale.font(1.0), fontWeight: FontWeight.w500, color: fg)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvBackButton extends StatefulWidget {
  const _EvBackButton({this.onTap});
  final VoidCallback? onTap;
  @override State<_EvBackButton> createState() => _EvBackButtonState();
}

class _EvBackButtonState extends State<_EvBackButton> {
  bool _hovered = false, _focused = false, _pressed = false;
  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), sz = scale.rem(2.5);
    return Semantics(
      key: const Key('ev_topbar_back'), button: true, label: '返回',
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) { if (widget.onTap == null || !evIsActivateKey(e)) return KeyEventResult.ignored; widget.onTap!(); return KeyEventResult.handled; },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: widget.onTap,
            onTapDown: (_) => setState(() => _pressed = true), onTapUp: (_) => setState(() => _pressed = false), onTapCancel: () => setState(() => _pressed = false),
            child: AnimatedScale(scale: _pressed ? 0.92 : (_hovered || _focused ? 1.08 : 1.0), duration: const Duration(milliseconds: 300), curve: EvCurves.spring,
              child: EvGlass(borderRadius: BorderRadius.circular(999),
                child: SizedBox(width: sz, height: sz, child: Center(child: EvIcon(EvIcons.left, size: scale.rem(1.125), color: theme.ink)))),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvTitlePlate extends StatelessWidget {
  const _EvTitlePlate({required this.plate});
  final EvChromeTitlePlate plate;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), accent = theme.zoneColor(plate.colorSlot);
    final sub = theme.bodyStyle(scale.font(0.8125), fontWeight: FontWeight.w500, color: theme.ink3).copyWith(fontFeatures: const [ui.FontFeature.tabularFigures()]);
    return Row(key: const Key('ev_topbar_title_plate'), mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: scale.rem(2.75), height: scale.rem(2.75), padding: EdgeInsets.all(scale.rem(0.625)),
        decoration: BoxDecoration(
          color: theme.isPaper ? const Color(0xFFFAF9F5) : accent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(scale.rem(0.8125)),
          border: Border.all(color: theme.isPaper ? const Color(0xFF141413) : accent.withValues(alpha: 0.32), width: theme.isPaper ? 1.25 : 1.0),
          boxShadow: theme.isPaper ? [BoxShadow(offset: Offset(scale.rem(0.1875), scale.rem(0.1875)), color: accent)] : null,
        ),
        child: EvIcon(EvIcons.byKey(plate.iconKey), size: scale.rem(1.5), color: theme.isPaper ? const Color(0xFF141413) : accent),
      ),
      SizedBox(width: scale.rem(0.75)),
      Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(plate.title, style: theme.displayStyle(scale.font(1.375), color: theme.ink, height: 1.1)),
        SizedBox(height: scale.rem(0.25)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${evFormatCount(plate.total)} ${plate.unit}', style: sub),
          if (plate.addedThisMonth > 0) ...[
            Container(width: 1, height: scale.rem(0.6875), margin: EdgeInsets.symmetric(horizontal: scale.rem(0.5)), color: theme.fill3),
            Text('本月新增 ${plate.addedThisMonth}', style: sub),
          ],
        ]),
      ]),
    ]);
  }
}
