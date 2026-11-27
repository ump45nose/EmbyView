/// Composition and staged registration. UI imports only embyview.dart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:server_emby/server_emby.dart';
import 'package:window_manager/window_manager.dart';

import '../auth/repositories/auth_repository.dart';
import '../auth/repositories/server_repository.dart';
import '../auth/repositories/session_repository.dart';
import '../auth/store/authentication_store.dart';
import '../auth/store/credential_store.dart';
import '../data/offline/connectivity_aware_media_server_client.dart';
import '../data/services/media_server_client_factory.dart';
import '../data/services/theme_music_service.dart';
import '../playback/aether_backend.dart';
import '../preference/user_preferences.dart';
import 'data/accounts.dart';
import 'data/build_info.dart';
import 'data/diagnostics_exporter.dart';
import 'data/emby_media_data.dart';
import 'embyview.dart';
import 'playback/immersion.dart';
import 'playback/moonfin_playback.dart';
import 'playback/native_playback.dart';
import 'prefs/machine_preferences.dart';
import 'subtitles/subtitle_service.dart';
import 'ui/collection/ev_collection_page.dart';
import 'ui/detail/ev_detail_page.dart';
import 'ui/home/ev_home_page.dart';
import 'ui/kit.dart';
import 'ui/login/ev_moonfin_login_backend.dart';
import 'ui/palette/ev_command_palette.dart';
import 'ui/person/ev_person_page.dart';
import 'ui/player/ev_player_page.dart';
import 'ui/quicklook/ev_quicklook.dart';
import 'ui/search/ev_search_page.dart';
import 'ui/settings/ev_settings_page.dart';
import 'ui/splash/ev_splash_page.dart';
import 'ui/users/ev_users_page.dart';
import 'ui/wall/ev_wall_page.dart';
import 'ui/zone/ev_zone_page.dart';

export 'data/diagnostics_exporter.dart' show evExportDiagnosticsViaDialog;
export 'ui/login/ev_login_models.dart' show EvLoginStep;
export 'ui/settings/ev_settings_page.dart' show EvSettingsSection;

typedef EmbyViewSessionFactory = FutureOr<EmbyViewSessionServices> Function(
  AccountSnapshot account,
);
typedef EmbyViewSubtitlesFactory = EmbyViewSubtitles? Function(
  EmbyViewServices services,
);
typedef EmbyViewHomeBuilder = Widget Function(
  BuildContext context,
  EmbyViewServices services,
);
typedef EmbyViewPlayerBuilder = Widget Function(
  BuildContext context,
  PlaybackSession session, {
  Rect? origin,
  CardArtwork? art,
});

/// Internal factories retain credentials; this object contains public services only.
class EmbyViewSessionServices {
  const EmbyViewSessionServices({
    required this.data,
    required this.playback,
    required this.immersion,
    required this.dispose,
    this.invalidate,
    this.subtitles,
  });

  final EmbyViewData data;
  final EmbyViewPlayback playback;
  final ImmersionPlayback immersion;
  final EmbyViewSubtitles? subtitles;

  /// Revoke browsing and start stopping previews in the account event itself.
  final void Function()? invalidate;

  /// Cancel requests and await playback Stop reporting before completing.
  final Future<void> Function() dispose;
}

/// Each later stage owns one registration section, without modifying app_router.
class EmbyViewRegistration {
  // Stage two: subtitle capability.
  EmbyViewSubtitlesFactory? stageTwoSubtitles;

  // Stage three: shell, home, zones and walls.
  EmbyViewHomeBuilder? stageThreeHome;
  final List<RouteBase> stageThreeRoutes = [];

  // Stage four: detail, search, users, settings and command surfaces.
  final List<RouteBase> stageFourRoutes = [];

  // Stage five: controls around a session created by EvPlayer.open.
  EmbyViewPlayerBuilder? stageFivePlayer;
  final List<RouteBase> stageFiveRoutes = [];

  List<RouteBase> get routes => [
    ...stageThreeRoutes,
    ...stageFourRoutes,
    ...stageFiveRoutes,
  ];
}

final embyViewRegistration = _registerStageFive(
  _registerStageFour(
    _registerStageThree(
      EmbyViewRegistration()..stageTwoSubtitles = (services) => services.subtitles,
    ),
  ),
);
final _installedEntry = ValueNotifier<EmbyViewEntry?>(null);

EmbyViewRegistration _registerStageThree(EmbyViewRegistration registration) {
  EvPlayer.pageBuilder = (context, session, {origin, art}) =>
      buildEmbyViewPlayer(
        context,
        session,
        origin: origin,
        art: art,
        registration: registration,
      );
  registration.stageThreeHome = (context, services) =>
      _buildStageThreeShell(services);
  registration.stageThreeRoutes.addAll([
    GoRoute(
      path: 'zone/:zoneId',
      builder: (context, state) {
        final zoneId = state.pathParameters['zoneId'] ?? '';
        return _EmbyViewRouteHost(
          destination: zoneId.isNotEmpty
              ? EvZoneDestination(zoneId)
              : const EvHomeDestination(),
        );
      },
    ),
    GoRoute(
      path: 'wall',
      builder: (context, state) => _EmbyViewRouteHost(
        destination: _wallDestinationFromRoute(state),
      ),
    ),
  ]);
  return registration;
}

EmbyViewRegistration _registerStageFour(EmbyViewRegistration registration) {
  registration.stageFourRoutes.addAll([
    GoRoute(path: 'detail/:itemId', builder: (_, s) {
      final id = s.pathParameters['itemId'] ?? '';
      return _EmbyViewRouteHost(initialEntry: id.isNotEmpty ? _S4Detail(0, id) : null);
    }),
    GoRoute(path: 'collection/:collectionId', builder: (_, s) {
      final id = s.pathParameters['collectionId'] ?? '';
      return _EmbyViewRouteHost(initialEntry: id.isNotEmpty ? _S4Collection(0, id) : null);
    }),
    GoRoute(path: 'person/:personId', builder: (_, s) {
      final id = s.pathParameters['personId'] ?? '';
      final qp = s.uri.queryParameters;
      return _EmbyViewRouteHost(
        initialEntry: id.isNotEmpty ? _S4Person(0, id, name: qp['name'], roleHint: qp['role']) : null,
      );
    }),
    GoRoute(path: 'search', builder: (_, s) {
      final qp = s.uri.queryParameters;
      return _EmbyViewRouteHost(initialEntry: _S4Search(0, zoneId: qp['zone']?.isNotEmpty == true ? qp['zone'] : null, initialQuery: qp['q']));
    }),
    GoRoute(path: 'settings', builder: (_, s) {
      final qp = s.uri.queryParameters;
      final sec = EvSettingsSection.values.where((v) => v.name == qp['section']).firstOrNull ?? EvSettingsSection.account;
      return _EmbyViewRouteHost(initialEntry: _S4Settings(0, section: sec, openZoneEditor: qp['zedit'] == '1' || qp['zedit'] == 'true'));
    }),
    GoRoute(path: 'users', builder: (_, _) => const _EmbyViewRouteHost(initialEntry: _S4Users(0))),
  ]);
  return registration;
}

EmbyViewRegistration _registerStageFive(EmbyViewRegistration registration) {
  registration.stageFivePlayer = (context, session, {origin, art}) =>
      EvPlayerPage(session: session, origin: origin, art: art);
  return registration;
}

Widget _buildStageThreeShell(
  EmbyViewServices services, {
  EvShellDestination? initialDestination,
  _S4Entry? initialEntry,
  bool showOnboardingOverlay = true,
}) => _StageFourShellHost(
  services: services,
  initialDestination: initialDestination,
  initialEntry: initialEntry,
  showOnboardingOverlay: showOnboardingOverlay,
);

