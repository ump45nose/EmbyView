import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/entry.dart';
import 'package:moonfin/embyview/prefs/machine_preferences.dart';
import 'package:moonfin/embyview/subtitles/ai/local_subtitle_asr.dart';
import 'package:moonfin/embyview/ui/home/ev_home_page.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(ThemeMode mode, Widget child, {bool disableAnimations = true}) {
  return MediaQuery(
    data: MediaQueryData(
      size: const Size(1440, 900),
      disableAnimations: disableAnimations,
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: EvThemeScope(
        themeMode: mode,
        child: child,
      ),
    ),
  );
}

class _FakePrefs implements EmbyViewPreferences {
  _FakePrefs([LocalPreferences initial = const LocalPreferences()])
    : _current = initial;

  LocalPreferences _current;
  final _changes = StreamController<LocalPreferences>.broadcast();
  final List<String> authorizeCalls = [];

  @override
  LocalPreferences get current => _current;

  @override
  Stream<LocalPreferences> get changes => _changes.stream;

  @override
  Future<void> update(LocalPreferences value) async {
    _current = value;
    _changes.add(value);
  }

  @override
  Future<bool> authorizeMediaFolder({required String embyRoot}) async {
    authorizeCalls.add(embyRoot);
    _current = _current.copyWith(
      mediaFolder: MediaFolderStatus(
        state: MediaFolderState.authorized,
        embyRoot: embyRoot,
        localRoot: '/Volumes/Media',
        writable: true,
      ),
    );
    _changes.add(_current);
    return true;
  }

  @override
  Future<MediaFolderStatus> mediaFolderStatus() async => _current.mediaFolder;

  @override
  Future<Set<SecretKind>> configuredSecrets() async => const {};

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccounts implements EmbyViewAccounts {
  _FakeAccounts({
    AccountPhase phase = AccountPhase.signedIn,
    AccountProfile? current = const AccountProfile(
      id: 'srv-1/sfw',
      displayName: 'sfw',
      serverId: 'srv-1',
    ),
    String? sessionId = 'sess-1',
  }) : _snapshot = AccountSnapshot(
         phase: phase,
         current: current,
         profiles: [
           ?current,
           const AccountProfile(
             id: 'srv-1/guest',
             displayName: '访客',
             serverId: 'srv-1',
             hasPassword: false,
           ),
         ],
         serverName: '家里的 Emby',
         serverAddress: 'http://nas.local:8096',
         connection: ConnectionState.connected,
         sessionId: sessionId,
       );

  AccountSnapshot _snapshot;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final _notices = StreamController<ConnectionNoticeEvent>.broadcast();
  int signOutCalls = 0;

  @override
  AccountSnapshot get snapshot => _snapshot;

  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

  @override
  Stream<ConnectionNoticeEvent> get connectionNotices => _notices.stream;

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _snapshot = AccountSnapshot(
      phase: AccountPhase.choosing,
      current: null,
      profiles: _snapshot.profiles,
      serverName: _snapshot.serverName,
      serverAddress: _snapshot.serverAddress,
      connection: _snapshot.connection,
    );
    _changes.add(_snapshot);
  }

