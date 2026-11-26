import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/entry.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_page.dart';
import 'package:moonfin/embyview/ui/home/ev_home_page.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/search/ev_search_page.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_page.dart';
import 'package:moonfin/embyview/ui/users/ev_users_page.dart';
import 'package:moonfin/embyview/ui/wall/ev_wall_page.dart';
import 'package:moonfin/embyview/ui/zone/ev_zone_page.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

const _kAlice = AccountProfile(id: 'alice', displayName: 'Alice');
const _kBob = AccountProfile(id: 'bob', displayName: 'Bob');

const _kDefaultZonePrefs = [
  ZonePreference(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 0, rule: ZoneRule.library('movie'), custom: false),
  ZonePreference(id: 'tv', name: '剧集', iconKey: 'nav_tv', colorSlot: 1, rule: ZoneRule.library('tv'), custom: false),
];

class _FakeArt implements ArtworkRef {
  _FakeArt(this.id, {this.aspectRatio = 16 / 9, this.width = 1920, this.height = 1080})
    : cacheKey = 's4_$id',
      image = MemoryImage(_kPngBytes);
  @override final String id, cacheKey;
  @override final ImageProvider<Object> image;
  @override final double? aspectRatio;
  @override final int? width, height;
}

class _FakePreview implements PreviewRef {
  const _FakePreview(this.id, this.name);
  @override final String id, name;
  @override Duration? get duration => const Duration(seconds: 30);
}

MediaCard _card(
  String id,
  String title, {
  MediaKind kind = MediaKind.movie,
  String libraryId = 'movie',
  int year = 2024,
  double score = 8.8,
  String overview = '深度整合测试剧情简介内容。',
  MediaQuality? quality,
  int? childCount,
}) {
  final bg = _FakeArt('bg_$id');
  final poster = _FakeArt('p_$id', aspectRatio: 2 / 3, width: 600, height: 900);
  return MediaCard(
    id: id, kind: kind, libraryId: libraryId, title: title, year: year, score: score,
    genres: const ['科幻'], duration: const Duration(minutes: 120), overview: overview,
    quality: quality, childCount: childCount,
    art: CardArtwork(
      landscape: ArtworkPlan(layers: [ArtworkLayer(source: bg, fit: ArtworkFit.cover)], fallbackTitle: title),
      poster: ArtworkPlan(layers: [ArtworkLayer(source: poster)], fallbackTitle: title),
      stage: ArtworkPlan(layers: [ArtworkLayer(source: bg, fit: ArtworkFit.cover)], fallbackTitle: title),
      backdrops: [bg],
    ),
  );
}

class _FakePrefs implements EmbyViewPreferences {
  _FakePrefs([LocalPreferences? initial])
    : _current = initial ?? const LocalPreferences(zones: _kDefaultZonePrefs, detailTrailerDelay: null);
  LocalPreferences _current;
  final _changes = StreamController<LocalPreferences>.broadcast();

  @override LocalPreferences get current => _current;
  @override Stream<LocalPreferences> get changes => _changes.stream;

  @override
  Future<void> update(LocalPreferences value) async {
    _current = value;
    _changes.add(value);
  }

  @override
  Future<void> saveZone(ZonePreference zone) async {
    final next = [for (final z in _current.zones) if (z.id != zone.id) z, zone];
    await update(_copyPrefs(_current, zones: next));
  }

  @override
  Future<void> removeCustomZone(String zoneId) async {
    await update(_copyPrefs(_current, zones: [for (final z in _current.zones) if (z.id != zoneId) z]));
  }

  @override
  Future<void> reorderZones(List<String> ids) async {
    final byId = {for (final z in _current.zones) z.id: z};
    await update(_copyPrefs(_current, zones: [for (final id in ids) if (byId[id] != null) byId[id]!]));
  }

  @override
  Future<void> resetZones() => update(_copyPrefs(_current, zones: _kDefaultZonePrefs));

  @override Future<Set<SecretKind>> configuredSecrets() async => const {SecretKind.openSubtitles};
  @override Future<void> setSecret(SecretKind kind, String? value) async {}
  @override Future<MediaFolderStatus> mediaFolderStatus() async => const MediaFolderStatus(state: MediaFolderState.unconfigured);
  @override Future<bool> authorizeMediaFolder({required String embyRoot}) async => false;

  Future<void> close() => _changes.close();
}