/// Test and smoke-verification helper mounting the full Stage 4 EmbyView host.
Widget buildStageFourTestShell({
  required EmbyViewServices services, EvShellDestination? initialDestination,
  String? initialDetailId, bool openVersionPopoverOnMount = false,
  String? initialCollectionId, String? initialPersonId, String? initialPersonName,
  bool initialSearch = false, EvSettingsSection? initialSettings,
  bool initialUsers = false, bool openZoneEditorOnMount = false,
  bool showOnboardingOverlay = false,
  EvShellController? shellController,
  EvNoticeState? initialNotice,
  bool initialShortcutsOpen = false,
  Future<void> Function()? onExportDiagnostics,
  VoidCallback? onSignedOutToUserPicker,
  VoidCallback? onSwitchServer,
  VoidCallback? onAddAccount,
}) => KeyedSubtree(
  key: ValueKey(services.sessionId),
  child: _StageFourShellHost(
    services: services, initialDestination: initialDestination,
    initialEntry: initialDetailId != null
        ? _S4Detail(0, initialDetailId, openVersionPopover: openVersionPopoverOnMount)
        : initialCollectionId != null
        ? _S4Collection(0, initialCollectionId)
        : initialPersonId != null
        ? _S4Person(0, initialPersonId, name: initialPersonName)
        : initialSearch ? const _S4Search(0)
        : initialSettings != null ? _S4Settings(0, section: initialSettings, openZoneEditor: openZoneEditorOnMount)
        : initialUsers ? const _S4Users(0) : null,
    showOnboardingOverlay: showOnboardingOverlay,
    shellController: shellController,
    initialNotice: initialNotice,
    initialShortcutsOpen: initialShortcutsOpen,
    onExportDiagnostics: onExportDiagnostics,
    onSignedOutToUserPicker: onSignedOutToUserPicker,
    onSwitchServer: onSwitchServer,
    onAddAccount: onAddAccount,
  ),
);

Future<void> _macWin(Future<void> Function() action) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
  try { await action(); } catch (_) {}
}

Widget _buildMacWindowDragArea(BuildContext _) => GestureDetector(
  key: const Key('ev_topbar_drag_area'),
  behavior: HitTestBehavior.translucent,
  onPanStart: (_) => unawaited(_macWin(windowManager.startDragging)),
  onDoubleTap: () => unawaited(_macWin(() async => (await windowManager.isMaximized()) ? windowManager.unmaximize() : windowManager.maximize())),
);

class _StageThreeRuntime {
  _StageThreeRuntime(this.sessionId, EmbyViewServices services) : stage = EvStageController() {
    immersion = Immersion(stage: stage, services: services);
  }
  static _StageThreeRuntime? _active;
  final String? sessionId;
  final EvStageController stage;
  late final Immersion immersion;
  int refs = 0;
  bool _disposed = false;

  static _StageThreeRuntime acquire(EmbyViewServices services) {
    final cur = _active;
    if (cur != null && !cur._disposed && cur.sessionId == services.sessionId) {
      cur.refs++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!cur._disposed) unawaited(cur.immersion.rebind(services));
      });
      if (cur.refs > 1) unawaited(cur.immersion.stopAll());
      return cur;
    }
    if (cur != null && !cur._disposed) unawaited(cur.immersion.stopAll());
    return _active = _StageThreeRuntime(services.sessionId, services)..refs = 1;
  }

  void release() {
    if (--refs <= 0) {
      if (identical(_active, this)) _active = null;
      if (!_disposed) { _disposed = true; immersion.dispose(); stage.dispose(); }
    } else if (!_disposed) {
      unawaited(immersion.stopAll());
    }
  }
}

sealed class _S4Entry { const _S4Entry(this.id); final int id; }
final class _S4Detail extends _S4Entry { const _S4Detail(super.id, this.itemId, {this.openVersionPopover = false}); final String itemId; final bool openVersionPopover; }
final class _S4Collection extends _S4Entry { const _S4Collection(super.id, this.collectionId); final String collectionId; }
final class _S4Person extends _S4Entry { const _S4Person(super.id, this.personId, {this.name, this.roleHint, this.sourceItem}); final String personId; final String? name, roleHint; final MediaCard? sourceItem; }
final class _S4Search extends _S4Entry { const _S4Search(super.id, {this.zoneId, this.initialQuery}); final String? zoneId, initialQuery; }
final class _S4Settings extends _S4Entry { const _S4Settings(super.id, {this.section = EvSettingsSection.account, this.openZoneEditor = false}); final EvSettingsSection section; final bool openZoneEditor; }
final class _S4Users extends _S4Entry { const _S4Users(super.id); }
class _S4Cmd extends Intent { const _S4Cmd(this.kind); final String kind; }

typedef _StageSnap = ({
  EvStageMode mode, ArtworkPlan? baseBackdrop, double scrollProgress, bool detailNoBlur, Color? ambientColor,
  bool scrolled, double topFade, EvChromeTitlePlate? titlePlate, List<Widget> rightActions,
  bool hideTabs, bool hideAvatar, bool showBack,
});

class _StageFourShellHost extends StatefulWidget {
  const _StageFourShellHost({
    required this.services,
    this.initialDestination,
    this.initialEntry,
    this.showOnboardingOverlay = true,
    this.shellController,
    this.initialNotice,
    this.initialShortcutsOpen = false,
    this.onExportDiagnostics,
    this.onSignedOutToUserPicker,
    this.onSwitchServer,
    this.onAddAccount,
  });
  final EmbyViewServices services;
  final EvShellDestination? initialDestination;
  final _S4Entry? initialEntry;
  final bool showOnboardingOverlay;
  final EvShellController? shellController;
  final EvNoticeState? initialNotice;
  final bool initialShortcutsOpen;
  final Future<void> Function()? onExportDiagnostics;
  final VoidCallback? onSignedOutToUserPicker;
  final VoidCallback? onSwitchServer;
  final VoidCallback? onAddAccount;
  @override State<_StageFourShellHost> createState() => _StageFourShellHostState();
}

class _StageFourShellHostState extends State<_StageFourShellHost> {
  late _StageThreeRuntime _runtime;
  late EvShellController _shell;
  late bool _ownsShell;
  late EvShellDestination _lastShellDest;
  late bool _lastShortcutsOpen;
  EvNoticeState? _lastNotice;
  String? _lastSignedInSessionId;
  String? _lastSignedInUserId;
  late LocalPreferences _prefs;
  late AccountSnapshot _account;
  StreamSubscription<LocalPreferences>? _prefsSub;
  StreamSubscription<AccountSnapshot>? _accountsSub;
  StreamSubscription<ConnectionNoticeEvent>? _noticeSub;
  Object? _menuToken;
  final _quickLook = EvQuickLookController(), _palette = EvCommandPaletteController();
  final _shellScope = FocusScopeNode(debugLabel: 'ev_shell_scope');
  final _s4Scope = FocusScopeNode(debugLabel: 'ev_stage4_scope'), _s4MenuScope = FocusScopeNode(debugLabel: 'ev_stage4_menu_scope');
  final List<({_S4Entry entry, _StageSnap? saved, FocusNode? savedFocus})> _s4Stack = [];
  bool _shellMounted = true, _avatarMenuOpen = false, _onboardingDismissedLocally = false;
  int _nextEntryId = 1, _zonesToken = 0;

  @override
  void initState() {
    super.initState();
    _runtime = _StageThreeRuntime.acquire(widget.services);
    _lastSignedInSessionId = widget.services.sessionId;
    _lastSignedInUserId = widget.services.accounts.snapshot.current?.id;
    _ownsShell = widget.shellController == null;
    _shell = widget.shellController ??
        EvShellController(initial: widget.initialDestination ?? const EvHomeDestination());
    _bindShellCallbacks(_shell);
    if (widget.initialNotice != null) {
      _shell.showNotice(widget.initialNotice!);
    }
    if (widget.initialShortcutsOpen) {
      _shell.showShortcuts();
    }
    _lastShellDest = _shell.current;
    _lastShortcutsOpen = _shell.shortcutsOpen;
    _lastNotice = _shell.notice;
    _shell.addListener(_onShellChanged);
    if (widget.initialEntry != null) { _s4Stack.add((entry: widget.initialEntry!, saved: null, savedFocus: null)); _shellMounted = false; }
    _attachServices(widget.services);
    HardwareKeyboard.instance.addHandler(_onGlobalHardwareKey);
    _menuToken = EvMenuChannel.instance.registerHandler(
      (action, _) => _shell.handleMenuAction(action),
    );
    EvDiagnosticsLog.instance.record(
      'app',
      'shell_init',
      details: {
        'version': EvBuildInfo.current.version,
        'destination': _shell.current.viewKey,
        'signedIn': widget.services.signedIn,
        'theme': _prefs.theme.name,
      },
    );
    if (_s4Stack.isNotEmpty) _focusStageFourLater();
  }

