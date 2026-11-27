import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide ConnectionState, Page, ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/entry.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/ev_player_page.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_sections.dart';
import 'package:server_core/server_core.dart';

const List<ZoneTile> _kZones = [
  ZoneTile(id: 'anime', name: '番剧', iconKey: 'nav_anime', colorSlot: 0, total: 12, unit: '部'),
  ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 24, unit: '部'),
  ZoneTile(id: 'tv', name: '剧集', iconKey: 'nav_tv', colorSlot: 2, total: 18, unit: '部'),
  ZoneTile(id: 'doc', name: '纪录片', iconKey: 'nav_doc', colorSlot: 3, total: 8, unit: '部'),
  ZoneTile(id: 'box', name: '合集', iconKey: 'nav_box', colorSlot: 4, total: 5, unit: '套'),
];

class _FakePreferences implements EmbyViewPreferences {
  _FakePreferences([LocalPreferences? initial])
    : _current = initial ?? const LocalPreferences(onboardingDismissed: true);

  LocalPreferences _current;
  final _changes = StreamController<LocalPreferences>.broadcast();

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
  Future<Set<SecretKind>> configuredSecrets() async => const {};

  Future<void> close() async {
    if (!_changes.isClosed) unawaited(_changes.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccounts implements EmbyViewAccounts {
  _FakeAccounts({AccountSnapshot? initial})
    : _snapshot = initial ??
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: AccountProfile(id: 'sfw', displayName: 'sfw'),
            profiles: [AccountProfile(id: 'sfw', displayName: 'sfw')],
            serverName: '家里的 Emby',
            serverAddress: 'http://nas.local:8096',
            connection: ConnectionState.connected,
            sessionId: 'sess-w74',
          );

  final AccountSnapshot _snapshot;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final _notices = StreamController<ConnectionNoticeEvent>.broadcast();
  int signOutCalls = 0;
  int retryConnectionCalls = 0;

  @override
  AccountSnapshot get snapshot => _snapshot;

  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

  @override
  Stream<ConnectionNoticeEvent> get connectionNotices => _notices.stream;

  void emitNotice(ConnectionNoticeEvent event) => _notices.add(event);

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }

  @override
  Future<void> retryConnection() async {
    retryConnectionCalls++;
  }

  @override
  Future<Uri?> probeAndFailover({Duration timeout = const Duration(seconds: 5)}) async => null;

  Future<void> close() async {
    if (!_changes.isClosed) unawaited(_changes.close());
    if (!_notices.isClosed) unawaited(_notices.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeData implements EmbyViewData {
  bool failHome = false;
  int homeCalls = 0;

  @override
  Future<HomeData> home({required ShelfSort seriesSort}) async {
    homeCalls++;
    if (failHome) {
      throw const EmbyViewFailure('无法连接媒体服务器，请重试', retryable: true, code: 'network');
    }
    return const HomeData(zones: _kZones);
  }

  @override
  Future<List<ZoneTile>> zones() async => _kZones;

  @override
  Future<ZoneData> zone(String zoneId) async {
    final tile = _kZones.firstWhere(
      (z) => z.id == zoneId,
      orElse: () => _kZones.first,
    );
    return ZoneData(
      zone: tile,
      all: (
        scope: WallScope.zone(tile.id),
        sort: WallSort.title,
        watched: WatchFilter.all,
        genreId: null,
        years: null,
        technology: null,
      ),
    );
  }

  @override
  Future<Page<ResumeCard>> continueWatching({
    String? zoneId,
    int offset = 0,
    int limit = 20,
  }) async => const Page<ResumeCard>(items: [], total: 0);

  @override
  Future<ZoneFacets> customZoneFacets() async => const ZoneFacets();

  @override
  Future<SearchLanding> searchLanding({String? zoneId}) async =>
      const SearchLanding();

  @override
  Future<SearchResults> search(
    String text, {
    String? zoneId,
    int offset = 0,
    int limit = 20,
  }) async => const SearchResults();

  @override
  Future<WallListing> openWall(WallQuery query) async => _FakeWallListing();

  @override
  Future<WallFacets> wallFacets(WallQuery query) async => const WallFacets();

  @override
  Future<ThemeMedia> themeMedia(String itemId) async => const ThemeMedia();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWallListing implements WallListing {
  @override
  WallInfo get info => const WallInfo(total: 0);

  @override
  Future<Page<MediaCard>> page({required int offset, required int limit}) async =>
      const Page<MediaCard>(items: [], total: 0);
}

class _FakePlaybackSession implements PlaybackSession {
  _FakePlaybackSession(this._snap);

  PlaybackSnapshot _snap;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();
  int pauseCalls = 0;
  int resumeCalls = 0;
  final List<Duration> seekByCalls = [];
  int playNextCalls = 0;
  final List<bool> anime4kCalls = [];
  final List<bool> fullscreenCalls = [];

  @override
  PlaybackSnapshot get snapshot => _snap;

  @override
  Stream<PlaybackSnapshot> get changes => _changes.stream;

  @override
  Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF000000));

  @override
  Future<void> pause() async {
    pauseCalls++;
    _snap = _copy(phase: PlaybackPhase.paused);
    _changes.add(_snap);
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    _snap = _copy(phase: PlaybackPhase.playing);
    _changes.add(_snap);
  }

  @override
  Future<void> seekBy(Duration delta) async {
    seekByCalls.add(delta);
  }

  @override
  Future<void> playNext({bool finishCurrent = false}) async {
    playNextCalls++;
  }

  @override
  Future<void> setAnime4k(bool enabled) async {
    anime4kCalls.add(enabled);
    _snap = _copy(
      anime4k: Anime4kSnapshot(
        requested: enabled,
        state: enabled ? Anime4kState.active : Anime4kState.off,
      ),
    );
    _changes.add(_snap);
  }

  @override
  Future<void> setFullscreen(bool enabled) async {
    fullscreenCalls.add(enabled);
    _snap = _copy(fullscreen: enabled);
    _changes.add(_snap);
  }

  @override
  Future<void> setVolume(double value) async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAnime4kComparison(double? split) async {}

  @override
  Future<void> dismissCreditsPrompt() async {}

  @override
  Future<void> selectSubtitle(String? trackId) async {}

  @override
  Future<void> selectSecondarySubtitle(String? trackId) async {}

  @override
  Future<void> selectAudio(String trackId) async {}

  @override
  Future<void> setPictureInPicture(bool enabled) async {}

  @override
  Future<ThumbnailFrame?> thumbnailAt(Duration position) async => null;

  @override
  Future<void> close() async {
    if (!_changes.isClosed) {
      unawaited(_changes.close());
    }
  }

  PlaybackSnapshot _copy({
    PlaybackPhase? phase,
    Anime4kSnapshot? anime4k,
    bool? fullscreen,
  }) => PlaybackSnapshot(
    generation: _snap.generation,
    target: _snap.target,
    phase: phase ?? _snap.phase,
    position: _snap.position,
    duration: _snap.duration,
    nextEpisode: _snap.nextEpisode,
    anime4k: anime4k ?? _snap.anime4k,
    fullscreen: fullscreen ?? _snap.fullscreen,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSubtitlePanel implements SubtitlePanel {
  final _changes = StreamController<SubtitleSnapshot>.broadcast();
  int startAiCalls = 0;

  @override
  SubtitleSnapshot get snapshot => const SubtitleSnapshot(generation: 1);

  @override
  Stream<SubtitleSnapshot> get changes => _changes.stream;

  @override
  Future<void> startAi() async {
    startAiCalls++;
  }

  @override
  Future<List<SubtitleSearchGroup>> search(String? text) async => const [];

  @override
  Future<void> close() async {
    if (!_changes.isClosed) {
      unawaited(_changes.close());
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSubtitles implements EmbyViewSubtitles {
  _FakeSubtitles(this.panel);
  final _FakeSubtitlePanel panel;

  @override
  SubtitlePanel bind(PlaybackSession session) => panel;

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
  Future<void> showMutedVideo(PreviewRef? video) async {}

  @override
  Widget videoSurface({Key? key}) => SizedBox.shrink(key: key);

  @override
  Future<void> playTheme(PreviewRef? song) async {}

  @override
  Future<void> setThemeMuted(bool muted) async {}

  @override
  Future<void> stop() async {}
}

class _FakePlayback implements EmbyViewPlayback {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<({
  _FakePreferences prefs,
  _FakeAccounts accounts,
  _FakeData data,
  EvShellController controller,
})> _pumpHost(
  WidgetTester tester, {
  ThemeMode theme = ThemeMode.cinema,
  EvShellDestination? initialDestination,
  EvSettingsSection? initialSettings,
  EvNoticeState? initialNotice,
  bool initialShortcutsOpen = false,
  Future<void> Function()? onExportDiagnostics,
  VoidCallback? onSignedOutToUserPicker,
  Size surfaceSize = const Size(1440, 900),
}) async {
  tester.view.physicalSize = surfaceSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final prefs = _FakePreferences(
    LocalPreferences(theme: theme, onboardingDismissed: true),
  );
  final accounts = _FakeAccounts();
  final data = _FakeData();
  final controller = EvShellController(
    initial: initialDestination ?? const EvHomeDestination(),
    zones: _kZones,
  );
  final services = EmbyViewServices(
    preferences: prefs,
    accounts: accounts,
    sessionId: 'sess-w74',
    data: data,
    playback: _FakePlayback(),
    immersion: _FakeImmersion(),
  );

  addTearDown(() async {
    controller.dispose();
    await prefs.close();
    await accounts.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: buildStageFourTestShell(
        services: services,
        initialDestination: initialDestination,
        initialSettings: initialSettings,
        shellController: controller,
        initialNotice: initialNotice,
        initialShortcutsOpen: initialShortcutsOpen,
        onExportDiagnostics: onExportDiagnostics,
        onSignedOutToUserPicker: onSignedOutToUserPicker,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (prefs: prefs, accounts: accounts, data: data, controller: controller);
}

Future<void> _pressQuestionMark(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.slash);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
}

void main() {
  group('MainMenu.xib & AppDelegate.swift specification', () {
    test('MainMenu.xib defines all 6 menu groups, shortcuts, and selectors wired in AppDelegate', () {
      final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
      final appDelegate = File('macos/Runner/AppDelegate.swift').readAsStringSync();

      // Top-level 6 menu groups
      for (final group in ['EmbyView', '编辑', '前往', '播放', '窗口', '帮助']) {
        expect(xib, contains('menu key="submenu" title="$group"'));
      }

      // Expected menu items + key equivalents + selectors
      final expectedSelectors = <String>[
        'embyViewAbout:',
        'embyViewSettings:',
        'embyViewSignOut:',
        'embyViewSearch:',
        'embyViewGoHome:',
        'embyViewGoZone1:',
        'embyViewGoZone2:',
        'embyViewGoZone3:',
        'embyViewGoZone4:',
        'embyViewGoZone5:',
        'embyViewCommandPalette:',
        'embyViewBack:',
        'embyViewPlayPause:',
        'embyViewSeekBack10:',
        'embyViewSeekForward10:',
        'embyViewNextEpisode:',
        'embyViewSubtitlePanel:',
        'embyViewAiSubtitle:',
        'embyViewToggleAnime4k:',
        'embyViewToggleFullscreen:',
        'embyViewShortcuts:',
        'embyViewExportDiagnostics:',
      ];

      for (final sel in expectedSelectors) {
        expect(xib, contains('selector="$sel" target="Voe-Tx-rLC"'), reason: 'Missing selector $sel in MainMenu.xib');
        final swiftMethod = sel.substring(0, sel.length - 1);
        expect(appDelegate, contains('@IBAction func $swiftMethod('), reason: 'Missing @IBAction $swiftMethod in AppDelegate.swift');
      }

      // Key equivalents check
      expect(xib, contains('title="设置…" keyEquivalent=","'));
      expect(xib, contains('title="退出登录"'));
      expect(xib, contains('title="隐藏 EmbyView" keyEquivalent="h"'));
      expect(xib, contains('title="退出 EmbyView" keyEquivalent="q"'));
      expect(xib, contains('title="查找" keyEquivalent="f"'));
      expect(xib, contains('title="首页" keyEquivalent="1"'));
      expect(xib, contains('keyEquivalent="2"'));
      expect(xib, contains('keyEquivalent="3"'));
      expect(xib, contains('keyEquivalent="4"'));
      expect(xib, contains('keyEquivalent="5"'));
      expect(xib, contains('keyEquivalent="6"'));
      expect(xib, contains('title="命令面板" keyEquivalent="k"'));
      expect(xib, contains('title="后退" keyEquivalent="["'));
      expect(xib, contains('title="播放 / 暂停"'));
      expect(xib, contains('title="后退 10 秒"'));
      expect(xib, contains('title="前进 10 秒"'));
      expect(xib, contains('title="下一集"'));
      expect(xib, contains('title="字幕面板"'));
      expect(xib, contains('title="AI 中字"'));
      expect(xib, contains('title="Anime4K"'));
      expect(xib, contains('title="全屏" keyEquivalent="f"'));
      expect(xib, contains('control="YES" command="YES"'));
      expect(xib, contains('title="最小化" keyEquivalent="m"'));
      expect(xib, contains('title="快捷键" keyEquivalent="/"'));
      expect(xib, contains('title="导出诊断日志"'));
    });
  });

  group('macOS menu channel & EvShellController dispatch', () {
    testWidgets('dispatches all navigation, account, palette, shortcuts, and diagnostics actions', (tester) async {
      var signedOut = false;
      var exported = false;
      final env = await _pumpHost(
        tester,
        onSignedOutToUserPicker: () => signedOut = true,
        onExportDiagnostics: () async => exported = true,
      );

      // About -> Settings:About
      expect(env.controller.handleMenuAction(EvMenuAction.about), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_about_version')), findsOneWidget);

      // Back (⌘[) -> returns to Home
      expect(env.controller.handleMenuAction(EvMenuAction.back), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_about_version')), findsNothing);

      // Settings (⌘,)
      expect(env.controller.handleMenuAction(EvMenuAction.settings), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_settings_nav_shortcuts')), findsOneWidget);

      // Go Home (⌘1)
      expect(env.controller.handleMenuAction(EvMenuAction.goHome), isTrue);
      await tester.pumpAndSettle();
      expect(env.controller.current, const EvHomeDestination());
      expect(find.byKey(const Key('ev_settings_nav_shortcuts')), findsNothing);

      // Zones (⌘2–⌘6)
      for (var i = 0; i < EvMenuAction.zoneActions.length; i++) {
        expect(env.controller.handleMenuAction(EvMenuAction.zoneActions[i]), isTrue);
        await tester.pumpAndSettle();
        expect(env.controller.current, EvZoneDestination(_kZones[i].id));
      }

      // Search (⌘F)
      expect(env.controller.handleMenuAction(EvMenuAction.search), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_search_input')), findsOneWidget);

      // Command palette (⌘K) toggle open & close
      expect(env.controller.handleMenuAction(EvMenuAction.commandPalette), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_palette_box')), findsOneWidget);
      expect(env.controller.handleMenuAction(EvMenuAction.commandPalette), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_palette_box')), findsNothing);

      // Shortcuts (⌘/) toggle open & close
      expect(env.controller.handleMenuAction(EvMenuAction.shortcuts), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsOneWidget);
      expect(env.controller.handleMenuAction(EvMenuAction.shortcuts), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsNothing);

      // Export diagnostics
      expect(env.controller.handleMenuAction(EvMenuAction.exportDiagnostics), isTrue);
      await tester.pump();
      expect(exported, isTrue);

      // Sign out
      expect(env.controller.handleMenuAction(EvMenuAction.signOut), isTrue);
      await tester.pumpAndSettle();
      expect(env.accounts.signOutCalls, 1);
      expect(signedOut, isTrue);
    });

    testWidgets('dispatches all 8 playback menu actions to active EvPlayerPage and safely ignores when closed', (tester) async {
      final controller = EvShellController();
      addTearDown(controller.dispose);

      // Without active player, every playback action safely returns false without throwing.
      for (final action in EvMenuAction.playbackActions) {
        expect(controller.handleMenuAction(action), isFalse);
      }

      final session = _FakePlaybackSession(
        const PlaybackSnapshot(
          generation: 1,
          target: PlayTarget(itemId: 'ep1'),
          phase: PlaybackPhase.playing,
          position: Duration(seconds: 40),
          duration: Duration(minutes: 24),
          nextEpisode: MediaCard(id: 'ep2', kind: MediaKind.episode, title: '第 2 集'),
        ),
      );
      final subPanel = _FakeSubtitlePanel();
      final subs = _FakeSubtitles(subPanel);

      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: EvPlayerPage(session: session, subtitles: subs),
          ),
        ),
      );
      await tester.pump();

      expect(EvPlayer.activePlayerActions, isNotNull);

      expect(controller.handleMenuAction(EvMenuAction.playPause), isTrue);
      expect(session.pauseCalls, 1);

      expect(controller.handleMenuAction(EvMenuAction.seekBack10), isTrue);
      expect(controller.handleMenuAction(EvMenuAction.seekForward10), isTrue);
      expect(session.seekByCalls, [
        const Duration(seconds: -10),
        const Duration(seconds: 10),
      ]);

      expect(controller.handleMenuAction(EvMenuAction.nextEpisode), isTrue);
      expect(session.playNextCalls, 1);

      expect(controller.handleMenuAction(EvMenuAction.subtitlePanel), isTrue);
      await tester.pump();

      expect(controller.handleMenuAction(EvMenuAction.aiSubtitle), isTrue);
      await tester.pump();
      expect(subPanel.startAiCalls, 1);

      expect(controller.handleMenuAction(EvMenuAction.toggleAnime4k), isTrue);
      expect(session.anime4kCalls, [true]);

      expect(controller.handleMenuAction(EvMenuAction.toggleFullscreen), isTrue);
      expect(session.fullscreenCalls, [true]);

      // Disposing player unregisters delegate cleanly
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(EvPlayer.activePlayerActions, isNull);
      expect(controller.handleMenuAction(EvMenuAction.playPause), isFalse);
      await session.close();
      await subPanel.close();
    });

    test('EvMenuChannel deduplicates cross-source menu + keyboard triggers within window', () {
      var now = DateTime(2026, 11, 26, 12, 0, 0);
      EvMenuChannel.instance.configureClockForTesting(() => now);
      addTearDown(() => EvMenuChannel.instance.configureClockForTesting(null));

      var calls = 0;
      final token = EvMenuChannel.instance.registerHandler((action, _) {
        calls++;
        return true;
      });
      addTearDown(() => EvMenuChannel.instance.unregisterHandler(token));

      // Native menu fires ⌘K, Flutter keyboard echoes it 20ms later -> only 1 call
      EvMenuChannel.instance.dispatchAction(EvMenuAction.commandPalette, source: EvMenuActionSource.menu);
      now = now.add(const Duration(milliseconds: 20));
      EvMenuChannel.instance.dispatchAction(EvMenuAction.commandPalette, source: EvMenuActionSource.keyboard);
      expect(calls, 1);

      // Same-source repeat press (user taps ⌘K twice rapidly) -> allowed
      now = now.add(const Duration(milliseconds: 40));
      EvMenuChannel.instance.dispatchAction(EvMenuAction.commandPalette, source: EvMenuActionSource.menu);
      expect(calls, 2);

      // After dedupe window expires, cross-source press triggers normally
      now = now.add(const Duration(milliseconds: 250));
      EvMenuChannel.instance.dispatchAction(EvMenuAction.commandPalette, source: EvMenuActionSource.keyboard);
      expect(calls, 3);
    });
  });

  group('Esc, F1, ?, and ⌘/ keyboard behavior', () {
    testWidgets('Esc does nothing at Home, pops subpages, closes overlays first; F1 is unbound', (tester) async {
      final env = await _pumpHost(tester);

      // At Home: Esc does nothing and never shows any exit dialog
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(env.controller.current, const EvHomeDestination());
      expect(find.byType(AlertDialog), findsNothing);

      // F1 does NOT open shortcuts overlay
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsNothing);

      // Open zone -> Esc pops back to Home
      env.controller.openZone('anime');
      await tester.pumpAndSettle();
      expect(env.controller.current, const EvZoneDestination('anime'));

      // Open shortcuts overlay -> Esc closes overlay first (stays on zone)
      env.controller.showShortcuts();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsNothing);
      expect(env.controller.current, const EvZoneDestination('anime'));

      // Open avatar menu -> Esc closes avatar menu first (stays on zone)
      await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_avatar_menu')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_avatar_menu')), findsNothing);
      expect(env.controller.current, const EvZoneDestination('anime'));

      // Next Esc pops zone back to Home
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(env.controller.current, const EvHomeDestination());
    });

    testWidgets('? and ⌘/ toggle EmbyView shortcuts overlay; ? is ignored while editing text', (tester) async {
      await _pumpHost(tester);

      // Bare ? (Shift+/) opens shortcuts overlay
      await _pressQuestionMark(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsOneWidget);
      expect(find.text('浏览'), findsOneWidget);
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('窗口'), findsOneWidget);
      expect(find.text('一瞥：预览选中的片子'), findsOneWidget);
      expect(find.text('命令面板'), findsOneWidget);

      // ⌘/ closes shortcuts overlay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsNothing);

      // ⌘/ opens again
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsOneWidget);

      // Esc closes it
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsNothing);

      // Open Search (focuses text input) -> bare ? should NOT open shortcuts
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_search_input')), findsOneWidget);

      await _pressQuestionMark(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_shortcuts_card')), findsNothing);
    });
  });

  group('Shortcuts overlay & Settings -> Shortcuts dual theme', () {
    for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
      testWidgets('renders shortcuts overlay and settings:shortcuts cleanly in ${mode.name} theme', (tester) async {
        await _pumpHost(tester, theme: mode, initialSettings: EvSettingsSection.shortcuts);

        // Verify sidebar ordering: 密钥 -> 快捷键 -> 关于
        final keysY = tester.getTopLeft(find.byKey(const Key('ev_settings_nav_keys'))).dy;
        final shortcutsY = tester.getTopLeft(find.byKey(const Key('ev_settings_nav_shortcuts'))).dy;
        final aboutY = tester.getTopLeft(find.byKey(const Key('ev_settings_nav_about'))).dy;
        expect(keysY, lessThan(shortcutsY));
        expect(shortcutsY, lessThan(aboutY));

        // Verify pane content matches shared catalog & footnote
        expect(find.byKey(const Key('ev_settings_shortcuts_pane')), findsOneWidget);
        expect(find.byType(EvShortcutsSettingsPane), findsOneWidget);
        expect(find.byKey(const Key('ev_settings_shortcuts_note')), findsOneWidget);
        expect(find.text('随时按'), findsOneWidget);
        expect(find.text('打开速查卡。'), findsOneWidget);
        for (final g in evShortcutGroups) {
          expect(find.text(g.title), findsWidgets);
          for (final item in g.items) {
            expect(find.text(item.label), findsWidgets);
          }
        }
        expect(find.textContaining('Anthropic'), findsNothing);

        // Open overlay in same theme and verify all 3 groups render cleanly
        await _pressQuestionMark(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_shortcuts_overlay')), findsOneWidget);
        expect(find.byKey(const Key('ev_shortcuts_card')), findsOneWidget);
        expect(find.text('关闭'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('EvNoticeCapsule & connectionNotices subscription', () {
    for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
      testWidgets('renders notice:offline countdown, retry, server settings & notice:switched auto-dismiss in ${mode.name}', (tester) async {
        final env = await _pumpHost(tester, theme: mode);

        // 1. Offline event via connectionNotices stream (server remains unreachable on retry)
        env.data.failHome = true;
        final homeCallsBeforeRetry = env.data.homeCalls;
        env.accounts.emitNotice(
          const ConnectionNoticeEvent.offline(serverName: '家里的 Emby', triedAddressCount: 2),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(find.byKey(const Key('ev_notice_offline')), findsOneWidget);
        expect(find.text('连不上家里的 Emby'), findsOneWidget);
        expect(find.text('· 8 秒后重试'), findsOneWidget);

        // Advance 3 seconds -> countdown ticks down
        await tester.pump(const Duration(seconds: 3));
        expect(find.text('· 5 秒后重试'), findsOneWidget);

        // Advance remaining 5 seconds -> auto retries (connection + home) and resets to 10s
        await tester.pump(const Duration(seconds: 5));
        expect(env.accounts.retryConnectionCalls, 1);
        expect(env.data.homeCalls, greaterThan(homeCallsBeforeRetry));
        expect(find.text('· 10 秒后重试'), findsOneWidget);

        // Tap 立即重试 -> triggers retry immediately
        await tester.tap(find.byKey(const Key('ev_notice_retry')));
        await tester.pump();
        expect(env.accounts.retryConnectionCalls, 2);
        env.data.failHome = false;

        // Tap 服务器设置 -> dismisses capsule and opens Settings:account
        await tester.tap(find.byKey(const Key('ev_notice_server_settings')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byKey(const Key('ev_notice_offline')), findsNothing);
        expect(env.controller.notice, isNull);
        expect(find.text('用户与服务器'), findsWidgets);

        // 2. Switched event via connectionNotices stream
        env.accounts.emitNotice(
          const ConnectionNoticeEvent.switched(
            serverName: '家里的 Emby',
            fromLabel: '内网',
            toLabel: 'Tailscale',
            activeAddress: 'https://nas.tail-example.ts.net',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(find.byKey(const Key('ev_notice_switched')), findsOneWidget);
        expect(find.text('内网连不上，已换到 Tailscale 地址'), findsOneWidget);

        // After 8 seconds it dismisses automatically
        await tester.pump(const Duration(seconds: 8));
        await tester.pump();
        expect(find.byKey(const Key('ev_notice_switched')), findsNothing);

        // 3. Direct controller API (W7.5 / demo launcher) + recovered clears notice
        env.controller.showOfflineNotice(serverName: '家里的 Emby', autoTick: false);
        await tester.pump();
        expect(find.byKey(const Key('ev_notice_offline')), findsOneWidget);

        env.accounts.emitNotice(const ConnectionNoticeEvent.recovered());
        await tester.pump();
        expect(find.byKey(const Key('ev_notice_offline')), findsNothing);
      });
    }

    test('isEmbyViewAppMode disables legacy banners, offline snackbar, update checks, and exit dialog on EmbyView routes', () {
      expect(isEmbyViewAppMode(path: '/embyview', isMacOS: true), isTrue);
      expect(isEmbyViewAppMode(path: '/embyview/settings', isMacOS: true), isTrue);
      expect(isEmbyViewAppMode(path: '/embyview-login', isMacOS: true), isTrue);
      expect(isEmbyViewAppMode(path: '/', isMacOS: true, embyServersOnly: true), isTrue);
      expect(isEmbyViewAppMode(path: '/', isMacOS: true, embyServersOnly: false), isFalse);
      expect(isEmbyViewAppMode(path: '/home', isMacOS: false), isFalse);
      expect(
        isEmbyViewAppMode(
          path: '/home',
          isMacOS: true,
          activeServerType: ServerType.jellyfin,
        ),
        isFalse,
      );
      expect(
        isEmbyViewAppMode(
          path: '/home',
          isMacOS: true,
          activeServerType: ServerType.emby,
        ),
        isTrue,
      );
    });

    testWidgets('buildStageFourTestShell mounts cleanly with initialNotice and initialShortcutsOpen without LateInitializationError', (tester) async {
      await _pumpHost(
        tester,
        initialNotice: const EvNoticeState.switched(
          serverName: '家里的 Emby',
          message: '内网连不上，已换到 Tailscale 地址',
          autoDismissAfter: null,
        ),
        initialShortcutsOpen: true,
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('ev_notice_switched')), findsOneWidget);
      expect(find.byKey(const Key('ev_shortcuts_overlay')), findsOneWidget);
    });

    test('player menu isolation blocks browse/overlay actions while player is active and blocks non-fullscreen controls on failed phase', () {
      var closed = 0;
      var signedOut = 0;
      var exported = 0;
      var settingsOpened = 0;
      var searchOpened = 0;
      var paletteToggled = 0;
      var playPauseCalls = 0;
      var fullscreenCalls = 0;
      var failed = false;

      final delegate = EvPlayerMenuDelegate(
        togglePlayPause: () => playPauseCalls++,
        seekBack10: () {},
        seekForward10: () {},
        nextEpisode: () {},
        toggleSubtitlePanel: () {},
        triggerAiSubtitle: () {},
        toggleAnime4k: () {},
        toggleFullscreen: () => fullscreenCalls++,
        closePlayer: () => closed++,
        isFailed: () => failed,
      );

      final controller = EvShellController(
        zones: _kZones,
        onOpenSettings: () => settingsOpened++,
        onOpenSearch: () => searchOpened++,
        onToggleCommandPalette: () => paletteToggled++,
        onSignOut: () => signedOut++,
        onExportDiagnostics: () async => exported++,
        activePlayerResolver: () => delegate,
      );
      addTearDown(controller.dispose);

      // Non-player browsing/overlay actions are blocked while player is active.
      expect(controller.handleMenuAction(EvMenuAction.settings), isFalse);
      expect(controller.handleMenuAction(EvMenuAction.search), isFalse);
      expect(controller.handleMenuAction(EvMenuAction.goZone1), isFalse);
      expect(controller.handleMenuAction(EvMenuAction.commandPalette), isFalse);
      expect(controller.handleMenuAction(EvMenuAction.shortcuts), isFalse);
      expect(settingsOpened, 0);
      expect(searchOpened, 0);
      expect(paletteToggled, 0);
      expect(controller.shortcutsOpen, isFalse);

      // Playback, exportDiagnostics, back (closePlayer), and signOut (closePlayer + signOut) are allowed.
      expect(controller.handleMenuAction(EvMenuAction.playPause), isTrue);
      expect(playPauseCalls, 1);
      expect(controller.handleMenuAction(EvMenuAction.exportDiagnostics), isTrue);
      expect(exported, 1);
      expect(controller.handleMenuAction(EvMenuAction.back), isTrue);
      expect(closed, 1);
      expect(controller.handleMenuAction(EvMenuAction.signOut), isTrue);
      expect(closed, 2);
      expect(signedOut, 1);

      // When player is in PlaybackPhase.failed, only toggleFullscreen is permitted among playback actions.
      failed = true;
      expect(controller.handleMenuAction(EvMenuAction.playPause), isFalse);
      expect(playPauseCalls, 1);
      expect(controller.handleMenuAction(EvMenuAction.seekBack10), isFalse);
      expect(controller.handleMenuAction(EvMenuAction.subtitlePanel), isFalse);
      expect(controller.handleMenuAction(EvMenuAction.toggleFullscreen), isTrue);
      expect(fullscreenCalls, 1);
    });

    testWidgets('EmbyViewLoginHost wires EvMenuChannel for exportDiagnostics and login step back', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var exported = 0;
      final prefs = _FakePreferences(const LocalPreferences(theme: ThemeMode.cinema));
      addTearDown(prefs.close);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(1440, 900),
            disableAnimations: true,
          ),
          child: MaterialApp(
            home: EmbyViewLoginHost(
              initialStep: EvLoginStep.pass,
              backend: EvDemoLoginBackend(),
              preferences: prefs,
              onExportDiagnostics: () async => exported++,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(EvMenuChannel.instance.dispatchAction(EvMenuAction.exportDiagnostics), isTrue);
      expect(exported, 1);

      // Back steps from pass -> users -> server, then returns false at root.
      expect(EvMenuChannel.instance.dispatchAction(EvMenuAction.back), isTrue);
      await tester.pump();
      expect(find.byKey(const Key('ev_login_password_bar')), findsNothing);
      expect(find.byKey(const Key('ev_login_users_grid')), findsOneWidget);

      expect(EvMenuChannel.instance.dispatchAction(EvMenuAction.back), isTrue);
      await tester.pump();
      expect(find.byKey(const Key('ev_login_server_card')), findsOneWidget);

      expect(EvMenuChannel.instance.dispatchAction(EvMenuAction.back), isFalse);
    });

    testWidgets('standalone EvShell dismisses offline notice capsule when tapping server settings', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = _FakePreferences();
      final accounts = _FakeAccounts();
      var serverSettingsOpened = 0;
      final controller = EvShellController(
        zones: _kZones,
        onOpenServerSettings: () => serverSettingsOpened++,
      );
      addTearDown(() async {
        controller.dispose();
        await prefs.close();
        await accounts.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: EvShell(
            services: EmbyViewServices(
              preferences: prefs,
              accounts: accounts,
              sessionId: 'sess-standalone',
              data: _FakeData(),
              playback: _FakePlayback(),
              immersion: _FakeImmersion(),
            ),
            controller: controller,
            configureWindow: false,
            enableStageMotion: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      controller.showOfflineNotice(serverName: '家里的 Emby', autoTick: false);
      await tester.pump();
      expect(find.byKey(const Key('ev_notice_offline')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ev_notice_server_settings')));
      await tester.pump();

      expect(serverSettingsOpened, 1);
      expect(controller.notice, isNull);
      expect(find.byKey(const Key('ev_notice_offline')), findsNothing);
    });

    testWidgets('avatar menu look row shows theme mode label and opens Settings:look in Stage 4 host', (tester) async {
      final env = await _pumpHost(tester, theme: ThemeMode.automatic);

      await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
      await tester.pumpAndSettle();
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
          matching: find.text('昼夜自动'),
        ),
        findsOneWidget,
      );

      final usersY = tester.getTopLeft(find.byKey(const Key('ev_avatar_menu_users'))).dy;
      final lookY = tester.getTopLeft(find.byKey(const Key('ev_avatar_menu_look'))).dy;
      final zonesY = tester.getTopLeft(find.byKey(const Key('ev_avatar_menu_zones'))).dy;
      expect(usersY, lessThan(lookY));
      expect(lookY, lessThan(zonesY));

      await tester.tap(find.byKey(const Key('ev_avatar_menu_look')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_avatar_menu')), findsNothing);
      expect(find.byType(EvLookSettingsPane), findsOneWidget);

      // Update theme to paper and verify Stage 4 frame avatar menu reflects it
      await env.prefs.update(env.prefs.current.copyWith(theme: ThemeMode.paper));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('ev_avatar_menu_look')),
          matching: find.text('纸面'),
        ),
        findsOneWidget,
      );
    });
  });
}
