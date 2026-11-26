import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/shell/ev_menu_channel.dart';
import 'package:moonfin/embyview/ui/shell/ev_notice_capsule.dart';
import 'package:moonfin/embyview/ui/shell/ev_player.dart';
import 'package:moonfin/embyview/ui/stage/ev_stage_controller.dart';
import 'package:moonfin/embyview/ui/stage/immersion.dart';

/// Route destinations hosted inside [EvShell].
sealed class EvShellDestination {
  const EvShellDestination();
  String? get activeTabId;
  String get viewKey;
}

final class EvHomeDestination extends EvShellDestination {
  const EvHomeDestination();
  @override String get activeTabId => 'home';
  @override String get viewKey => 'home';
  @override bool operator ==(Object other) => other is EvHomeDestination;
  @override int get hashCode => 17;
}

final class EvZoneDestination extends EvShellDestination {
  const EvZoneDestination(this.zoneId);
  final String zoneId;
  @override String get activeTabId => zoneId;
  @override String get viewKey => 'zone:$zoneId';
  @override bool operator ==(Object other) => other is EvZoneDestination && other.zoneId == zoneId;
  @override int get hashCode => Object.hash('zone', zoneId);
}

final class EvWallDestination extends EvShellDestination {
  const EvWallDestination(this.query, {this.title});
  final WallQuery query;
  final String? title;
  @override String? get activeTabId => switch (query.scope) {
    ZoneWallScope(:final zoneId) => zoneId,
    FeatureWallScope() => null,
  };
  @override String get viewKey => 'wall:${query.scope}:${query.sort}:${query.watched}:${query.genreId}:${query.years?.from}-${query.years?.to}:${query.technology}:${title ?? ''}';
  @override bool operator ==(Object other) => other is EvWallDestination && other.query == query && other.title == title;
  @override int get hashCode => Object.hash('wall', query, title);
}

/// Zone title plate displayed on the left of [EvTopBar] (`.ptitle`).
@immutable
class EvChromeTitlePlate {
  const EvChromeTitlePlate({
    required this.iconKey, required this.title, required this.colorSlot,
    required this.total, required this.unit, this.addedThisMonth = 0,
  });
  final String iconKey, title, unit;
  final int colorSlot, total, addedThisMonth;

  @override
  bool operator ==(Object other) => identical(this, other) ||
      (other is EvChromeTitlePlate && other.iconKey == iconKey && other.title == title &&
       other.colorSlot == colorSlot && other.total == total && other.unit == unit && other.addedThisMonth == addedThisMonth);

  @override int get hashCode => Object.hash(iconKey, title, colorSlot, total, unit, addedThisMonth);
}

/// Shared navigation stack, zone catalog, top-bar chrome state, global overlays
/// (shortcuts reference & connection notice capsule), and macOS menu bar
/// dispatcher owned by or supplied to [EvShell].
class EvShellController extends ChangeNotifier {
  EvShellController({
    EvShellDestination initial = const EvHomeDestination(),
    List<ZoneTile> zones = const [],
    bool hasVisibleLibraries = true,
    this.onOpenDetail,
    this.onOpenSearch,
    this.onOpenSettings,
    this.onOpenAbout,
    this.onOpenServerSettings,
    this.onOpenUsers,
    this.onManageZones,
    this.onSignedOutToUserPicker,
    this.onSignOut,
    this.onSwitchServer,
    this.onAddAccount,
    this.onToggleCommandPalette,
    this.onBack,
    this.onGoHome,
    this.onOpenZoneById,
    this.onExportDiagnostics,
    this.onRetryConnection,
    this.onRetryHome,
    this.activePlayerResolver,
  }) : _stack = [initial],
       _zones = List<ZoneTile>.unmodifiable(zones),
       _hasVisibleLibraries = hasVisibleLibraries;

  final List<EvShellDestination> _stack;
  List<ZoneTile> _zones;
  bool _hasVisibleLibraries;
  HomeData? _cachedHome;
  String? _cachedHomeSessionId;
  Object? _cachedHomeDataOwner;
  bool _scrolled = false, _hideTabs = false, _hideAvatar = false;
  double _topFade = 0.0;
  EvChromeTitlePlate? _titlePlate;
  List<Widget> _rightActions = const [];
  bool? _showBackOverride;
  bool _shortcutsOpen = false;
  EvNoticeState? _notice;

  ValueChanged<String>? onOpenDetail;
  VoidCallback? onOpenSearch, onOpenSettings, onOpenAbout, onOpenServerSettings;
  VoidCallback? onOpenUsers, onManageZones;
  VoidCallback? onSignedOutToUserPicker, onSignOut, onSwitchServer, onAddAccount;
  VoidCallback? onToggleCommandPalette, onGoHome, onRetryConnection, onRetryHome;
  bool Function()? onBack;
  bool Function()? onCloseAvatarMenu;
  ValueChanged<String>? onOpenZoneById;
  Future<void> Function()? onExportDiagnostics;
  EvPlayerMenuDelegate? Function()? activePlayerResolver;