LocalPreferences _copyPrefs(LocalPreferences b, {List<ZonePreference>? zones}) => LocalPreferences(
  theme: b.theme, navigation: b.navigation, seriesSort: b.seriesSort, chooseUserOnStartup: b.chooseUserOnStartup,
  backgroundVideo: b.backgroundVideo, backgroundVideoDelay: b.backgroundVideoDelay, detailTrailerDelay: b.detailTrailerDelay,
  themeMusic: b.themeMusic, themeVolume: b.themeVolume, quickLook: b.quickLook, hideUnwatchedOverview: b.hideUnwatchedOverview,
  preResolve115: b.preResolve115, readAheadBytes: b.readAheadBytes, autoPlayNext: b.autoPlayNext,
  anime4kForAnime: b.anime4kForAnime, anime4kForOther: b.anime4kForOther, subtitleLanguages: b.subtitleLanguages,
  autoSelectChineseSubtitle: b.autoSelectChineseSubtitle, subtitleSources: b.subtitleSources,
  translationBaseUrl: b.translationBaseUrl, translationModel: b.translationModel, monthlyBudgetMicros: b.monthlyBudgetMicros,
  mediaFolder: b.mediaFolder, zones: zones ?? b.zones,
);

class _FakeAccounts implements EmbyViewAccounts {
  _FakeAccounts({AccountProfile current = _kAlice, String sessionId = 'sess-alice'})
    : _snapshot = AccountSnapshot(
        phase: AccountPhase.signedIn,
        current: current,
        profiles: const [_kAlice, _kBob],
        sessionId: sessionId,
        serverAddress: 'https://emby.test',
      );
  AccountSnapshot _snapshot;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  int _seq = 1;

  @override AccountSnapshot get snapshot => _snapshot;
  @override Stream<AccountSnapshot> get changes => _changes.stream;

  @override
  Future<void> switchTo(String profileId, {String? password}) async {
    final target = _snapshot.profiles.firstWhere((p) => p.id == profileId);
    _snapshot = AccountSnapshot(
      phase: AccountPhase.switching, current: _snapshot.current, profiles: _snapshot.profiles,
      serverAddress: _snapshot.serverAddress,
    );
    _changes.add(_snapshot);
    await Future<void>.microtask(() {});
    _snapshot = AccountSnapshot(
      phase: AccountPhase.signedIn, current: target, profiles: _snapshot.profiles,
      sessionId: 'sess-${target.id}-${++_seq}',
      serverAddress: _snapshot.serverAddress,
    );
    _changes.add(_snapshot);
  }

  Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlaybackSession implements PlaybackSession {
  _FakePlaybackSession(this.target);
  final PlayTarget target;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();
  bool closed = false;
  @override PlaybackSnapshot get snapshot => PlaybackSnapshot(generation: 1, target: target);
  @override Stream<PlaybackSnapshot> get changes => _changes.stream;
  @override Widget videoSurface({Key? key}) => ColoredBox(key: key ?? const Key('fake_player_surface'), color: const Color(0xFF000000));
  @override Future<void> close() async { closed = true; await _changes.close(); }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayback implements EmbyViewPlayback {
  final List<String> preparedIds = [];
  final List<PlayTarget> openedTargets = [];
  @override Future<void> prepare(String itemId) async => preparedIds.add(itemId);
  @override PlaybackSession open(PlayTarget target) {
    openedTargets.add(target);
    return _FakePlaybackSession(target);
  }
}

class _FakeImmersion implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast();
  ImmersionSnapshot _snapshot = const ImmersionSnapshot();
  final List<PreviewRef?> playedThemes = [];
  final List<PreviewRef?> shownVideos = [];

  @override ImmersionSnapshot get snapshot => _snapshot;
  @override Stream<ImmersionSnapshot> get changes => _changes.stream;
  @override Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF101820));

  @override
  Future<void> playTheme(PreviewRef? song) async {
    playedThemes.add(song);
    _snapshot = ImmersionSnapshot(theme: song == null ? PreviewState.idle : PreviewState.ready, video: _snapshot.video);
    _changes.add(_snapshot);
  }

  @override
  Future<void> showMutedVideo(PreviewRef? video) async {
    shownVideos.add(video);
    _snapshot = ImmersionSnapshot(theme: _snapshot.theme, video: video == null ? PreviewState.idle : PreviewState.ready);
    _changes.add(_snapshot);
  }

  @override Future<void> setThemeMuted(bool muted) async {}
  @override Future<void> stop() async { _snapshot = const ImmersionSnapshot(); _changes.add(_snapshot); }
  Future<void> close() => _changes.close();
}

class _FakeWallListing implements WallListing {
  _FakeWallListing(this.items);
  final List<MediaCard> items;
  @override WallInfo get info => WallInfo(total: items.length);
  @override
  Future<Page<MediaCard>> page({required int offset, required int limit}) async =>
      Page(items: offset == 0 ? items : const [], total: items.length);
}