  void _bindShellCallbacks(EvShellController shell) {
    shell.onOpenDetail = _openDetail;
    shell.onOpenCollection = _openCollection;
    shell.onOpenPerson = _openPerson;
    shell.onOpenSearch = _openSearch;
    shell.onOpenSettings = _openSettings;
    shell.onOpenPlaySettings = () => _openSettings(section: EvSettingsSection.play);
    shell.onOpenAbout = () => _openSettings(section: EvSettingsSection.about);
    shell.onOpenServerSettings = () => _openSettings(section: EvSettingsSection.account);
    shell.onOpenUsers = _openUsers;
    shell.onOpenLook = () => _openSettings(section: EvSettingsSection.look);
    shell.onManageZones = () => _openSettings(section: EvSettingsSection.zones);
    shell.onSignedOutToUserPicker = _handleSignedOutToUserPicker;
    shell.onSignOut = _handleMenuSignOut;
    shell.onSwitchServer = _handleSwitchServer;
    shell.onAddAccount = _handleAddAccount;
    shell.onToggleCommandPalette = _toggleCommandPalette;
    shell.onBack = _handleUnifiedBack;
    shell.onGoHome = () => _returnToShell(const EvHomeDestination(), _shell.goHome, resetHero: true);
    shell.onOpenZoneById = (z) => _returnToShell(EvZoneDestination(z), () => _shell.openZone(z));
    shell.onExportDiagnostics = _handleExportDiagnostics;
    shell.onRetryConnection = _handleRetryConnection;
  }

  void _attachServices(EmbyViewServices services) {
    unawaited(_prefsSub?.cancel());
    unawaited(_accountsSub?.cancel());
    unawaited(_noticeSub?.cancel());
    _noticeSub = null;
    _prefs = services.preferences.current; _account = services.accounts.snapshot;
    _prefsSub = services.preferences.changes.listen((next) {
      String sig(List<ZonePreference> zs) => zs.map((z) => '${z.id}:${z.name}:${z.iconKey}:${z.colorSlot}').join('|');
      final zc = sig(_prefs.zones) != sig(next.zones);
      if (!mounted) return;
      setState(() => _prefs = next);
      if (zc && !_shellMounted) unawaited(_loadZones(services, force: true));
    });
    _accountsSub = services.accounts.changes.listen((next) { if (mounted) setState(() => _account = next); });
    _noticeSub = services.accounts.connectionNotices.listen(
      _shell.handleConnectionNotice,
    );
    if (!_shellMounted && _shell.zones.isEmpty) unawaited(_loadZones(services, force: false));
  }

  Future<void> _loadZones(EmbyViewServices services, {required bool force}) async {
    final data = services.data;
    if (data == null) return;
    final token = ++_zonesToken;
    try { final loaded = await data.zones(); if (mounted && token == _zonesToken && (loaded.isNotEmpty || force)) _shell.setZones(loaded); }
    catch (_) { if (mounted && token == _zonesToken && force) _shell.setZones(const []); }
  }