  Future<void> close() async {
    await _changes.close();
    await _notices.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeData implements EmbyViewData {
  @override
  Future<List<ZoneTile>> zones() async => const [
    ZoneTile(
      id: 'movie',
      name: '电影',
      iconKey: 'nav_movie',
      colorSlot: 0,
      total: 10,
      unit: '部',
    ),
  ];

  @override
  Future<HomeData> home({required ShelfSort seriesSort}) async =>
      const HomeData(recommendations: [], zones: []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayback implements EmbyViewPlayback {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImmersion implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast();

  @override
  ImmersionSnapshot get snapshot => const ImmersionSnapshot();

  @override
  Stream<ImmersionSnapshot> get changes => _changes.stream;

  @override
  Widget videoSurface({Key? key}) => SizedBox.shrink(key: key);

  @override
  Future<void> stop() async {}

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ScriptedLoginBackend implements EvLoginBackend {
  int connectCalls = 0;
  int trustCalls = 0;
  int signInUserCalls = 0;
  int signInManualCalls = 0;
  String? lastAddress;
  String? lastUsername;
  String? lastPassword;
  bool? lastRemember;
  bool trusted = false;
  bool failNextConnect = false;

  @override
  Stream<List<EvDiscoveredServer>> discoverServers() =>
      Stream<List<EvDiscoveredServer>>.value(EvLoginDemoData.discoveredServers);

  @override
  Future<EvConnectedServer?> loadSavedServer({String? serverId}) async =>
      EvLoginDemoData.server;

  @override
  Future<List<EvLoginUser>> loadUsers(EvConnectedServer server) async =>
      EvLoginDemoData.users;

  @override
  Future<EvServerConnectResult> connectServer(String rawAddress) async {
    connectCalls++;
    lastAddress = rawAddress;
    if (failNextConnect || rawAddress.contains('192.168.1.20:8096')) {
      return EvServerConnectFailure(
        EvConnectFailure(
          address: formatServerAddressForDisplay(rawAddress),
          reason: EvLoginDemoData.connectFailure.reason,
        ),
      );
    }
    if (rawAddress.startsWith('https://') && !trusted) {
      return EvServerConnectUntrustedCert(
        EvCertChallenge(
          address: rawAddress,
          host: '192.168.1.20',
          fingerprint: EvLoginDemoData.certChallenge.fingerprint,
        ),
      );
    }
    return const EvServerConnectSuccess(
      server: EvLoginDemoData.server,
      users: EvLoginDemoData.users,
    );
  }

  @override
  Future<EvServerConnectResult> trustCertificateAndConnect(
    EvCertChallenge challenge,
  ) async {
    trustCalls++;
    trusted = true;
    return const EvServerConnectSuccess(
      server: EvLoginDemoData.server,
      users: EvLoginDemoData.users,
    );
  }

  @override
  Future<void> signInWithUser({
    required EvConnectedServer server,
    required EvLoginUser user,
    String? password,
    bool rememberPassword = true,
  }) async {
    signInUserCalls++;
    lastUsername = user.name;
    lastPassword = password;
    lastRemember = rememberPassword;
  }

  @override
  Future<void> signInManually({
    required EvConnectedServer server,
    required String username,
    required String password,
    bool rememberPassword = true,
  }) async {
    signInManualCalls++;
    lastUsername = username;
    lastPassword = password;
    lastRemember = rememberPassword;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 7.2 EvLoginPage 5-step flow & dual theme', () {
    testWidgets('renders all 5 login steps cleanly in cinema and paper themes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
        for (final step in EvLoginStep.values) {
          await tester.pumpWidget(
            _wrap(
              mode,
              EvLoginPage(
                initialStep: step,
                initialDiscoveredServers: EvLoginDemoData.discoveredServers,
                initialServer: EvLoginDemoData.server,
                initialUsers: EvLoginDemoData.users,
                initialSelectedUser: step == EvLoginStep.pass
                    ? EvLoginDemoData.users.first
                    : null,
                initialPassword: step == EvLoginStep.pass ? 'emby-demo' : null,
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('ev_login_brand')), findsOneWidget);
          expect(find.text('EmbyView'), findsOneWidget);

          switch (step) {
            case EvLoginStep.server:
              expect(find.text('连接到你的 Emby'), findsOneWidget);
              expect(find.text('在局域网里找到 2 台'), findsOneWidget);
              expect(find.text('家里的 Emby'), findsOneWidget);
              expect(find.text('12 ms'), findsOneWidget);
              expect(find.byKey(const Key('ev_login_addr_hint')), findsOneWidget);
            case EvLoginStep.cert:
              expect(find.byKey(const Key('ev_login_cert_box')), findsOneWidget);
              expect(find.text('这台服务器用的是自签名证书'), findsOneWidget);
              expect(find.textContaining('SHA-256'), findsOneWidget);
              expect(find.text('信任并继续'), findsOneWidget);
            case EvLoginStep.fail:
              expect(find.byKey(const Key('ev_login_fail_box')), findsOneWidget);
              expect(find.text('连不上 192.168.1.20:8096'), findsOneWidget);
              expect(
                find.descendant(
                  of: find.byKey(const Key('ev_login_fail_box')),
                  matching: find.textContaining('8096'),
                ),
                findsWidgets,
              );
              expect(find.text('重试'), findsOneWidget);
            case EvLoginStep.users:
              expect(find.text('谁在看？'), findsOneWidget);
              expect(find.text('不用密码'), findsOneWidget);
              expect(find.text('换服务器'), findsOneWidget);
              expect(find.text('其他用户'), findsOneWidget);
            case EvLoginStep.pass:
              expect(find.byKey(const Key('ev_login_password_bar')), findsOneWidget);
              expect(
                find.text('记住密码（存在这台 Mac 的钥匙串里）'),
                findsOneWidget,
              );
          }
        }
      }
    });

    testWidgets(
      'transitions server -> fail -> retry -> cert -> cancel -> trust -> users -> passwordless & pass submit',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final backend = _ScriptedLoginBackend();
        var signedInCount = 0;
        final steps = <EvLoginStep>[];

        await tester.pumpWidget(
          _wrap(
            ThemeMode.cinema,
            EvLoginPage(
              backend: backend,
              onStepChanged: steps.add,
              onSignedIn: () => signedInCount++,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('在局域网里找到 2 台'), findsOneWidget);

        // 1) Unreachable address -> fail step + retry
        await tester.enterText(
          find.byType(EditableText).first,
          '192.168.1.20:8096',
        );
        await tester.tap(find.byKey(const Key('ev_login_connect_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_login_fail_box')), findsOneWidget);
        expect(backend.connectCalls, 1);

        await tester.tap(find.byKey(const Key('ev_login_retry_btn')));
        await tester.pumpAndSettle();
        expect(backend.connectCalls, 2);

        // 2) Self-signed HTTPS -> cert step -> cancel -> back to server
        await tester.enterText(
          find.byType(EditableText).first,
          'https://192.168.1.20:8920',
        );
        await tester.tap(find.byKey(const Key('ev_login_connect_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_login_cert_box')), findsOneWidget);
        expect(find.textContaining('4F:2A:9C:07'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_login_cert_cancel_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_login_cert_box')), findsNothing);
        expect(find.byKey(const Key('ev_login_addr_hint')), findsOneWidget);

        // 3) Reconnect HTTPS -> trust & continue -> users step
        await tester.tap(find.byKey(const Key('ev_login_connect_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_login_cert_box')), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_login_cert_trust_btn')));
        await tester.pumpAndSettle();
        expect(backend.trustCalls, 1);
        expect(find.byKey(const Key('ev_login_users_title')), findsOneWidget);

        // 4) Passwordless user signs in directly without entering pass step
        await tester.tap(find.byKey(const Key('ev_login_user_guest')));
        await tester.pumpAndSettle();
        expect(backend.signInUserCalls, 1);
        expect(backend.lastUsername, '访客');
        expect(backend.lastPassword, isNull);
        expect(signedInCount, 1);

        // 5) Passworded user opens pass step, remembers password by default, can toggle & submit
        await tester.tap(find.byKey(const Key('ev_login_user_sfw')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_login_password_bar')), findsOneWidget);

        // Toggle remember checkbox off
        await tester.tap(find.byKey(const Key('ev_login_remember_checkbox')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('ev_login_password_input')),
          's3cr3t',
        );
        await tester.tap(find.byKey(const Key('ev_login_submit_btn')));
        await tester.pumpAndSettle();
        expect(backend.signInUserCalls, 2);
        expect(backend.lastUsername, 'sfw');
        expect(backend.lastPassword, 's3cr3t');
        expect(backend.lastRemember, isFalse);
        expect(signedInCount, 2);

        // 6) Other user manual login
        await tester.tap(find.byKey(const Key('ev_login_other_user_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_login_manual_form')), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const Key('ev_login_manual_username_input')),
            matching: find.byType(EditableText),
          ),
          'admin',
        );
        await tester.enterText(
          find.descendant(
            of: find.byKey(const Key('ev_login_password_input')),
            matching: find.byType(EditableText),
          ),
          'pw123',
        );
        await tester.tap(find.byKey(const Key('ev_login_submit_btn')));
        await tester.pumpAndSettle();
        expect(backend.signInManualCalls, 1);
        expect(backend.lastUsername, 'admin');
        expect(backend.lastPassword, 'pw123');
        expect(signedInCount, 3);

        // 7) Switch server returns to server step
        await tester.tap(find.byKey(const Key('ev_login_switch_server_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_login_server_card')), findsOneWidget);
        expect(steps.last, EvLoginStep.server);
      },
    );

    testWidgets(
      'login:pass collapses prefilled password selection to end on initial focus without blocking later select-all',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const prefilled = 'emby-demo';
        await tester.pumpWidget(
          _wrap(
            ThemeMode.cinema,
            EvLoginPage(
              initialStep: EvLoginStep.pass,
              initialServer: EvLoginDemoData.server,
              initialUsers: EvLoginDemoData.users,
              initialSelectedUser: EvLoginDemoData.users.first,
              initialPassword: prefilled,
            ),
          ),
        );
        // Pump post-frame focus request + focus listener microtask + collapse post-frame callback.
        await tester.pump();
        await tester.pump();

        final editable = tester.widget<EditableText>(
          find.byKey(const Key('ev_login_password_input')),
        );
        expect(editable.focusNode.hasFocus, isTrue);
        expect(
          editable.controller.selection,
          const TextSelection.collapsed(offset: prefilled.length),
        );

        // Subsequent manual select-all is not interfered with.
        editable.controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: prefilled.length,
        );
        await tester.pump();
        expect(
          editable.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: prefilled.length),
        );

        // Re-focusing later (after blur) does not override manual selection behavior.
        editable.focusNode.unfocus();
        await tester.pump();
        editable.focusNode.requestFocus();
        await tester.pump();
        editable.controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: prefilled.length,
        );
        await tester.pump();
        expect(
          editable.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: prefilled.length),
        );
      },
    );
  });

  group('Stage 7.2 EvOnboardingCard & MachinePreferences persistence', () {
    testWidgets('renders onboard and onboard:busy states in both themes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
        await tester.pumpWidget(
          _wrap(
            mode,
            const EvOnboardingCard(
              demoOverride: EvOnboardingSnapshot.demoInitial(userName: 'sfw'),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('欢迎，sfw'), findsOneWidget);
        expect(find.text('字幕存到 NAS'), findsOneWidget);
        expect(find.text('选择文件夹…'), findsOneWidget);
        expect(find.text('本机听写模型'), findsOneWidget);
        expect(find.text('后台下载'), findsOneWidget);
        expect(find.text('翻译通道'), findsOneWidget);
        expect(find.text('选填'), findsOneWidget);
        expect(find.text('填写…'), findsOneWidget);
        expect(find.text('以后再说'), findsOneWidget);
        expect(find.text('开始看片'), findsOneWidget);

        await tester.pumpWidget(
          _wrap(
            mode,
            const EvOnboardingCard(
              demoOverride: EvOnboardingSnapshot.demoBusy(userName: 'sfw'),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('/Volumes/Media'), findsOneWidget);
        expect(find.text('218 / 574 MB'), findsOneWidget);
      }
    });

    testWidgets(
      'triggers folder authorization, ASR download progress, AI settings jump, and persists onboardingDismissed',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const asrChannel = MethodChannel('embyview/asr_test_onboard');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var modelState = 'notDownloaded';
        var receivedBytes = 0;
        const totalBytes = 574 * 1024 * 1024;
        var downloadCalls = 0;

        messenger.setMockMethodCallHandler(asrChannel, (call) async {
          if (call.method == 'downloadModel') {
            downloadCalls++;
            modelState = 'downloading';
            receivedBytes = 218 * 1024 * 1024;
            return null;
          }
          if (call.method == 'modelStatus') {
            return {
              'state': modelState,
              'receivedBytes': receivedBytes,
              'totalBytes': totalBytes,
            };
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(asrChannel, null));

        final prefs = _FakePrefs();
        addTearDown(prefs.close);
        var dismissed = 0;
        var openedAi = 0;

        await tester.pumpWidget(
          _wrap(
            ThemeMode.paper,
            EvOnboardingCard(
              preferences: prefs,
              profile: const AccountProfile(id: 'sfw', displayName: 'sfw'),
              asr: const LocalSubtitleAsr(channel: asrChannel),
              onDismissed: () => dismissed++,
              onOpenAiSettings: () => openedAi++,
            ),
          ),
        );
        await tester.pump();

        // Authorize NAS folder
        await tester.tap(find.byKey(const Key('ev_onboard_folder_btn')));
        await tester.pump();
        expect(prefs.authorizeCalls, ['/mnt/media']);
        expect(find.text('/Volumes/Media'), findsOneWidget);

        // Start ASR model background download and verify progress update -> ready
        await tester.tap(find.byKey(const Key('ev_onboard_model_btn')));
        await tester.pump();
        expect(downloadCalls, 1);
        expect(find.text('218 / 574 MB'), findsOneWidget);

        modelState = 'ready';
        receivedBytes = totalBytes;
        await tester.pump(const Duration(milliseconds: 550));
        expect(find.text('已就绪'), findsOneWidget);

        // Clicking 填写… closes, persists onboardingDismissed = true, and opens AI settings
        await tester.tap(find.byKey(const Key('ev_onboard_gate_btn')));
        await tester.pump();
        expect(prefs.current.onboardingDismissed, isTrue);
        expect(dismissed, 1);
        expect(openedAi, 1);
      },
    );

    testWidgets(
      'MachinePreferences persists onboardingDismissed across reopen and shell stops auto-showing',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        SharedPreferences.setMockInitialValues({});
        final folderChannel = const MethodChannel('embyview/media_folder_test');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          folderChannel,
          (_) async => {'authorized': false, 'state': 'unconfigured'},
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(folderChannel, null),
        );

        final prefs1 = await MachinePreferences.open(folder: folderChannel);
        expect(prefs1.current.onboardingDismissed, isFalse);

        final accounts = _FakeAccounts();
        final data = _FakeData();
        final playback = _FakePlayback();
        final immersion = _FakeImmersion();
        MachinePreferences? prefs2;

        try {
          final services1 = EmbyViewServices(
            preferences: prefs1,
            accounts: accounts,
            sessionId: 's1',
            data: data,
            playback: playback,
            immersion: immersion,
          );

          await tester.pumpWidget(
            _wrap(
              ThemeMode.cinema,
              buildStageFourTestShell(
                services: services1,
                showOnboardingOverlay: true,
              ),
            ),
          );
          await tester.pump();
          expect(find.byType(EvOnboardingCard), findsOneWidget);

          // Click 以后再说 -> closes card & persists onboardingDismissed = true
          await tester.tap(find.byKey(const Key('ev_onboard_later_btn')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(find.byType(EvOnboardingCard), findsNothing);
          expect(prefs1.current.onboardingDismissed, isTrue);

          // Verify persisted JSON & reopening MachinePreferences keeps onboardingDismissed = true
          final sp = await SharedPreferences.getInstance();
          final decoded =
              jsonDecode(sp.getString('embyview.machine.v1')!)
                  as Map<String, dynamic>;
          expect(decoded['onboardingDismissed'], isTrue);

          prefs2 = await MachinePreferences.open(folder: folderChannel);
          expect(prefs2.current.onboardingDismissed, isTrue);

          final services2 = EmbyViewServices(
            preferences: prefs2,
            accounts: accounts,
            sessionId: 's2',
            data: data,
            playback: playback,
            immersion: immersion,
          );
          await tester.pumpWidget(
            _wrap(
              ThemeMode.cinema,
              buildStageFourTestShell(
                services: services2,
                showOnboardingOverlay: true,
              ),
            ),
          );
          await tester.pump();
          expect(find.byType(EvOnboardingCard), findsNothing);
          expect(find.byType(EvHomePage), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await prefs1.close();
          await prefs2?.close();
          await accounts.close();
          await immersion.close();
        }
      },
    );
  });

  group('Stage 7.2 routing: /setup bypass, chooseUserOnStartup, sign-out & switch-server', () {
    test('short-circuits /setup for macOS Emby while keeping upstream platforms/servers intact', () {
      expect(
        shouldSkipSetupWizardForEmbyView(isMacOS: true, isEmby: true),
        isTrue,
      );
      expect(
        shouldSkipSetupWizardForEmbyView(isMacOS: false, isEmby: true),
        isFalse,
      );
      expect(
        shouldSkipSetupWizardForEmbyView(isMacOS: true, isEmby: false),
        isFalse,
      );

      expect(
        embyViewRouteRedirect(
          path: '/setup',
          isMacOS: true,
          isEmby: true,
          authenticated: true,
          legacyHome: '/home',
          signedOut: '/',
          setupPath: '/setup',
        ),
        embyViewHomePath,
      );
      expect(
        embyViewRouteRedirect(
          path: '/setup',
          isMacOS: true,
          isEmby: false,
          authenticated: true,
          legacyHome: '/home',
          signedOut: '/',
          setupPath: '/setup',
        ),
        isNull,
      );
      expect(
        embyViewRouteRedirect(
          path: '/setup',
          isMacOS: false,
          isEmby: true,
          authenticated: true,
          legacyHome: '/home',
          signedOut: '/',
          setupPath: '/setup',
        ),
        isNull,
      );
    });

    test('cold-start route honors MachinePreferences.chooseUserOnStartup', () async {
      expect(
        resolveEmbyViewColdStartRoute(chooseUserOnStartup: true),
        '$embyViewHomePath/users',
      );
      expect(
        resolveEmbyViewColdStartRoute(chooseUserOnStartup: false),
        embyViewHomePath,
      );

      SharedPreferences.setMockInitialValues({
        'embyview.machine.v1': '{"chooseUser":true}',
      });
      final folderChannel = const MethodChannel('embyview/media_folder_cold');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        folderChannel,
        (_) async => {'authorized': false, 'state': 'unconfigured'},
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(folderChannel, null),
      );

      final prefsTrue = await MachinePreferences.open(folder: folderChannel);
      expect(
        resolveEmbyViewColdStartRoute(
          chooseUserOnStartup: prefsTrue.current.chooseUserOnStartup,
        ),
        '$embyViewHomePath/users',
      );
      await prefsTrue.update(
        prefsTrue.current.copyWith(chooseUserOnStartup: false),
      );
      expect(
        resolveEmbyViewColdStartRoute(
          chooseUserOnStartup: prefsTrue.current.chooseUserOnStartup,
        ),
        embyViewHomePath,
      );
      await prefsTrue.close();
    });

    testWidgets(
      'shell sign-out routes to login:users (preserving server) and switch-server routes to login:server',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePrefs(
          const LocalPreferences(onboardingDismissed: true),
        );
        final accounts = _FakeAccounts();
        final immersion = _FakeImmersion();
        final services = EmbyViewServices(
          preferences: prefs,
          accounts: accounts,
          sessionId: 'sess-1',
          data: _FakeData(),
          playback: _FakePlayback(),
          immersion: immersion,
        );
        addTearDown(() async {
          await prefs.close();
          await accounts.close();
          await immersion.close();
        });

        String? landedLoginStep;
        String? landedServerId;

        final router = GoRouter(
          initialLocation: embyViewHomePath,
          routes: [
            GoRoute(
              path: embyViewHomePath,
              builder: (_, _) => buildStageFourTestShell(services: services),
            ),
            GoRoute(
              path: embyViewLoginPath,
              builder: (_, state) {
                landedLoginStep =
                    state.uri.queryParameters['step'] ?? EvLoginStep.server.name;
                landedServerId = state.uri.queryParameters['serverId'];
                final step = EvLoginStep.values
                        .where((v) => v.name == landedLoginStep)
                        .firstOrNull ??
                    EvLoginStep.server;
                return EvThemeScope(
                  themeMode: ThemeMode.cinema,
                  child: EvLoginPage(
                    initialStep: step,
                    initialServer: EvLoginDemoData.server,
                    initialUsers: EvLoginDemoData.users,
                  ),
                );
              },
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(1440, 900),
              disableAnimations: true,
            ),
            child: WidgetsApp.router(
              color: const Color(0xFF09090B),
              routerConfig: router,
            ),
          ),
        );
        await tester.pump();

        try {
          // Trigger sign-out callback from EvShellController -> lands on login:users with serverId kept
          final scope = EvScope.of(tester.element(find.byType(EvHomePage)));
          scope.shell.onSignedOutToUserPicker?.call();
          await tester.pumpAndSettle();
          expect(landedLoginStep, 'users');
          expect(landedServerId, 'srv-1');
          expect(find.byKey(const Key('ev_login_users_title')), findsOneWidget);

          // Navigate back to home and trigger switch-server -> lands on login:server
          router.go(embyViewHomePath);
          await tester.pumpAndSettle();
          final scope2 = EvScope.of(tester.element(find.byType(EvHomePage)));
          scope2.shell.onSwitchServer?.call();
          await tester.pumpAndSettle();
          expect(landedLoginStep, 'server');
          expect(landedServerId, isNull);
          expect(find.byKey(const Key('ev_login_server_card')), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );

    testWidgets('pass step prefilled with initialPassword collapses selection to end without selecting all text', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(
          ThemeMode.cinema,
          EvLoginPage(
            initialStep: EvLoginStep.pass,
            initialServer: EvLoginDemoData.server,
            initialUsers: EvLoginDemoData.users,
            initialSelectedUser: EvLoginDemoData.users.first,
            initialPassword: 'demo-password',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editable = tester.widget<EditableText>(
        find.byKey(const Key('ev_login_password_input')),
      );
      expect(editable.controller.text, 'demo-password');
      expect(editable.controller.selection.isCollapsed, isTrue);
      expect(editable.controller.selection.baseOffset, 'demo-password'.length);
    });

    testWidgets('cold start /embyview/users switches to another user and navigates to /embyview, and preserves password form on auth failure', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const alice = AccountProfile(id: 'srv/alice', displayName: 'Alice', serverId: 'srv');
      const bob = AccountProfile(id: 'srv/bob', displayName: 'Bob', serverId: 'srv');
      final prefs = _FakePrefs(const LocalPreferences(onboardingDismissed: true));
      var failBobWithoutPassword = true;
      var seq = 1;
      Completer<void>? switchGate;
      late _SwitchableAccounts accounts;
      accounts = _SwitchableAccounts(
        const AccountSnapshot(
          phase: AccountPhase.signedIn,
          current: alice,
          profiles: [alice, bob],
          serverName: '家里的 Emby',
          serverAddress: 'http://nas.local:8096',
          sessionId: 'sess-alice-1',
        ),
        onSwitchTo: (profileId, {password}) async {
          accounts.emit(
            const AccountSnapshot(
              phase: AccountPhase.switching,
              profiles: [alice, bob],
              serverName: '家里的 Emby',
              serverAddress: 'http://nas.local:8096',
            ),
          );
          if (switchGate != null) {
            await switchGate.future;
          }
          if (profileId == bob.id && failBobWithoutPassword && password != 'ok-pass') {
            const failure = EmbyViewFailure(
              '登录失败，请检查用户名、密码和服务器权限。',
              code: 'sign_in_failed',
            );
            accounts.emit(
              AccountSnapshot(
                phase: AccountPhase.signedIn,
                current: alice,
                profiles: const [alice, bob],
                serverName: '家里的 Emby',
                serverAddress: 'http://nas.local:8096',
                sessionId: 'sess-alice-${++seq}',
                failure: failure,
              ),
            );
            throw failure;
          }
          final target = profileId == bob.id ? bob : alice;
          accounts.emit(
            AccountSnapshot(
              phase: AccountPhase.signedIn,
              current: target,
              profiles: const [alice, bob],
              serverName: '家里的 Emby',
              serverAddress: 'http://nas.local:8096',
              sessionId: 'sess-${target.id}-${++seq}',
            ),
          );
        },
      );

      final entry = EmbyViewEntry(
        preferences: prefs,
        accounts: accounts,
        createSession: (account) => EmbyViewSessionServices(
          data: _FakeData(),
          playback: _FakePlayback(),
          immersion: _FakeImmersion(),
          dispose: () async {},
        ),
      );
      await entry.ready;
      installEmbyViewEntry(entry);

      final router = GoRouter(
        initialLocation: '$embyViewHomePath/users',
        routes: buildEmbyViewRoutes(
          legacyHome: (_) => const SizedBox.shrink(),
        ),
      );

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900), disableAnimations: true),
          child: WidgetsApp.router(
            color: const Color(0xFF09090B),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      try {
        expect(find.byKey(const Key('ev_users_page')), findsOneWidget);

        // 1. Wrong/missing password keeps EvUsersPage mounted during switching,
        //    stays on /embyview/users, and shows password form + error.
        switchGate = Completer<void>();
        await tester.tap(find.byKey(const Key('ev_users_profile_srv/bob')));
        await tester.pump();
        expect(accounts.snapshot.phase, AccountPhase.switching);
        expect(find.byKey(const Key('ev_users_page')), findsOneWidget);

        switchGate.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(router.routerDelegate.currentConfiguration.uri.path, '$embyViewHomePath/users');
        expect(find.byKey(const Key('ev_users_password_form')), findsOneWidget);
        expect(find.byKey(const Key('ev_users_error')), findsOneWidget);

        // 2. Submitting valid password stays mounted during switching and navigates to /embyview home.
        failBobWithoutPassword = false;
        switchGate = Completer<void>();
        await tester.enterText(find.byKey(const Key('ev_users_password_field')), 'ok-pass');
        await tester.tap(find.byKey(const Key('ev_users_form_submit_btn')));
        await tester.pump();
        expect(accounts.snapshot.phase, AccountPhase.switching);
        expect(find.byKey(const Key('ev_users_page')), findsOneWidget);

        switchGate.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(router.routerDelegate.currentConfiguration.uri.path, embyViewHomePath);
        expect(find.byType(EvHomePage), findsOneWidget);
        expect(accounts.snapshot.current?.id, bob.id);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        router.dispose();
        installEmbyViewEntry(null);
        var closed = false;
        unawaited(entry.close().whenComplete(() => closed = true));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(closed, isTrue);
        entry.dispose();
        await tester.runAsync(() async {
          await accounts.close();
          await prefs.close();
        });
      }
    });
  });
}

class _SwitchableAccounts implements EmbyViewAccounts {
  _SwitchableAccounts(this._snapshot, {required this.onSwitchTo});

  AccountSnapshot _snapshot;
  final Future<void> Function(String profileId, {String? password}) onSwitchTo;
  final _changes = StreamController<AccountSnapshot>.broadcast(sync: true);
  final _notices = StreamController<ConnectionNoticeEvent>.broadcast();

  void emit(AccountSnapshot next) {
    _snapshot = next;
    _changes.add(next);
  }

  @override
  AccountSnapshot get snapshot => _snapshot;

  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

  @override
  Stream<ConnectionNoticeEvent> get connectionNotices => _notices.stream;

  @override
  Future<void> switchTo(String profileId, {String? password}) =>
      onSwitchTo(profileId, password: password);

  @override
  Future<Uri?> probeAndFailover({Duration timeout = const Duration(seconds: 5)}) async => null;

  @override
  Future<void> retryConnection() async {}

  Future<void> close() async {
    await _changes.close();
    await _notices.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