class _FakeData implements EmbyViewData {
  _FakeData(this.prefs, {this.owner = 'alice'});
  final EmbyViewPreferences prefs;
  final String owner;

  late final MediaCard heroCard = _card('${owner}_hero', '$owner 首页主推');
  late final MediaCard seriesCard = _card('s1', '星际剧集', kind: MediaKind.series, libraryId: 'tv', childCount: 1);
  late final MediaCard movieCard = _card('m1', '星际穿越', libraryId: 'movie');
  late final MediaCard similarCard = _card('m2', '沙丘续章', libraryId: 'movie');
  late final MediaCard dvCard = _card('dv1', '杜比视界示范片', libraryId: 'movie',
      quality: const MediaQuality(resolution: '4K', videoRange: '杜比视界', audioLabel: 'Atmos'));
  late final MediaCard ep1Card = _card('ep1', '第一集 启程', kind: MediaKind.episode, libraryId: 'tv', overview: '飞船起航。');

  List<ZoneTile> _buildTiles() => [
    for (final z in prefs.current.zones)
      ZoneTile(
        id: z.id, name: z.name, iconKey: z.iconKey, colorSlot: z.colorSlot,
        total: z.custom ? 12 : 42, unit: '部',
        representative: z.custom ? dvCard : movieCard,
      ),
  ];

  @override Future<List<ZoneTile>> zones() async => _buildTiles();

  @override
  Future<HomeData> home({required ShelfSort seriesSort}) async => HomeData(
    recommendations: [HomeRecommendation(card: heroCard, reason: RecommendationReason.daily)],
    zones: _buildTiles(),
    recentMovies: HomeShelf(id: 'movies', title: '$owner 最近电影', items: [seriesCard, movieCard]),
  );

  @override
  Future<ZoneData> zone(String zoneId) async {
    final pref = prefs.current.zones.where((z) => z.id == zoneId).firstOrNull;
    final isCustom = pref?.custom ?? false;
    final tile = _buildTiles().where((z) => z.id == zoneId).firstOrNull ??
        ZoneTile(id: zoneId, name: zoneId, iconKey: 'star', colorSlot: 4, total: 12, unit: '部', representative: dvCard);
    final items = isCustom ? [dvCard] : [movieCard, similarCard];
    return ZoneData(
      zone: tile,
      all: (scope: WallScope.zone(tile.id), sort: WallSort.title, watched: WatchFilter.all, genreId: null, years: null, technology: null),
      recommendations: [HomeRecommendation(card: items.first, reason: RecommendationReason.daily)],
      latest: HomeShelf(id: 'z_${tile.id}_s', title: '${tile.name}内容', items: items),
    );
  }

  @override
  Future<WallListing> openWall(WallQuery query) async => _FakeWallListing([movieCard, similarCard]);

  @override Future<WallFacets> wallFacets(WallQuery query) async => const WallFacets();

  @override
  Future<MediaDetail> detail(String itemId) async {
    final card = switch (itemId) {
      's1' => seriesCard,
      'm2' => similarCard,
      'dv1' => dvCard,
      'ep1' => ep1Card,
      _ => movieCard,
    };
    return MediaDetail(card: card, tagline: '${card.title} 标语');
  }

  @override Future<List<PersonCredit>> people(String itemId) async => const [];
  @override Future<List<MediaCard>> similar(String itemId, {int limit = 16}) async => itemId == 'm2' ? [movieCard] : [similarCard];
  @override Future<ThemeMedia> themeMedia(String itemId) async => ThemeMedia(songs: [_FakePreview('theme_$itemId', '主题曲 $itemId')]);
  @override Future<MediaQuality?> quality(String itemId) async => const MediaQuality(resolution: '4K', origin: MediaOrigin.nasLocal);
  @override Future<List<SeasonSummary>> seasons(String seriesId) async => const [SeasonSummary(id: 'season1', number: 1, name: '第 1 季', total: 1)];
  @override Future<List<SafeEpisodeStill>> safeEpisodeStills(String seriesId) async => const [];
  @override
  Future<SeasonEpisodes> episodes(String seriesId, String seasonId) async => SeasonEpisodes(
    season: const SeasonSummary(id: 'season1', number: 1, name: '第 1 季', total: 1),
    episodes: [EpisodeCard(card: ep1Card, episodeNumber: 1, played: false, resumePosition: const Duration(minutes: 5), still: ep1Card.art.landscape)],
    playedCount: 0,
  );

  @override
  Future<SearchLanding> searchLanding({String? zoneId}) async => SearchLanding(
    recentTerms: const ['星际'],
    shelves: [HomeShelf(id: 'sl', title: '大家在看', items: [movieCard])],
  );

