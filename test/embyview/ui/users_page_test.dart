import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/home/ev_home_page.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/users/ev_users_page.dart';
import 'package:moonfin/embyview/ui/wall/ev_wall_page.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

const _kSfw = AccountProfile(id: 'sfw', displayName: 'sfw');
const _kFamily = AccountProfile(id: 'family', displayName: '家人');
const _kGuest = AccountProfile(id: 'guest', displayName: '访客');

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(this.id)
    : cacheKey = 'users_test_$id',
      image = MemoryImage(_kPngBytes);

  @override final String id;
  @override final String cacheKey;
  @override final ImageProvider<Object> image;
  @override double? get aspectRatio => 2 / 3;
  @override int? get width => 600;
  @override int? get height => 900;
}

class _FakePreferences implements EmbyViewPreferences {
  _FakePreferences([LocalPreferences initial = const LocalPreferences()]) : _current = initial;

  LocalPreferences _current;
  final _changes = StreamController<LocalPreferences>.broadcast();

  @override LocalPreferences get current => _current;
  @override Stream<LocalPreferences> get changes => _changes.stream;

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
  _FakeAccounts({AccountSnapshot? initial, this.onSwitch})
    : _snapshot = initial ??
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kSfw,
            profiles: [_kSfw, _kFamily, _kGuest],
            serverAddress: 'http://nas.local:8096',
            serverVersion: '4.10.2',
            connection: ConnectionState.connected,
            sessionId: 'sess_sfw',
          );

  AccountSnapshot _snapshot;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final Future<void> Function(String profileId, String? password)? onSwitch;

  final List<(String, String?)> switchCalls = [];
  final List<(Uri, String, String)> signInCalls = [];

  @override AccountSnapshot get snapshot => _snapshot;
  @override Stream<AccountSnapshot> get changes => _changes.stream;

  void emit(AccountSnapshot next) {
    _snapshot = next;
    _changes.add(next);
  }

  @override
  Future<void> switchTo(String profileId, {String? password}) async {
    switchCalls.add((profileId, password));
    if (onSwitch != null) {
      await onSwitch!(profileId, password);
      return;
    }
    final target = _snapshot.profiles.where((p) => p.id == profileId).firstOrNull;
    if (target == null) throw const EmbyViewFailure('未找到该用户');
    emit(AccountSnapshot(
      phase: AccountPhase.switching,
      current: _snapshot.current,
      profiles: _snapshot.profiles,
      serverAddress: _snapshot.serverAddress,
      serverVersion: _snapshot.serverVersion,
      connection: _snapshot.connection,
    ));
    emit(AccountSnapshot(
      phase: AccountPhase.signedIn,
      current: target,
      profiles: _snapshot.profiles,
      serverAddress: _snapshot.serverAddress,
      serverVersion: _snapshot.serverVersion,
      connection: _snapshot.connection,
      sessionId: 'sess_${target.id}',
    ));
  }

  @override
  Future<void> signIn(Uri server, String username, String password) async {
    signInCalls.add((server, username, password));
    final created = AccountProfile(id: username, displayName: username);
    final profiles = [..._snapshot.profiles.where((p) => p.id != created.id), created];
    emit(AccountSnapshot(
      phase: AccountPhase.signedIn,
      current: created,
      profiles: profiles,
      serverAddress: server.toString(),
      serverVersion: _snapshot.serverVersion,
      connection: ConnectionState.connected,
      sessionId: 'sess_${created.id}',
    ));
  }

  @override Future<void> restore() async {}
  @override Future<void> signOut() async {}
  Future<void> close() => _changes.close();
}

class _FakeImmersionPlayback implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast();
  @override ImmersionSnapshot get snapshot => const ImmersionSnapshot();
  @override Stream<ImmersionSnapshot> get changes => _changes.stream;
  @override Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF000000));
  @override Future<void> showMutedVideo(PreviewRef? video) async {}
  @override Future<void> playTheme(PreviewRef? song) async {}
  @override Future<void> setThemeMuted(bool muted) async {}
  @override Future<void> stop() async {}
  Future<void> close() => _changes.close();
}

MediaCard _card(String id, String title, {bool played = false, String lib = 'movie'}) {
  final ref = _FakeArtworkRef(id);
  return MediaCard(
    id: id,
    kind: MediaKind.movie,
    libraryId: lib,
    title: title,
    year: 2024,
    score: 8.5,
    genres: const ['科幻'],
    duration: const Duration(minutes: 110),
    played: played,
    art: CardArtwork(
      landscape: ArtworkPlan(layers: [ArtworkLayer(source: ref, fit: ArtworkFit.cover)], fallbackTitle: title),
      poster: ArtworkPlan(layers: [ArtworkLayer(source: ref)], fallbackTitle: title),
      stage: ArtworkPlan(layers: [ArtworkLayer(source: ref, fit: ArtworkFit.cover)], fallbackTitle: title),
      backdrops: [ref],
    ),
  );
}