  void _scheduleImmersionRebind(EmbyViewServices services) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(widget.services, services)) {
        unawaited(_runtime.immersion.rebind(services));
      }
    });
  }

  @override
  void didUpdateWidget(_StageFourShellHost old) {
    super.didUpdateWidget(old);
    final nextSessionId = widget.services.sessionId;
    final snap = widget.services.accounts.snapshot;
    if (nextSessionId == null &&
        (snap.phase == AccountPhase.switching || snap.phase == AccountPhase.signingIn)) {
      if (!identical(old.services, widget.services)) {
        _scheduleImmersionRebind(widget.services);
        _attachServices(widget.services);
      }
      return;
    }
    if (nextSessionId != null && nextSessionId != _lastSignedInSessionId) {
      final nextUserId = snap.current?.id;
      final isFailedRecoveryOnUsers =
          _s4Stack.lastOrNull?.entry is _S4Users &&
          snap.failure != null &&
          nextUserId == _lastSignedInUserId;
      final stayOnUsersForCallback =
          widget.initialEntry is _S4Users && _s4Stack.lastOrNull?.entry is _S4Users;
      _lastSignedInSessionId = nextSessionId;
      _lastSignedInUserId = nextUserId;
      final prev = _runtime;
      _runtime = _StageThreeRuntime.acquire(widget.services);
      prev.release();
      ++_zonesToken;
      _shell
        ..clearHomeCache()
        ..hasVisibleLibraries = true
        ..setZones(const []);
      if (!isFailedRecoveryOnUsers && !stayOnUsersForCallback) {
        _closeOverlays(rebuild: false);
        _s4Stack.clear();
        _shellMounted = true;
        _shell.goHome();
      }
      _attachServices(widget.services);
    } else if (old.services.sessionId != nextSessionId) {
      final prev = _runtime;
      _runtime = _StageThreeRuntime.acquire(widget.services);
      prev.release();
      ++_zonesToken;
      _closeOverlays(rebuild: false);
      _s4Stack.clear();
      _shellMounted = true;
      _shell
        ..clearHomeCache()
        ..hasVisibleLibraries = true
        ..setZones(const [])
        ..goHome();
      _attachServices(widget.services);
    } else if (!identical(old.services, widget.services)) {
      _scheduleImmersionRebind(widget.services);
      _attachServices(widget.services);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalHardwareKey);
    if (_menuToken != null) {
      EvMenuChannel.instance.unregisterHandler(_menuToken!);
      _menuToken = null;
    }
    unawaited(_prefsSub?.cancel());
    unawaited(_accountsSub?.cancel());
    unawaited(_noticeSub?.cancel());
    _shell.removeListener(_onShellChanged);
    if (_ownsShell) _shell.dispose();
    _quickLook.dispose(); _palette.dispose(); _shellScope.dispose(); _s4Scope.dispose(); _s4MenuScope.dispose();
    _runtime.release(); super.dispose();
  }

  void _onShellChanged() {
    if (!mounted) return;
    final destChanged = _shell.current != _lastShellDest;
    final shortcutsChanged = _shell.shortcutsOpen != _lastShortcutsOpen;
    final noticeChanged = _shell.notice != _lastNotice;
    if (destChanged) {
      _lastShellDest = _shell.current;
      _closeOverlays();
    }
    if (shortcutsChanged || noticeChanged) {
      _lastShortcutsOpen = _shell.shortcutsOpen;
      _lastNotice = _shell.notice;
      setState(() {});
    }
  }

  void _closeOverlays({bool rebuild = true}) {
    _quickLook.close();
    _palette.close();
    _shell.closeShortcuts();
    if (_avatarMenuOpen) { _avatarMenuOpen = false; if (rebuild && mounted) setState(() {}); }
  }

  void _toggleCommandPalette() {
    _shell.closeShortcuts();
    _palette.toggle();
  }

  void _handleMenuSignOut() {
    _closeOverlays(rebuild: true);
    unawaited(() async {
      final rootNav = Navigator.maybeOf(context, rootNavigator: true);
      if (EvPlayer.isOpening && rootNav != null && rootNav.canPop()) {
        await rootNav.maybePop();
      }
      try {
        await widget.services.accounts.signOut();
      } catch (_) {
      } finally {
        _handleSignedOutToUserPicker();
      }
    }());
  }

  Future<void> _handleExportDiagnostics() async {
    if (widget.onExportDiagnostics != null) {
      await widget.onExportDiagnostics!();
      return;
    }
    await evExportDiagnosticsViaDialog();
  }

  Future<void> _handleRetryConnection() async {
    await widget.services.accounts.retryConnection();
  }

  bool get _isShowingOnboarding =>
      widget.showOnboardingOverlay &&
      _s4Stack.isEmpty &&
      !_onboardingDismissedLocally &&
      !_prefs.onboardingDismissed &&
      _shell.current is EvHomeDestination;

  bool _handleUnifiedBack() {
    if (_shell.shortcutsOpen) {
      _shell.closeShortcuts();
      return true;
    }
    if (_palette.isOpen) {
      _palette.close();
      return true;
    }
    if (_quickLook.isOpen) {
      _quickLook.close();
      return true;
    }
    if (_avatarMenuOpen) {
      setState(() => _avatarMenuOpen = false);
      return true;
    }
    if (_shell.onCloseAvatarMenu?.call() == true) {
      return true;
    }
    if (_isShowingOnboarding) {
      setState(() => _onboardingDismissedLocally = true);
      return true;
    }
    if (_s4Stack.isNotEmpty) {
      _popStageFour();
      return true;
    }
    if (_shell.pop()) {
      return true;
    }
    if (Navigator.canPop(context)) {
      unawaited(Navigator.maybePop(context));
      return true;
    }
    // At Home with no overlays open: intentionally do nothing (never show exit dialog).
    return false;
  }

  bool _onGlobalHardwareKey(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_shell.shortcutsOpen) {
        _shell.closeShortcuts();
        return true;
      }
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary == FocusManager.instance.rootScope) {
        _handleUnifiedBack();
        return true;
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

  _StageSnap _captureSnap() => (
    mode: _runtime.stage.mode, baseBackdrop: _runtime.stage.baseBackdrop, scrollProgress: _runtime.stage.scrollProgress,
    detailNoBlur: _runtime.stage.detailNoBlur, ambientColor: _runtime.stage.ambientColor, scrolled: _shell.scrolled,
    topFade: _shell.topFade, titlePlate: _shell.titlePlate, rightActions: _shell.rightActions,
    hideTabs: _shell.hideTabs, hideAvatar: _shell.hideAvatar, showBack: _shell.showBack,
  );

  void _restoreSnap(_StageSnap snap, {required bool restoreShellChrome}) {
    _runtime.stage..setMode(snap.mode, detailNoBlur: snap.detailNoBlur)..setBaseBackdrop(snap.baseBackdrop)
      ..setScrollProgress(snap.scrollProgress)..setAmbientColor(snap.ambientColor)..setVeilLifted(false)..clearPreviewBackdrop();
    if (!restoreShellChrome) return;
    void apply() => _shell.updateChrome(
      scrolled: snap.scrolled, topFade: snap.topFade, titlePlate: snap.titlePlate, clearTitlePlate: snap.titlePlate == null,
      rightActions: snap.rightActions, hideTabs: snap.hideTabs, hideAvatar: snap.hideAvatar, showBack: snap.showBack,
    );
    apply();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _s4Stack.isEmpty) apply(); });
  }

  void _resetHeroStage() => _runtime.stage..setMode(EvStageMode.hero)..setScrollProgress(0.0)..setVeilLifted(false)..clearPreviewBackdrop()..setAmbientColor(null);
  void _focusStageFourLater() => WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _s4Stack.isNotEmpty && !_s4Scope.hasFocus) _s4Scope.requestFocus(); });

  void _restoreFocusLater(FocusNode? target, {required bool backToShell}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (backToShell) {
        if (_s4Stack.isNotEmpty) return;
        if (target != null && target.context != null && target.canRequestFocus) {
          target.requestFocus();
        } else if (_shellScope.canRequestFocus && !_shellScope.hasFocus) {
          _shellScope.requestFocus();
        }
        return;
      }
      if (_s4Stack.isEmpty) return;
      if (target != null && target.context != null && target.canRequestFocus) {
        target.requestFocus();
      } else if (!_s4Scope.hasFocus) {
        _s4Scope.requestFocus();
      }
    });
  }

  void _pushStageFour(_S4Entry next) {
    if (!mounted) return;
    final savedFocus = FocusManager.instance.primaryFocus;
    _closeOverlays(rebuild: false); _runtime.immersion.onCardHoverEnd();
    final saved = _captureSnap();
    _shell.updateChrome(scrolled: false, topFade: 0.0);
    setState(() => _s4Stack.add((entry: next, saved: saved, savedFocus: savedFocus)));
    _focusStageFourLater();
  }

  void _openDetail(String id) { final top = _s4Stack.lastOrNull?.entry; if (id.isNotEmpty && (top is! _S4Detail || top.itemId != id)) _pushStageFour(_S4Detail(_nextEntryId++, id)); }
  void _openCollection(String id) { final top = _s4Stack.lastOrNull?.entry; if (id.isNotEmpty && (top is! _S4Collection || top.collectionId != id)) _pushStageFour(_S4Collection(_nextEntryId++, id)); }
  void _openPerson(String id, {String? name, String? roleHint, MediaCard? sourceItem}) {
    final top = _s4Stack.lastOrNull?.entry;
    if (id.isNotEmpty && (top is! _S4Person || top.personId != id)) {
      _pushStageFour(_S4Person(_nextEntryId++, id, name: name, roleHint: roleHint, sourceItem: sourceItem));
    }
  }
  void _openSearch({String? zoneId, String? query}) {
    final top = _s4Stack.lastOrNull?.entry;
    if (top is _S4Search && top.zoneId == zoneId && query == null) { _closeOverlays(); return; }
    _pushStageFour(_S4Search(_nextEntryId++, zoneId: zoneId, initialQuery: query));
  }
  void _openSettings({EvSettingsSection section = EvSettingsSection.account, bool openZoneEditor = false}) {
    final top = _s4Stack.lastOrNull?.entry;
    if (top is _S4Settings && top.section == section && !openZoneEditor) { _closeOverlays(); return; }
    _pushStageFour(_S4Settings(_nextEntryId++, section: section, openZoneEditor: openZoneEditor));
  }
  void _openUsers() { _s4Stack.lastOrNull?.entry is _S4Users ? _closeOverlays() : _pushStageFour(_S4Users(_nextEntryId++)); }

  void _returnToShell(EvShellDestination target, VoidCallback navigate, {bool resetHero = false}) {
    _closeOverlays(rebuild: false);
    final firstSaved = _s4Stack.firstOrNull?.saved, sameDest = _shellMounted && _shell.current == target;
    setState(() { _s4Stack.clear(); _shellMounted = true; });
    if (sameDest && firstSaved != null) { _restoreSnap(firstSaved, restoreShellChrome: true); }
    else { navigate(); if (resetHero) _resetHeroStage(); }
    _restoreFocusLater(null, backToShell: true);
  }

  void _popStageFour() {
    _closeOverlays(rebuild: false);
    if (_s4Stack.isEmpty) {
      if (!_shell.pop() && Navigator.canPop(context)) unawaited(Navigator.maybePop(context));
      return;
    }
    if (_s4Stack.length == 1 && _s4Stack.first.saved == null && Navigator.canPop(context)) { unawaited(Navigator.maybePop(context)); return; }
    final popped = _s4Stack.removeLast(), backToShell = _s4Stack.isEmpty;
    if (backToShell) _shellMounted = true;
    setState(() {});
    if (popped.saved != null) { _restoreSnap(popped.saved!, restoreShellChrome: backToShell); }
    else if (backToShell) { _resetHeroStage(); }
    _restoreFocusLater(popped.savedFocus, backToShell: backToShell);
  }

  String? get _currentServerId =>
      _account.current?.serverId ?? _account.profiles.firstOrNull?.serverId;

  void _handleSignedOutToUserPicker() {
    if (!mounted) return;
    if (widget.onSignedOutToUserPicker != null) {
      widget.onSignedOutToUserPicker!();
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(
        embyViewLoginRoute(
          step: EvLoginStep.users,
          serverId: _currentServerId,
        ),
      );
      return;
    }
    _openUsers();
  }

  void _handleSwitchServer() {
    if (!mounted) return;
    if (widget.onSwitchServer != null) {
      widget.onSwitchServer!();
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(embyViewLoginRoute(step: EvLoginStep.server));
    }
  }

  void _handleAddAccount() {
    if (!mounted) return;
    if (widget.onAddAccount != null) {
      widget.onAddAccount!();
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(
        embyViewLoginRoute(
          step: EvLoginStep.users,
          serverId: _currentServerId,
        ),
      );
      return;
    }
    _openUsers();
  }

  void _onUserSelected(AccountProfile _) {
    if (!mounted) return;
    if (widget.initialEntry is _S4Users) {
      final router = GoRouter.maybeOf(context);
      if (router != null) {
        router.go(embyViewHomePath);
        return;
      }
      _closeOverlays(rebuild: false);
      setState(() { _s4Stack.clear(); _shellMounted = true; });
      return;
    }
    if (widget.services.accounts.snapshot.sessionId != widget.services.sessionId) {
      _closeOverlays(rebuild: false); setState(() { _s4Stack.clear(); _shellMounted = true; }); return;
    }
    _popStageFour();
  }

  void _selectStageFourTab(String id) => id == 'home'
      ? _returnToShell(const EvHomeDestination(), _shell.goHome, resetHero: true)
      : id == 'search' ? _openSearch() : _returnToShell(EvZoneDestination(id), () => _shell.openZone(id));

  void _toggleAvatarMenu() {
    setState(() => _avatarMenuOpen = !_avatarMenuOpen);
    if (_avatarMenuOpen) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _avatarMenuOpen) _s4MenuScope.requestFocus(); });
  }

  EvQuickLookTarget? _resolveEpisodeQuickLook(BuildContext focusCtx) {
    EvEpisodeCard? epW; BuildContext? cardCtx;
    if (focusCtx.widget is EvEpisodeCard) { epW = focusCtx.widget as EvEpisodeCard; cardCtx = focusCtx; }
    else { focusCtx.visitAncestorElements((el) { if (el.widget is EvEpisodeCard) { epW = el.widget as EvEpisodeCard; cardCtx = el; return false; } return true; }); }
    if (epW == null) return null;
    final ep = epW!.episode, ro = (cardCtx ?? focusCtx).findRenderObject(), pos = ep.resumePosition;
    final origin = ro is RenderBox && ro.hasSize ? (ro.localToGlobal(Offset.zero) & ro.size) : null;
    final resume = (pos != null && pos > Duration.zero)
        ? ResumeCard(card: epW!.card, target: PlayTarget(itemId: epW!.card.id, startAt: pos, episodeNumber: ep.episodeNumber), position: pos, duration: epW!.card.duration)
        : null;
    return EvQuickLookTarget(card: epW!.card, resume: resume, origin: origin);
  }

  @override
  Widget build(BuildContext context) {
    final showingStageFour = _s4Stack.isNotEmpty;
    final showOnboarding = _isShowingOnboarding;
    final activeNotice = _shell.notice;
    final shortcutsOpen = _shell.shortcutsOpen;
    return EvThemeScope(
      preferences: widget.services.preferences,
      child: EvScope(
        services: widget.services, stage: _runtime.stage, immersion: _runtime.immersion, shell: _shell,
        child: Stack(fit: StackFit.expand, children: [
          EvQuickLookHost(
            controller: _quickLook,
            isSuppressed: () => showOnboarding || _palette.isOpen || shortcutsOpen || ModalRoute.of(context)?.isCurrent == false,
            resolveFocusTarget: _resolveEpisodeQuickLook, onOpenDetail: _openDetail,
            child: EvCommandPaletteHost(
              controller: _palette, onBeforeOpen: () { _quickLook.close(); _shell.closeShortcuts(); },
              onOpenDetail: _openDetail, onOpenSearch: _openSearch, onOpenSettings: _openSettings, onOpenUsers: _openUsers,
              onAddZone: () => _openSettings(section: EvSettingsSection.zones, openZoneEditor: true),
              onOpenZone: (z) => _returnToShell(EvZoneDestination(z), () => _shell.openZone(z)),
              child: Stack(fit: StackFit.expand, children: [
                if (_shellMounted)
                  ExcludeFocus(
                    excluding: showingStageFour || showOnboarding || shortcutsOpen,
                    child: Offstage(
                      offstage: showingStageFour,
                      child: TickerMode(
                        enabled: !showingStageFour,
                        child: EvShell(
                          services: widget.services, initialDestination: widget.initialDestination,
                          controller: _shell, stage: _runtime.stage, immersion: _runtime.immersion,
                          focusScopeNode: _shellScope,
                          renderGlobalOverlays: false,
                          onConfigureWindow: () => _macWin(() => windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: true)),
                          windowDragBuilder: _buildMacWindowDragArea,
                          homeBuilder: (_) => const EvHomePage(), zoneBuilder: (_, z) => EvZonePage(zoneId: z),
                          wallBuilder: (_, q, t) => EvWallPage(initialQuery: q, title: t),
                        ),
                      ),
                    ),
                  ),
                if (showOnboarding)
                  Positioned.fill(
                    child: EvOnboardingCard(
                      preferences: widget.services.preferences,
                      profile: _account.current,
                      onDismissed: () {
                        if (mounted) setState(() => _onboardingDismissedLocally = true);
                      },
                      onOpenAiSettings: () => _openSettings(section: EvSettingsSection.ai),
                    ),
                  ),
                if (showingStageFour) Positioned.fill(child: _buildStageFourFrame(context, _s4Stack.last.entry)),
                if (activeNotice != null)
                  Positioned.fill(
                    child: EvNoticeCapsule(
                      notice: activeNotice,
                      onRetry: _shell.triggerConnectionRetry,
                      onOpenServerSettings: () {
                        _shell.dismissNotice();
                        _openSettings(section: EvSettingsSection.account);
                      },
                      onDismiss: _shell.dismissNotice,
                    ),
                  ),
              ]),
            ),
          ),
          if (shortcutsOpen)
            Positioned.fill(
              child: EvShortcutsOverlay(onClose: _shell.closeShortcuts),
            ),
        ]),
      ),
    );
  }

  Widget _buildStageFourFrame(BuildContext context, _S4Entry entry) {
    final isBareChrome = entry is _S4Detail || entry is _S4Collection || entry is _S4Person;
    final page = switch (entry) {
      _S4Detail(:final id, :final itemId, :final openVersionPopover) => EvDetailPage(
        key: ValueKey('s4_detail_${id}_$itemId'), itemId: itemId,
        openVersionPopoverOnMount: openVersionPopover,
        onOpenItem: _openDetail, onOpenCollection: _openCollection,
        onOpenPerson: _openPerson, onOpenPlaySettings: () => _openSettings(section: EvSettingsSection.play)),
      _S4Collection(:final id, :final collectionId) => EvCollectionPage(
        key: ValueKey('s4_collection_${id}_$collectionId'), collectionId: collectionId,
        onOpenItem: _openDetail),
      _S4Person(:final id, :final personId, :final name, :final roleHint, :final sourceItem) => EvPersonPage(
        key: ValueKey('s4_person_${id}_$personId'), personId: personId,
        personName: name, roleHint: roleHint, sourceItem: sourceItem,
        onOpenItem: _openDetail),
      _S4Search(:final id, :final zoneId, :final initialQuery) => EvSearchPage(
        key: ValueKey('s4_search_$id'), zoneId: zoneId, initialQuery: initialQuery, onOpenItem: _openDetail, onOpenPalette: _palette.open),
      _S4Settings(:final id, :final section, :final openZoneEditor) => EvSettingsPage(
        key: ValueKey('s4_settings_$id'), initialSection: section, openZoneEditorOnMount: openZoneEditor, onOpenUsers: _openUsers,
        onSignedOutToUserPicker: _handleSignedOutToUserPicker, onSwitchServer: _handleSwitchServer, onAddAccount: _handleAddAccount),
      _S4Users(:final id) => EvUsersPage(
        key: ValueKey('s4_users_$id'), onSelected: _onUserSelected,
        onSignedOutToUserPicker: _handleSignedOutToUserPicker, onSwitchServer: _handleSwitchServer),
    };
    return Builder(builder: (context) {
      final theme = EvTheme.of(context), scale = EvScale.of(context);
      return Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): _S4Cmd('esc'),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _S4Cmd: CallbackAction<_S4Cmd>(onInvoke: (i) {
              if (i.kind == 'esc') { _handleUnifiedBack(); }
              return null;
            }),
          },
          child: FocusScope(
            node: _s4Scope, autofocus: true,
            child: ColoredBox(
              color: theme.bg,
              child: Stack(fit: StackFit.expand, children: [
                Positioned.fill(child: EvStage(controller: _runtime.stage, immersion: _runtime.immersion)),
                Positioned.fill(child: page),
                if (entry is! _S4Users)
                  Positioned(left: 0, right: 0, top: 0, child: ListenableBuilder(
                    listenable: Listenable.merge([_shell, _runtime.stage]),
                    builder: (_, _) => EvTopBar(
                      zones: _shell.zones, activeTabId: entry is _S4Search ? 'search' : null,
                      navigationStyle: _prefs.navigation, scrolled: _shell.scrolled, topFade: _shell.topFade,
                      onImageBackdrop: _runtime.stage.mode != EvStageMode.ambient && _runtime.stage.mode != EvStageMode.person, showBack: true,
                      hideTabs: isBareChrome, hideAvatar: isBareChrome, showSearchTab: true,
                      currentProfile: _account.current, avatarMenuOpen: _avatarMenuOpen,
                      windowDragBuilder: _buildMacWindowDragArea, onSelectTab: _selectStageFourTab,
                      onBack: _popStageFour, onAvatarTap: _toggleAvatarMenu,
                    ),
                  )),
                if (_avatarMenuOpen && entry is! _S4Users && !isBareChrome) ...[
                  Positioned.fill(child: GestureDetector(key: const Key('ev_avatar_menu_scrim'), behavior: HitTestBehavior.translucent, onTap: () => setState(() => _avatarMenuOpen = false))),
                  Positioned(right: scale.rem(1.5), top: scale.rem(4.0), child: FocusScope(
                    node: _s4MenuScope,
                    child: EvAvatarMenu(
                      accounts: widget.services.accounts,
                      themeMode: _prefs.theme,
                      onSwitchUsers: _openUsers,
                      onOpenLook: () => _openSettings(section: EvSettingsSection.look),
                      onManageZones: () => _openSettings(section: EvSettingsSection.zones),
                      onOpenSettings: _openSettings,
                      onSignOut: _shell.onSignedOutToUserPicker,
                      onDismiss: () { if (_avatarMenuOpen) setState(() => _avatarMenuOpen = false); },
                    ),
                  )),
                ],
              ]),
            ),
          ),
        ),
      );
    });
  }
}