  EvShellDestination get current => _stack.last;
  List<EvShellDestination> get stack => List<EvShellDestination>.unmodifiable(_stack);
  bool get canPop => _stack.length > 1;
  List<ZoneTile> get zones => _hasVisibleLibraries ? _zones : const [];
  List<ZoneTile> get allZones => _zones;
  bool get hasVisibleLibraries => _hasVisibleLibraries;
  bool get scrolled => _scrolled;
  double get topFade => _topFade;
  EvChromeTitlePlate? get titlePlate => _titlePlate;
  List<Widget> get rightActions => _rightActions;
  bool get hideTabs => _hideTabs;
  bool get hideAvatar => _hideAvatar;
  bool get showBack => _showBackOverride ?? (canPop && current is EvWallDestination);
  bool get shortcutsOpen => _shortcutsOpen;
  EvNoticeState? get notice => _notice;

  void _resetChrome() {
    _scrolled = _hideTabs = _hideAvatar = false;
    _topFade = 0.0;
    _titlePlate = null;
    _rightActions = const [];
    _showBackOverride = null;
  }

  void goHome() {
    if (_stack.length == 1 && _stack.first is EvHomeDestination) {
      if (_scrolled || _topFade > 0 || _titlePlate != null || _rightActions.isNotEmpty) {
        _resetChrome(); notifyListeners();
      }
      return;
    }
    _stack..clear()..add(const EvHomeDestination());
    _resetChrome(); notifyListeners();
  }

  void openZone(String zoneId) {
    final dest = EvZoneDestination(zoneId);
    if (current == dest) return;
    _stack.add(dest); _resetChrome(); notifyListeners();
  }

  void openWall(WallQuery query, {String? title}) {
    final dest = EvWallDestination(query, title: title);
    if (current == dest) return;
    _stack.add(dest); _resetChrome(); notifyListeners();
  }

  bool pop() {
    if (_stack.length <= 1) return false;
    _stack.removeLast(); _resetChrome(); notifyListeners();
    return true;
  }

  void setZones(List<ZoneTile> value) {
    _zones = List<ZoneTile>.unmodifiable(value);
    unawaited(EvMenuChannel.instance.syncZones(zones));
    notifyListeners();
  }

  set hasVisibleLibraries(bool v) {
    if (_hasVisibleLibraries == v) return;
    _hasVisibleLibraries = v;
    unawaited(EvMenuChannel.instance.syncZones(zones));
    notifyListeners();
  }

  HomeData? cachedHomeFor(String? sessionId, Object? dataOwner) {
    if (_cachedHome == null) return null;
    if (_cachedHomeSessionId != sessionId || !identical(_cachedHomeDataOwner, dataOwner)) {
      return null;
    }
    return _cachedHome;
  }

  void cacheHome(String? sessionId, Object? dataOwner, HomeData home) {
    _cachedHomeSessionId = sessionId;
    _cachedHomeDataOwner = dataOwner;
    _cachedHome = home;
  }

  void clearHomeCache() {
    _cachedHome = null;
    _cachedHomeSessionId = null;
    _cachedHomeDataOwner = null;
  }

  void triggerConnectionRetry() {
    onRetryConnection?.call();
    onRetryHome?.call();
  }

  void setScrollOffset(double offset) {
    final fade = (offset / 160.0).clamp(0.0, 1.0), s = offset > 0.5;
    if (_scrolled == s && (_topFade - fade).abs() < 0.005) return;
    _scrolled = s; _topFade = fade; notifyListeners();
  }

  set scrolled(bool v) { if (_scrolled != v) { _scrolled = v; notifyListeners(); } }
  set topFade(double v) {
    final c = v.isNaN ? 0.0 : v.clamp(0.0, 1.0);
    if ((_topFade - c).abs() < 0.001) return;
    _topFade = c; _scrolled = c > 0.0; notifyListeners();
  }
  set titlePlate(EvChromeTitlePlate? v) { if (_titlePlate != v) { _titlePlate = v; notifyListeners(); } }
  set rightActions(List<Widget> v) { _rightActions = List<Widget>.unmodifiable(v); notifyListeners(); }
  set hideTabs(bool v) { if (_hideTabs != v) { _hideTabs = v; notifyListeners(); } }
  set hideAvatar(bool v) { if (_hideAvatar != v) { _hideAvatar = v; notifyListeners(); } }
  set showBack(bool v) { if (_showBackOverride != v) { _showBackOverride = v; notifyListeners(); } }
  void clearShowBackOverride() { if (_showBackOverride != null) { _showBackOverride = null; notifyListeners(); } }

