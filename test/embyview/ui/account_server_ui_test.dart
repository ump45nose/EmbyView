import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_page.dart';
import 'package:moonfin/embyview/ui/users/ev_users_page.dart';

const _kLan = ServerAddressEntry(
  id: 'lan',
  url: 'http://nas.local:8096',
  label: '内网',
  subtitle: '在家时用',
);
const _kTail = ServerAddressEntry(
  id: 'ts',
  url: 'https://nas.tail-example.ts.net',
  label: 'Tailscale',
  subtitle: '出门时自动换到这里',
);

const _kSfw = AccountProfile(
  id: 'sfw',
  displayName: 'sfw',
  hasPassword: true,
  visibleLibraryCount: 5,
);
const _kFamily = AccountProfile(
  id: 'family',
  displayName: '家人',
  hasPassword: true,
  lastUsedLabel: '昨天用过',
);
const _kGuest = AccountProfile(
  id: 'guest',
  displayName: '访客',
  hasPassword: false,
  lastUsedLabel: '3 天前用过',
);

class _FakePrefs implements EmbyViewPreferences {
  _FakePrefs([LocalPreferences initial = const LocalPreferences()])
    : _current = initial;

  LocalPreferences _current;
  final _changes = StreamController<LocalPreferences>.broadcast();

  @override LocalPreferences get current => _current;
  @override Stream<LocalPreferences> get changes => _changes.stream;

  @override
  Future<void> update(LocalPreferences value) async {
    _current = value;
    _changes.add(value);
  }

  @override Future<Set<SecretKind>> configuredSecrets() async => const {};
  @override Future<MediaFolderStatus> mediaFolderStatus() async => _current.mediaFolder;
  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccounts implements EmbyViewAccounts {
  _FakeAccounts([AccountSnapshot? initial])
    : _snapshot =
          initial ??
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kSfw,
            profiles: [_kSfw, _kFamily, _kGuest],
            serverName: '家里的 Emby',
            serverAddress: 'http://nas.local:8096',
            activeAddress: _kLan,
            addresses: [_kLan, _kTail],
            serverVersion: '4.10.2',
            latencyMs: 12,
            connection: ConnectionState.connected,
            sessionId: 'sess_sfw',
          );

  AccountSnapshot _snapshot;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final _notices = StreamController<ConnectionNoticeEvent>.broadcast();

  int signOutCalls = 0;
  int removeServerCalls = 0;
  final List<String> removeAccountCalls = [];
  final List<ServerAddressEntry> addAddressCalls = [];
  final List<ServerAddressEntry> updateAddressCalls = [];
  final List<String> removeAddressCalls = [];
  final List<List<String>> reorderAddressCalls = [];
  final List<String> activateAddressCalls = [];

  @override AccountSnapshot get snapshot => _snapshot;
  @override Stream<AccountSnapshot> get changes => _changes.stream;
  @override Stream<ConnectionNoticeEvent> get connectionNotices => _notices.stream;

  void _emit(AccountSnapshot next) {
    _snapshot = next;
    _changes.add(next);
  }