EvWallDestination _wallDestinationFromRoute(GoRouterState state) {
  final extra = state.extra;
  if (extra is EvWallDestination) return extra;
  final qp = state.uri.queryParameters;
  final title = qp['title'];
  if (extra is WallQuery) return EvWallDestination(extra, title: title);

  final featureName = qp['feature'];
  final feature = featureName == null
      ? null
      : HomeFeature.values.where((f) => f.name == featureName).firstOrNull;
  final scope = feature != null
      ? WallScope.feature(feature)
      : WallScope.zone(qp['zone'] ?? '');
  final sort =
      WallSort.values.where((s) => s.name == qp['sort']).firstOrNull ??
      WallSort.title;
  final watched =
      WatchFilter.values.where((w) => w.name == qp['watched']).firstOrNull ??
      WatchFilter.all;
  final from = qp['from'] != null ? int.tryParse(qp['from']!) : null;
  final to = qp['to'] != null ? int.tryParse(qp['to']!) : null;
  final years = (from != null || to != null) && (from == null || to == null || from <= to)
      ? YearRange(from: from, to: to)
      : null;
  final technology = qp['tech'] == null
      ? null
      : TechFilter.values.where((t) => t.name == qp['tech']).firstOrNull;

  return EvWallDestination(
    (
      scope: scope,
      sort: sort,
      watched: watched,
      genreId: qp['genre'],
      years: years,
      technology: technology,
    ),
    title: title,
  );
}