  @override
  Future<SearchResults> search(String query, {String? zoneId, int offset = 0, int limit = 20}) async => SearchResults(
    bestMatch: movieCard,
    groups: [SearchGroup(libraryId: 'movie', name: '电影', items: [movieCard, similarCard], total: 2)],
    total: 2,
  );

  @override Future<Page<ResumeCard>> continueWatching({String? zoneId, int offset = 0, int limit = 20}) async => const Page(items: [], total: 0);
  @override Future<MediaCard?> randomInZone(String zoneId) async => movieCard;

  @override
  Future<ZoneFacets> customZoneFacets() async => const ZoneFacets(
    genres: [FacetOption(value: 'scifi', label: '科幻', count: 18)],
    technologies: [
      FacetOption(value: TechFilter.dolbyVision, label: '杜比视界', count: 12),
      FacetOption(value: TechFilter.uhd4k, label: '4K', count: 30),
    ],
    libraries: [FacetOption(value: 'movie', label: '电影', count: 42)],
  );

  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _setViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpFrames(WidgetTester tester, [int ms = 120]) async {
  await tester.pump();
  await tester.pump(Duration(milliseconds: ms));
}

Future<void> _sendCmdKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await _pumpFrames(tester);
}

Future<void> _focusWidget(WidgetTester tester, Finder finder) async {
  final target = find.descendant(of: finder, matching: find.byType(MouseRegion)).first;
  Focus.of(tester.element(target)).requestFocus();
  await tester.pump();
}

