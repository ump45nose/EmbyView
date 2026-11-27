import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Page, ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/entry.dart';
import 'package:moonfin/embyview/ui/home/ev_home_page.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/wall/ev_wall_page.dart';
import 'package:moonfin/embyview/ui/zone/ev_zone_page.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(this.id)
    : cacheKey = 'shell_test_$id',
      image = MemoryImage(_kPngBytes);

  @override
  final String id;

  @override
  final String cacheKey;

  @override
  final ImageProvider<Object> image;

  @override
  double? get aspectRatio => 16 / 9;

  @override
  int? get width => 1920;

  @override
  int? get height => 1080;
}

class _FakePreferences implements EmbyViewPreferences {
  _FakePreferences([LocalPreferences initial = const LocalPreferences()])
    : _current = initial;

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

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccounts implements EmbyViewAccounts {
  _FakeAccounts(AccountSnapshot initial) : _snapshot = initial;

  AccountSnapshot _snapshot;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final List<String> switchCalls = [];

  @override
  AccountSnapshot get snapshot => _snapshot;

  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

  @override
  Stream<ConnectionNoticeEvent> get connectionNotices => const Stream.empty();

  @override
  Future<Uri?> probeAndFailover({Duration timeout = const Duration(seconds: 5)}) async => null;

  @override
  Future<void> retryConnection() async {}

  @override
  Future<void> switchTo(String profileId, {String? password}) async {
    switchCalls.add(profileId);
    final next = _snapshot.profiles.where((p) => p.id == profileId).firstOrNull;
    if (next != null) {
      _snapshot = AccountSnapshot(
        phase: AccountPhase.signedIn,
        current: next,
        profiles: _snapshot.profiles,
        sessionId: 'session_$profileId',
      );
      _changes.add(_snapshot);
    }
  }

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWallListing implements WallListing {
  const _FakeWallListing();

  @override
  WallInfo get info => const WallInfo(total: 0);

  @override
  Future<Page<MediaCard>> page({required int offset, required int limit}) async =>
      const Page<MediaCard>(items: [], total: 0);
}

class _FakeData implements EmbyViewData {
  _FakeData(this.zoneList);

  final List<ZoneTile> zoneList;
  int zonesCalls = 0;

  @override
  Future<List<ZoneTile>> zones() async {
    zonesCalls++;
    return zoneList;
  }

  @override
  Future<HomeData> home({required ShelfSort seriesSort}) async =>
      HomeData(zones: zoneList);

  @override
  Future<ZoneData> zone(String zoneId) async {
    final tile = zoneList.where((z) => z.id == zoneId).firstOrNull ??
        ZoneTile(
          id: zoneId,
          name: zoneId,
          iconKey: 'nav_movie',
          colorSlot: 1,
          total: 0,
          unit: '部',
        );
    return ZoneData(
      zone: tile,
      all: (
        scope: WallScope.zone(zoneId),
        sort: WallSort.title,
        watched: WatchFilter.all,
        genreId: null,
        years: null,
        technology: null,
      ),
    );
  }

  @override
  Future<WallListing> openWall(WallQuery query) async =>
      const _FakeWallListing();

  @override
  Future<WallFacets> wallFacets(WallQuery query) async => const WallFacets();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImmersionPlayback implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast(sync: true);
  final ImmersionSnapshot _snapshot = const ImmersionSnapshot();
  int stopCalls = 0;

  @override
  ImmersionSnapshot get snapshot => _snapshot;

  @override
  Stream<ImmersionSnapshot> get changes => _changes.stream;

  @override
  Future<void> showMutedVideo(PreviewRef? video) async {}

  @override
  Widget videoSurface({Key? key}) =>
      ColoredBox(key: key, color: const Color(0xFF000000));

  @override
  Future<void> playTheme(PreviewRef? song) async {}

  @override
  Future<void> setThemeMuted(bool muted) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  Future<void> close() => _changes.close();
}

class _FakePlaybackSession implements PlaybackSession {
  _FakePlaybackSession(this.target);

  final PlayTarget target;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();
  bool closed = false;
  int closeCalls = 0;

  @override
  PlaybackSnapshot get snapshot =>
      PlaybackSnapshot(generation: 1, target: target);

  @override
  Stream<PlaybackSnapshot> get changes => _changes.stream;

  @override
  Widget videoSurface({Key? key}) => ColoredBox(
    key: key ?? Key('fake_player_video_${target.itemId}'),
    color: const Color(0xFF102030),
  );

  @override
  Future<void> close() async {
    closed = true;
    closeCalls++;
    await _changes.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayback implements EmbyViewPlayback {
  final List<PlayTarget> openedTargets = [];
  final List<_FakePlaybackSession> sessions = [];

  @override
  Future<void> prepare(String itemId, {String? mediaSourceId}) async {}

  @override
  PlaybackSession open(PlayTarget target) {
    openedTargets.add(target);
    final s = _FakePlaybackSession(target);
    sessions.add(s);
    return s;
  }
}

const List<ZoneTile> _kDefaultZones = [
  ZoneTile(
    id: 'anime',
    name: '番剧',
    iconKey: 'nav_anime',
    colorSlot: 0,
    total: 12,
    unit: '部',
  ),
  ZoneTile(
    id: 'movie',
    name: '电影',
    iconKey: 'nav_movie',
    colorSlot: 1,
    total: 733,
    unit: '部',
  ),
  ZoneTile(
    id: 'tv',
    name: '剧集',
    iconKey: 'nav_tv',
    colorSlot: 2,
    total: 92,
    unit: '部',
  ),
];

const _kProfileSfw = AccountProfile(id: 'sfw', displayName: 'sfw');
const _kProfileFamily = AccountProfile(id: 'family', displayName: '家人');
const _kProfileGuest = AccountProfile(id: 'guest', displayName: '访客');

MediaCard _card(String id, String title) => MediaCard(
  id: id,
  kind: MediaKind.movie,
  libraryId: 'movie',
  title: title,
  year: 2024,
  art: CardArtwork(
    poster: ArtworkPlan(
      layers: [ArtworkLayer(source: _FakeArtworkRef('p_$id'))],
      fallbackTitle: title,
    ),
    landscape: ArtworkPlan(
      layers: [ArtworkLayer(source: _FakeArtworkRef('l_$id'))],
      fallbackTitle: title,
    ),
  ),
);

Widget _appShell(Widget child, {Size size = const Size(1440, 900)}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  group('C3.3 EvTopBar navigation styles, indicator, auto-tuck, scroll bar & avatar menu', () {
    testWidgets(
      'supports icon (active-only label + hover tip), iconAndText, and text NavigationStyle',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences(
          const LocalPreferences(navigation: NavigationStyle.icon),
        );
        final accounts = _FakeAccounts(
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kProfileSfw,
            profiles: [_kProfileSfw, _kProfileFamily],
            sessionId: 's1',
          ),
        );
        final data = _FakeData(_kDefaultZones);
        final shellController = EvShellController(zones: _kDefaultZones);
        addTearDown(() async {
          shellController.dispose();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(
          _appShell(
            EvShell(
              services: EmbyViewServices(
                preferences: prefs,
                accounts: accounts,
                sessionId: 's1',
                data: data,
              ),
              controller: shellController,
              configureWindow: false,
              enableStageMotion: false,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. NavigationStyle.icon: active tab shows label + icon; unselected tabs show icon only.
        expect(find.text('首页'), findsOneWidget);
        expect(find.text('番剧'), findsNothing);
        expect(find.text('电影'), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_topbar_tab_anime')),
            matching: find.byType(EvIcon),
          ),
          findsOneWidget,
        );

        // Hovering unselected tab shows `.tip` bubble with tab name.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('ev_topbar_tab_movie'))),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_topbar_tip_movie')), findsOneWidget);
        expect(find.text('电影'), findsOneWidget);

        // Hovering active tab hides `.tip` (no tooltip on active tab).
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('ev_topbar_tab_home'))),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_topbar_tip_movie')), findsNothing);
        expect(find.byKey(const Key('ev_topbar_tip_home')), findsNothing);

        // 2. NavigationStyle.iconAndText: all tabs show icons and labels, no tooltip.
        await prefs.update(
          const LocalPreferences(navigation: NavigationStyle.iconAndText),
        );
        await tester.pumpAndSettle();
        expect(find.text('首页'), findsOneWidget);
        expect(find.text('番剧'), findsOneWidget);
        expect(find.text('电影'), findsOneWidget);
        expect(find.text('剧集'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_topbar_tab_movie')),
            matching: find.byType(EvIcon),
          ),
          findsOneWidget,
        );
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('ev_topbar_tab_movie'))),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_topbar_tip_movie')), findsNothing);

        // 3. NavigationStyle.text: all tabs show text only, no icons inside tabs.
        await prefs.update(
          const LocalPreferences(navigation: NavigationStyle.text),
        );
        await tester.pumpAndSettle();
        expect(find.text('首页'), findsOneWidget);
        expect(find.text('番剧'), findsOneWidget);
        expect(find.text('电影'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_topbar_tab_home')),
            matching: find.byType(EvIcon),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_topbar_tab_movie')),
            matching: find.byType(EvIcon),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'sliding indicator tracks selected tab geometry, zone auto-tucks after 1.4s, hover expands & leave re-tucks',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences(
          const LocalPreferences(navigation: NavigationStyle.iconAndText),
        );
        final accounts = _FakeAccounts(
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kProfileSfw,
            profiles: [_kProfileSfw],
            sessionId: 's1',
          ),
        );
        final shellController = EvShellController(zones: _kDefaultZones);
        addTearDown(() async {
          shellController.dispose();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(
          _appShell(
            EvShell(
              services: EmbyViewServices(
                preferences: prefs,
                accounts: accounts,
                sessionId: 's1',
                data: _FakeData(_kDefaultZones),
              ),
              controller: shellController,
              configureWindow: false,
              enableStageMotion: false,
              zoneBuilder: (context, zoneId) => Center(child: Text('ZONE:$zoneId')),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Indicator initially aligns with 'home'.
        final homeRect = tester.getRect(find.byKey(const Key('ev_topbar_tab_home')));
        final indHome = tester.getRect(find.byKey(const Key('ev_topbar_indicator')));
        expect(indHome.left, closeTo(homeRect.left, 1.0));
        expect(indHome.width, closeTo(homeRect.width, 1.0));

        // Switch to 'movie' zone -> indicator slides to 'movie' tab.
        shellController.openZone('movie');
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final indMid = tester.getRect(find.byKey(const Key('ev_topbar_indicator')));
        expect(indMid.left, greaterThan(indHome.left));

        // Finish indicator spring (500ms total), still before 1.4s auto-tuck.
        await tester.pump(const Duration(milliseconds: 350));
        final movieRect = tester.getRect(find.byKey(const Key('ev_topbar_tab_movie')));
        final indMovie = tester.getRect(find.byKey(const Key('ev_topbar_indicator')));
        expect(indMovie.left, closeTo(movieRect.left, 1.0));
        expect(indMovie.width, closeTo(movieRect.width, 1.0));
        expect(find.text('切换'), findsNothing);

        // Cross 1.4s on zone page -> tucks into '切换' capsule.
        await tester.pump(const Duration(milliseconds: 900));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_topbar_tucked_capsule')), findsOneWidget);
        expect(find.text('切换'), findsOneWidget);

        // Hovering expands tabs immediately.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('ev_topbar_tucked_capsule'))),
        );
        await tester.pumpAndSettle();
        expect(find.text('切换'), findsNothing);
        expect(find.byKey(const Key('ev_topbar_tab_movie')), findsOneWidget);

        // Leaving tabs re-arms timer and re-tucks.
        await mouse.moveTo(const Offset(20, 400));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('切换'), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(find.text('切换'), findsOneWidget);

        // Going back to home untucks and stays expanded past 2s.
        shellController.goHome();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('切换'), findsNothing);
        expect(find.byKey(const Key('ev_topbar_tab_home')), findsOneWidget);
      },
    );

    testWidgets(
      'scroll activates frosted bar, wall shows back button, title plate renders, and avatar menu triggers callbacks',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences();
        final accounts = _FakeAccounts(
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kProfileSfw,
            profiles: [_kProfileSfw, _kProfileFamily, _kProfileGuest],
            sessionId: 's1',
          ),
        );
        var usersOpened = 0;
        var lookOpened = 0;
        var settingsOpened = 0;
        final shellController = EvShellController(
          zones: _kDefaultZones,
          onOpenUsers: () => usersOpened++,
          onOpenLook: () => lookOpened++,
          onOpenSettings: () => settingsOpened++,
        );
        final scrollController = ScrollController();
        addTearDown(() async {
          scrollController.dispose();
          shellController.dispose();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(
          _appShell(
            EvShell(
              services: EmbyViewServices(
                preferences: prefs,
                accounts: accounts,
                sessionId: 's1',
                data: _FakeData(_kDefaultZones),
              ),
              controller: shellController,
              configureWindow: false,
              enableStageMotion: false,
              homeBuilder: (_) => SingleChildScrollView(
                controller: scrollController,
                child: const SizedBox(height: 2200, width: 1440),
              ),
              wallBuilder: (_, query, title) =>
                  Center(child: Text('WALL:${title ?? ''}')),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initially frosted bar opacity is 0.
        AnimatedOpacity frostedBar() => tester.widget<AnimatedOpacity>(
          find.byKey(const Key('ev_topbar_frosted_bar')),
        );
        expect(frostedBar().opacity, 0.0);

        // Scroll down -> frosted bar activates with BackdropFilter.
        scrollController.jumpTo(200);
        await tester.pumpAndSettle();
        expect(frostedBar().opacity, closeTo(1.0, 0.01));
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_topbar_frosted_bar')),
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
        );

        // Zone title plate renders formatted total + monthly additions.
        shellController.titlePlate = const EvChromeTitlePlate(
          iconKey: 'nav_movie',
          title: '电影',
          colorSlot: 1,
          total: 1234,
          unit: '部',
          addedThisMonth: 8,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_topbar_title_plate')), findsOneWidget);
        expect(find.text('1,234 部'), findsOneWidget);
        expect(find.text('本月新增 8'), findsOneWidget);

        // Push wall destination -> shows back button; tapping back pops to home.
        shellController.openWall(
          (
            scope: const WallScope.zone('movie'),
            sort: WallSort.title,
            watched: WatchFilter.all,
            genreId: null,
            years: null,
            technology: null,
          ),
          title: '全部电影',
        );
        await tester.pumpAndSettle();
        expect(find.text('WALL:全部电影'), findsOneWidget);
        expect(find.byKey(const Key('ev_topbar_back')), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_topbar_back')));
        await tester.pumpAndSettle();
        expect(shellController.current, const EvHomeDestination());
        expect(find.byKey(const Key('ev_topbar_back')), findsNothing);

        // Open avatar menu -> displays profiles, switch users, settings.
        await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_avatar_menu')), findsOneWidget);
        expect(find.text('sfw'), findsOneWidget);
        expect(find.text('家人'), findsOneWidget);
        expect(find.text('切换用户…'), findsOneWidget);
        expect(find.text('设置'), findsOneWidget);

        // Trigger switch profile via accounts.switchTo.
        await tester.tap(find.byKey(const Key('ev_avatar_menu_profile_family')));
        await tester.pumpAndSettle();
        expect(accounts.switchCalls, ['family']);
        expect(find.byKey(const Key('ev_avatar_menu')), findsNothing);

        // Re-open menu and trigger '切换用户…'.
        await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ev_avatar_menu_users')));
        await tester.pumpAndSettle();
        expect(usersOpened, 1);

        // Re-open menu and trigger '外观'.
        await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_avatar_menu_look')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_avatar_menu_look')),
            matching: find.text('影院'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('ev_avatar_menu_look')));
        await tester.pumpAndSettle();
        expect(lookOpened, 1);

        // Re-open menu and trigger '设置'.
        await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ev_avatar_menu_settings')));
        await tester.pumpAndSettle();
        expect(settingsOpened, 1);

        // Paper theme renders EvIcons.faceFor smiley inside avatar button.
        await prefs.update(const LocalPreferences(theme: ThemeMode.paper));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_topbar_avatar')),
            matching: find.byType(EvIcon),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('EvShell rebinds Immersion and reloads zones when sessionId changes', (
      tester,
    ) async {
      final prefs = _FakePreferences();
      final accounts = _FakeAccounts(
        const AccountSnapshot(
          phase: AccountPhase.signedIn,
          current: _kProfileSfw,
          profiles: [_kProfileSfw],
          sessionId: 'sess-1',
        ),
      );
      final immersionA = _FakeImmersionPlayback();
      final immersionB = _FakeImmersionPlayback();
      final dataA = _FakeData([_kDefaultZones.first]);
      final dataB = _FakeData(_kDefaultZones);
      addTearDown(() async {
        await prefs.close();
        await accounts.close();
        await immersionA.close();
        await immersionB.close();
      });

      final servicesNotifier = ValueNotifier<EmbyViewServices>(
        EmbyViewServices(
          preferences: prefs,
          accounts: accounts,
          sessionId: 'sess-1',
          data: dataA,
          immersion: immersionA,
        ),
      );
      addTearDown(servicesNotifier.dispose);

      await tester.pumpWidget(
        _appShell(
          ValueListenableBuilder<EmbyViewServices>(
            valueListenable: servicesNotifier,
            builder: (_, services, _) => EvShell(
              services: services,
              configureWindow: false,
              enableStageMotion: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(dataA.zonesCalls, 1);
      expect(find.byKey(const Key('ev_topbar_tab_anime')), findsOneWidget);
      expect(find.byKey(const Key('ev_topbar_tab_movie')), findsNothing);

      // Update services with a new sessionId -> rebinds Immersion and reloads zones.
      servicesNotifier.value = EmbyViewServices(
        preferences: prefs,
        accounts: accounts,
        sessionId: 'sess-2',
        data: dataB,
        immersion: immersionB,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(immersionA.stopCalls, 1);
      expect(dataB.zonesCalls, 1);
      expect(find.byKey(const Key('ev_topbar_tab_movie')), findsOneWidget);
    });
  });

  group('C3.4 keyboard-only directional focus across top bar and two EvShelf rows', () {
    testWidgets(
      'navigates from top bar down to shelf 1, across cards, down to shelf 2, and back up to top bar using arrow keys only',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences(
          const LocalPreferences(navigation: NavigationStyle.iconAndText),
        );
        final accounts = _FakeAccounts(
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kProfileSfw,
            profiles: [_kProfileSfw],
            sessionId: 's1',
          ),
        );
        final shellController = EvShellController(zones: _kDefaultZones);
        final row1Nodes = List.generate(5, (i) => FocusNode(debugLabel: 'r1_$i'));
        final row2Nodes = List.generate(5, (i) => FocusNode(debugLabel: 'r2_$i'));
        final zoneCardNode = FocusNode(debugLabel: 'zone_card');
        addTearDown(() async {
          for (final n in [...row1Nodes, ...row2Nodes, zoneCardNode]) {
            n.dispose();
          }
          shellController.dispose();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(
          _appShell(
            EvShell(
              services: EmbyViewServices(
                preferences: prefs,
                accounts: accounts,
                sessionId: 's1',
                data: _FakeData(_kDefaultZones),
              ),
              controller: shellController,
              configureWindow: false,
              enableStageMotion: false,
              zoneBuilder: (_, zoneId) => Padding(
                padding: const EdgeInsets.only(top: 160),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: EvCard(
                    card: _card('z_$zoneId', '分区卡片'),
                    style: EvCardStyle.landscape,
                    width: 300,
                    focusNode: zoneCardNode,
                  ),
                ),
              ),
              homeBuilder: (_) => SingleChildScrollView(
                padding: const EdgeInsets.only(top: 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EvShelf(
                      title: '第一排',
                      style: EvCardStyle.landscape,
                      itemCount: 5,
                      itemBuilder: (_, i) => EvCard(
                        card: _card('r1_$i', '排一卡片 $i'),
                        style: EvCardStyle.landscape,
                        focusNode: row1Nodes[i],
                      ),
                    ),
                    EvShelf(
                      title: '第二排',
                      style: EvCardStyle.landscape,
                      itemCount: 5,
                      itemBuilder: (_, i) => EvCard(
                        card: _card('r2_$i', '排二卡片 $i'),
                        style: EvCardStyle.landscape,
                        focusNode: row2Nodes[i],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        bool focusInside(Key ancestorKey) {
          final primary = FocusManager.instance.primaryFocus;
          if (primary?.context == null) return false;
          final ancestorElement = tester.element(find.byKey(ancestorKey));
          if (primary!.context == ancestorElement) return true;
          var found = false;
          primary.context!.visitAncestorElements((el) {
            if (el == ancestorElement) {
              found = true;
              return false;
            }
            return true;
          });
          return found;
        }

        // Start keyboard focus on top bar 'home' tab.
        final homeFocus = tester.widget<Focus>(
          find.descendant(
            of: find.byKey(const Key('ev_topbar_tab_home')),
            matching: find.byType(Focus),
          ).first,
        );
        homeFocus.focusNode!.requestFocus();
        await tester.pump();
        expect(focusInside(const Key('ev_topbar_tab_home')), isTrue);

        // Move right & left inside top bar.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(focusInside(const Key('ev_topbar_tab_anime')), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(focusInside(const Key('ev_topbar_tab_home')), isTrue);

        // Move down from top bar -> lands on a card in Shelf 1.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        final r1Index = row1Nodes.indexWhere((n) => n.hasFocus);
        expect(r1Index, greaterThanOrEqualTo(0));

        // Walk right to the next card in Shelf 1, then left back to card 0.
        if (r1Index < row1Nodes.length - 1) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
          expect(row1Nodes[r1Index + 1].hasFocus, isTrue);
        }
        while (!row1Nodes[0].hasFocus) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pumpAndSettle();
        }
        expect(row1Nodes[0].hasFocus, isTrue);

        // Move down from Shelf 1 -> lands on Shelf 2 card 0.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(row2Nodes[0].hasFocus, isTrue);

        // Walk right across Shelf 2 cards.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(row2Nodes[1].hasFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(row2Nodes[2].hasFocus, isTrue);

        // Move up from Shelf 2 -> returns to Shelf 1.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(row1Nodes.any((n) => n.hasFocus), isTrue);

        // Move up from Shelf 1 -> returns to top bar.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(focusInside(const Key('ev_topbar_tabs_pill')), isTrue);

        // Verify keyboard focus also expands tucked '切换' capsule on a zone page.
        shellController.openZone('movie');
        await tester.pumpAndSettle();
        zoneCardNode.requestFocus();
        await tester.pump();
        // Wait past 1.4s so top bar tucks into '切换' capsule while focus is on zone card.
        await tester.pump(const Duration(milliseconds: 1500));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_topbar_tucked_capsule')), findsOneWidget);

        // Press ArrowUp from zone card -> moves focus into tucked capsule & expands tabs.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(find.text('切换'), findsNothing);
        expect(find.byKey(const Key('ev_topbar_tab_movie')), findsOneWidget);
        expect(focusInside(const Key('ev_topbar_tab_movie')), isTrue);
      },
    );

    testWidgets(
      'EvShell autofocuses on initial mount so arrow keys work immediately without Tab or click',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences();
        final accounts = _FakeAccounts(
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kProfileSfw,
            profiles: [_kProfileSfw],
            sessionId: 's-auto',
          ),
        );
        final shellController = EvShellController(zones: _kDefaultZones);
        final cardNodes = List.generate(3, (i) => FocusNode(debugLabel: 'auto_card_$i'));
        addTearDown(() async {
          for (final n in cardNodes) {
            n.dispose();
          }
          shellController.dispose();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(
          _appShell(
            EvShell(
              services: EmbyViewServices(
                preferences: prefs,
                accounts: accounts,
                sessionId: 's-auto',
                data: _FakeData(_kDefaultZones),
              ),
              controller: shellController,
              configureWindow: false,
              enableStageMotion: false,
              homeBuilder: (_) => SingleChildScrollView(
                padding: const EdgeInsets.only(top: 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EvButton.primary(label: '首屏按钮', onPressed: () {}),
                    EvShelf(
                      title: '首排卡片',
                      style: EvCardStyle.landscape,
                      itemCount: 3,
                      itemBuilder: (_, i) => EvCard(
                        card: _card('auto_$i', '卡片 $i'),
                        style: EvCardStyle.landscape,
                        focusNode: cardNodes[i],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Directly press ArrowDown without Tab or clicking -> focuses first card.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(cardNodes[0].hasFocus, isTrue);

        // Press ArrowRight -> moves to second card.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(cardNodes[1].hasFocus, isTrue);
      },
    );

    testWidgets(
      'buildStageFourTestShell opens detail with Enter from home card and restores scroll offset and card focus on Esc',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences();
        final accounts = _FakeAccounts(
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kProfileSfw,
            profiles: [_kProfileSfw],
            sessionId: 's-esc-restore',
          ),
        );
        final data = _DetailFlowData(_kDefaultZones);
        addTearDown(() async {
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1440, 900)),
              child: buildStageFourTestShell(
                services: EmbyViewServices(
                  preferences: prefs,
                  accounts: accounts,
                  sessionId: 's-esc-restore',
                  data: data,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));

        // Directly press ArrowDown then ArrowRight without Tab/click to focus 2nd card in row 1.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();

        final scroller = tester.widget<SingleChildScrollView>(find.byKey(const Key('ev_home_scroller'))).controller!;
        expect(scroller.offset, closeTo(0.0, 0.5));

        final focusedCardNode = FocusManager.instance.primaryFocus;
        expect(focusedCardNode, isNotNull);
        final focusedCard = focusedCardNode!.context?.findAncestorWidgetOfExactType<EvCard>();
        expect(focusedCard, isNotNull);
        expect(focusedCard!.card.id, 'cw_2');
        expect(focusedCardNode.hasFocus, isTrue);

        // Press Enter -> opens detail page for cw_2.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('ev_topbar_back')), findsOneWidget);
        expect(find.text('星际穿越详情简介'), findsOneWidget);

        // Press Esc -> returns to home with scroll offset and exact card FocusNode restored.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byKey(const Key('ev_topbar_back')), findsNothing);
        expect(scroller.offset, closeTo(0.0, 0.5));
        expect(focusedCardNode.hasFocus, isTrue);

        // Now scroll down to a lower shelf, focus a card there, open detail, and Esc back -> both scroll and focus restore.
        scroller.jumpTo(520);
        await tester.pump();
        final recentCardFinder = find.descendant(
          of: find.byKey(const Key('ev_home_section_recent')),
          matching: find.byType(EvCard),
        ).first;
        final recentFocusWidget = tester.widget<Focus>(
          find.descendant(of: recentCardFinder, matching: find.byType(Focus)).first,
        );
        final recentCardEl = tester.element(
          find.descendant(of: recentCardFinder, matching: find.byType(Focus)).first,
        );
        final recentNode = recentFocusWidget.focusNode ?? Focus.of(recentCardEl);
        recentNode.requestFocus();
        await tester.pump();
        expect(recentNode.hasFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('ev_topbar_back')), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byKey(const Key('ev_topbar_back')), findsNothing);
        expect(scroller.offset, closeTo(520.0, 1.0));
        expect(recentNode.hasFocus, isTrue);
      },
    );
  });

  group('EvPlayer.open lifecycle, duplicate guard, immersion & custom builder', () {
    EvPlayerPageBuilder? savedBuilder;

    setUp(() {
      savedBuilder = EvPlayer.pageBuilder;
      EvPlayer.pageBuilder = null;
    });

    tearDown(() {
      EvPlayer.pageBuilder = savedBuilder;
    });

    testWidgets(
      'opens minimal videoSurface, pauses immersion, ignores duplicate opens, and closes session + resumes immersion on return',
      (tester) async {
        final prefs = _FakePreferences();
        final accounts = _FakeAccounts(
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kProfileSfw,
            profiles: [_kProfileSfw],
            sessionId: 's1',
          ),
        );
        final playback = _FakePlayback();
        final immersionPlayback = _FakeImmersionPlayback();
        final shellController = EvShellController(zones: _kDefaultZones);
        addTearDown(() async {
          shellController.dispose();
          await prefs.close();
          await accounts.close();
          await immersionPlayback.close();
        });

        late BuildContext innerContext;
        await tester.pumpWidget(
          _appShell(
            EvShell(
              services: EmbyViewServices(
                preferences: prefs,
                accounts: accounts,
                sessionId: 's1',
                data: _FakeData(_kDefaultZones),
                playback: playback,
                immersion: immersionPlayback,
              ),
              controller: shellController,
              configureWindow: false,
              enableStageMotion: false,
              homeBuilder: (context) {
                innerContext = context;
                return const SizedBox.expand();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final immersion = EvScope.of(innerContext).immersion;
        expect(immersion.isPlayerActive, isFalse);
        expect(EvPlayer.isOpening, isFalse);

        // Open player & immediately fire a duplicate click while opening.
        final openFuture = EvPlayer.open(
          innerContext,
          const PlayTarget(itemId: 'item-42'),
        );
        final duplicateFuture = EvPlayer.open(
          innerContext,
          const PlayTarget(itemId: 'item-99'),
        );
        await duplicateFuture;
        await tester.pumpAndSettle();

        expect(EvPlayer.isOpening, isTrue);
        expect(immersion.isPlayerActive, isTrue);
        expect(playback.openedTargets.length, 1);
        expect(playback.openedTargets.single.itemId, 'item-42');
        expect(find.byKey(const Key('fake_player_video_item-42')), findsOneWidget);
        expect(find.byKey(const Key('ev_player_close')), findsOneWidget);

        // Close minimal player via close button -> closes session & resumes immersion.
        await tester.tap(find.byKey(const Key('ev_player_close')));
        await tester.pumpAndSettle();
        await openFuture;

        expect(playback.sessions.single.closed, isTrue);
        expect(playback.sessions.single.closeCalls, 1);
        expect(immersion.isPlayerActive, isFalse);
        expect(EvPlayer.isOpening, isFalse);
      },
    );

    testWidgets(
      'supports registered EvPlayer.pageBuilder with origin and art, and cleans up on route error',
      (tester) async {
        final playback = _FakePlayback();
        final immersion = Immersion();
        addTearDown(immersion.dispose);

        Rect? receivedOrigin;
        CardArtwork? receivedArt;
        EvPlayer.pageBuilder = (context, session, {origin, art}) {
          receivedOrigin = origin;
          receivedArt = art;
          return GestureDetector(
            key: const Key('custom_player_root'),
            onTap: () => Navigator.of(context).pop(),
            child: session.videoSurface(),
          );
        };

        late BuildContext ctx;
        await tester.pumpWidget(
          _appShell(
            EvThemeScope(
              themeMode: ThemeMode.cinema,
              child: Builder(
                builder: (context) {
                  ctx = context;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        );

        const origin = Rect.fromLTWH(100, 200, 300, 169);
        const art = CardArtwork(
          landscape: ArtworkPlan(fallbackTitle: '测试封面'),
        );

        final openFuture = EvPlayer.open(
          ctx,
          const PlayTarget(itemId: 'custom-1'),
          origin: origin,
          art: art,
          playback: playback,
          immersion: immersion,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('custom_player_root')), findsOneWidget);
        expect(receivedOrigin, origin);
        expect(receivedArt, art);
        expect(immersion.isPlayerActive, isTrue);

        await tester.tap(find.byKey(const Key('custom_player_root')));
        await tester.pumpAndSettle();
        await openFuture;

        expect(playback.sessions.single.closed, isTrue);
        expect(immersion.isPlayerActive, isFalse);
        expect(EvPlayer.isOpening, isFalse);

        // Verify cleanup if playback.open throws before route can open.
        final failingPlayback = _ThrowingPlayback();
        await expectLater(
          EvPlayer.open(
            ctx,
            const PlayTarget(itemId: 'boom'),
            playback: failingPlayback,
            immersion: immersion,
          ),
          throwsStateError,
        );
        expect(immersion.isPlayerActive, isFalse);
        expect(EvPlayer.isOpening, isFalse);
      },
    );
  });

  group('Stage 3 entry registration and GoRouter integration', () {
    test('EmbyViewRegistration constructor keeps empty defaults while global registration registers stage 3', () {
      final fresh = EmbyViewRegistration();
      expect(fresh.stageThreeHome, isNull);
      expect(fresh.stageThreeRoutes, isEmpty);

      expect(embyViewRegistration.stageThreeHome, isNotNull);
      expect(embyViewRegistration.stageThreeRoutes.length, 2);
      expect(EvPlayer.pageBuilder, isNotNull);
    });

    testWidgets('EvPlayer.open automatically routes through embyViewRegistration.stageFivePlayer', (tester) async {
      final prevStageFive = embyViewRegistration.stageFivePlayer;
      final playback = _FakePlayback();
      final immersion = Immersion();
      addTearDown(() {
        embyViewRegistration.stageFivePlayer = prevStageFive;
        immersion.dispose();
      });

      // Touch global registration to ensure stage-3 player wiring is initialized.
      expect(embyViewRegistration.stageThreeHome, isNotNull);
      Rect? receivedOrigin;
      embyViewRegistration.stageFivePlayer = (ctx, session, {origin, art}) {
        receivedOrigin = origin;
        return GestureDetector(
          key: const Key('stage5_registered_player'),
          onTap: () => Navigator.of(ctx).pop(),
          child: session.videoSurface(),
        );
      };

      late BuildContext ctx;
      await tester.pumpWidget(
        _appShell(
          EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );

      const origin = Rect.fromLTWH(10, 20, 300, 169);
      final openFuture = EvPlayer.open(
        ctx,
        const PlayTarget(itemId: 'stage5-item'),
        origin: origin,
        playback: playback,
        immersion: immersion,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stage5_registered_player')), findsOneWidget);
      expect(receivedOrigin, origin);

      await tester.tap(find.byKey(const Key('stage5_registered_player')));
      await tester.pumpAndSettle();
      await openFuture;
      expect(playback.sessions.single.closed, isTrue);
    });

    testWidgets('stageThreeHome and stageThreeRoutes render EvHomePage, EvZonePage, EvWallPage and fallback safely when signed out', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = _FakePreferences();
      final accounts = _FakeAccounts(
        const AccountSnapshot(
          phase: AccountPhase.signedIn,
          current: _kProfileSfw,
          profiles: [_kProfileSfw],
          sessionId: 'route-sess-1',
        ),
      );
      final data = _FakeData(_kDefaultZones);
      final playback = _FakePlayback();
      final immersionPlayback = _FakeImmersionPlayback();

      final entry = await tester.runAsync(() async {
        final created = EmbyViewEntry(
          preferences: prefs,
          accounts: accounts,
          createSession: (_) => EmbyViewSessionServices(
            data: data,
            playback: playback,
            immersion: immersionPlayback,
            dispose: () async {},
          ),
        );
        await created.ready;
        return created;
      });
      installEmbyViewEntry(entry);

      final router = GoRouter(
        initialLocation: embyViewHomePath,
        routes: buildEmbyViewRoutes(
          legacyHome: (_) => const Text('LEGACY_FALLBACK'),
        ),
      );
      addTearDown(() {
        router.dispose();
        installEmbyViewEntry(null);
      });

      try {
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Home route -> EvShell + EvHomePage
        expect(find.byType(EvShell), findsOneWidget);
        expect(find.byType(EvHomePage), findsOneWidget);
        final homeScope = EvScope.of(tester.element(find.byType(EvHomePage)));

        // Zone route -> /embyview/zone/movie -> shares single stage & immersion
        router.go('$embyViewHomePath/zone/movie');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(EvZonePage), findsOneWidget);
        expect(
          tester.widget<EvZonePage>(find.byType(EvZonePage)).zoneId,
          'movie',
        );
        final zoneScope = EvScope.of(tester.element(find.byType(EvZonePage)));
        expect(zoneScope.stage, same(homeScope.stage));
        expect(zoneScope.immersion, same(homeScope.immersion));

        // Wall route -> /embyview/wall?zone=movie&title=全部电影 -> shares stage & back pops via Navigator
        router.go('$embyViewHomePath/wall?zone=movie&title=全部电影');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(EvWallPage), findsOneWidget);
        final wall = tester.widget<EvWallPage>(find.byType(EvWallPage));
        expect(wall.title, '全部电影');
        expect(wall.initialQuery.scope, isA<ZoneWallScope>());
        expect((wall.initialQuery.scope as ZoneWallScope).zoneId, 'movie');
        final wallScope = EvScope.of(tester.element(find.byType(EvWallPage)));
        expect(wallScope.stage, same(homeScope.stage));

        // Tapping top-bar back on GoRouter subroute falls back to Navigator.maybePop.
        await tester.tap(find.byKey(const Key('ev_topbar_back')));
        await tester.pumpAndSettle();
        expect(find.byType(EvHomePage), findsOneWidget);

        // Navigate back to wall and verify signed out / uninstalled entry falls back safely.
        router.go('$embyViewHomePath/wall?zone=movie&title=全部电影');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        installEmbyViewEntry(null);
        await tester.pump();
        expect(find.byType(EvWallPage), findsNothing);
      } finally {
        installEmbyViewEntry(null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await entry!.close();
          entry.dispose();
          await prefs.close();
          await accounts.close();
          await immersionPlayback.close();
        });
      }
    });

    testWidgets(
      'default stage-3 EvPlayer falls back to exitable minimal player, scroll isolates body rebuilds, onImage uses 0.75 threshold, and zone errors do not fabricate zones',
      (tester) async {
        final prevStageFive = embyViewRegistration.stageFivePlayer;
        embyViewRegistration.stageFivePlayer = null;
        addTearDown(() => embyViewRegistration.stageFivePlayer = prevStageFive);

        final prefs = _FakePreferences(
          const LocalPreferences(
            theme: ThemeMode.paper,
            zones: [
              ZonePreference(
                id: 'pref_only',
                name: '不应伪造',
                iconKey: 'nav_movie',
                colorSlot: 0,
                rule: ZoneRule.library('pref_only'),
              ),
            ],
          ),
        );
        final accounts = _FakeAccounts(
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kProfileSfw,
            profiles: [_kProfileSfw],
            sessionId: 's-iso',
          ),
        );
        final playback = _FakePlayback();
        final scrollCtrl = ScrollController();
        final shellCtrl = EvShellController();
        var bodyBuilds = 0;
        var windowConfigured = 0;
        late BuildContext innerCtx;
        addTearDown(() async {
          scrollCtrl.dispose();
          shellCtrl.dispose();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(
          _appShell(
            EvShell(
              services: EmbyViewServices(
                preferences: prefs,
                accounts: accounts,
                sessionId: 's-iso',
                data: _FailingZonesData(),
                playback: playback,
              ),
              controller: shellCtrl,
              enableStageMotion: false,
              onConfigureWindow: () => windowConfigured++,
              windowDragBuilder: (_) => const SizedBox(key: Key('custom_drag_area')),
              homeBuilder: (ctx) {
                innerCtx = ctx;
                bodyBuilds++;
                return SingleChildScrollView(
                  controller: scrollCtrl,
                  child: const SizedBox(height: 2000, width: 1440),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(windowConfigured, 1);
        expect(find.byKey(const Key('custom_drag_area')), findsOneWidget);
        expect(shellCtrl.zones, isEmpty);
        expect(find.byKey(const Key('ev_topbar_tab_pref_only')), findsNothing);

        // Scroll updates EvTopBar without rebuilding home body; paper onImage stays true below 0.75.
        shellCtrl.titlePlate = const EvChromeTitlePlate(
          iconKey: 'nav_movie', title: '电影', colorSlot: 1, total: 10, unit: '部',
        );
        await tester.pump();
        final buildsBeforeScroll = bodyBuilds;

        scrollCtrl.jumpTo(40); // topFade = 0.25 < 0.75
        await tester.pump();
        expect(bodyBuilds, buildsBeforeScroll);
        expect(
          EvTheme.of(tester.element(find.byKey(const Key('ev_topbar_title_plate')))).onImage,
          isTrue,
        );

        scrollCtrl.jumpTo(140); // topFade = 0.875 >= 0.75
        await tester.pump();
        expect(bodyBuilds, buildsBeforeScroll);
        expect(
          EvTheme.of(tester.element(find.byKey(const Key('ev_topbar_title_plate')))).onImage,
          isFalse,
        );

        // Production EvPlayer.pageBuilder with stageFivePlayer == null falls back to exitable _defaultPage.
        final openFuture = EvPlayer.open(innerCtx, const PlayTarget(itemId: 'fallback-1'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_minimal_player_page')), findsOneWidget);
        expect(find.byKey(const Key('ev_player_close')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await openFuture;
        expect(playback.sessions.single.closed, isTrue);
      },
    );
  });
}

class _FailingZonesData implements EmbyViewData {
  @override
  Future<List<ZoneTile>> zones() => Future<List<ZoneTile>>.error(StateError('zones unavailable'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingPlayback implements EmbyViewPlayback {
  @override
  Future<void> prepare(String itemId, {String? mediaSourceId}) async {}

  @override
  PlaybackSession open(PlayTarget target) =>
      throw StateError('playback unavailable');
}

class _DetailFlowData extends _FakeData {
  _DetailFlowData(super.zoneList);

  static final MediaCard _cw1 = _card('cw_1', '盗梦空间');
  static final MediaCard _cw2 = _card('cw_2', '星际穿越');
  static final MediaCard _rm1 = _card('rm_1', '最近电影甲');

  @override
  Future<HomeData> home({required ShelfSort seriesSort}) async => HomeData(
    recommendations: [
      HomeRecommendation(card: _cw1, reason: RecommendationReason.daily),
    ],
    continueWatching: [
      ResumeCard(
        card: _cw1,
        target: const PlayTarget(itemId: 'cw_1', startAt: Duration(minutes: 20)),
        position: const Duration(minutes: 20),
        duration: const Duration(minutes: 148),
      ),
      ResumeCard(
        card: _cw2,
        target: const PlayTarget(itemId: 'cw_2', startAt: Duration(minutes: 45)),
        position: const Duration(minutes: 45),
        duration: const Duration(minutes: 169),
      ),
    ],
    zones: zoneList,
    recentMovies: HomeShelf(
      id: 'movie',
      title: '最近添加',
      items: [_rm1],
    ),
  );

  @override
  Future<MediaDetail> detail(String itemId) async {
    final card = switch (itemId) {
      'cw_2' => _cw2,
      'rm_1' => _rm1,
      _ => _cw1,
    };
    return MediaDetail(
      card: MediaCard(
        id: card.id,
        kind: card.kind,
        libraryId: card.libraryId,
        title: card.title,
        year: card.year,
        overview: '${card.title}详情简介',
        art: card.art,
      ),
      playTarget: PlayTarget(itemId: card.id),
    );
  }

  @override
  Future<List<PersonCredit>> people(String itemId) async => const [];

  @override
  Future<List<MediaCard>> similar(String itemId, {int limit = 16}) async => const [];

  @override
  Future<ThemeMedia> themeMedia(String itemId) async => const ThemeMedia();

  @override
  Future<MediaQuality?> quality(String itemId) async => null;
}