class _EmbyViewRouteHost extends StatelessWidget {
  const _EmbyViewRouteHost({this.destination, this.initialEntry});

  final EvShellDestination? destination;
  final _S4Entry? initialEntry;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EmbyViewEntry?>(
      valueListenable: _installedEntry,
      builder: (context, entry, _) {
        if (entry == null) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: entry,
          builder: (context, _) {
            final services = entry.services;
            final phase = services.accounts.snapshot.phase;
            final keepMountedDuringSwitch =
                phase == AccountPhase.switching || phase == AccountPhase.signingIn;
            if (!services.signedIn && !keepMountedDuringSwitch) {
              return const SizedBox.shrink();
            }
            return _buildStageThreeShell(
              services,
              initialDestination: destination,
              initialEntry: initialEntry,
            );
          },
        );
      },
    );
  }
}
Future<EmbyViewEntry>? _productionInitialization;

EmbyViewEntry? get installedEmbyViewEntry => _installedEntry.value;

/// The application composition root installs this before first signed-in routing.
void installEmbyViewEntry(EmbyViewEntry? entry) {
  _installedEntry.value = entry;
  if (entry == null) _productionInitialization = null;
}

/// Called by the verified Mac/Emby route after Moonfin has authenticated.
/// Playback module registration precedes login, so the shared Aether backend
/// already exists; this does not create another engine or restore another login.
Future<EmbyViewEntry> ensureMoonfinEmbyViewEntry() async {
  final installed = installedEmbyViewEntry;
  if (installed != null) {
    await installed.ready;
    return installed;
  }
  return _productionInitialization ??= _createMoonfinEntry().catchError((
    Object error,
  ) {
    _productionInitialization = null;
    throw error;
  });
}

Future<EmbyViewEntry> _createMoonfinEntry() async {
  EvDiagnosticsLog.instance.record(
    'app',
    'entry_init',
    details: {
      'version': EvBuildInfo.current.version,
      if (EvBuildInfo.current.commit.isNotEmpty) 'commit': EvBuildInfo.current.commit,
    },
  );
  final dependencies = GetIt.instance;
  final sessions = dependencies<SessionRepository>();
  late final EmbyViewEntry entry;
  final preferences = await MachinePreferences.open(
    loadDefaultZones: () async {
      final data = entry.services.data;
      if (data is! EmbyMediaData) {
        throw const EmbyViewFailure('当前用户的片库尚未就绪，请稍后重试。', retryable: true);
      }
      return data.defaultZonePreferences();
    },
  );
  final accounts = MoonfinEmbyViewAccounts(
    store: dependencies<AuthenticationStore>(),
    sessions: sessions,
    auth: dependencies<AuthRepository>(),
    servers: dependencies<ServerRepository>(),
    clients: dependencies<MediaServerClientFactory>(),
    preferences: preferences,
    credentials: dependencies.isRegistered<CredentialStore>()
        ? dependencies<CredentialStore>()
        : null,
    beforeSessionChange: () => entry.releaseCurrentSession(),
    chooseUserOnStartup: () => preferences.current.chooseUserOnStartup,
  );
  final subtitleRuntime = SubtitleRuntime(
    preferences,
    dependencies<AuthenticationStore>(),
    dependencies<ServerRepository>(),
    dependencies<MediaServerClientFactory>().deviceInfo,
    dependencies<PlaybackManager>(),
  );
  entry = EmbyViewEntry(
    preferences: preferences,
    accounts: accounts,
    createSession: (account) {
      final active = dependencies<MediaServerClient>();
      final client = active is ConnectivityAwareMediaServerClient
          ? active.onlineClient
          : active;
      final profileId =
          '${Uri.encodeComponent(sessions.activeServerId ?? '')}/${Uri.encodeComponent(sessions.activeUserId ?? '')}';
      if (client is! EmbyMediaServerClient ||
          client.userId != sessions.activeUserId ||
          client.accessToken?.isNotEmpty != true ||
          account.current?.id != profileId) {
        throw const EmbyViewFailure('Emby 用户已变更，请重新打开。', retryable: true);
      }
      final manager = dependencies<PlaybackManager>();
      final native = EmbyViewNativePlayback(dependencies<AetherBackend>());
      final data = EmbyMediaData(
        client: client,
        serverId: sessions.activeServerId,
        activeServerId: () => sessions.activeServerId,
        zonePreferences: () => preferences.current.zones,
      );
      final immersion = MacImmersionPlayback(
        preferences: preferences,
        legacyThemeMusic: dependencies.isRegistered<ThemeMusicService>()
            ? dependencies<ThemeMusicService>()
            : null,
        mainPlaybackChanges: manager.state.playingStream,
      );
      final settings = preferences.current;
      final playback = MoonfinPlaybackAdapter(
        manager: manager,
        client: client,
        native: native,
        serverId: sessions.activeServerId,
        activeServerId: () => sessions.activeServerId,
        data: data,
        beforeOpen: immersion.stop,
        preferences: () => preferences.current,
        userPreferences: dependencies.isRegistered<UserPreferences>()
            ? dependencies<UserPreferences>()
            : null,
        prefetch115: settings.preResolve115,
        autoNext: settings.autoPlayNext,
        sessionCacheByteBudget: settings.readAheadBytes,
        anime4kForAnime: settings.anime4kForAnime,
        anime4kForOther: settings.anime4kForOther,
        anime4kDefaults: () => (
          anime: preferences.current.anime4kForAnime,
          other: preferences.current.anime4kForOther,
        ),
        isAnimeItem: data.isAnimePlaybackItem,
      );
      final subtitles = subtitleRuntime.bind(profileId, data, client);
      Future<void>? stoppingImmersion, closingSubtitles;
      return EmbyViewSessionServices(
        data: data,
        playback: playback,
        immersion: immersion,
        subtitles: subtitles,
        invalidate: () {
          closingSubtitles ??= subtitles.close();
          data.dispose();
          stoppingImmersion ??= immersion.stop();
          // Observe errors immediately; dispose still awaits the original result.
          unawaited(stoppingImmersion!.catchError((_) {}));
          unawaited(closingSubtitles!.catchError((_) {}));
        },
        dispose: () async {
          try {
            await playback.dispose();
            // The stage-one fallback page still opens the shared legacy player.
            await manager.stopAndDrainReports();
          } finally {
            try {
              await (closingSubtitles ??= subtitles.close());
            } finally {
              try {
                await stoppingImmersion;
                await immersion.close();
              } finally {
                data.dispose();
                await native.dispose();
              }
            }
          }
        },
      );
    },
  );
  // Legacy pages still change Moonfin sessions directly during stage one.
  // Their async state stream cannot make that producer await our drain. Revoke
  // data and start stopping previews as soon as its state event is delivered.
  final sessionChanges = sessions.stateStream.listen((state) {
    final phase = accounts.snapshot.phase;
    if (phase == AccountPhase.switching ||
        phase == AccountPhase.signingIn ||
        phase == AccountPhase.restoring) {
      return;
    }
    final current = accounts.snapshot.current;
    final expected =
        '${Uri.encodeComponent(sessions.activeServerId ?? '')}/${Uri.encodeComponent(sessions.activeUserId ?? '')}';
    if (state != SessionState.ready ||
        current?.id != expected ||
        entry.services.sessionId == null) {
      unawaited(
        entry
            .releaseCurrentSession()
            .then((_) async {
              if (sessions.state == SessionState.ready) {
                await accounts.restore();
              }
            })
            .catchError((_) {}),
      );
    }
  });
  dependencies.registerSingleton<EmbyViewEntry>(
    entry,
    dispose: (value) async {
      await sessionChanges.cancel();
      await value.close();
      await subtitleRuntime.close();
      await accounts.close();
      await preferences.close();
      if (identical(installedEmbyViewEntry, value)) installEmbyViewEntry(null);
      value.dispose();
    },
  );
  installEmbyViewEntry(entry);
  await entry.ready;
  return entry;
}