class _FakeWallListing implements WallListing {
  _FakeWallListing(this.items);
  final List<MediaCard> items;

  @override
  WallInfo get info => WallInfo(total: items.length, letterOffsets: {'A': 0});

  @override
  Future<Page<MediaCard>> page({required int offset, required int limit}) async {
    final end = (offset + limit).clamp(0, items.length);
    return Page(items: offset >= items.length ? const [] : items.sublist(offset, end), total: items.length);
  }
}

class _UserFakeData implements EmbyViewData {
  _UserFakeData({required this.homeData, required this.wallItems});
  final HomeData homeData;
  final List<MediaCard> wallItems;

  @override Future<HomeData> home({required ShelfSort seriesSort}) async => homeData;
  @override Future<List<ZoneTile>> zones() async => homeData.zones;
  @override Future<WallListing> openWall(WallQuery query) async => _FakeWallListing(wallItems);
  @override Future<WallFacets> wallFacets(WallQuery query) async => const WallFacets();
  @override Future<ThemeMedia> themeMedia(String itemId) async => const ThemeMedia();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HomeData _buildUserHome({
  required String heroId,
  required String heroTitle,
  required String resumeId,
  required String resumeTitle,
  required String recentId,
  required String recentTitle,
}) {
  const zones = [ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 2, unit: '部')];
  final heroCard = _card(heroId, heroTitle);
  final resumeCard = _card(resumeId, resumeTitle);
  final recentCard = _card(recentId, recentTitle);
  return HomeData(
    recommendations: [HomeRecommendation(card: heroCard, reason: RecommendationReason.daily)],
    continueWatching: [
      ResumeCard(
        card: resumeCard,
        position: const Duration(minutes: 40),
        duration: const Duration(minutes: 100),
        target: PlayTarget(itemId: resumeId),
      ),
    ],
    zones: zones,
    recentMovies: HomeShelf(id: 'recent_movies', title: '电影', items: [recentCard]),
  );
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<({EvStageController stage, EvShellController shell, Immersion immersion})> _pumpUsersPage(
  WidgetTester tester, {
  required _FakeAccounts accounts,
  required _FakePreferences prefs,
  Size viewport = const Size(1440, 900),
  ValueChanged<AccountProfile>? onSelected,
  VoidCallback? onManageUsers,
  VoidCallback? onAddUser,
  VoidCallback? onOpenSettings,
}) async {
  await _setViewport(tester, viewport);
  final stage = EvStageController();
  final services = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: accounts.snapshot.sessionId);
  final immersion = Immersion(stage: stage, services: services);
  final shell = EvShellController(onOpenSettings: onOpenSettings);
  addTearDown(() {
    immersion.dispose();
    stage.dispose();
    shell.dispose();
  });