  void updateChrome({
    bool? scrolled, double? topFade, EvChromeTitlePlate? titlePlate, bool clearTitlePlate = false,
    List<Widget>? rightActions, bool? hideTabs, bool? hideAvatar, bool? showBack, bool clearShowBack = false,
  }) {
    if (scrolled != null) _scrolled = scrolled;
    if (topFade != null) _topFade = topFade.clamp(0.0, 1.0);
    if (clearTitlePlate) { _titlePlate = null; } else if (titlePlate != null) { _titlePlate = titlePlate; }
    if (rightActions != null) _rightActions = List<Widget>.unmodifiable(rightActions);
    if (hideTabs != null) _hideTabs = hideTabs;
    if (hideAvatar != null) _hideAvatar = hideAvatar;
    if (clearShowBack) { _showBackOverride = null; } else if (showBack != null) { _showBackOverride = showBack; }
    notifyListeners();
  }

  // --- Global shortcuts overlay ---

  void showShortcuts() {
    if (_shortcutsOpen) return;
    _shortcutsOpen = true;
    notifyListeners();
  }

  void closeShortcuts() {
    if (!_shortcutsOpen) return;
    _shortcutsOpen = false;
    notifyListeners();
  }

  void toggleShortcuts() {
    _shortcutsOpen = !_shortcutsOpen;
    notifyListeners();
  }

  // --- Global connection notice capsule ---

  void showNotice(EvNoticeState value) {
    if (_notice == value) return;
    _notice = value;
    notifyListeners();
  }

  void showOfflineNotice({
    String? serverName,
    int initialCountdownSeconds = 8,
    int retryIntervalSeconds = 10,
    int triedAddressCount = 0,
    bool autoTick = true,
  }) {
    showNotice(EvNoticeState.offline(
      serverName: serverName,
      initialCountdownSeconds: initialCountdownSeconds,
      retryIntervalSeconds: retryIntervalSeconds,
      triedAddressCount: triedAddressCount,
      autoTick: autoTick,
    ));
  }

  void showSwitchedNotice({
    String? message,
    String? serverName,
    Duration? autoDismissAfter = const Duration(seconds: 8),
  }) {
    showNotice(EvNoticeState.switched(
      message: message,
      serverName: serverName,
      autoDismissAfter: autoDismissAfter,
    ));
  }

  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  void clearNotice() => dismissNotice();

  void handleConnectionNotice(ConnectionNoticeEvent event) {
    if (event.kind == ConnectionNoticeKind.recovered) {
      dismissNotice();
      return;
    }
    showNotice(EvNoticeState.fromConnectionEvent(event));
  }

  // --- macOS menu bar & shortcut dispatcher ---

  bool handleMenuAction(String action) {
    if (EvMenuAction.isPlaybackAction(action)) {
      final player = (activePlayerResolver ?? () => EvPlayer.activePlayerActions)();
      if (player == null) return false;
      return player.dispatch(action);
    }

    final zoneIndex = EvMenuAction.zoneIndexFor(action);
    if (zoneIndex != null) {
      final activeZones = zones;
      if (zoneIndex >= activeZones.length) return false;
      closeShortcuts();
      final zoneId = activeZones[zoneIndex].id;
      if (onOpenZoneById != null) {
        onOpenZoneById!(zoneId);
      } else {
        openZone(zoneId);
      }
      return true;
    }

    switch (action) {
      case EvMenuAction.about:
        closeShortcuts();
        if (onOpenAbout != null) {
          onOpenAbout!();
        } else {
          onOpenSettings?.call();
        }
        return true;
      case EvMenuAction.settings:
        closeShortcuts();
        onOpenSettings?.call();
        return true;
      case EvMenuAction.signOut:
        closeShortcuts();
        if (onSignOut != null) {
          onSignOut!();
        } else {
          onSignedOutToUserPicker?.call();
        }
        return true;
      case EvMenuAction.search:
        closeShortcuts();
        onOpenSearch?.call();
        return true;
      case EvMenuAction.goHome:
        closeShortcuts();
        if (onGoHome != null) {
          onGoHome!();
        } else {
          goHome();
        }
        return true;
      case EvMenuAction.commandPalette:
        closeShortcuts();
        onToggleCommandPalette?.call();
        return true;
      case EvMenuAction.back:
        if (_shortcutsOpen) {
          closeShortcuts();
          return true;
        }
        if (onBack != null) {
          return onBack!();
        }
        return pop();
      case EvMenuAction.shortcuts:
        toggleShortcuts();
        return true;
      case EvMenuAction.exportDiagnostics:
        final exporter = onExportDiagnostics;
        if (exporter != null) {
          unawaited(exporter());
          return true;
        }
        return false;
      default:
        return false;
    }
  }
}

/// Injects app-wide EmbyView services, stage, immersion, and shell controller.
class EvScope extends InheritedWidget {
  const EvScope({
    super.key, required this.services, required this.stage,
    required this.immersion, required this.shell, required super.child,
  });
  final EmbyViewServices services;
  final EvStageController stage;
  final Immersion immersion;
  final EvShellController shell;

  static EvScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<EvScope>();
  static EvScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'No EvScope found in widget tree.');
    return scope!;
  }

  @override
  bool updateShouldNotify(EvScope old) =>
      !identical(old.services, services) || !identical(old.stage, stage) ||
      !identical(old.immersion, immersion) || !identical(old.shell, shell);
}