/// Replaces all user services at the account boundary; device services survive.
class EmbyViewEntry extends ChangeNotifier {
  EmbyViewEntry({
    required EmbyViewPreferences preferences,
    required EmbyViewAccounts accounts,
    required this.createSession,
    EmbyViewRegistration? registration,
  }) : _preferences = preferences,
       _accounts = accounts,
       registration = registration ?? embyViewRegistration {
    _services = EmbyViewServices(preferences: preferences, accounts: accounts);
    _subscription = accounts.changes.listen((account) {
      unawaited(_bind(account));
    });
    ready = _bind(accounts.snapshot);
  }

  final EmbyViewPreferences _preferences;
  final EmbyViewAccounts _accounts;
  final EmbyViewSessionFactory createSession;
  final EmbyViewRegistration registration;
  late final StreamSubscription<AccountSnapshot> _subscription;
  late final Future<void> ready;
  late EmbyViewServices _services;
  EmbyViewSessionServices? _session;
  EmbyViewFailure? _failure;
  Future<void> _release = Future.value();
  String? _bindingKey;
  int _revision = 0;
  bool _closed = false;
  Future<void>? _closeFuture;

  EmbyViewServices get services => _services;
  EmbyViewFailure? get failure => _failure;

  /// Accounts await this before the underlying authenticated client can change.
  /// Device preferences and accounts remain available while user services vanish.
  Future<void> releaseCurrentSession() {
    if (_closed) return _closeFuture ?? Future.value();
    _session?.invalidate?.call();
    ++_revision;
    _bindingKey = null;
    _services = EmbyViewServices(
      preferences: _preferences,
      accounts: _accounts,
    );
    notifyListeners();
    final released = _release.then((_) async {
      final old = _session;
      if (old != null) await old.dispose();
      _session = null;
    });
    _release = released.catchError((Object error) {
      _failure = error is EmbyViewFailure
          ? error
          : const EmbyViewFailure('无法结束旧用户的播放，请重试。', retryable: true);
      if (!_closed) notifyListeners();
    });
    return released;
  }

  Future<void> _bind(AccountSnapshot account) {
    if (_closed) return Future.value();
    final signedIn =
        account.phase == AccountPhase.signedIn &&
        account.current != null &&
        account.sessionId != null;
    final key = signedIn ? account.sessionId : null;
    if (key != null && key == _bindingKey) return _release;
    final revision = ++_revision;
    _bindingKey = key;
    _session?.invalidate?.call();
    _failure = null;
    _services = EmbyViewServices(
      preferences: _preferences,
      accounts: _accounts,
    );
    notifyListeners();
    // Serialize creation as well as teardown. A late factory must finish and
    // release its resources before a new account can own the playback manager.
    _release = _release.then((_) async {
      try {
        final old = _session;
        if (old != null) await old.dispose();
        _session = null;
        if (!signedIn || _closed || revision != _revision) return;
        final created = await createSession(account);
        if (_closed || revision != _revision) {
          await created.dispose();
          return;
        }
        final base = EmbyViewServices(
          preferences: _preferences,
          accounts: _accounts,
          sessionId: key,
          data: created.data,
          playback: created.playback,
          immersion: created.immersion,
          subtitles: created.subtitles,
        );
        try {
          final subtitles = registration.stageTwoSubtitles?.call(base);
          _session = created;
          _services = EmbyViewServices(
            preferences: _preferences,
            accounts: _accounts,
            sessionId: key,
            data: created.data,
            playback: created.playback,
            immersion: created.immersion,
            subtitles: subtitles,
          );
          EvDiagnosticsLog.instance.record(
            'app',
            'session_bound',
            details: {
              'phase': account.phase.name,
              'subtitles': subtitles != null,
            },
          );
        } catch (_) {
          await created.dispose();
          rethrow;
        }
      } catch (error) {
        if (_closed || revision != _revision) return;
        _bindingKey = null;
        _failure = error is EmbyViewFailure
            ? error
            : const EmbyViewFailure(
                'Unable to open this account.',
                retryable: true,
              );
        EvDiagnosticsLog.instance.record(
          'app',
          'session_bind_failed',
          level: 'WARN',
          details: {'code': _failure?.code ?? 'unknown'},
        );
      }
      if (!_closed && revision == _revision) notifyListeners();
    });
    return _release;
  }

  /// Await this at application shutdown, before disposing account adapters.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    ++_revision;
    _session?.invalidate?.call();
    await _subscription.cancel();
    _bindingKey = null;
    _services = EmbyViewServices(
      preferences: _preferences,
      accounts: _accounts,
    );
    await _release;
    final old = _session;
    _session = null;
    if (old != null) await old.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

const embyViewHomePath = '/embyview';
const embyViewLoginPath = '/embyview-login';

String embyViewLoginRoute({
  EvLoginStep step = EvLoginStep.server,
  String? serverId,
}) {
  final params = <String, String>{
    if (step != EvLoginStep.server) 'step': step.name,
    if (serverId != null && serverId.isNotEmpty) 'serverId': serverId,
  };
  return params.isEmpty
      ? embyViewLoginPath
      : Uri(path: embyViewLoginPath, queryParameters: params).toString();
}

/// Whether the legacy 5-step Moonfin setup wizard must be bypassed for EmbyView.
bool shouldSkipSetupWizardForEmbyView({
  required bool isMacOS,
  required bool isEmby,
}) => isMacOS && isEmby;

/// Cold-start destination after restoring an EmbyView session.
String resolveEmbyViewColdStartRoute({required bool chooseUserOnStartup}) =>
    chooseUserOnStartup ? '$embyViewHomePath/users' : embyViewHomePath;

bool isEmbyViewPath(String path) =>
    path == embyViewHomePath || path.startsWith('$embyViewHomePath/');

bool isEmbyViewRoutePath(String path) =>
    isEmbyViewPath(path) ||
    path == embyViewLoginPath ||
    path.startsWith('$embyViewLoginPath/');

/// Whether the running app is currently in EmbyView mode (suppressing legacy
/// banners, in-app update checks, exit confirmation dialog, F1, and legacy
/// shortcut reference).
bool isEmbyViewAppMode({
  required String path,
  required bool isMacOS,
  bool? embyServersOnly,
  ServerType? activeServerType,
}) {
  if (isEmbyViewRoutePath(path)) return true;
  if (!isMacOS) return false;
  if (activeServerType != null) return activeServerType == ServerType.emby;
  if (embyServersOnly != null) return embyServersOnly;
  try {
    if (GetIt.instance.isRegistered<SessionRepository>() &&
        GetIt.instance.isRegistered<ServerRepository>()) {
      final activeServerId = GetIt.instance<SessionRepository>().activeServerId;
      if (activeServerId != null && activeServerId.isNotEmpty) {
        final active = GetIt.instance<ServerRepository>().getServer(activeServerId);
        if (active != null) {
          return active.serverType == ServerType.emby;
        }
      }
    }
    if (GetIt.instance.isRegistered<ServerRepository>()) {
      final servers = GetIt.instance<ServerRepository>().servers;
      if (servers.isNotEmpty) {
        return servers.every((s) => s.serverType == ServerType.emby);
      }
    }
  } catch (_) {}
  return true;
}

/// The caller supplies verified platform, server and authentication state.
String? embyViewRouteRedirect({
  required String path,
  required bool isMacOS,
  required bool isEmby,
  required bool authenticated,
  required String legacyHome,
  required String signedOut,
  String? setupPath,
  bool homeRegistered = true,
}) {
  final allowed = isMacOS && isEmby && authenticated;
  if (isEmbyViewPath(path) && !allowed) {
    return authenticated ? legacyHome : signedOut;
  }
  if (setupPath != null && path == setupPath && allowed) {
    return homeRegistered ? embyViewHomePath : legacyHome;
  }
  if (path == embyViewHomePath && allowed && !homeRegistered) return legacyHome;
  if (path == legacyHome && allowed && homeRegistered) return embyViewHomePath;
  return null;
}

/// Themed host for [EvSplashPage] used by [StartupScreen] on macOS EmbyView launches.
class EmbyViewSplashHost extends StatefulWidget {
  const EmbyViewSplashHost({
    super.key,
    this.serverName,
    this.statusText,
    this.preferences,
  });