Widget _appShell(Widget child) => WidgetsApp(
  color: const Color(0xFF0A0A0D),
  pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
      PageRouteBuilder<T>(settings: settings, pageBuilder: (ctx, _, _) => builder(ctx)),
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('1. GoRouter stageFourRoutes registers and navigates directly to detail, search, settings, and users', (tester) async {
    await _setViewport(tester);
    expect(embyViewRegistration.stageThreeRoutes.length, 2);
    expect(
      embyViewRegistration.stageFourRoutes.map((r) => (r as GoRoute).path).toList(),
      ['detail/:itemId', 'search', 'settings', 'users'],
    );

    final prefs = _FakePrefs();
    final accounts = _FakeAccounts();
    final data = _FakeData(prefs);
    final playback = _FakePlayback();
    final immersion = _FakeImmersion();
    final entry = await tester.runAsync(() async {
      final created = EmbyViewEntry(
        preferences: prefs, accounts: accounts,
        createSession: (_) => EmbyViewSessionServices(data: data, playback: playback, immersion: immersion, dispose: () async {}),
      );
      await created.ready;
      return created;
    });
    installEmbyViewEntry(entry);

    final router = GoRouter(
      initialLocation: '$embyViewHomePath/detail/m1',
      routes: buildEmbyViewRoutes(legacyHome: (_) => const Text('LEGACY')),
    );

    try {
      await tester.pumpWidget(WidgetsApp.router(color: const Color(0xFF0A0A0D), routerConfig: router));
      await _pumpFrames(tester, 200);

      // detail/:itemId
      expect(find.byType(EvDetailPage), findsOneWidget);
      expect(tester.widget<EvDetailPage>(find.byType(EvDetailPage)).itemId, 'm1');
      final detailTopBar = tester.widget<EvTopBar>(find.byType(EvTopBar));
      expect(detailTopBar.hideTabs, isTrue);
      expect(detailTopBar.hideAvatar, isTrue);
      expect(detailTopBar.showBack, isTrue);

      // search?zone=movie&q=星际
      router.go('$embyViewHomePath/search?zone=movie&q=%E6%98%9F%E9%99%85');
      await _pumpFrames(tester, 250);
      expect(find.byType(EvSearchPage), findsOneWidget);
      final searchWidget = tester.widget<EvSearchPage>(find.byType(EvSearchPage));
      expect(searchWidget.zoneId, 'movie');
      expect(searchWidget.initialQuery, '星际');
      final searchTopBar = tester.widget<EvTopBar>(find.byType(EvTopBar));
      expect(searchTopBar.activeTabId, 'search');
      expect(searchTopBar.showSearchTab, isTrue);
      expect(searchTopBar.showBack, isTrue);
      expect(find.byKey(const Key('ev_search_results')), findsOneWidget);

      // settings?section=zones&zedit=1
      router.go('$embyViewHomePath/settings?section=zones&zedit=1');
      await _pumpFrames(tester, 200);
      expect(find.byType(EvSettingsPage), findsOneWidget);
      final settingsTopBar = tester.widget<EvTopBar>(find.byType(EvTopBar));
      expect(settingsTopBar.activeTabId, isNull);
      expect(settingsTopBar.showSearchTab, isTrue);
      expect(settingsTopBar.showBack, isTrue);
      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsOneWidget);

      // users (topbar hidden; 管理用户 opens settings account)
      router.go('$embyViewHomePath/users');
      await _pumpFrames(tester, 200);
      expect(find.byType(EvUsersPage), findsOneWidget);
      expect(find.byType(EvTopBar), findsNothing);

      await tester.tap(find.byKey(const Key('ev_users_manage_btn')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvSettingsPage), findsOneWidget);
      expect(tester.widget<EvSettingsPage>(find.byType(EvSettingsPage)).initialSection, EvSettingsSection.account);
    } finally {
      router.dispose();
      installEmbyViewEntry(null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await entry!.close(); entry.dispose();
        await prefs.close(); await accounts.close(); await immersion.close();
      });
    }
  });

  testWidgets('2. Home -> Detail -> Similar Detail -> Back -> Back restores stage, Home state, and calls prepare & theme', (tester) async {
    await _setViewport(tester);
    final prefs = _FakePrefs();
    final accounts = _FakeAccounts();
    final data = _FakeData(prefs);
    final playback = _FakePlayback();
    final immersion = _FakeImmersion();
    final services = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 'sess-detail-flow',
      data: data, playback: playback, immersion: immersion,
    );

    try {
      expect(embyViewRegistration.stageFivePlayer, isNotNull);
      await tester.pumpWidget(_appShell(buildStageFourTestShell(services: services)));
      await _pumpFrames(tester, 200);

      expect(find.byType(EvHomePage), findsOneWidget);
      final scope = EvScope.of(tester.element(find.byType(EvHomePage)));
      final homeBackdropKey = scope.stage.activeBackdropKey;
      expect(scope.stage.mode, EvStageMode.hero);
      expect(homeBackdropKey, contains('s4_bg_alice_hero'));

      // Tap series card 's1' on Home
      final s1Card = find.byWidgetPredicate((w) => w is EvCard && w.card.id == 's1');
      await tester.ensureVisible(s1Card);
      await _pumpFrames(tester, 100);
      await tester.tap(s1Card);
      await _pumpFrames(tester, 200);

      // Verify Detail #1, top bar, prepare, theme, single active EvStage, Home kept offstage
      expect(find.byType(EvDetailPage), findsOneWidget);
      expect(tester.widget<EvDetailPage>(find.byType(EvDetailPage)).itemId, 's1');
      expect(find.byType(EvHomePage), findsNothing);
      expect(find.byType(EvHomePage, skipOffstage: false), findsOneWidget);
      expect(find.byType(EvStage), findsOneWidget);
      final topBar = tester.widget<EvTopBar>(find.byType(EvTopBar));
      expect(topBar.hideTabs, isTrue);
      expect(topBar.hideAvatar, isTrue);
      expect(topBar.showBack, isTrue);
      expect(playback.preparedIds, contains('s1'));
      expect(immersion.playedThemes.any((t) => t?.id == 'theme_s1'), isTrue);
      expect(scope.stage.mode, EvStageMode.detail);

      // Tap similar recommendation 'm2'
      final m2Card = find.descendant(
        of: find.byKey(const Key('ev_detail_similar_shelf')),
        matching: find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'm2'),
      );
      await tester.ensureVisible(m2Card);
      await _pumpFrames(tester, 100);
      await tester.tap(m2Card);
      await _pumpFrames(tester, 200);

      expect(tester.widget<EvDetailPage>(find.byType(EvDetailPage)).itemId, 'm2');
      expect(playback.preparedIds, contains('m2'));
      expect(scope.stage.activeBackdropKey, contains('s4_bg_m2'));

      // Back #1 -> back to s1 Detail
      await tester.tap(find.byKey(const Key('ev_topbar_back')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvDetailPage), findsOneWidget);
      expect(tester.widget<EvDetailPage>(find.byType(EvDetailPage)).itemId, 's1');
      expect(scope.stage.mode, EvStageMode.detail);

      // Back #2 -> back to Home with restored stage
      await tester.tap(find.byKey(const Key('ev_topbar_back')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvDetailPage), findsNothing);
      expect(find.byType(EvHomePage), findsOneWidget);
      expect(scope.stage.mode, EvStageMode.hero);
      expect(scope.stage.activeBackdropKey, homeBackdropKey);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await prefs.close(); await accounts.close(); await immersion.close(); });
    }
  });

  testWidgets('3. C4.6: QuickLook works on Home, Zone, Wall, Detail episode & similar cards; Enter plays, Space closes, Cmd+K suppresses', (tester) async {
    await _setViewport(tester);
    final prefs = _FakePrefs();
    final accounts = _FakeAccounts();
    final data = _FakeData(prefs);
    final playback = _FakePlayback();
    final immersion = _FakeImmersion();
    final services = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 'sess-ql',
      data: data, playback: playback, immersion: immersion,
    );

    try {
      expect(embyViewRegistration.stageFivePlayer, isNotNull);
      await tester.pumpWidget(_appShell(buildStageFourTestShell(services: services)));
      await _pumpFrames(tester, 200);

      // 3a. Home EvCard: Space opens, Space closes, Cmd+K suppresses Space, Enter plays
      final homeCard = find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'm1');
      await tester.ensureVisible(homeCard);
      await _focusWidget(tester, homeCard);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester, 550);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsNothing);

      // Cmd+K suppresses Space QuickLook
      await _sendCmdKey(tester, LogicalKeyboardKey.keyK);
      expect(find.byKey(const Key('ev_palette_box')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester, 550);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpFrames(tester);
      expect(find.byKey(const Key('ev_palette_box')), findsNothing);

      // Enter plays from QuickLook
      await _focusWidget(tester, homeCard);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpFrames(tester, 200);
      expect(playback.openedTargets.last.itemId, 'm1');
      expect(find.byKey(const Key('ev_player_page')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpFrames(tester, 450);

      // 3b. Zone EvCard
      await tester.tap(find.byKey(const Key('ev_topbar_tab_movie')));
      await _pumpFrames(tester, 250);
      expect(find.byType(EvZonePage), findsOneWidget);
      final zoneCard = find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'm1').first;
      await tester.ensureVisible(zoneCard);
      await _focusWidget(tester, zoneCard);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester, 550);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsNothing);

      // 3c. Detail EvEpisodeCard & Similar EvCard
      final scope = EvScope.of(tester.element(find.byType(EvZonePage)));
      scope.shell.onOpenDetail?.call('s1');
      await _pumpFrames(tester, 250);
      expect(find.byType(EvDetailPage), findsOneWidget);

      final epCard = find.byType(EvEpisodeCard).first;
      await tester.ensureVisible(epCard);
      await _focusWidget(tester, epCard);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpFrames(tester, 200);
      expect(playback.openedTargets.last.itemId, 'ep1');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpFrames(tester, 450);

      final simCard = find.descendant(
        of: find.byKey(const Key('ev_detail_similar_shelf')),
        matching: find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'm2'),
      );
      await tester.ensureVisible(simCard);
      await _focusWidget(tester, simCard);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester, 550);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsNothing);

      // 3d. Pop back to Zone -> open Wall -> QuickLook on Wall EvCard
      await tester.tap(find.byKey(const Key('ev_topbar_back')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvZonePage), findsOneWidget);
      scope.shell.openWall((
        scope: const WallScope.zone('movie'), sort: WallSort.title, watched: WatchFilter.all,
        genreId: null, years: null, technology: null,
      ), title: '全部电影');
      await _pumpFrames(tester, 650);
      expect(find.byType(EvWallPage), findsOneWidget);
      final wallCard = find.descendant(of: find.byType(EvWallPage), matching: find.byType(EvCard)).first;
      await _focusWidget(tester, wallCard);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _pumpFrames(tester, 550);
      expect(find.byKey(const Key('ev_quicklook_overlay')), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await prefs.close(); await accounts.close(); await immersion.close(); });
    }
  });

  testWidgets('4. C4.5: Cmd+K command palette executes Add Zone, Switch User, and Go To Zone', (tester) async {
    await _setViewport(tester);
    final prefs = _FakePrefs();
    final accounts = _FakeAccounts();
    final data = _FakeData(prefs);
    final playback = _FakePlayback();
    final immersion = _FakeImmersion();
    final services = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 'sess-cmdk',
      data: data, playback: playback, immersion: immersion,
    );

    try {
      expect(embyViewRegistration.stageFivePlayer, isNotNull);
      await tester.pumpWidget(_appShell(buildStageFourTestShell(services: services)));
      await _pumpFrames(tester, 200);

      // Add Zone -> Settings zones + zone editor open
      await _sendCmdKey(tester, LogicalKeyboardKey.keyK);
      expect(find.byKey(const Key('ev_palette_box')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_add_zone')));
      await _pumpFrames(tester, 200);
      expect(find.byKey(const Key('ev_palette_box')), findsNothing);
      expect(find.byType(EvSettingsPage), findsOneWidget);
      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsOneWidget);

      // Switch User -> EvUsersPage
      await _sendCmdKey(tester, LogicalKeyboardKey.keyK);
      await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_users')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvUsersPage), findsOneWidget);
      expect(find.byType(EvTopBar), findsNothing);

      // Go To Zone -> EvZonePage('movie')
      await _sendCmdKey(tester, LogicalKeyboardKey.keyK);
      await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_zone_movie')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvUsersPage), findsNothing);
      expect(find.byType(EvZonePage), findsOneWidget);
      expect(tester.widget<EvZonePage>(find.byType(EvZonePage)).zoneId, 'movie');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await prefs.close(); await accounts.close(); await immersion.close(); });
    }
  });

  testWidgets('5. C4.7: Switching user via avatar menu / Users rebuilds host and resets old Search/Detail/Home/Wall state', (tester) async {
    await _setViewport(tester);
    final prefs = _FakePrefs();
    final accounts = _FakeAccounts(current: _kAlice, sessionId: 'sess-alice-1');
    final playback = _FakePlayback();
    final immersion = _FakeImmersion();

    final entry = await tester.runAsync(() async {
      final created = EmbyViewEntry(
        preferences: prefs, accounts: accounts,
        createSession: (acc) => EmbyViewSessionServices(
          data: _FakeData(prefs, owner: acc.current!.id),
          playback: playback, immersion: immersion, dispose: () async {},
        ),
      );
      await created.ready;
      return created;
    });
    installEmbyViewEntry(entry);

    final router = GoRouter(
      initialLocation: embyViewHomePath,
      routes: buildEmbyViewRoutes(legacyHome: (_) => const Text('SWITCHING')),
    );

    try {
      await tester.pumpWidget(WidgetsApp.router(color: const Color(0xFF0A0A0D), routerConfig: router));
      await _pumpFrames(tester, 200);
      expect(find.text('alice 首页主推'), findsOneWidget);

      // Open Search from topbar, type query, then open Avatar Menu -> Switch User
      await tester.tap(find.byKey(const Key('ev_topbar_tab_search')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvSearchPage), findsOneWidget);
      await tester.enterText(find.byKey(const Key('ev_search_input')), '星际');
      await _pumpFrames(tester, 250);

      await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
      await _pumpFrames(tester, 150);
      await tester.tap(find.byKey(const Key('ev_avatar_menu_users')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvUsersPage), findsOneWidget);

      // Select Bob -> triggers EmbyViewEntry sessionId change -> full host rebuild
      await tester.tap(find.byKey(const Key('ev_users_profile_bob')));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await _pumpFrames(tester, 250);

      expect(entry!.services.sessionId, contains('sess-bob'));
      expect(find.byType(EvUsersPage), findsNothing);
      expect(find.byType(EvSearchPage), findsNothing);
      expect(find.byType(EvDetailPage), findsNothing);
      expect(find.byType(EvHomePage), findsOneWidget);
      expect(find.text('bob 首页主推'), findsOneWidget);
      expect(find.text('alice 首页主推'), findsNothing);
    } finally {
      router.dispose();
      installEmbyViewEntry(null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await entry!.close(); entry.dispose();
        await prefs.close(); await accounts.close(); await immersion.close();
      });
    }
  });

  testWidgets('6. C4.8: Creating custom "杜比视界" zone in Settings updates topbar & Home and loads zone page', (tester) async {
    await _setViewport(tester);
    final prefs = _FakePrefs();
    final accounts = _FakeAccounts();
    final data = _FakeData(prefs);
    final playback = _FakePlayback();
    final immersion = _FakeImmersion();
    final services = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 'sess-custom-zone',
      data: data, playback: playback, immersion: immersion,
    );

    try {
      expect(embyViewRegistration.stageFivePlayer, isNotNull);
      await tester.pumpWidget(_appShell(buildStageFourTestShell(services: services)));
      await _pumpFrames(tester, 200);

      // Open Avatar Menu -> 分区 (Settings zones)
      await tester.tap(find.byKey(const Key('ev_topbar_avatar')));
      await _pumpFrames(tester, 150);
      await tester.tap(find.byKey(const Key('ev_avatar_menu_zones')));
      await _pumpFrames(tester, 200);
      expect(find.byType(EvSettingsPage), findsOneWidget);

      // Click Add Zone -> Esc closes ONLY the zone editor without popping Settings
      await tester.tap(find.byKey(const Key('ev_zone_add')));
      await _pumpFrames(tester, 200);
      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpFrames(tester, 150);
      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsNothing);
      expect(find.byType(EvSettingsPage), findsOneWidget);

      // Re-open Add Zone -> fill "杜比视界" + technology dolbyVision -> save
      await tester.tap(find.byKey(const Key('ev_zone_add')));
      await _pumpFrames(tester, 200);
      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsOneWidget);

      final nameField = find.descendant(of: find.byKey(const Key('ev_zone_name_input')), matching: find.byType(EditableText));
      await tester.enterText(nameField, '杜比视界');
      await tester.tap(find.byKey(const Key('ev_zone_rule_tab_technology')));
      await _pumpFrames(tester, 100);
      await tester.tap(find.byKey(const Key('ev_zone_facet_tech_dolbyVision')));
      await _pumpFrames(tester, 100);
      await tester.tap(find.byKey(const Key('ev_zone_save')));
      await _pumpFrames(tester, 250);

      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsNothing);
      final createdZone = prefs.current.zones.where((z) => z.name == '杜比视界').single;
      expect(createdZone.custom, isTrue);

      // Topbar immediately shows new custom zone tab
      expect(find.byKey(Key('ev_topbar_tab_${createdZone.id}')), findsOneWidget);

      // Return to Home -> Home zone strip shows "杜比视界"
      await tester.tap(find.byKey(const Key('ev_topbar_back')));
      await _pumpFrames(tester, 250);
      expect(find.byType(EvHomePage), findsOneWidget);
      expect(find.byKey(Key('ev_topbar_tab_${createdZone.id}')), findsOneWidget);
      expect(find.text('杜比视界'), findsWidgets);

      // Click new custom zone tab -> enters EvZonePage and loads custom zone content
      await tester.tap(find.byKey(Key('ev_topbar_tab_${createdZone.id}')));
      await _pumpFrames(tester, 250);
      expect(find.byType(EvZonePage), findsOneWidget);
      expect(tester.widget<EvZonePage>(find.byType(EvZonePage)).zoneId, createdZone.id);
      expect(find.text('杜比视界示范片'), findsWidgets);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await prefs.close(); await accounts.close(); await immersion.close(); });
    }
  });

  testWidgets('7. Regression: didUpdateWidget clears shell.zones immediately on sessionId change and guards unmounted _pushStageFour', (tester) async {
    await _setViewport(tester);
    final prefs = _FakePrefs();
    final accounts = _FakeAccounts(current: _kAlice, sessionId: 'sess-a');
    final playback = _FakePlayback();
    final immersion = _FakeImmersion();
    final bobZonesGate = Completer<List<ZoneTile>>();
    final aliceData = _FakeData(prefs, owner: 'alice');
    final bobData = _PendingZonesData(prefs, bobZonesGate.future, owner: 'bob');
    final servicesA = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: 'sess-a', data: aliceData, playback: playback, immersion: immersion);
    final servicesB = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: 'sess-b', data: bobData, playback: playback, immersion: immersion);

    var active = servicesA;
    late StateSetter hostSetState;
    try {
      await tester.pumpWidget(_appShell(StatefulBuilder(builder: (ctx, setState) {
        hostSetState = setState;
        return embyViewRegistration.stageThreeHome!(ctx, active);
      })));
      await _pumpFrames(tester, 200);

      final shell = EvScope.of(tester.element(find.byType(EvHomePage))).shell;
      expect(shell.zones.map((z) => z.id), ['movie', 'tv']);

      // Open Users overlay then swap sessionId in-place via didUpdateWidget
      shell.onOpenUsers?.call();
      await _pumpFrames(tester, 150);
      expect(find.byType(EvUsersPage), findsOneWidget);

      hostSetState(() => active = servicesB);
      await tester.pump();
      expect(shell.zones, isEmpty);
      expect(find.byType(EvUsersPage), findsNothing);

      // Complete Bob's zones and verify fresh zones populate
      bobZonesGate.complete(const [ZoneTile(id: 'bob_only', name: 'Bob片库', iconKey: 'nav_movie', colorSlot: 0, total: 3, unit: '部')]);
      await _pumpFrames(tester, 200);
      expect(shell.zones.map((z) => z.id), ['bob_only']);

      // Unmount host and invoke stale shell callback -> _pushStageFour mounted guard prevents StateError
      await tester.pumpWidget(const SizedBox.shrink());
      expect(() => shell.onOpenDetail?.call('m1'), returnsNormally);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await prefs.close(); await accounts.close(); await immersion.close(); });
    }
  });
}

class _PendingZonesData extends _FakeData {
  _PendingZonesData(super.prefs, this._zonesFuture, {super.owner});
  final Future<List<ZoneTile>> _zonesFuture;
  @override Future<List<ZoneTile>> zones() => _zonesFuture;
  @override
  Future<HomeData> home({required ShelfSort seriesSort}) async => HomeData(
    recommendations: [HomeRecommendation(card: heroCard, reason: RecommendationReason.daily)],
    zones: await _zonesFuture,
    recentMovies: HomeShelf(id: 'movies', title: '$owner 最近电影', items: [movieCard]),
  );
}
