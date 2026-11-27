import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter/services.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/shelf/ev_card.dart';
import 'package:moonfin/embyview/ui/shell/ev_avatar_menu.dart';
import 'package:moonfin/embyview/ui/shell/ev_menu_channel.dart';
import 'package:moonfin/embyview/ui/shell/ev_notice_capsule.dart';
import 'package:moonfin/embyview/ui/shell/ev_scope.dart';
import 'package:moonfin/embyview/ui/shell/ev_shortcuts_overlay.dart';
import 'package:moonfin/embyview/ui/shell/ev_top_bar.dart';
import 'package:moonfin/embyview/ui/stage/ev_stage.dart';
import 'package:moonfin/embyview/ui/stage/ev_stage_controller.dart';
import 'package:moonfin/embyview/ui/stage/immersion.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Frameless macOS window shell hosting the single app-wide [EvStage] and
/// [Immersion], [EvThemeScope], [EvScope], animated view transitions,
/// [EvTopBar], avatar menu popover, and spatial directional focus navigation.
class EvShell extends StatefulWidget {
  const EvShell({
    super.key, required this.services, this.initialDestination, this.controller,
    this.stage, this.immersion, this.focusScopeNode,
    this.homeBuilder, this.zoneBuilder, this.wallBuilder,
    this.configureWindow = true, this.onConfigureWindow, this.windowDragBuilder,
    this.enableStageMotion = true, this.renderGlobalOverlays = true,
  });

  final EmbyViewServices services;
  final EvShellDestination? initialDestination;
  final EvShellController? controller;
  final EvStageController? stage;
  final Immersion? immersion;
  final FocusScopeNode? focusScopeNode;
  final WidgetBuilder? homeBuilder;
  final Widget Function(BuildContext context, String zoneId)? zoneBuilder;
  final Widget Function(BuildContext context, WallQuery query, String? title)? wallBuilder;
  final bool configureWindow, enableStageMotion, renderGlobalOverlays;
  final FutureOr<void> Function()? onConfigureWindow;
  final WidgetBuilder? windowDragBuilder;

  @override
  State<EvShell> createState() => _EvShellState();
}

class _EvShellState extends State<EvShell> {
  late EvStageController _stage;
  late Immersion _immersion;
  late bool _ownsStage, _ownsImmersion;
  late EvShellController _shell;
  late bool _ownsShell;
  late EvShellDestination _lastDestination;
  late List<ZoneTile> _lastZones;
  late bool _lastHasVisibleLibraries;
  late bool _lastShortcutsOpen;
  EvNoticeState? _lastNotice;

  StreamSubscription<LocalPreferences>? _prefsSub;
  StreamSubscription<AccountSnapshot>? _accountsSub;
  StreamSubscription<ConnectionNoticeEvent>? _noticeSub;
  Object? _menuToken;
  late LocalPreferences _prefs;
  late AccountSnapshot _account;
  bool _avatarMenuOpen = false;
  int _zonesToken = 0;

  late FocusScopeNode _shellScope;
  late bool _ownsShellScope;
  final _menuScope = FocusScopeNode(debugLabel: 'ev_avatar_menu_scope');

  void _bindStage() {
    _ownsImmersion = widget.immersion == null;
    _ownsStage = widget.stage == null && widget.immersion == null;
    _stage = widget.stage ?? widget.immersion?.stage ?? EvStageController();
    _immersion = widget.immersion ?? Immersion(stage: _stage, services: widget.services);
  }