  final String? serverName;
  final String? statusText;
  final EmbyViewPreferences? preferences;

  @override
  State<EmbyViewSplashHost> createState() => _EmbyViewSplashHostState();
}

class _EmbyViewSplashHostState extends State<EmbyViewSplashHost> {
  MachinePreferences? _ownedPrefs;

  EmbyViewPreferences? get _effectivePrefs =>
      widget.preferences ?? installedEmbyViewEntry?.services.preferences ?? _ownedPrefs;

  @override
  void initState() {
    super.initState();
    EvDiagnosticsLog.instance.record('app', 'splash_init');
    if (_effectivePrefs == null) {
      unawaited(_openPrefs());
    }
  }

  Future<void> _openPrefs() async {
    try {
      final prefs = await MachinePreferences.open();
      if (!mounted) {
        await prefs.close();
        return;
      }
      setState(() => _ownedPrefs = prefs);
    } catch (_) {}
  }

  @override
  void dispose() {
    final owned = _ownedPrefs;
    if (owned != null) unawaited(owned.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _effectivePrefs;
    return EvThemeScope(
      preferences: prefs,
      themeMode: prefs == null ? ThemeMode.cinema : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          EvSplashPage(
            serverName: widget.serverName,
            statusText: widget.statusText,
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 52,
            child: _buildMacWindowDragArea(context),
          ),
        ],
      ),
    );
  }
}

/// Themed host for [EvLoginPage] wired to Moonfin repositories and frameless drag.
class EmbyViewLoginHost extends StatefulWidget {
  const EmbyViewLoginHost({
    super.key,
    this.initialStep = EvLoginStep.server,
    this.initialServerId,
    this.backend,
    this.preferences,
    this.onSignedIn,
    this.onExportDiagnostics,
  });

  final EvLoginStep initialStep;
  final String? initialServerId;
  final EvLoginBackend? backend;
  final EmbyViewPreferences? preferences;
  final VoidCallback? onSignedIn;
  final Future<void> Function()? onExportDiagnostics;

  @override
  State<EmbyViewLoginHost> createState() => _EmbyViewLoginHostState();
}

class _EmbyViewLoginHostState extends State<EmbyViewLoginHost> {
  final _loginKey = GlobalKey<EvLoginPageState>();
  late final EvLoginBackend _backend =
      widget.backend ?? MoonfinEvLoginBackend();
  MachinePreferences? _ownedPrefs;
  Object? _menuToken;

  EmbyViewPreferences? get _effectivePrefs =>
      widget.preferences ?? installedEmbyViewEntry?.services.preferences ?? _ownedPrefs;

  @override
  void initState() {
    super.initState();
    unawaited(
      _macWin(
        () => windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: true,
        ),
      ),
    );
    if (_effectivePrefs == null) {
      unawaited(_openPrefs());
    }
    _menuToken = EvMenuChannel.instance.registerHandler(_handleMenuAction);
    EvDiagnosticsLog.instance.record(
      'app',
      'login_init',
      details: {'step': widget.initialStep.name},
    );
  }

  bool _handleMenuAction(String action, EvMenuActionSource _) {
    switch (action) {
      case EvMenuAction.exportDiagnostics:
        unawaited(
          widget.onExportDiagnostics != null
              ? widget.onExportDiagnostics!()
              : evExportDiagnosticsViaDialog(),
        );
        return true;
      case EvMenuAction.back:
        return _loginKey.currentState?.handleBack() ?? false;
      default:
        return false;
    }
  }

  Future<void> _openPrefs() async {
    try {
      final prefs = await MachinePreferences.open();
      if (!mounted) {
        await prefs.close();
        return;
      }
      setState(() => _ownedPrefs = prefs);
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_menuToken != null) {
      EvMenuChannel.instance.unregisterHandler(_menuToken!);
      _menuToken = null;
    }
    final owned = _ownedPrefs;
    if (owned != null) unawaited(owned.close());
    super.dispose();
  }

  Future<void> _handleSignedIn() async {
    if (widget.onSignedIn != null) {
      widget.onSignedIn!();
      return;
    }
    try {
      final entry = await ensureMoonfinEmbyViewEntry();
      await entry.services.accounts.restore();
    } catch (_) {}
    if (!mounted) return;
    GoRouter.maybeOf(context)?.go(embyViewHomePath);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _effectivePrefs;
    return EvThemeScope(
      preferences: prefs,
      themeMode: prefs == null ? ThemeMode.cinema : null,
      child: EvLoginPage(
        key: _loginKey,
        backend: _backend,
        initialStep: widget.initialStep,
        initialServerId: widget.initialServerId,
        windowDragBuilder: _buildMacWindowDragArea,
        onSignedIn: () => unawaited(_handleSignedIn()),
      ),
    );
  }
}

List<RouteBase> buildEmbyViewRoutes({
  required WidgetBuilder legacyHome,
  EmbyViewRegistration? registration,
}) {
  final routes = registration ?? embyViewRegistration;
  return [
    GoRoute(
      path: embyViewHomePath,
      builder: (context, state) =>
          _EmbyViewHome(legacyHome: legacyHome, registration: routes),
      routes: routes.routes,
    ),
  ];
}

class _EmbyViewHome extends StatelessWidget {
  const _EmbyViewHome({required this.legacyHome, required this.registration});

  final WidgetBuilder legacyHome;
  final EmbyViewRegistration registration;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EmbyViewEntry?>(
      valueListenable: _installedEntry,
      builder: (context, entry, _) {
        if (entry == null) return legacyHome(context);
        return ListenableBuilder(
          listenable: entry,
          builder: (context, _) {
            final services = entry.services;
            final home = registration.stageThreeHome;
            if (home == null) return legacyHome(context);
            final snap = services.accounts.snapshot;
            if (!services.signedIn &&
                snap.phase != AccountPhase.switching &&
                snap.phase != AccountPhase.signingIn) {
              return switch (snap.phase) {
                AccountPhase.choosing => EmbyViewLoginHost(
                  initialStep: EvLoginStep.users,
                  initialServerId: snap.profiles.firstOrNull?.serverId,
                  preferences: services.preferences,
                ),
                AccountPhase.signedOut => EmbyViewLoginHost(
                  initialStep: EvLoginStep.server,
                  preferences: services.preferences,
                ),
                _ => EmbyViewSplashHost(
                  serverName: snap.serverName,
                  preferences: services.preferences,
                ),
              };
            }
            return home(context, services);
          },
        );
      },
    );
  }
}

/// Stage three calls this while stage five has not registered a player yet.
/// Returning `null` lets [EvPlayer.open] fall back to its built-in minimal page.
Widget? buildEmbyViewPlayer(
  BuildContext context,
  PlaybackSession session, {
  Rect? origin,
  CardArtwork? art,
  EmbyViewRegistration? registration,
}) => (registration ?? embyViewRegistration).stageFivePlayer?.call(
  context,
  session,
  origin: origin,
  art: art,
);