  @override Future<void> restore() async {}
  @override Future<void> signIn(Uri server, String username, String password) async {}
  @override Future<void> switchTo(String profileId, {String? password}) async {}

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _emit(AccountSnapshot(
      phase: AccountPhase.choosing,
      current: null,
      profiles: _snapshot.profiles,
      serverName: _snapshot.serverName,
      serverAddress: _snapshot.serverAddress,
      activeAddress: _snapshot.activeAddress,
      addresses: _snapshot.addresses,
      serverVersion: _snapshot.serverVersion,
      latencyMs: _snapshot.latencyMs,
      connection: _snapshot.connection,
    ));
  }

  @override
  Future<void> removeLocalAccount(String profileId) async {
    removeAccountCalls.add(profileId);
    final isCurrent = _snapshot.current?.id == profileId;
    _emit(AccountSnapshot(
      phase: isCurrent ? AccountPhase.choosing : _snapshot.phase,
      current: isCurrent ? null : _snapshot.current,
      profiles: _snapshot.profiles.where((p) => p.id != profileId).toList(),
      serverName: _snapshot.serverName,
      serverAddress: _snapshot.serverAddress,
      activeAddress: _snapshot.activeAddress,
      addresses: _snapshot.addresses,
      serverVersion: _snapshot.serverVersion,
      latencyMs: _snapshot.latencyMs,
      connection: _snapshot.connection,
      sessionId: isCurrent ? null : _snapshot.sessionId,
    ));
  }

  @override
  Future<void> removeCurrentServer() async {
    removeServerCalls++;
    _emit(const AccountSnapshot(phase: AccountPhase.signedOut));
  }

  @override Future<Uri?> probeAndFailover({Duration timeout = const Duration(seconds: 5)}) async => null;
  @override Future<void> retryConnection() async {}

  @override
  Future<void> setServerAddresses(List<ServerAddressEntry> entries) async {
    _emit(AccountSnapshot(
      phase: _snapshot.phase,
      current: _snapshot.current,
      profiles: _snapshot.profiles,
      serverName: _snapshot.serverName,
      serverAddress: entries.first.url,
      activeAddress: entries.first,
      addresses: List.unmodifiable(entries),
      serverVersion: _snapshot.serverVersion,
      latencyMs: _snapshot.latencyMs,
      connection: _snapshot.connection,
      sessionId: _snapshot.sessionId,
    ));
  }

  @override
  Future<void> addServerAddress(ServerAddressEntry entry) async {
    addAddressCalls.add(entry);
    final next = [..._snapshot.addresses, entry];
    _emit(AccountSnapshot(
      phase: _snapshot.phase,
      current: _snapshot.current,
      profiles: _snapshot.profiles,
      serverName: _snapshot.serverName,
      serverAddress: _snapshot.serverAddress,
      activeAddress: _snapshot.activeAddress,
      addresses: List.unmodifiable(next),
      serverVersion: _snapshot.serverVersion,
      latencyMs: _snapshot.latencyMs,
      connection: _snapshot.connection,
      sessionId: _snapshot.sessionId,
    ));
  }

  @override
  Future<void> updateServerAddress(ServerAddressEntry entry) async {
    updateAddressCalls.add(entry);
    final next = [
      for (final a in _snapshot.addresses) a.id == entry.id ? entry : a,
    ];
    final active = _snapshot.activeAddress?.id == entry.id ? entry : _snapshot.activeAddress;
    _emit(AccountSnapshot(
      phase: _snapshot.phase,
      current: _snapshot.current,
      profiles: _snapshot.profiles,
      serverName: _snapshot.serverName,
      serverAddress: active?.url ?? _snapshot.serverAddress,
      activeAddress: active,
      addresses: List.unmodifiable(next),
      serverVersion: _snapshot.serverVersion,
      latencyMs: _snapshot.latencyMs,
      connection: _snapshot.connection,
      sessionId: _snapshot.sessionId,
    ));
  }

  @override
  Future<void> removeServerAddress(String addressId) async {
    removeAddressCalls.add(addressId);
    final next = _snapshot.addresses.where((a) => a.id != addressId).toList();
    final active = _snapshot.activeAddress?.id == addressId ? next.firstOrNull : _snapshot.activeAddress;
    _emit(AccountSnapshot(
      phase: _snapshot.phase,
      current: _snapshot.current,
      profiles: _snapshot.profiles,
      serverName: _snapshot.serverName,
      serverAddress: active?.url,
      activeAddress: active,
      addresses: List.unmodifiable(next),
      serverVersion: _snapshot.serverVersion,
      latencyMs: _snapshot.latencyMs,
      connection: _snapshot.connection,
      sessionId: _snapshot.sessionId,
    ));
  }

  @override
  Future<void> reorderServerAddresses(List<String> addressIds) async {
    reorderAddressCalls.add(addressIds);
    final map = {for (final a in _snapshot.addresses) a.id: a};
    final ordered = [
      for (final id in addressIds)
        if (map.containsKey(id)) map.remove(id)!,
      ...map.values,
    ];
    _emit(AccountSnapshot(
      phase: _snapshot.phase,
      current: _snapshot.current,
      profiles: _snapshot.profiles,
      serverName: _snapshot.serverName,
      serverAddress: _snapshot.serverAddress,
      activeAddress: _snapshot.activeAddress,
      addresses: List.unmodifiable(ordered),
      serverVersion: _snapshot.serverVersion,
      latencyMs: _snapshot.latencyMs,
      connection: _snapshot.connection,
      sessionId: _snapshot.sessionId,
    ));
  }

  @override
  Future<void> activateServerAddress(String addressId) async {
    activateAddressCalls.add(addressId);
    final target = _snapshot.addresses.where((a) => a.id == addressId).firstOrNull;
    if (target == null) return;
    _emit(AccountSnapshot(
      phase: _snapshot.phase,
      current: _snapshot.current,
      profiles: _snapshot.profiles,
      serverName: _snapshot.serverName,
      serverAddress: target.url,
      activeAddress: target,
      addresses: _snapshot.addresses,
      serverVersion: _snapshot.serverVersion,
      latencyMs: _snapshot.latencyMs,
      connection: _snapshot.connection,
      sessionId: _snapshot.sessionId,
    ));
  }

  Future<void> close() async {
    await _changes.close();
    await _notices.close();
  }
}

