import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState, ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/home/ev_home_page.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/ev_player_page.dart';

class _FakePreferences implements EmbyViewPreferences {
  _FakePreferences(this._current);
  LocalPreferences _current;
  final _ctrl = StreamController<LocalPreferences>.broadcast();

  @override
  LocalPreferences get current => _current;

  @override
  Stream<LocalPreferences> get changes => _ctrl.stream;

  @override
  Future<void> update(LocalPreferences next) async {
    _current = next;
    _ctrl.add(next);
  }

  @override
  Future<void> resetZones() async {}

  Future<void> dispose() => _ctrl.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccounts implements EmbyViewAccounts {
  _FakeAccounts(this._snapshot, {this.onProbeAndFailover});
  AccountSnapshot _snapshot;
  final Future<Uri?> Function()? onProbeAndFailover;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final _notices = StreamController<ConnectionNoticeEvent>.broadcast();
  int retryConnectionCalls = 0;
  int probeAndFailoverCalls = 0;

  @override
  AccountSnapshot get snapshot => _snapshot;

  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

  @override
  Stream<ConnectionNoticeEvent> get connectionNotices => _notices.stream;

  void emit(AccountSnapshot next) {
    _snapshot = next;
    _changes.add(next);
  }

  void emitNotice(ConnectionNoticeEvent event) {
    _notices.add(event);
  }

  @override
  Future<Uri?> probeAndFailover({Duration timeout = const Duration(seconds: 5)}) async {
    probeAndFailoverCalls++;
    if (onProbeAndFailover != null) return onProbeAndFailover!();
    return null;
  }

  @override
  Future<void> retryConnection() async {
    retryConnectionCalls++;
  }

  Future<void> dispose() async {
    await _changes.close();
    await _notices.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeData implements EmbyViewData {
  _FakeData({required this.onHome, List<ZoneTile>? zones})
    : _zones = zones ?? const [];

  final Future<HomeData> Function(ShelfSort sort) onHome;
  final List<ZoneTile> _zones;
  int homeCalls = 0;
  int zonesCalls = 0;

  @override
  Future<HomeData> home({required ShelfSort seriesSort}) {
    homeCalls++;
    return onHome(seriesSort);
  }

  @override
  Future<List<ZoneTile>> zones() async {
    zonesCalls++;
    return _zones;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImmersion implements ImmersionPlayback {
  @override
  ImmersionSnapshot get snapshot => const ImmersionSnapshot();
  @override
  Stream<ImmersionSnapshot> get changes => const Stream.empty();
  @override
  Future<void> showMutedVideo(PreviewRef? video) async {}
  @override
  Future<void> playTheme(PreviewRef? song) async {}
  @override
  Future<void> setThemeMuted(bool muted) async {}
  @override
  Future<void> stop() async {}
  @override
  Widget videoSurface({Key? key}) => SizedBox.shrink(key: key);
}

class _FakePlayback implements EmbyViewPlayback {
  @override
  Future<void> prepare(String itemId, {String? mediaSourceId}) async {}
  @override
  PlaybackSession open(PlayTarget target) => throw UnimplementedError();
}

class _RetryTrackingSession implements PlaybackSession {
  _RetryTrackingSession(this._snapshot, {this.onRetryOpen});

  PlaybackSnapshot _snapshot;
  final Future<void> Function(int attempt)? onRetryOpen;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();
  int resolveCalls = 1;
  int retryOpenCalls = 0;
  int closeCalls = 0;

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get changes => _changes.stream;

  void emit(PlaybackSnapshot next) {
    _snapshot = next;
    _changes.add(next);
  }

  @override
  Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF000000));

  @override
  Future<void> retryOpen() async {
    retryOpenCalls++;
    resolveCalls++;
    if (onRetryOpen != null) {
      await onRetryOpen!(retryOpenCalls);
    }
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await _changes.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<ZoneTile> _sampleZones() => const [
  ZoneTile(id: 'anime', name: '番剧', iconKey: 'nav_anime', colorSlot: 0, total: 42, unit: '部'),
  ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 120, unit: '部'),
];

HomeData _sampleHome() => HomeData(
  recommendations: const [
    HomeRecommendation(
      card: MediaCard(id: 'm1', kind: MediaKind.movie, title: '芙莉莲'),
      reason: RecommendationReason.daily,
    ),
  ],
  zones: _sampleZones(),
  recentMovies: const HomeShelf(
    id: 'recent',
    title: '最近添加',
    items: [MediaCard(id: 'm2', kind: MediaKind.movie, title: '沙丘 2')],
  ),
);

AccountSnapshot _sampleAccount({
  String username = '访客',
  String serverName = '家里的 Emby',
  int triedAddressCount = 2,
  int? visibleLibraryCount,
  List<ServerAddressEntry> addresses = const [
    ServerAddressEntry(id: 'a1', url: 'http://nas.local:8096', label: '内网'),
    ServerAddressEntry(id: 'a2', url: 'https://nas.ts.net', label: 'Tailscale'),
  ],
}) => AccountSnapshot(
  phase: AccountPhase.signedIn,
  current: AccountProfile(
    id: 'guest',
    displayName: username,
    visibleLibraryCount: visibleLibraryCount,
  ),
  serverName: serverName,
  triedAddressCount: triedAddressCount,
  addresses: addresses,
  connection: ConnectionState.connected,
  sessionId: 'sess-w75',
);

void main() {
  group('W7.5 home:empty (0 visible libraries)', () {
    for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
      testWidgets('renders empty state card and hides zone tabs in ${mode.name} theme', (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences(LocalPreferences(theme: mode));
        final accounts = _FakeAccounts(_sampleAccount(username: '访客', visibleLibraryCount: 0));
        var returnEmpty = true;
        final data = _FakeData(
          zones: _sampleZones(),
          onHome: (_) async => returnEmpty ? const HomeData() : _sampleHome(),
        );
        final services = EmbyViewServices(
          preferences: prefs,
          accounts: accounts,
          sessionId: 'sess-empty',
          data: data,
          playback: _FakePlayback(),
          immersion: _FakeImmersion(),
        );
        var switchUserCalls = 0;
        var searchCalls = 0;
        final shell = EvShellController(
          zones: _sampleZones(),
          onOpenSearch: () => searchCalls++,
          onOpenUsers: () => switchUserCalls++,
        );
        addTearDown(() async {
          shell.dispose();
          await prefs.dispose();
          await accounts.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: EvShell(
              services: services,
              controller: shell,
              configureWindow: false,
              enableStageMotion: false,
              homeBuilder: (_) => const EvHomePage(enableAnimations: false, enableAutoRetry: false),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_home_empty')), findsOneWidget);
        expect(find.byType(EvBrandBackground), findsOneWidget);
        expect(find.byKey(const Key('ev_home_state_icon_lock')), findsOneWidget);
        expect(find.text('这个账号还看不到片库'), findsOneWidget);
        expect(
          find.text(
            '服务器上的「访客」还没有开放任何片库。请管理员在 Emby 网页后台打开「用户 → 访客 → 媒体库访问」，勾选要开放的片库，再回来点「重新检查」。',
          ),
          findsOneWidget,
        );

        // Top bar hides all zone tabs, leaving only Home and Search (+ avatar).
        expect(shell.hasVisibleLibraries, isFalse);
        expect(find.byKey(const Key('ev_topbar_tab_home')), findsOneWidget);
        expect(find.byKey(const Key('ev_topbar_tab_search')), findsOneWidget);
        expect(find.byKey(const Key('ev_topbar_tab_anime')), findsNothing);
        expect(find.byKey(const Key('ev_topbar_tab_movie')), findsNothing);
        expect(find.byKey(const Key('ev_topbar_avatar')), findsOneWidget);

        // Tapping "切换用户" opens the user picker.
        await tester.tap(find.byKey(const Key('ev_home_empty_switch_user')));
        await tester.pump();
        expect(switchUserCalls, 1);

        // Tapping "重新检查" re-fetches home; once libraries are available, zones return.
        final callsBefore = data.homeCalls;
        returnEmpty = false;
        await tester.tap(find.byKey(const Key('ev_home_empty_recheck')));
        await tester.pumpAndSettle();

        expect(data.homeCalls, greaterThan(callsBefore));
        expect(shell.hasVisibleLibraries, isTrue);
        expect(find.byKey(const Key('ev_home_empty')), findsNothing);
        expect(find.byKey(const Key('ev_home_sections')), findsOneWidget);
        expect(find.byKey(const Key('ev_topbar_tab_anime')), findsOneWidget);
        expect(find.byKey(const Key('ev_topbar_tab_movie')), findsOneWidget);
        expect(searchCalls, 0);
      });
    }
  });

  group('W7.5 home:error (no-cache error card & cached offline capsule)', () {
    for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
      testWidgets('no-cache failure shows error card, retries every 10s, and wires all 3 buttons in ${mode.name} theme', (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences(LocalPreferences(theme: mode));
        final accounts = _FakeAccounts(_sampleAccount(serverName: '家里的 Emby', triedAddressCount: 2));
        var shouldFail = true;
        final data = _FakeData(
          zones: _sampleZones(),
          onHome: (_) async {
            if (shouldFail) throw const EmbyViewFailure('连接超时', retryable: true);
            return _sampleHome();
          },
        );
        final services = EmbyViewServices(
          preferences: prefs,
          accounts: accounts,
          sessionId: 'sess-err',
          data: data,
          playback: _FakePlayback(),
          immersion: _FakeImmersion(),
        );
        var serverSettingsCalls = 0;
        var switchUserCalls = 0;
        final shell = EvShellController(
          zones: _sampleZones(),
          onOpenSearch: () {},
          onOpenServerSettings: () => serverSettingsCalls++,
          onOpenUsers: () => switchUserCalls++,
        );
        addTearDown(() async {
          shell.dispose();
          await prefs.dispose();
          await accounts.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: EvShell(
              services: services,
              controller: shell,
              configureWindow: false,
              enableStageMotion: false,
              homeBuilder: (_) => const EvHomePage(enableAnimations: false, enableAutoRetry: true),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byKey(const Key('ev_home_error')), findsOneWidget);
        expect(find.byType(EvBrandBackground), findsOneWidget);
        expect(find.byKey(const Key('ev_home_state_icon_nowifi')), findsOneWidget);
        expect(find.text('连不上家里的 Emby'), findsOneWidget);
        expect(
          find.text('内网地址和备用地址都没有回应。NAS 可能在睡眠、断网，或者 Emby 服务没在运行。'),
          findsOneWidget,
        );
        expect(find.text('已试 2 个地址 · 每 10 秒自动重试一次'), findsOneWidget);
        expect(find.byKey(const Key('ev_notice_offline')), findsNothing);

        final initialCalls = data.homeCalls;
        expect(initialCalls, 1);

        // 10s periodic auto-retry triggers reload.
        await tester.pump(const Duration(seconds: 10));
        expect(data.homeCalls, 2);

        // Buttons "服务器设置" & "切换账号" wire correctly.
        await tester.tap(find.byKey(const Key('ev_home_error_settings')));
        await tester.tap(find.byKey(const Key('ev_home_error_switch_user')));
        await tester.pump();
        expect(serverSettingsCalls, 1);
        expect(switchUserCalls, 1);

        // Manual "立即重试" recovers and stops the periodic timer cleanly.
        shouldFail = false;
        await tester.tap(find.byKey(const Key('ev_home_retry_btn')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_home_error')), findsNothing);
        expect(find.byKey(const Key('ev_home_sections')), findsOneWidget);
        final callsAfterRecovery = data.homeCalls;
        await tester.pump(const Duration(seconds: 15));
        expect(data.homeCalls, callsAfterRecovery);
      });
    }

    testWidgets('cached home keeps content and shows W7.4 offline notice capsule on refresh failure; switching user clears cache', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = _FakePreferences(const LocalPreferences(theme: ThemeMode.cinema));
      final accounts = _FakeAccounts(_sampleAccount(serverName: '家里的 Emby', triedAddressCount: 2));
      var shouldFail = false;
      final data1 = _FakeData(
        zones: _sampleZones(),
        onHome: (_) async {
          if (shouldFail) throw const EmbyViewFailure('网络不可达', retryable: true);
          return _sampleHome();
        },
      );
      final services1 = EmbyViewServices(
        preferences: prefs,
        accounts: accounts,
        sessionId: 'sess-u1',
        data: data1,
        playback: _FakePlayback(),
        immersion: _FakeImmersion(),
      );
      final shell = EvShellController(zones: _sampleZones(), onOpenSearch: () {});
      addTearDown(() async {
        shell.dispose();
        await prefs.dispose();
        await accounts.dispose();
      });

      Widget buildApp(EmbyViewServices services) => MaterialApp(
        home: EvShell(
          services: services,
          controller: shell,
          configureWindow: false,
          enableStageMotion: false,
          homeBuilder: (_) => const EvHomePage(enableAnimations: false, enableAutoRetry: false),
        ),
      );

      await tester.pumpWidget(buildApp(services1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_home_sections')), findsOneWidget);
      expect(find.byKey(const Key('ev_notice_offline')), findsNothing);

      // Trigger reload while offline -> keeps cached sections and shows W7.4 notice capsule.
      shouldFail = true;
      await prefs.update(const LocalPreferences(theme: ThemeMode.cinema, seriesSort: ShelfSort.score));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byKey(const Key('ev_home_sections')), findsOneWidget);
      expect(find.byKey(const Key('ev_home_error')), findsNothing);
      expect(find.byKey(const Key('ev_notice_offline')), findsOneWidget);
      expect(find.text('连不上家里的 Emby'), findsOneWidget);

      // Tapping "立即重试" on the offline notice reloads home and dismisses the capsule.
      shouldFail = false;
      await tester.tap(find.byKey(const Key('ev_notice_retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_notice_offline')), findsNothing);
      expect(find.byKey(const Key('ev_home_sections')), findsOneWidget);

      // Switching to a new user clears cache so an error shows the full error card.
      final data2 = _FakeData(
        zones: _sampleZones(),
        onHome: (_) async => throw const EmbyViewFailure('离线', retryable: true),
      );
      final services2 = EmbyViewServices(
        preferences: prefs,
        accounts: accounts,
        sessionId: 'sess-u2',
        data: data2,
        playback: _FakePlayback(),
        immersion: _FakeImmersion(),
      );
      await tester.pumpWidget(buildApp(services2));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ev_home_sections')), findsNothing);
      expect(find.byKey(const Key('ev_home_error')), findsOneWidget);
    });

    testWidgets('forcedState supports static screenshot rendering without pending timers', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = _FakePreferences(const LocalPreferences(theme: ThemeMode.paper));
      final accounts = _FakeAccounts(_sampleAccount(serverName: '工作室 Emby', triedAddressCount: 0));
      final services = EmbyViewServices(
        preferences: prefs,
        accounts: accounts,
        sessionId: 'sess-demo',
        data: _FakeData(onHome: (_) async => _sampleHome()),
        playback: _FakePlayback(),
        immersion: _FakeImmersion(),
      );
      final shell = EvShellController(zones: _sampleZones(), onOpenSearch: () {});
      addTearDown(() async {
        shell.dispose();
        await prefs.dispose();
        await accounts.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: EvShell(
            services: services,
            controller: shell,
            configureWindow: false,
            enableStageMotion: false,
            homeBuilder: (_) => const EvHomePage(
              enableAnimations: false,
              enableAutoRetry: false,
              forcedState: EvHomeForcedState.error,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ev_home_error')), findsOneWidget);
      expect(find.text('连不上工作室 Emby'), findsOneWidget);
      expect(find.text('已试 2 个地址 · 每 10 秒自动重试一次'), findsOneWidget);
    });
  });

  group('W7.5 playerr:22749 (115 HTTP 403 playback open failure)', () {
    for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
      testWidgets('renders centered 403 error card with 30s countdown ring, auto-retry, manual retry & back in ${mode.name} theme', (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences(LocalPreferences(theme: mode));
        final item = const MediaCard(
          id: '22749',
          kind: MediaKind.movie,
          title: '葬送的芙莉莲',
          quality: MediaQuality(resolution: '4K', origin: MediaOrigin.direct115),
        );
        late _RetryTrackingSession session;
        session = _RetryTrackingSession(
          PlaybackSnapshot(
            generation: 1,
            target: const PlayTarget(itemId: '22749'),
            item: item,
            phase: PlaybackPhase.failed,
            failure: const EmbyViewFailure.rateLimited115(),
          ),
          onRetryOpen: (attempt) async {
            // Re-emit failed on first auto retry to verify attempt count increments.
            session.emit(
              PlaybackSnapshot(
                generation: 1 + attempt,
                target: const PlayTarget(itemId: '22749'),
                item: item,
                phase: PlaybackPhase.failed,
                failure: const EmbyViewFailure.rateLimited115(),
              ),
            );
          },
        );
        var closed = false;
        addTearDown(() async {
          await session.close();
          await prefs.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: EvThemeScope(
              preferences: prefs,
              child: EvPlayerPage(
                session: session,
                autoTickRetry: true,
                onClose: () => closed = true,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Stays on opening overlay with centered 403 error card and no black screen / OSD.
        final opening = tester.widget<AnimatedOpacity>(find.byKey(const Key('ev_player_opening')));
        expect(opening.opacity, 1.0);
        expect(find.byKey(const Key('ev_player_error_card')), findsOneWidget);
        expect(find.byKey(const Key('ev_player_error_countdown_ring')), findsOneWidget);
        expect(find.text('30'), findsOneWidget);
        expect(find.text('115 暂时限制了播放'), findsOneWidget);
        expect(
          find.text('短时间内请求太多，被片源方临时限流，通常 1 分钟内恢复。倒计时结束会自动再试一次。'),
          findsOneWidget,
        );
        expect(find.text('HTTP 403 · 115 网盘 · 第 1 次自动重试'), findsOneWidget);
        expect(find.text('立即重试'), findsOneWidget);
        expect(find.text('返回详情'), findsOneWidget);

        // Countdown decrements smoothly each second.
        await tester.pump(const Duration(seconds: 5));
        expect(find.text('25'), findsOneWidget);

        // Reaching 0 at 30s triggers retryOpen (fresh address resolution) and bumps retry count.
        await tester.pump(const Duration(seconds: 25));
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.retryOpenCalls, 1);
        expect(session.resolveCalls, 2);
        expect(find.text('HTTP 403 · 115 网盘 · 第 2 次自动重试'), findsOneWidget);
        expect(find.text('30'), findsOneWidget);

        // Manual tap on "立即重试" re-resolves address immediately.
        await tester.tap(find.byKey(const Key('ev_player_opening_retry')));
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.retryOpenCalls, 2);
        expect(session.resolveCalls, 3);
        expect(find.text('HTTP 403 · 115 网盘 · 第 3 次自动重试'), findsOneWidget);

        // Tap "返回详情" closes the player.
        await tester.tap(find.byKey(const Key('ev_player_opening_back')));
        await tester.pump();
        expect(closed, isTrue);
      });
    }

    testWidgets('autoTickRetry: false freezes countdown at 30 for screenshot matrix without pending timers', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = _FakePreferences(const LocalPreferences(theme: ThemeMode.paper));
      final session = _RetryTrackingSession(
        const PlaybackSnapshot(
          generation: 1,
          target: PlayTarget(itemId: '22749'),
          item: MediaCard(id: '22749', kind: MediaKind.movie, title: '葬送的芙莉莲'),
          phase: PlaybackPhase.failed,
          failure: EmbyViewFailure.rateLimited115(),
        ),
      );
      addTearDown(() async {
        await session.close();
        await prefs.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: EvThemeScope(
            preferences: prefs,
            child: EvPlayerPage(
              session: session,
              autoTickRetry: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('30'), findsOneWidget);
      expect(find.text('HTTP 403 · 115 网盘 · 第 1 次自动重试'), findsOneWidget);
      expect(session.retryOpenCalls, 0);
    });

    testWidgets('non-115 HTTP 403 renders generic playback error without 115 copy or 30s countdown', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = _FakePreferences(const LocalPreferences(theme: ThemeMode.cinema));
      final session = _RetryTrackingSession(
        const PlaybackSnapshot(
          generation: 1,
          target: PlayTarget(itemId: 'local403'),
          item: MediaCard(id: 'local403', kind: MediaKind.movie, title: '本地影片'),
          phase: PlaybackPhase.failed,
          failure: EmbyViewFailure(
            '播放无法打开，请重试。',
            retryable: true,
            code: 'engineFailed',
            httpStatus: 403,
            isRateLimited: false,
          ),
        ),
      );
      addTearDown(() async {
        await session.close();
        await prefs.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: EvThemeScope(
            preferences: prefs,
            child: EvPlayerPage(session: session, autoTickRetry: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ev_player_error_countdown_ring')), findsNothing);
      expect(find.text('115 暂时限制了播放'), findsNothing);
      expect(find.text('播放无法打开，请重试。'), findsOneWidget);
      expect(find.text('HTTP 403'), findsOneWidget);

      await tester.pump(const Duration(seconds: 31));
      expect(session.retryOpenCalls, 0);
    });
  });

  group('Home auto-failover & unconditional retryConnection', () {
    testWidgets('primary address failure automatically triggers probeAndFailover, emits switched capsule, and loads home', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = _FakePreferences(const LocalPreferences(autoSwitchServerAddress: true));
      var activeAddress = 'http://nas.local:8096';
      late _FakeAccounts accounts;
      accounts = _FakeAccounts(
        _sampleAccount(),
        onProbeAndFailover: () async {
          activeAddress = 'https://nas.ts.net';
          accounts.emitNotice(
            const ConnectionNoticeEvent.switched(
              serverName: '家里的 Emby',
              fromLabel: '内网',
              toLabel: 'Tailscale',
              activeAddress: 'https://nas.ts.net',
            ),
          );
          return Uri.parse(activeAddress);
        },
      );
      final data = _FakeData(
        zones: _sampleZones(),
        onHome: (_) async {
          if (activeAddress == 'http://nas.local:8096') {
            throw const EmbyViewFailure('无法连接媒体服务器，请重试', retryable: true, code: 'network');
          }
          return _sampleHome();
        },
      );
      final services = EmbyViewServices(
        preferences: prefs,
        accounts: accounts,
        sessionId: 'sess-failover',
        data: data,
        playback: _FakePlayback(),
        immersion: _FakeImmersion(),
      );
      final shell = EvShellController(zones: _sampleZones());
      addTearDown(() async {
        shell.dispose();
        await prefs.dispose();
        await accounts.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: EvShell(
            services: services,
            controller: shell,
            configureWindow: false,
            enableStageMotion: false,
            homeBuilder: (_) => const EvHomePage(enableAnimations: false, enableAutoRetry: false),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(accounts.probeAndFailoverCalls, 1);
      expect(data.homeCalls, 2);
      expect(find.byKey(const Key('ev_home_error')), findsNothing);
      expect(find.byKey(const Key('ev_home_sections')), findsOneWidget);
      expect(find.byKey(const Key('ev_notice_switched')), findsOneWidget);
      expect(find.text('内网连不上，已换到 Tailscale 地址'), findsOneWidget);
    });
  });
}