  await tester.pumpWidget(
    WidgetsApp(
      color: const Color(0xFF09090B),
      pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: services,
          stage: stage,
          immersion: immersion,
          shell: shell,
          child: ColoredBox(
            color: const Color(0xFF09090B),
            child: EvUsersPage(onSelected: onSelected, onManageUsers: onManageUsers, onAddUser: onAddUser),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (stage: stage, shell: shell, immersion: immersion);
}

void main() {
  testWidgets('C4.7 renders multi-user list in cinema & paper themes at 1440x900 and 2560x1440 without overflow', (tester) async {
    for (final themeMode in [ThemeMode.cinema, ThemeMode.paper]) {
      for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
        final prefs = _FakePreferences(LocalPreferences(theme: themeMode));
        final accounts = _FakeAccounts();
        addTearDown(() async { await prefs.close(); await accounts.close(); });

        final env = await _pumpUsersPage(tester, accounts: accounts, prefs: prefs, viewport: size);
        expect(tester.takeException(), isNull, reason: 'No overflow at $themeMode $size');
        expect(env.stage.mode, EvStageMode.ambient);
        expect(find.byKey(const Key('ev_users_title')), findsOneWidget);
        expect(find.text('谁在看？'), findsOneWidget);
        expect(find.byKey(const Key('ev_users_profile_sfw')), findsOneWidget);
        expect(find.byKey(const Key('ev_users_profile_family')), findsOneWidget);
        expect(find.byKey(const Key('ev_users_profile_guest')), findsOneWidget);
        expect(find.byKey(const Key('ev_users_current_sfw')), findsOneWidget);
        expect(find.byKey(const Key('ev_users_current_family')), findsNothing);
        expect(find.byKey(const Key('ev_users_add_btn')), findsOneWidget);
        expect(find.byKey(const Key('ev_users_manage_btn')), findsOneWidget);
        expect(find.byType(EvAvatarButton), findsNWidgets(3));

        final titleText = tester.widget<Text>(find.byKey(const Key('ev_users_title')));
        if (themeMode == ThemeMode.paper) {
          expect(titleText.style?.fontFamily, 'Anthropic Serif');
          final icons = tester.widgetList<EvIcon>(find.descendant(of: find.byType(EvAvatarButton), matching: find.byType(EvIcon))).toList();
          expect(icons, hasLength(3));
          expect(icons.every((i) => i.forcePaper == true), isTrue);
          expect(icons.map((i) => i.icon), [EvIcons.faceSfw, EvIcons.faceFamily, EvIcons.faceGuest]);
        } else {
          expect(titleText.style?.fontFamily, 'SF Pro Display');
        }
      }
    }
  });

  testWidgets('keyboard navigation (ArrowRight + Enter/Space) and clicking current profile work', (tester) async {
    final prefs = _FakePreferences();
    final accounts = _FakeAccounts();
    addTearDown(() async { await prefs.close(); await accounts.close(); });

    final selected = <AccountProfile>[];
    await _pumpUsersPage(tester, accounts: accounts, prefs: prefs, onSelected: selected.add);

    // Tapping current logged-in profile invokes onSelected directly without switchTo.
    await tester.tap(find.byKey(const Key('ev_users_profile_sfw')));
    await tester.pumpAndSettle();
    expect(accounts.switchCalls, isEmpty);
    expect(selected.map((p) => p.id), ['sfw']);

    // Focus sfw, press ArrowRight to focus family, then press Enter to switch.
    final sfwFocus = tester.widget<Focus>(find.descendant(of: find.byKey(const Key('ev_users_profile_sfw')), matching: find.byType(Focus)));
    FocusScope.of(tester.element(find.byKey(const Key('ev_users_profile_sfw')))).requestFocus();
    await tester.pump();
    // Request focus directly on sfw's Focus descendant node.
    final sfwNode = Focus.of(tester.element(find.descendant(of: find.byKey(const Key('ev_users_profile_sfw')), matching: find.byType(MouseRegion))));
    expect(sfwFocus.canRequestFocus, isTrue);
    sfwNode.requestFocus();
    await tester.pump();
    expect(sfwNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final familyNode = Focus.of(tester.element(find.descendant(of: find.byKey(const Key('ev_users_profile_family')), matching: find.byType(MouseRegion))));
    expect(familyNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(accounts.switchCalls, [('family', null)]);
    expect(selected.map((p) => p.id), ['sfw', 'family']);
    expect(find.byKey(const Key('ev_users_current_family')), findsOneWidget);
  });

  testWidgets('shows switching status, handles failure + retry, password form, add-user form, and manage callbacks', (tester) async {
    final prefs = _FakePreferences();
    final switchCompleter = Completer<void>();
    var failMode = 'network';
    late _FakeAccounts accounts;
    accounts = _FakeAccounts(
      onSwitch: (id, password) async {
        if (failMode == 'pending') {
          await switchCompleter.future;
          accounts.emit(AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: _kFamily,
            profiles: accounts.snapshot.profiles,
            serverAddress: accounts.snapshot.serverAddress,
            sessionId: 'sess_family',
          ));
          return;
        }
        if (failMode == 'network') throw const EmbyViewFailure('网络连接失败，请重试。', retryable: true);
        if (failMode == 'password' && password != 'secret') {
          throw const EmbyViewFailure('该用户需要密码验证', code: 'password_required');
        }
        accounts.emit(AccountSnapshot(
          phase: AccountPhase.signedIn,
          current: _kFamily,
          profiles: accounts.snapshot.profiles,
          serverAddress: accounts.snapshot.serverAddress,
          sessionId: 'sess_family_pw',
        ));
      },
    );
    addTearDown(() async { await prefs.close(); await accounts.close(); });

    var manageCalls = 0, settingsFallbackCalls = 0, addCalls = 0;
    final selected = <AccountProfile>[];

    // 1) Explicit onManageUsers and onAddUser callbacks.
    await _pumpUsersPage(
      tester,
      accounts: accounts,
      prefs: prefs,
      onSelected: selected.add,
      onManageUsers: () => manageCalls++,
      onAddUser: () => addCalls++,
      onOpenSettings: () => settingsFallbackCalls++,
    );
    await tester.tap(find.byKey(const Key('ev_users_manage_btn')));
    await tester.tap(find.byKey(const Key('ev_users_add_btn')));
    await tester.pump();
    expect(manageCalls, 1);
    expect(settingsFallbackCalls, 0);
    expect(addCalls, 1);

    // 2) Switch failure displays error and retry works; password_required opens obscured password EditableText.
    await tester.tap(find.byKey(const Key('ev_users_profile_family')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_users_error')), findsOneWidget);
    expect(find.text('网络连接失败，请重试。'), findsOneWidget);

    failMode = 'password';
    await tester.tap(find.byKey(const Key('ev_users_retry_btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_users_password_form')), findsOneWidget);
    final pwEditable = tester.widget<EditableText>(
      find.descendant(of: find.byKey(const Key('ev_users_password_field')), matching: find.byType(EditableText)),
    );
    expect(pwEditable.obscureText, isTrue);

    await tester.enterText(find.descendant(of: find.byKey(const Key('ev_users_password_field')), matching: find.byType(EditableText)), 'secret');
    await tester.tap(find.byKey(const Key('ev_users_form_submit_btn')));
    await tester.pumpAndSettle();
    expect(accounts.switchCalls.last, ('family', 'secret'));
    expect(selected.last.id, 'family');
    expect(find.byKey(const Key('ev_users_error')), findsNothing);
    expect(find.byKey(const Key('ev_users_password_form')), findsNothing);

    // 3) Fallback to shell.onOpenSettings + built-in inline sign-in form + in-flight status.
    accounts.emit(const AccountSnapshot(
      phase: AccountPhase.signedIn,
      current: _kSfw,
      profiles: [_kSfw, _kFamily],
      serverAddress: 'http://nas.local:8096',
      sessionId: 'sess_sfw_2',
    ));
    await _pumpUsersPage(tester, accounts: accounts, prefs: prefs, onSelected: selected.add, onOpenSettings: () => settingsFallbackCalls++);
    await tester.tap(find.byKey(const Key('ev_users_manage_btn')));
    await tester.pump();
    expect(settingsFallbackCalls, 1);

    // Switching in-flight shows status hint.
    failMode = 'pending';
    await tester.tap(find.byKey(const Key('ev_users_profile_family')));
    await tester.pump();
    expect(find.byKey(const Key('ev_users_status')), findsOneWidget);
    expect(find.text('正在切换至 家人…'), findsOneWidget);
    switchCompleter.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_users_status')), findsNothing);

    // Inline add-user signIn form submits URI + user + obscured password.
    await tester.tap(find.byKey(const Key('ev_users_add_btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_users_signin_form')), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byKey(const Key('ev_users_username_field')), matching: find.byType(EditableText)), 'kids');
    await tester.enterText(find.descendant(of: find.byKey(const Key('ev_users_password_field')), matching: find.byType(EditableText)), '1234');
    await tester.tap(find.byKey(const Key('ev_users_form_submit_btn')));
    await tester.pumpAndSettle();
    expect(accounts.signInCalls, [(Uri.parse('http://nas.local:8096'), 'kids', '1234')]);
    expect(selected.last.id, 'kids');
  });

  testWidgets('subscribes to accounts.changes and clears stale error & highlight on external switch', (tester) async {
    final prefs = _FakePreferences();
    final accounts = _FakeAccounts(onSwitch: (_, _) async => throw const EmbyViewFailure('临时故障'));
    addTearDown(() async { await prefs.close(); await accounts.close(); });

    await _pumpUsersPage(tester, accounts: accounts, prefs: prefs);
    await tester.tap(find.byKey(const Key('ev_users_profile_family')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_users_error')), findsOneWidget);

    accounts.emit(const AccountSnapshot(
      phase: AccountPhase.signedIn,
      current: _kFamily,
      profiles: [_kSfw, _kFamily, _kGuest],
      sessionId: 'sess_family_ext',
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_users_error')), findsNothing);
    expect(find.byKey(const Key('ev_users_current_family')), findsOneWidget);
    expect(find.byKey(const Key('ev_users_current_sfw')), findsNothing);
  });

  testWidgets('C4.7 integration: switching from sfw to family via EvUsersPage updates EvShell + EvHomePage + EvWallPage with zero stale data', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final prefs = _FakePreferences();
    final accounts = _FakeAccounts();
    final immersionPlayback = _FakeImmersionPlayback();
    addTearDown(() async {
      await prefs.close();
      await accounts.close();
      await immersionPlayback.close();
    });

    final dataByUser = <String, _UserFakeData>{
      'sfw': _UserFakeData(
        homeData: _buildUserHome(
          heroId: 'sfw_hero', heroTitle: 'SFW 专属推荐',
          resumeId: 'sfw_res', resumeTitle: 'SFW 继续观看片',
          recentId: 'sfw_rec', recentTitle: 'SFW 最近电影',
        ),
        wallItems: [
          _card('shared_a', '星际穿越', played: true),
          _card('shared_b', '盗梦空间', played: false),
          _card('sfw_only', 'SFW 独占片', played: true),
        ],
      ),
      'family': _UserFakeData(
        homeData: _buildUserHome(
          heroId: 'fam_hero', heroTitle: '家人专属推荐',
          resumeId: 'fam_res', resumeTitle: '家人继续观看片',
          recentId: 'fam_rec', recentTitle: '家人最近电影',
        ),
        wallItems: [
          _card('shared_a', '星际穿越', played: false),
          _card('shared_b', '盗梦空间', played: true),
          _card('fam_only', '家人独占片', played: false),
        ],
      ),
    };

    final shellController = EvShellController();
    addTearDown(shellController.dispose);
    var showUsers = false;

    late StateSetter hostSetState;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF09090B),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
        home: StatefulBuilder(
          builder: (context, setState) {
            hostSetState = setState;
            return StreamBuilder<AccountSnapshot>(
              stream: accounts.changes,
              initialData: accounts.snapshot,
              builder: (_, snap) {
                final account = snap.data ?? accounts.snapshot;
                final uid = account.current?.id ?? 'sfw';
                final services = EmbyViewServices(
                  preferences: prefs,
                  accounts: accounts,
                  sessionId: account.sessionId,
                  data: dataByUser[uid],
                  immersion: immersionPlayback,
                );
                shellController.onOpenUsers = () => setState(() => showUsers = true);
                return EvShell(
                  services: services,
                  controller: shellController,
                  configureWindow: false,
                  enableStageMotion: false,
                  homeBuilder: (_) => showUsers
                      ? EvUsersPage(onSelected: (_) => setState(() => showUsers = false))
                      : const EvHomePage(enableAnimations: false),
                  wallBuilder: (_, query, title) => EvWallPage(initialQuery: query, title: title),
                );
              },
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify sfw Home data.
    expect(find.text('SFW 专属推荐'), findsOneWidget);
    expect(find.text('SFW 继续观看片'), findsOneWidget);
    expect(find.text('家人专属推荐'), findsNothing);

    // Open Wall for sfw: 星际穿越 watched (check icon), 盗梦空间 unwatched, SFW 独占片 present.
    const wallQuery = (
      scope: ZoneWallScope('movie'),
      sort: WallSort.title,
      watched: WatchFilter.all,
      genreId: null,
      years: null,
      technology: null,
    );
    shellController.openWall(wallQuery, title: '电影');
    await tester.pumpAndSettle();

    Finder cardByTitle(String title) => find.ancestor(of: find.text(title), matching: find.byType(EvCard));
    bool hasSeenCheck(String title) => tester
        .widgetList<EvIcon>(find.descendant(of: cardByTitle(title), matching: find.byType(EvIcon)))
        .any((icon) => icon.icon == EvIcons.check);

    expect(find.text('SFW 独占片'), findsOneWidget);
    expect(find.text('家人独占片'), findsNothing);
    expect(hasSeenCheck('星际穿越'), isTrue);
    expect(hasSeenCheck('盗梦空间'), isFalse);

    // Go back home and open EvUsersPage to switch from sfw to family.
    shellController.goHome();
    hostSetState(() => showUsers = true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_users_page')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ev_users_profile_family')));
    await tester.pumpAndSettle();
    expect(accounts.switchCalls, [('family', null)]);
    expect(accounts.snapshot.sessionId, 'sess_family');

    // Home page now shows ONLY family data, zero sfw residue.
    expect(find.text('家人专属推荐'), findsOneWidget);
    expect(find.text('家人继续观看片'), findsOneWidget);
    expect(find.text('SFW 专属推荐'), findsNothing);
    expect(find.text('SFW 继续观看片'), findsNothing);

    // Open Wall for family: watched marks flipped and SFW-only item gone!
    shellController.openWall(wallQuery, title: '电影');
    await tester.pumpAndSettle();
    expect(find.text('家人独占片'), findsOneWidget);
    expect(find.text('SFW 独占片'), findsNothing);
    expect(hasSeenCheck('星际穿越'), isFalse);
    expect(hasSeenCheck('盗梦空间'), isTrue);
  });
}