Widget _wrapWithScope({
  required EmbyViewServices services,
  required EvStageController stage,
  required Immersion immersion,
  required EvShellController shell,
  required Widget child,
}) {
  return WidgetsApp(
    color: const Color(0xFF09090B),
    pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
      settings: settings,
      pageBuilder: (context, _, _) => builder(context),
    ),
    home: EvThemeScope(
      preferences: services.preferences,
      child: EvScope(
        services: services,
        stage: stage,
        immersion: immersion,
        shell: shell,
        child: Builder(
          builder: (context) => ColoredBox(
            color: EvTheme.of(context).bg,
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final themeMode in [ThemeMode.cinema, ThemeMode.paper]) {
    final themeLabel = themeMode == ThemeMode.cinema ? 'cinema' : 'paper';

    group('W7.3 UI [$themeLabel]', () {
      testWidgets('usermenu displays server header, active address, and logout triggers signOut + callback', (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefs = _FakePrefs(LocalPreferences(theme: themeMode));
        final accounts = _FakeAccounts();
        final services = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: 'sess_sfw');
        final stage = EvStageController();
        final immersion = Immersion(stage: stage, services: services);
        var signedOutCallback = 0;
        var dismissed = 0;
        final shell = EvShellController(
          onSignedOutToUserPicker: () => signedOutCallback++,
        );
        var lookOpened = 0;
        addTearDown(() async {
          shell.dispose();
          immersion.dispose();
          stage.dispose();
          await accounts.close();
          await prefs.close();
        });

        await tester.pumpWidget(
          _wrapWithScope(
            services: services,
            stage: stage,
            immersion: immersion,
            shell: shell,
            child: Center(
              child: EvAvatarMenu(
                accounts: accounts,
                themeMode: themeMode,
                onOpenLook: () => lookOpened++,
                onManageZones: () {},
                onDismiss: () => dismissed++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        expect(find.byKey(const Key('ev_avatar_menu_server_header')), findsOneWidget);
        expect(find.text('家里的 Emby'), findsOneWidget);
        expect(find.text('nas.local:8096 · 已连接'), findsOneWidget);
        expect(find.byKey(const Key('ev_avatar_menu_look')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_avatar_menu_look')),
            matching: find.text('外观'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_avatar_menu_look')),
            matching: find.text(themeMode == ThemeMode.cinema ? '影院' : '纸面'),
          ),
          findsOneWidget,
        );
        final lookIcon = tester.widget<EvIcon>(
          find.descendant(
            of: find.byKey(const Key('ev_avatar_menu_look')),
            matching: find.byType(EvIcon),
          ),
        );
        expect(lookIcon.icon, EvIcons.palette);
        final usersY = tester.getTopLeft(find.byKey(const Key('ev_avatar_menu_users'))).dy;
        final lookY = tester.getTopLeft(find.byKey(const Key('ev_avatar_menu_look'))).dy;
        final zonesY = tester.getTopLeft(find.byKey(const Key('ev_avatar_menu_zones'))).dy;
        expect(usersY, lessThan(lookY));
        expect(lookY, lessThan(zonesY));

        await tester.tap(find.byKey(const Key('ev_avatar_menu_look')));
        await tester.pumpAndSettle();
        expect(lookOpened, 1);
        expect(dismissed, 1);

        // Verify automatic theme mode displays '昼夜自动'
        await tester.pumpWidget(
          _wrapWithScope(
            services: services,
            stage: stage,
            immersion: immersion,
            shell: shell,
            child: Center(
              child: EvAvatarMenu(
                accounts: accounts,
                themeMode: ThemeMode.automatic,
                onOpenLook: () => lookOpened++,
                onManageZones: () {},
                onDismiss: () => dismissed++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_avatar_menu_look')),
            matching: find.text('昼夜自动'),
          ),
          findsOneWidget,
        );

        expect(find.byKey(const Key('ev_avatar_menu_logout')), findsOneWidget);
        expect(find.text('退出登录'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_avatar_menu_logout')));
        await tester.pumpAndSettle();
        expect(dismissed, 2);
        expect(accounts.signOutCalls, 1);
        expect(signedOutCallback, 1);
      });

      testWidgets('profiles:manage renders footer server, manage mode, switch server, and inline confirm removal', (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefs = _FakePrefs(LocalPreferences(theme: themeMode));
        final accounts = _FakeAccounts();
        final services = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: 'sess_sfw');
        final stage = EvStageController();
        final immersion = Immersion(stage: stage, services: services);
        var switchServerCalls = 0;
        var signedOutCalls = 0;
        final shell = EvShellController(
          onSwitchServer: () => switchServerCalls++,
          onSignedOutToUserPicker: () => signedOutCalls++,
        );
        addTearDown(() async {
          shell.dispose();
          immersion.dispose();
          stage.dispose();
          await accounts.close();
          await prefs.close();
        });

        // Normal mode footer shows server, 管理, 换服务器
        await tester.pumpWidget(
          _wrapWithScope(
            services: services,
            stage: stage,
            immersion: immersion,
            shell: shell,
            child: const EvUsersPage(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('ev_users_server_info')), findsOneWidget);
        expect(find.text('家里的 Emby · nas.local:8096'), findsOneWidget);
        expect(find.text('管理'), findsOneWidget);
        expect(find.text('换服务器'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_users_switch_server_btn')));
        await tester.pump();
        expect(switchServerCalls, 1);

        // Initial manage mode (profiles:manage)
        await tester.pumpWidget(
          _wrapWithScope(
            services: services,
            stage: stage,
            immersion: immersion,
            shell: shell,
            child: const EvUsersPage(initialManageMode: true),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('管理这台 Mac 上的账号'), findsOneWidget);
        expect(find.text('完成'), findsOneWidget);
        expect(find.byKey(const Key('ev_users_add_btn')), findsNothing);
        expect(find.text('退出并移出'), findsOneWidget);
        expect(find.text('移出本机'), findsNWidgets(2));

        // Open inline confirm for family, cancel, then confirm
        await tester.tap(find.byKey(const Key('ev_users_remove_btn_family')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_users_remove_confirm_family')), findsOneWidget);
        expect(find.textContaining('只删这台 Mac 上保存的登录'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_users_remove_confirm_cancel_family')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_users_remove_confirm_family')), findsNothing);

        await tester.tap(find.byKey(const Key('ev_users_remove_btn_family')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ev_users_remove_confirm_ok_family')));
        await tester.pumpAndSettle();
        expect(accounts.removeAccountCalls, ['family']);
        expect(find.byKey(const Key('ev_users_profile_family')), findsNothing);

        // Remove current account triggers onSignedOutToUserPicker
        await tester.tap(find.byKey(const Key('ev_users_remove_btn_sfw')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ev_users_remove_confirm_ok_sfw')));
        await tester.pumpAndSettle();
        expect(accounts.removeAccountCalls, ['family', 'sfw']);
        expect(signedOutCalls, 1);
      });

      testWidgets('settings:account renders server card, multi-address CRUD/reorder, auto-switch, accounts, and server actions', (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefs = _FakePrefs(LocalPreferences(theme: themeMode));
        final accounts = _FakeAccounts();
        final services = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: 'sess_sfw');
        final stage = EvStageController();
        final immersion = Immersion(stage: stage, services: services);
        var switchServerCalls = 0;
        var addAccountCalls = 0;
        var signedOutCalls = 0;
        final shell = EvShellController(
          onSwitchServer: () => switchServerCalls++,
          onAddAccount: () => addAccountCalls++,
          onSignedOutToUserPicker: () => signedOutCalls++,
        );
        addTearDown(() async {
          shell.dispose();
          immersion.dispose();
          stage.dispose();
          await accounts.close();
          await prefs.close();
        });

        await tester.pumpWidget(
          _wrapWithScope(
            services: services,
            stage: stage,
            immersion: immersion,
            shell: shell,
            child: const EvSettingsPage(initialSection: EvSettingsSection.account),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Server overview + ordered addresses
        expect(find.text('家里的 Emby'), findsOneWidget);
        expect(find.text('Emby 4.10.2 · 走内网 · 12 ms'), findsOneWidget);
        expect(find.text('已连接'), findsOneWidget);
        expect(find.text('nas.local:8096'), findsOneWidget);
        expect(find.text('正在用'), findsOneWidget);
        expect(find.text('https://nas.tail-example.ts.net'), findsOneWidget);

        // Reorder: move ts up
        await tester.tap(find.byKey(const Key('ev_addr_move_up_ts')));
        await tester.pumpAndSettle();
        expect(accounts.reorderAddressCalls.last, ['ts', 'lan']);

        // Add address with validation error then valid URL
        await tester.tap(find.byKey(const Key('ev_settings_add_addr')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(of: find.byKey(const Key('ev_addr_url_input')), matching: find.byType(EditableText)),
          'bad url :::',
        );
        await tester.tap(find.byKey(const Key('ev_addr_add_save')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_addr_form_error')), findsOneWidget);

        await tester.enterText(
          find.descendant(of: find.byKey(const Key('ev_addr_url_input')), matching: find.byType(EditableText)),
          'https://emby.example.com',
        );
        await tester.enterText(
          find.descendant(of: find.byKey(const Key('ev_addr_label_input')), matching: find.byType(EditableText)),
          '公网',
        );
        await tester.tap(find.byKey(const Key('ev_addr_add_save')));
        await tester.pumpAndSettle();
        expect(accounts.addAddressCalls, hasLength(1));
        expect(accounts.addAddressCalls.single.url, 'https://emby.example.com');
        expect(find.text('https://emby.example.com'), findsOneWidget);

        // Edit existing address
        await tester.tap(find.byKey(const Key('ev_addr_edit_ts')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(of: find.byKey(const Key('ev_addr_sub_input')), matching: find.byType(EditableText)),
          '外网首选',
        );
        await tester.tap(find.byKey(const Key('ev_addr_save')));
        await tester.pumpAndSettle();
        expect(accounts.updateAddressCalls, hasLength(1));
        expect(accounts.updateAddressCalls.single.subtitle, '外网首选');

        // Auto-switch toggle defaults to true and updates preference
        expect(prefs.current.autoSwitchServerAddress, isTrue);
        await tester.ensureVisible(find.byKey(const Key('ev_toggle_auto_switch_addr')));
        await tester.tap(find.byKey(const Key('ev_toggle_auto_switch_addr')));
        await tester.pumpAndSettle();
        expect(prefs.current.autoSwitchServerAddress, isFalse);

        // Saved accounts: inline confirm remove family
        await tester.ensureVisible(find.byKey(const Key('ev_settings_remove_btn_family')));
        await tester.tap(find.byKey(const Key('ev_settings_remove_btn_family')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_settings_remove_confirm_family')), findsOneWidget);
        expect(find.text('只删这台 Mac 上的登录'), findsOneWidget);
        await tester.tap(find.byKey(const Key('ev_settings_remove_ok_family')));
        await tester.pumpAndSettle();
        expect(accounts.removeAccountCalls, ['family']);

        // Add account button
        await tester.ensureVisible(find.byKey(const Key('ev_settings_profiles_manage')));
        await tester.tap(find.byKey(const Key('ev_settings_profiles_manage')));
        await tester.pumpAndSettle();
        expect(addAccountCalls, 1);

        // Choose user on startup toggle
        await tester.ensureVisible(find.byKey(const Key('ev_toggle_choose_user')));
        await tester.tap(find.byKey(const Key('ev_toggle_choose_user')));
        await tester.pumpAndSettle();
        expect(prefs.current.chooseUserOnStartup, isFalse);

        // Current account logout
        await tester.ensureVisible(find.byKey(const Key('ev_settings_logout_sfw')));
        await tester.tap(find.byKey(const Key('ev_settings_logout_sfw')));
        await tester.pumpAndSettle();
        expect(accounts.signOutCalls, 1);
        expect(signedOutCalls, 1);

        // Connect other server + remove server with inline confirm
        await tester.ensureVisible(find.byKey(const Key('ev_settings_connect_other_server')));
        await tester.tap(find.byKey(const Key('ev_settings_connect_other_server')));
        await tester.pumpAndSettle();
        expect(switchServerCalls, 1);

        await tester.ensureVisible(find.byKey(const Key('ev_settings_remove_server_btn')));
        await tester.tap(find.byKey(const Key('ev_settings_remove_server_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_settings_remove_server_confirm')), findsOneWidget);
        await tester.tap(find.byKey(const Key('ev_settings_remove_server_ok')));
        await tester.pumpAndSettle();
        expect(accounts.removeServerCalls, 1);
        expect(switchServerCalls, 2);
      });
    });
  }
}