  void _ensureInitialFocus() {
    if (!mounted || _avatarMenuOpen) return;
    if (_shellScope.hasFocus || !_shellScope.canRequestFocus) return;
    if (_shellScope.ancestors.any((a) => !a.descendantsAreFocusable)) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == FocusManager.instance.rootScope) {
      _shellScope.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    _ownsShellScope = widget.focusScopeNode == null;
    _shellScope = widget.focusScopeNode ?? FocusScopeNode(debugLabel: 'ev_shell_scope');
    _bindStage();
    _ownsShell = widget.controller == null;
    _shell = widget.controller ?? EvShellController(initial: widget.initialDestination ?? const EvHomeDestination());
    _lastDestination = _shell.current;
    _lastZones = _shell.zones;
    _lastHasVisibleLibraries = _shell.hasVisibleLibraries;
    _lastShortcutsOpen = _shell.shortcutsOpen;
    _lastNotice = _shell.notice;
    _shell.onCloseAvatarMenu = _closeMenuIfOpen;
    _scheduleStageSyncForDestination(_lastDestination, allowSync: _ownsStage);
    _shell.addListener(_onShellChanged);
    _attachServices(widget.services, initial: true);
    if (widget.renderGlobalOverlays) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
      _menuToken = EvMenuChannel.instance.registerHandler(
        (action, _) => _handleLocalMenuAction(action),
      );
    }
    if (widget.configureWindow && widget.onConfigureWindow != null) {
      unawaited(() async { try { await widget.onConfigureWindow!(); } catch (_) {} }());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureInitialFocus());
  }

  @override
  void didUpdateWidget(EvShell old) {
    super.didUpdateWidget(old);
    if (old.focusScopeNode != widget.focusScopeNode) {
      if (_ownsShellScope) _shellScope.dispose();
      _ownsShellScope = widget.focusScopeNode == null;
      _shellScope = widget.focusScopeNode ?? FocusScopeNode(debugLabel: 'ev_shell_scope');
    }
    if (old.stage != widget.stage || old.immersion != widget.immersion) {
      if (_ownsImmersion) _immersion.dispose();
      if (_ownsStage) _stage.dispose();
      _bindStage();
    }
    if (old.controller != widget.controller) {
      _shell.removeListener(_onShellChanged);
      if (identical(_shell.onCloseAvatarMenu, _closeMenuIfOpen)) {
        _shell.onCloseAvatarMenu = null;
      }
      if (_ownsShell) _shell.dispose();
      _ownsShell = widget.controller == null;
      _shell = widget.controller ?? EvShellController(initial: widget.initialDestination ?? const EvHomeDestination());
      _shell.onCloseAvatarMenu = _closeMenuIfOpen;
      _lastDestination = _shell.current;
      _lastZones = _shell.zones;
      _lastHasVisibleLibraries = _shell.hasVisibleLibraries;
      _lastShortcutsOpen = _shell.shortcutsOpen;
      _lastNotice = _shell.notice;
      _scheduleStageSyncForDestination(_lastDestination, allowSync: false);
      _shell.addListener(_onShellChanged);
    }
    if (old.renderGlobalOverlays != widget.renderGlobalOverlays) {
      if (widget.renderGlobalOverlays) {
        HardwareKeyboard.instance.addHandler(_onHardwareKey);
        _menuToken ??= EvMenuChannel.instance.registerHandler(
          (action, _) => _handleLocalMenuAction(action),
        );
      } else {
        HardwareKeyboard.instance.removeHandler(_onHardwareKey);
        if (_menuToken != null) {
          EvMenuChannel.instance.unregisterHandler(_menuToken!);
          _menuToken = null;
        }
      }
      _attachNoticeStream(widget.services);
    }
    if (!identical(old.services, widget.services) || old.services.sessionId != widget.services.sessionId) {
      final next = widget.services;
      if (old.services.sessionId != next.sessionId) {
        _shell.clearHomeCache();
        _shell.hasVisibleLibraries = true;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) unawaited(_immersion.rebind(next)); });
      _attachServices(next, initial: false);
    }
  }

  void _attachServices(EmbyViewServices services, {required bool initial}) {
    unawaited(_prefsSub?.cancel());
    unawaited(_accountsSub?.cancel());
    _prefs = services.preferences.current;
    _account = services.accounts.snapshot;

    _prefsSub = services.preferences.changes.listen((next) {
      final zc = _prefs.zones.length != next.zones.length ||
          Iterable.generate(_prefs.zones.length).any((i) =>
              _prefs.zones[i].id != next.zones[i].id || _prefs.zones[i].name != next.zones[i].name ||
              _prefs.zones[i].iconKey != next.zones[i].iconKey || _prefs.zones[i].colorSlot != next.zones[i].colorSlot);
      if (!mounted) return;
      setState(() => _prefs = next);
      if (zc) unawaited(_loadZones(services, force: true));
    });
    _accountsSub = services.accounts.changes.listen((next) { if (mounted) setState(() => _account = next); });
    _attachNoticeStream(services);
    if (_shell.zones.isEmpty || !initial) unawaited(_loadZones(services, force: !initial));
  }

  void _attachNoticeStream(EmbyViewServices services) {
    unawaited(_noticeSub?.cancel());
    _noticeSub = null;
    if (!widget.renderGlobalOverlays) return;
    _noticeSub = services.accounts.connectionNotices.listen(
      _shell.handleConnectionNotice,
    );
  }

  Future<void> _loadZones(EmbyViewServices services, {required bool force}) async {
    final data = services.data;
    if (data == null) return;
    final token = ++_zonesToken;
    try {
      final loaded = await data.zones();
      if (!mounted || token != _zonesToken) return;
      if (loaded.isNotEmpty || force) _shell.setZones(loaded);
    } catch (error) {
      if (!mounted || token != _zonesToken) return;
      debugPrint('EvShell: failed to load zones: $error');
      if (force) _shell.setZones(const []);
    }
  }

  void _scheduleStageSyncForDestination(EvShellDestination dest, {required bool allowSync}) {
    if (allowSync) {
      _syncStageForDestination(dest);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _shell.current == dest) _syncStageForDestination(dest);
    });
  }

  Color? _zoneAmbientColor(String zoneId) {
    final prefs = widget.services.preferences.current;
    int? slot;
    for (final z in _shell.zones) {
      if (z.id == zoneId) {
        slot = z.colorSlot;
        break;
      }
    }
    if (slot == null) {
      for (final z in prefs.zones) {
        if (z.id == zoneId) {
          slot = z.colorSlot;
          break;
        }
      }
    }
    if (slot == null) return null;
    final theme = prefs.theme == ThemeMode.paper ? EvTheme.paper : EvTheme.cinema;
    return theme.zoneColor(slot);
  }

  void _syncStageForDestination(EvShellDestination dest) {
    if (dest is EvWallDestination) {
      _immersion.onCardHoverEnd();
      _stage
        ..clearPreviewBackdrop()
        ..setMode(EvStageMode.ambient)
        ..setScrollProgress(0.0)
        ..setVeilLifted(false)
        ..setAmbientColor(null);
      return;
    }
    if (dest is EvZoneDestination) {
      _immersion.onCardHoverEnd();
      _stage
        ..clearPreviewBackdrop()
        ..setBaseBackdrop(null)
        ..setMode(EvStageMode.ambient)
        ..setScrollProgress(0.0)
        ..setVeilLifted(false)
        ..setAmbientColor(_zoneAmbientColor(dest.zoneId));
      return;
    }
    if (dest is EvHomeDestination) {
      _immersion.onCardHoverEnd();
      final cachedHome = _shell.cachedHomeFor(widget.services.sessionId, widget.services.data);
      final cachedBackdrop = cachedHome?.recommendations.firstOrNull?.card.art.stage;
      _stage
        ..clearPreviewBackdrop()
        ..setAmbientColor(null)
        ..setVeilLifted(false)
        ..setScrollProgress(0.0)
        ..setMode(EvStageMode.hero)
        ..setBaseBackdrop(cachedBackdrop);
    }
  }

  void _onShellChanged() {
    if (!mounted) return;
    final destChanged = _shell.current != _lastDestination;
    final zonesChanged = !identical(_shell.zones, _lastZones);
    final libsChanged = _shell.hasVisibleLibraries != _lastHasVisibleLibraries;
    final shortcutsChanged = _shell.shortcutsOpen != _lastShortcutsOpen;
    final noticeChanged = _shell.notice != _lastNotice;
    if (!destChanged && !zonesChanged && !libsChanged && !shortcutsChanged && !noticeChanged) return;
    _lastDestination = _shell.current;
    _lastZones = _shell.zones;
    _lastHasVisibleLibraries = _shell.hasVisibleLibraries;
    _lastShortcutsOpen = _shell.shortcutsOpen;
    _lastNotice = _shell.notice;
    if (destChanged) {
      if (_avatarMenuOpen) _avatarMenuOpen = false;
      _syncStageForDestination(_lastDestination);
    }
    setState(() {});
  }

  bool _handleBack(BuildContext context) {
    if (_shell.shortcutsOpen) {
      _shell.closeShortcuts();
      return true;
    }
    if (_avatarMenuOpen) {
      _closeMenu();
      return true;
    }
    if (_shell.pop()) return true;
    if (Navigator.canPop(context)) {
      unawaited(Navigator.maybePop(context));
      return true;
    }
    return false;
  }

  bool _handleLocalMenuAction(String action) {
    if (action == EvMenuAction.back) {
      return _handleBack(context);
    }
    return _shell.handleMenuAction(action);
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || !widget.renderGlobalOverlays || event is! KeyDownEvent) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_shell.shortcutsOpen) {
        _shell.closeShortcuts();
        return true;
      }
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary == FocusManager.instance.rootScope) {
        return _handleBack(context);
      }
      return false;
    }
    final action = evResolveShellMenuAction(
      event,
      isEditingText: evIsTextInputFocused(),
    );
    if (action == null) return false;
    return EvMenuChannel.instance.dispatchAction(
      action,
      source: EvMenuActionSource.keyboard,
    );
  }

  bool _closeMenuIfOpen() {
    if (!_avatarMenuOpen) return false;
    _closeMenu();
    return true;
  }

  void _toggleMenu() {
    setState(() => _avatarMenuOpen = !_avatarMenuOpen);
    if (_avatarMenuOpen) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _avatarMenuOpen) _menuScope.requestFocus(); });
  }

  void _closeMenu() { if (_avatarMenuOpen) setState(() => _avatarMenuOpen = false); }

  void _selectTab(String id) {
    _closeMenu();
    if (id == 'home') { _shell.goHome(); }
    else if (id == 'search') { _shell.onOpenSearch?.call(); }
    else { _shell.openZone(id); }
  }

  @override
  void dispose() {
    if (widget.renderGlobalOverlays) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
      if (_menuToken != null) {
        EvMenuChannel.instance.unregisterHandler(_menuToken!);
        _menuToken = null;
      }
    }
    unawaited(_prefsSub?.cancel());
    unawaited(_accountsSub?.cancel());
    unawaited(_noticeSub?.cancel());
    if (identical(_shell.onCloseAvatarMenu, _closeMenuIfOpen)) {
      _shell.onCloseAvatarMenu = null;
    }
    _shell.removeListener(_onShellChanged);
    if (_ownsShell) _shell.dispose();
    if (_ownsShellScope) _shellScope.dispose();
    _menuScope.dispose();
    if (_ownsImmersion) _immersion.dispose();
    if (_ownsStage) _stage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EvThemeScope(
      preferences: widget.services.preferences,
      child: Material(
        type: MaterialType.transparency,
        child: EvScope(
          services: widget.services, stage: _stage, immersion: _immersion, shell: _shell,
          child: Builder(
          builder: (context) {
            final theme = EvTheme.of(context), scale = EvScale.of(context), dest = _shell.current;
            return Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
                SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
                SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(TraversalDirection.left),
                SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(TraversalDirection.right),
                SingleActivator(LogicalKeyboardKey.escape): _EvEscapeIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  DirectionalFocusIntent: _EvSpatialAction(_shellScope),
                  _EvEscapeIntent: CallbackAction<_EvEscapeIntent>(
                    onInvoke: (_) {
                      _handleBack(context);
                      return null;
                    },
                  ),
                },
                child: FocusScope(
                  node: _shellScope,
                  autofocus: true,
                  child: FocusTraversalGroup(
                    policy: _EvSpatialPolicy(),
                    child: ColoredBox(
                      color: theme.bg,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(child: EvStage(controller: _stage, immersion: _immersion, enableMotion: widget.enableStageMotion)),
                          Positioned.fill(
                            child: NotificationListener<ScrollNotification>(
                              onNotification: (n) {
                                if (n.depth == 0 && n.metrics.axis == Axis.vertical) _shell.setScrollOffset(n.metrics.pixels);
                                return false;
                              },
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 550), reverseDuration: EvDurations.normal,
                                switchInCurve: EvCurves.out, switchOutCurve: EvCurves.soft,
                                layoutBuilder: (cur, prevs) => Stack(fit: StackFit.expand, children: [
                                  for (final p in prevs) IgnorePointer(child: p),
                                  ?cur,
                                ]),
                                transitionBuilder: (child, anim) {
                                  final enter = child.key == ValueKey<String>(dest.viewKey);
                                  return FadeTransition(
                                    opacity: anim,
                                    child: SlideTransition(
                                      position: enter ? Tween<Offset>(begin: const Offset(0, 0.015), end: Offset.zero).animate(anim) : const AlwaysStoppedAnimation(Offset.zero),
                                      child: ScaleTransition(scale: Tween<double>(begin: enter ? 0.992 : 1.01, end: 1.0).animate(anim), child: child),
                                    ),
                                  );
                                },
                                child: KeyedSubtree(
                                  key: ValueKey<String>(dest.viewKey),
                                  child: switch (dest) {
                                    EvHomeDestination() => widget.homeBuilder?.call(context) ?? const SizedBox.expand(),
                                    EvZoneDestination(:final zoneId) => widget.zoneBuilder?.call(context, zoneId) ?? const SizedBox.expand(),
                                    EvWallDestination(:final query, :final title) => widget.wallBuilder?.call(context, query, title) ?? const SizedBox.expand(),
                                  },
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0, right: 0, top: 0,
                            child: ListenableBuilder(
                              listenable: Listenable.merge([_shell, _stage]),
                              builder: (context, _) {
                                final current = _shell.current;
                                return EvTopBar(
                                  zones: _shell.zones, activeTabId: current.activeTabId,
                                  navigationStyle: _prefs.navigation, autoTuck: current is EvZoneDestination,
                                  scrolled: _shell.scrolled, topFade: _shell.topFade,
                                  onImageBackdrop: _stage.mode != EvStageMode.ambient,
                                  showBack: _shell.showBack, titlePlate: _shell.titlePlate,
                                  rightActions: _shell.rightActions, hideTabs: _shell.hideTabs,
                                  hideAvatar: _shell.hideAvatar, showSearchTab: _shell.onOpenSearch != null,
                                  currentProfile: _account.current, avatarMenuOpen: _avatarMenuOpen,
                                  enableWindowDrag: widget.configureWindow,
                                  windowDragBuilder: widget.configureWindow ? widget.windowDragBuilder : null,
                                  onSelectTab: _selectTab, onBack: () => _handleBack(context), onAvatarTap: _toggleMenu,
                                );
                              },
                            ),
                          ),
                          if (_avatarMenuOpen) ...[
                            Positioned.fill(child: GestureDetector(key: const Key('ev_avatar_menu_scrim'), behavior: HitTestBehavior.translucent, onTap: _closeMenu)),
                            Positioned(
                              right: scale.rem(1.5), top: scale.rem(4.0),
                              child: FocusScope(
                                node: _menuScope,
                                child: EvAvatarMenu(
                                  accounts: widget.services.accounts,
                                  themeMode: _prefs.theme,
                                  onSwitchUsers: _shell.onOpenUsers,
                                  onOpenLook: _shell.onOpenLook,
                                  onManageZones: _shell.onManageZones,
                                  onOpenSettings: _shell.onOpenSettings,
                                  onSignOut: _shell.onSignedOutToUserPicker,
                                  onDismiss: _closeMenu,
                                ),
                              ),
                            ),
                          ],
                          if (widget.renderGlobalOverlays && _shell.notice != null)
                            Positioned.fill(
                              child: EvNoticeCapsule(
                                notice: _shell.notice!,
                                onRetry: () {
                                  if (_shell.onRetryConnection != null || _shell.onRetryHome != null) {
                                    unawaited(_shell.triggerConnectionRetry());
                                  } else {
                                    unawaited(widget.services.accounts.retryConnection());
                                  }
                                },
                                onOpenServerSettings: () {
                                  _shell.dismissNotice();
                                  (_shell.onOpenServerSettings ?? _shell.onOpenSettings)?.call();
                                },
                                onDismiss: _shell.dismissNotice,
                              ),
                            ),
                          if (widget.renderGlobalOverlays && _shell.shortcutsOpen)
                            Positioned.fill(
                              child: EvShortcutsOverlay(
                                onClose: _shell.closeShortcuts,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      ),
    );
  }
}

class _EvEscapeIntent extends Intent {
  const _EvEscapeIntent();
}

class _EvSpatialPolicy extends ReadingOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode current, TraversalDirection dir) =>
      current.enclosingScope == null ? super.inDirection(current, dir) : moveFrom(current, current.enclosingScope!, dir);

  static bool moveFrom(FocusNode cur, FocusScopeNode scope, TraversalDirection dir) {
    final a = cur.rect;
    if (a.isEmpty) return false;
    final ax = a.center.dx, ay = a.center.dy;
    final horiz = dir == TraversalDirection.left || dir == TraversalDirection.right;
    final sign = (dir == TraversalDirection.right || dir == TraversalDirection.down) ? 1.0 : -1.0;
    final vw = scope.rect.width > 0 ? scope.rect.width : 1440.0;

    FocusNode? best;
    var bestScore = double.infinity;
    for (final n in scope.traversalDescendants) {
      if (n == cur || !n.canRequestFocus || n.skipTraversal) continue;
      final b = n.rect;
      if (b.isEmpty || b.width <= 0 || b.height <= 0) continue;
      final dx = b.center.dx - ax, dy = b.center.dy - ay;
      final double score;
      if (horiz) {
        if (dx * sign <= 1.0 || dy.abs() > math.max(a.height, b.height) * 0.65) continue;
        score = dx.abs() + dy.abs() * 3.0;
      } else {
        if (dy * sign <= 1.0 || dy.abs() <= math.min(a.height, b.height) * 0.45) continue;
        score = dy.abs() + dx.abs() * 0.6 + ((b.right <= 0 || b.left >= vw) ? 1000.0 : 0.0);
      }
      if (score < bestScore) { bestScore = score; best = n; }
    }
    if (best == null) return false;
    best.requestFocus();
    if (!horiz && best.context != null) {
      _scrollVerticallyForFocus(best.context!, best.rect, scope.rect, dir);
    }
    return true;
  }

  static ScrollableState? _findVerticalScrollable(BuildContext context) {
    ScrollableState? found;
    context.visitAncestorElements((el) {
      if (el is StatefulElement && el.state is ScrollableState) {
        final s = el.state as ScrollableState;
        if (s.widget.axisDirection == AxisDirection.down ||
            s.widget.axisDirection == AxisDirection.up) {
          found = s;
          return false;
        }
      }
      return true;
    });
    return found;
  }

  static void _scrollVerticallyForFocus(
    BuildContext context,
    Rect targetRect,
    Rect scopeRect,
    TraversalDirection dir,
  ) {
    final vScroll = _findVerticalScrollable(context);
    if (vScroll != null) {
      final pos = vScroll.position;
      final vh = pos.hasViewportDimension && pos.viewportDimension > 0
          ? pos.viewportDimension
          : (scopeRect.height > 0 ? scopeRect.height : 900.0);
      final scrollPixels = pos.pixels;
      final topInViewport = targetRect.top - scopeRect.top;
      final bottomInViewport = targetRect.bottom - scopeRect.top;
      final topInDoc = scrollPixels + topInViewport;
      final isHeroPage = EvScope.maybeOf(context)?.stage.mode == EvStageMode.hero;

      if (dir == TraversalDirection.up &&
          scrollPixels > 0.5 &&
          topInDoc < vh &&
          (isHeroPage || topInDoc + targetRect.height <= vh)) {
        try {
          unawaited(pos.animateTo(0.0, duration: EvDurations.normal, curve: EvCurves.out));
        } catch (_) {}
        return;
      }
      if (scrollPixels < vh * 0.25 &&
          topInViewport >= 0 &&
          topInViewport < vh &&
          (isHeroPage || bottomInViewport <= vh)) {
        return;
      }
    }
    try {
      Scrollable.ensureVisible(context, alignment: 0.5, duration: EvDurations.normal, curve: EvCurves.out);
    } catch (_) {}
  }
}

class _EvSpatialAction extends Action<DirectionalFocusIntent> {
  _EvSpatialAction(this.shellScope);
  final FocusScopeNode shellScope;

  @override
  bool isEnabled(DirectionalFocusIntent intent) => FocusManager.instance.primaryFocus?.context?.widget is! EditableText;

  static FocusNode? _firstInitialTarget(FocusScopeNode scope) {
    FocusNode? firstAny;
    FocusNode? firstCard;
    final scopeTop = scope.rect.top;
    final vh = scope.rect.height > 0 ? scope.rect.height : 900.0;
    for (final n in scope.traversalDescendants) {
      if (!n.canRequestFocus || n.skipTraversal) continue;
      final r = n.rect;
      if (r.isEmpty || r.width <= 0 || r.height <= 0) continue;
      firstAny ??= n;
      final ctx = n.context;
      if (ctx != null && ctx.findAncestorWidgetOfExactType<EvCard>() != null) {
        final top = r.top - scopeTop;
        if (top >= 0 && top < vh + 400) return n;
        firstCard ??= n;
      }
    }
    return firstCard ?? firstAny;
  }

  @override
  void invoke(DirectionalFocusIntent intent) {
    final p = FocusManager.instance.primaryFocus;
    if (p == null || p == shellScope || p is FocusScopeNode) {
      final scope = p is FocusScopeNode ? p : shellScope;
      _firstInitialTarget(scope)?.requestFocus();
      return;
    }
    _EvSpatialPolicy.moveFrom(p, p.enclosingScope ?? shellScope, intent.direction);
  }
}
