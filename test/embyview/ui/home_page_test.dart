import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/home/ev_feature_spread.dart';
import 'package:moonfin/embyview/ui/home/ev_hero.dart';
import 'package:moonfin/embyview/ui/home/ev_home_page.dart';
import 'package:moonfin/embyview/ui/home/ev_zone_strip.dart';
import 'package:moonfin/embyview/ui/kit.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(
    this.id, {
    this.aspectRatio = 2 / 3,
    this.width = 600,
    this.height = 900,
  }) : cacheKey = 'home_test_$id',
       image = MemoryImage(_kPngBytes);

  @override
  final String id;

  @override
  final String cacheKey;

  @override
  final ImageProvider<Object> image;

  @override
  final double? aspectRatio;

  @override
  final int? width;

  @override
  final int? height;
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
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final _snapshot = const AccountSnapshot(
    phase: AccountPhase.signedIn,
    current: AccountProfile(id: 'sfw', displayName: 'sfw'),
    profiles: [AccountProfile(id: 'sfw', displayName: 'sfw')],
    sessionId: 'home-sess-1',
  );

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

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlaybackSession implements PlaybackSession {
  _FakePlaybackSession(this.target);
  final PlayTarget target;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();

  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot(generation: 1, target: target);

  @override
  Stream<PlaybackSnapshot> get changes => _changes.stream;

  @override
  Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF000000));

  @override
  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayback implements EmbyViewPlayback {
  final List<PlayTarget> openedTargets = [];

  @override
  Future<void> prepare(String itemId) async {}

  @override
  PlaybackSession open(PlayTarget target) {
    openedTargets.add(target);
    return _FakePlaybackSession(target);
  }
}

class _FakeHomeData implements EmbyViewData {
  _FakeHomeData({required this.builder});

  final Future<HomeData> Function(ShelfSort sort) builder;
  final List<ShelfSort> homeCalls = [];
  final List<String> themeMediaCalls = [];

  @override
  Future<HomeData> home({required ShelfSort seriesSort}) {
    homeCalls.add(seriesSort);
    return builder(seriesSort);
  }

  @override
  Future<List<ZoneTile>> zones() async => (await builder(ShelfSort.added)).zones;

  @override
  Future<ThemeMedia> themeMedia(String itemId) async {
    themeMediaCalls.add(itemId);
    return const ThemeMedia();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImmersionPlayback implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast();
  @override
  ImmersionSnapshot get snapshot => const ImmersionSnapshot();
  @override
  Stream<ImmersionSnapshot> get changes => _changes.stream;
  @override
  Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF000000));
  @override
  Future<void> showMutedVideo(PreviewRef? video) async {}
  @override
  Future<void> playTheme(PreviewRef? song) async {}
  @override
  Future<void> setThemeMuted(bool muted) async {}
  @override
  Future<void> stop() async {}
  Future<void> close() => _changes.close();
}

MediaCard _makeCard({
  required String id,
  required String title,
  MediaKind kind = MediaKind.movie,
  String? libraryId = 'movie',
  int year = 2024,
  double score = 8.4,
  List<String> genres = const ['科幻', '剧情'],
  Duration? duration = const Duration(minutes: 118),
  String? rating = 'PG-13',
  String? overview = '一段跨越星际与时间的影像旅程，讲述孤独探索者在浩瀚宇宙中寻找归宿的故事。',
  int? childCount,
  MediaQuality? quality,
  bool withLogo = false,
  double posterAspect = 2 / 3,
  bool backdropOnlyPoster = false,
  int? episodeNumber,
}) {
  final bgRef = _FakeArtworkRef('bg_$id', aspectRatio: 16 / 9, width: 1920, height: 1080);
  final posterRef = _FakeArtworkRef(
    'poster_$id',
    aspectRatio: posterAspect,
    width: (posterAspect * 900).round(),
    height: 900,
  );
  final logoRef = withLogo
      ? _FakeArtworkRef('logo_$id', aspectRatio: 3.0, width: 900, height: 300)
      : null;

  return MediaCard(
    id: id,
    kind: kind,
    libraryId: libraryId,
    title: title,
    year: year,
    score: score,
    genres: genres,
    duration: duration,
    rating: rating,
    overview: overview,
    childCount: childCount,
    quality: quality,
    episodeNumber: episodeNumber,
    art: CardArtwork(
      landscape: ArtworkPlan(
        layers: [ArtworkLayer(source: bgRef, fit: ArtworkFit.cover)],
        fallbackTitle: title,
      ),
      poster: ArtworkPlan(
        layers: [
          if (backdropOnlyPoster)
            ArtworkLayer(source: bgRef, fit: ArtworkFit.cover, text: title)
          else
            ArtworkLayer(source: posterRef),
        ],
        fallbackTitle: title,
        stack: kind == MediaKind.collection
            ? [_FakeArtworkRef('stk1_$id'), _FakeArtworkRef('stk2_$id')]
            : const [],
      ),
      stage: ArtworkPlan(
        layers: [ArtworkLayer(source: bgRef, fit: ArtworkFit.cover)],
        fallbackTitle: title,
      ),
      backdrops: [bgRef],
      logo: logoRef,
    ),
  );
}

WallQuery _zoneQuery(String zoneId, {WallSort sort = WallSort.added}) => (
  scope: WallScope.zone(zoneId),
  sort: sort,
  watched: WatchFilter.all,
  genreId: null,
  years: null,
  technology: null,
);

WallQuery _featureQuery(HomeFeature feature) => (
  scope: WallScope.feature(feature),
  sort: WallSort.score,
  watched: WatchFilter.all,
  genreId: null,
  years: null,
  technology: null,
);

HomeData _buildRichHomeData(ShelfSort sort) {
  final heroResumeCard = _makeCard(
    id: 'hero_resume',
    title: '葬送的芙莉莲',
    kind: MediaKind.series,
    libraryId: 'anime',
    year: 2023,
    score: 9.2,
    genres: const ['奇幻', '冒险'],
    duration: const Duration(minutes: 24),
    childCount: 1,
    rating: 'TV-14',
    quality: const MediaQuality(resolution: '4K', videoRange: '杜比视界', audioLabel: '5.1'),
    withLogo: true,
    episodeNumber: 9,
  );
  final heroResume = ResumeCard(
    card: heroResumeCard,
    target: const PlayTarget(
      itemId: 'ep_frieren_9',
      startAt: Duration(minutes: 15),
      seriesId: 'hero_resume',
      episodeNumber: 9,
    ),
    position: const Duration(minutes: 15),
    duration: const Duration(minutes: 24),
  );

  final heroDailyWordmark = _makeCard(
    id: 'hero_daily',
    title: '沙丘：第二部',
    kind: MediaKind.movie,
    libraryId: 'movie',
    year: 2024,
    score: 8.6,
    genres: const ['科幻', '动作'],
    duration: const Duration(minutes: 166),
    rating: 'PG-13',
    quality: const MediaQuality(resolution: '4K', videoRange: 'HDR', audioLabel: 'Atmos'),
    withLogo: false,
  );

  final heroThird = _makeCard(
    id: 'hero_third',
    title: '奥本海默',
    kind: MediaKind.movie,
    libraryId: 'movie',
    year: 2023,
    score: 8.8,
    genres: const ['历史', '剧情'],
    duration: const Duration(minutes: 180),
    withLogo: false,
  );

  final cwMovie = _makeCard(id: 'cw_2', title: '星际穿越', libraryId: 'movie');
  final continueWatching = [
    heroResume,
    ResumeCard(
      card: cwMovie,
      target: const PlayTarget(itemId: 'cw_2', startAt: Duration(minutes: 120)),
      position: const Duration(minutes: 120),
      duration: const Duration(minutes: 169),
    ),
  ];

  final zones = [
    ZoneTile(
      id: 'anime',
      name: '番剧',
      iconKey: 'nav_anime',
      colorSlot: 0,
      art: _FakeArtworkRef('z_anime', aspectRatio: 16 / 9, width: 1920, height: 1080),
      total: 12,
      unit: '部',
      episodeTotal: 348,
    ),
    ZoneTile(
      id: 'movie',
      name: '电影',
      iconKey: 'nav_movie',
      colorSlot: 1,
      art: _FakeArtworkRef('z_movie', aspectRatio: 16 / 9, width: 1920, height: 1080),
      total: 733,
      unit: '部',
    ),
    ZoneTile(
      id: 'tv',
      name: '剧集',
      iconKey: 'nav_tv',
      colorSlot: 2,
      art: _FakeArtworkRef('z_tv', aspectRatio: 16 / 9, width: 1920, height: 1080),
      total: 92,
      unit: '部',
      episodeTotal: 2937,
    ),
    ZoneTile(
      id: 'doc',
      name: '纪录片',
      iconKey: 'nav_doc',
      colorSlot: 3,
      art: _FakeArtworkRef('z_doc', aspectRatio: 16 / 9, width: 1920, height: 1080),
      total: 14,
      unit: '部',
      episodeTotal: 208,
    ),
    ZoneTile(
      id: 'box',
      name: '合集',
      iconKey: 'nav_box',
      colorSlot: 4,
      art: _FakeArtworkRef('z_box', aspectRatio: 16 / 9, width: 1920, height: 1080),
      total: 37,
      unit: '个',
    ),
    ZoneTile(
      id: 'custom_scifi',
      name: '科幻精选',
      iconKey: 'rocket',
      colorSlot: 5,
      art: _FakeArtworkRef('z_scifi', aspectRatio: 16 / 9, width: 1920, height: 1080),
      total: 64,
      unit: '部',
    ),
  ];

  // Include portrait, landscape, square, and backdrop-fallback cards to verify filtering.
  final shortPosters = [
    _makeCard(id: 'sp_1', title: '短片一', posterAspect: 2 / 3),
    _makeCard(id: 'sp_2', title: '短片二', posterAspect: 0.67),
    _makeCard(id: 'sp_land', title: '横图过滤', posterAspect: 16 / 9),
    _makeCard(id: 'sp_sq', title: '方图过滤', posterAspect: 1.0),
    _makeCard(id: 'sp_bd', title: '剧照兜底过滤', backdropOnlyPoster: true),
    _makeCard(id: 'sp_3', title: '短片三', posterAspect: 2 / 3),
  ];

  final dvPosters = [
    _makeCard(id: 'dv_1', title: '杜比电影一', posterAspect: 2 / 3),
    _makeCard(id: 'dv_2', title: '杜比电影二', posterAspect: 2 / 3),
    _makeCard(id: 'dv_3', title: '杜比电影三', posterAspect: 2 / 3),
  ];

  return HomeData(
    recommendations: [
      HomeRecommendation(
        card: heroResumeCard,
        reason: RecommendationReason.continueWatching,
        resume: heroResume,
      ),
      HomeRecommendation(card: heroDailyWordmark, reason: RecommendationReason.daily),
      HomeRecommendation(card: heroThird, reason: RecommendationReason.daily),
    ],
    continueWatching: continueWatching,
    zones: zones,
    shortHighRated: FeatureSpread(
      feature: HomeFeature.shortHighRated,
      posters: shortPosters,
      total: 42,
      query: _featureQuery(HomeFeature.shortHighRated),
    ),
    recentMovies: HomeShelf(
      id: 'movie',
      title: '电影',
      more: _zoneQuery('movie'),
      items: [
        _makeCard(id: 'rm_1', title: '最近电影甲'),
        _makeCard(id: 'rm_2', title: '最近电影乙'),
      ],
    ),
    anime: HomeShelf(
      id: 'anime',
      title: '番剧',
      more: _zoneQuery('anime'),
      items: [
        _makeCard(
          id: 'an_1',
          title: sort == ShelfSort.score ? '高分番剧一' : '新番一',
          kind: MediaKind.series,
          libraryId: 'anime',
        ),
        _makeCard(id: 'an_2', title: '新番二', kind: MediaKind.series, libraryId: 'anime'),
      ],
    ),
    uhdDolbyVision: FeatureSpread(
      feature: HomeFeature.uhdDolbyVision,
      posters: dvPosters,
      total: 28,
      query: _featureQuery(HomeFeature.uhdDolbyVision),
    ),
    series: HomeShelf(
      id: 'tv',
      title: '剧集',
      more: _zoneQuery('tv'),
      items: [
        _makeCard(id: 'tv_1', title: '剧集甲', kind: MediaKind.series, libraryId: 'tv'),
        _makeCard(id: 'tv_2', title: '剧集乙', kind: MediaKind.series, libraryId: 'tv'),
      ],
    ),
    collections: HomeShelf(
      id: 'box',
      title: '合集',
      more: _zoneQuery('box'),
      items: [
        _makeCard(
          id: 'col_1',
          title: '指环王三部曲',
          kind: MediaKind.collection,
          libraryId: 'box',
          childCount: 3,
        ),
      ],
    ),
    documentaries: HomeShelf(
      id: 'doc',
      title: '纪录片',
      more: _zoneQuery('doc'),
      items: [
        _makeCard(id: 'doc_1', title: '地球脉动', libraryId: 'doc', genres: const ['纪录']),
      ],
    ),
  );
}

class _Harness {
  _Harness({
    required this.prefs,
    required this.accounts,
    required this.data,
    required this.playback,
    required this.stage,
    required this.immersion,
    required this.shell,
    required this.services,
  });

  final _FakePreferences prefs;
  final _FakeAccounts accounts;
  final _FakeHomeData data;
  final _FakePlayback playback;
  final EvStageController stage;
  final Immersion immersion;
  final EvShellController shell;
  final EmbyViewServices services;

  Future<void> dispose() async {
    immersion.dispose();
    stage.dispose();
    shell.dispose();
    await prefs.close();
    await accounts.close();
  }
}

_Harness _createHarness({
  LocalPreferences initialPrefs = const LocalPreferences(),
  Future<HomeData> Function(ShelfSort sort)? homeBuilder,
  ValueChanged<String>? onOpenDetail,
  VoidCallback? onManageZones,
}) {
  final prefs = _FakePreferences(initialPrefs);
  final accounts = _FakeAccounts();
  final data = _FakeHomeData(
    builder: homeBuilder ?? (sort) async => _buildRichHomeData(sort),
  );
  final playback = _FakePlayback();
  final services = EmbyViewServices(
    preferences: prefs,
    accounts: accounts,
    sessionId: 'home-sess-1',
    data: data,
    playback: playback,
  );
  final stage = EvStageController();
  final immersion = Immersion(stage: stage, services: services);
  final shell = EvShellController(
    onOpenDetail: onOpenDetail,
    onManageZones: onManageZones,
  );
  return _Harness(
    prefs: prefs,
    accounts: accounts,
    data: data,
    playback: playback,
    stage: stage,
    immersion: immersion,
    shell: shell,
    services: services,
  );
}

Widget _wrapHome(
  _Harness h, {
  Size size = const Size(1440, 900),
  bool enableAnimations = false,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: EvThemeScope(
        preferences: h.prefs,
        child: EvScope(
          services: h.services,
          stage: h.stage,
          immersion: h.immersion,
          shell: h.shell,
          child: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                EvStage(controller: h.stage, immersion: h.immersion, enableMotion: false),
                EvHomePage(enableAnimations: enableAnimations),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('C3.9 & C3.10 EvHomePage, EvHero, EvZoneStrip, EvFeatureSpread', () {
    testWidgets(
      'renders hero metadata, 9-second rotation, dot click, card hover preview, and all 9 sections in exact order',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final h = _createHarness();
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapHome(h, enableAnimations: true));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Hero content wrapped in EvOnImage.
        final heroFinder = find.byKey(const Key('ev_hero'));
        expect(heroFinder, findsOneWidget);
        expect(find.byType(EvHero), findsOneWidget);
        expect(find.byType(EvZoneStrip), findsOneWidget);
        expect(
          find.descendant(of: heroFinder, matching: find.byType(EvOnImage)),
          findsOneWidget,
        );

        // First recommendation: continue watching with resume ring + percentage + remaining time + logo + meta + badges.
        expect(find.byKey(const Key('ev_hero_resume_ring')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('63%')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('继续观看')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('第 9 集 · 剩 9 分钟')), findsOneWidget);
        expect(find.byKey(const ValueKey<String>('ev_hero_logo_home_test_logo_hero_resume')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.byType(EvScoreBadge)), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('9.2')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('4K')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('杜比视界')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('5.1')), findsOneWidget);
        expect(find.byKey(const Key('ev_hero_overview')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('继续第 9 集')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('· 剩 9 分钟')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('详情')), findsOneWidget);
        expect(find.byKey(const Key('ev_hero_favorite_btn')), findsOneWidget);
        final favRect = tester.getRect(find.byKey(const Key('ev_hero_favorite_btn')));
        final detailRect = tester.getRect(find.byKey(const Key('ev_hero_detail_btn')));
        expect(favRect.left, greaterThan(detailRect.right));
        expect(favRect.width, closeTo(favRect.height, 1.0));
        expect(h.stage.activeBackdropKey, contains('home_test_bg_hero_resume'));

        // 9-second auto-rotation switches to recommendation #2 (daily wordmark + 「今日推荐」 + 「立即播放」).
        await tester.pump(const Duration(seconds: 9));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('ev_hero_wordmark')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('沙丘：第二部')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('今日推荐')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('立即播放')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('HDR')), findsOneWidget);
        expect(h.stage.activeBackdropKey, contains('home_test_bg_hero_daily'));

        // Clicking dot #2 immediately switches to recommendation #3.
        await tester.tap(find.byKey(const Key('ev_hero_dot_2')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.descendant(of: heroFinder, matching: find.text('奥本海默')), findsOneWidget);
        expect(h.stage.activeBackdropKey, contains('home_test_bg_hero_third'));

        // Hovering a continue-watching card while hero is visible previews it after 400ms and pauses rotation.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        final cwSection = find.byKey(const Key('ev_home_section_continue'));
        final cwCards = find.descendant(of: cwSection, matching: find.byType(EvCard));
        final secondCardTopLeft = tester.getTopLeft(cwCards.at(1));
        await mouse.moveTo(secondCardTopLeft + const Offset(40, 30));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.descendant(of: heroFinder, matching: find.text('星际穿越')), findsOneWidget);

        // Even after >9s while still hovering, auto-rotation remains paused on the previewed card.
        await tester.pump(const Duration(seconds: 10));
        expect(find.descendant(of: heroFinder, matching: find.text('星际穿越')), findsOneWidget);

        // Leaving the card restores the hero recommendation and resumes rotation.
        await mouse.moveTo(const Offset(10, 10));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.descendant(of: heroFinder, matching: find.text('奥本海默')), findsOneWidget);

        // Verify all 9 sections exist in strict top-to-bottom order.
        const sectionKeys = [
          Key('ev_home_section_continue'),
          Key('ev_home_section_zones'),
          Key('ev_home_section_short_feature'),
          Key('ev_home_section_recent'),
          Key('ev_home_section_anime'),
          Key('ev_home_section_dv_feature'),
          Key('ev_home_section_series'),
          Key('ev_home_section_collections'),
          Key('ev_home_section_docs'),
        ];
        double prevTop = tester.getTopLeft(heroFinder).dy;
        for (final k in sectionKeys) {
          final finder = find.byKey(k);
          expect(finder, findsOneWidget, reason: 'Expected section $k');
          final top = tester.getTopLeft(finder).dy;
          expect(top, greaterThan(prevTop), reason: 'Section $k should appear below previous section');
          prevTop = top;
        }

        // Verify card styles match proto.js: continue=landscape, recent/anime/series=poster, collections=collection, docs=landscape.
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_home_section_continue'))).style, EvCardStyle.landscape);
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_home_section_recent'))).style, EvCardStyle.poster);
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_home_section_anime'))).style, EvCardStyle.poster);
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_home_section_series'))).style, EvCardStyle.poster);
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_home_section_collections'))).style, EvCardStyle.collection);
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_home_section_docs'))).style, EvCardStyle.landscape);

        // Verify 5 default zones + 1 custom zone & manage button.
        expect(find.byKey(const Key('ev_zone_tile_anime')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_tile_movie')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_tile_tv')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_tile_doc')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_tile_box')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_tile_custom_scifi')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_manage')), findsOneWidget);
      },
    );

    testWidgets(
      'hero height equals 100vh - peek and lays out cleanly at 1440x900 and 2560x1440',
      (tester) async {
        for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;

          final h = _createHarness();
          await tester.pumpWidget(_wrapHome(h, size: size, enableAnimations: false));
          await tester.pumpAndSettle();

          final scale = EvScale.fromSize(size);
          final expectedHeroHeight = scale.vh(100) - scale.peek;
          final heroRect = tester.getRect(find.byKey(const Key('ev_hero')));
          expect(heroRect.height, closeTo(expectedHeroHeight, 0.5));
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await h.dispose();
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      },
    );

    testWidgets(
      'renders cleanly in cinema and paper themes, with hand-drawn doodle icons in paper feature spreads',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final h = _createHarness(initialPrefs: const LocalPreferences(theme: ThemeMode.cinema));
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapHome(h, enableAnimations: false));
        await tester.pumpAndSettle();

        // Cinema theme: no doodle icons on feature spreads.
        expect(find.byKey(const Key('ev_feature_doodle_shortHighRated')), findsNothing);
        expect(find.byKey(const Key('ev_feature_doodle_uhdDolbyVision')), findsNothing);

        // Switch to paper theme.
        await h.prefs.update(const LocalPreferences(theme: ThemeMode.paper));
        await tester.pumpAndSettle();

        // Paper theme: both feature spreads show hand-drawn doodle icons.
        expect(find.byKey(const Key('ev_feature_doodle_shortHighRated')), findsOneWidget);
        expect(find.byKey(const Key('ev_feature_doodle_uhdDolbyVision')), findsOneWidget);

        // Hero still uses EvOnImage with light onImage ink even in paper theme.
        final reasonCtx = tester.element(find.byKey(const Key('ev_hero_reason')));
        final heroTheme = EvTheme.of(reasonCtx);
        expect(heroTheme.isPaper, isTrue);
        expect(heroTheme.onImage, isTrue);
        expect(heroTheme.ink, const Color(0xFFF5F5F7));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'reloads on seriesSort change, navigates to zone/wall/detail, syncs scroll, and opens EvPlayer with origin & art',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final openedDetails = <String>[];
        var manageZonesCalls = 0;
        final h = _createHarness(
          onOpenDetail: openedDetails.add,
          onManageZones: () => manageZonesCalls++,
        );
        addTearDown(h.dispose);

        Rect? capturedOrigin;
        CardArtwork? capturedArt;
        final prevBuilder = EvPlayer.pageBuilder;
        EvPlayer.pageBuilder = (context, session, {origin, art}) {
          capturedOrigin = origin;
          capturedArt = art;
          return GestureDetector(
            key: const Key('test_player_page'),
            onTap: () => Navigator.of(context).pop(),
            child: const ColoredBox(color: Color(0xFF000000)),
          );
        };
        addTearDown(() => EvPlayer.pageBuilder = prevBuilder);

        await tester.pumpWidget(_wrapHome(h, enableAnimations: false));
        await tester.pumpAndSettle();
        expect(h.data.homeCalls, [ShelfSort.added]);

        // 1. Hero detail button calls shell.onOpenDetail.
        await tester.tap(find.byKey(const Key('ev_hero_detail_btn')));
        await tester.pump();
        expect(openedDetails, ['hero_resume']);

        // 2. Hero play button calls EvPlayer.open with origin and art.
        await tester.tap(find.byKey(const Key('ev_hero_play_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('test_player_page')), findsOneWidget);
        expect(h.playback.openedTargets.single.itemId, 'ep_frieren_9');
        expect(capturedOrigin, isNotNull);
        expect(capturedOrigin!.width, greaterThan(0));
        expect(capturedArt, isNotNull);
        expect(capturedArt!.logo?.cacheKey, 'home_test_logo_hero_resume');

        // Dismiss player route.
        await tester.tap(find.byKey(const Key('test_player_page')));
        await tester.pumpAndSettle();

        // 3. Changing preferences.seriesSort re-requests data.home(seriesSort: ShelfSort.score).
        await h.prefs.update(const LocalPreferences(seriesSort: ShelfSort.score));
        await tester.pumpAndSettle();
        expect(h.data.homeCalls, [ShelfSort.added, ShelfSort.score]);
        expect(find.text('高分番剧一'), findsOneWidget);
        expect(find.text('评分最高'), findsWidgets);

        // 4. Scrolling updates stage.scrollProgress and shell.topFade.
        await tester.drag(find.byKey(const Key('ev_home_scroller')), const Offset(0, -450));
        await tester.pumpAndSettle();
        expect(h.stage.scrollProgress, greaterThan(0.5));
        expect(h.shell.scrolled, isTrue);
        expect(h.shell.topFade, greaterThan(0.5));

        // 5. Clicking a zone tile calls shell.openZone.
        await tester.ensureVisible(find.byKey(const Key('ev_zone_tile_movie')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ev_zone_tile_movie')));
        await tester.pump();
        expect(h.shell.current, const EvZoneDestination('movie'));
        h.shell.goHome();

        // 6. Clicking 「管理分区 ›」 calls shell.onManageZones.
        await tester.ensureVisible(find.byKey(const Key('ev_zone_manage')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ev_zone_manage')));
        await tester.pump();
        expect(manageZonesCalls, 1);

        // 7. Clicking feature spread 「看看这 N 部」 calls shell.openWall.
        final shortFeature = find.byKey(const Key('ev_feature_shortHighRated'));
        await tester.ensureVisible(shortFeature);
        await tester.pumpAndSettle();
        expect(find.text('看看这 42 部'), findsOneWidget);
        await tester.tap(shortFeature);
        await tester.pump();
        expect(h.shell.current, isA<EvWallDestination>());
        final wallDest = h.shell.current as EvWallDestination;
        expect(wallDest.query.scope, isA<FeatureWallScope>());
        expect((wallDest.query.scope as FeatureWallScope).feature, HomeFeature.shortHighRated);
      },
    );

    testWidgets(
      'feature spread filters out non-portrait posters and pauses wall animation when scrolled off-screen',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final h = _createHarness();
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapHome(h, enableAnimations: true));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final featureFinder = find.byKey(const Key('ev_home_section_short_feature'));
        final state = tester.state<EvFeatureSpreadState>(featureFinder);

        // Verify portrait-only filtering (only sp_1, sp_2, sp_3 pass; sp_land, sp_sq, sp_bd filtered out).
        final keptIds = state.portraitPosters.map((r) => r.id).toSet();
        expect(keptIds, {'poster_sp_1', 'poster_sp_2', 'poster_sp_3'});

        // Initially below the fold at scroll=0 -> paused!
        expect(state.isWallAnimating, isFalse);

        // Scroll feature spread into view -> resumes animation and moves column transforms.
        final scroller = tester.widget<SingleChildScrollView>(find.byKey(const Key('ev_home_scroller'))).controller!;
        final featureTop = tester.getTopLeft(featureFinder).dy;
        scroller.jumpTo(featureTop - 200);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(state.isWallAnimating, isTrue);

        double col0Offset() =>
            tester.widget<Transform>(find.byKey(const Key('ev_feature_col_shortHighRated_0'))).transform.storage[13];
        final yBefore = col0Offset();
        await tester.pump(const Duration(seconds: 2));
        final yAfter = col0Offset();
        expect((yAfter - yBefore).abs(), greaterThan(1.0));

        // Scroll feature spread completely above the viewport -> pauses animation & freezes transform.
        scroller.jumpTo(scroller.position.maxScrollExtent);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(state.isWallAnimating, isFalse);

        final yFrozen1 = col0Offset();
        await tester.pump(const Duration(seconds: 2));
        final yFrozen2 = col0Offset();
        expect(yFrozen2, equals(yFrozen1));
      },
    );

    testWidgets(
      'shows loading skeletons while fetching and skips empty sections automatically',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final completer = Completer<HomeData>();
        final h = _createHarness(homeBuilder: (_) => completer.future);
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapHome(h, enableAnimations: false));
        await tester.pump();

        expect(find.byKey(const Key('ev_home_skeletons')), findsOneWidget);
        expect(find.byType(EvShelfSkeleton), findsNWidgets(3));

        // Complete with partial data (only recentMovies present; other 8 sections empty).
        completer.complete(
          HomeData(
            recommendations: [
              HomeRecommendation(
                card: _makeCard(id: 'only_hero', title: '唯一推荐'),
                reason: RecommendationReason.daily,
              ),
            ],
            recentMovies: HomeShelf(
              id: 'movie',
              title: '电影',
              items: [_makeCard(id: 'only_m', title: '唯一电影')],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_home_skeletons')), findsNothing);
        expect(find.byKey(const Key('ev_home_section_recent')), findsOneWidget);
        expect(find.byKey(const Key('ev_home_section_continue')), findsNothing);
        expect(find.byKey(const Key('ev_home_section_zones')), findsNothing);
        expect(find.byKey(const Key('ev_home_section_short_feature')), findsNothing);
        expect(find.byKey(const Key('ev_home_section_anime')), findsNothing);
        expect(find.byKey(const Key('ev_home_section_dv_feature')), findsNothing);
        expect(find.byKey(const Key('ev_home_section_series')), findsNothing);
        expect(find.byKey(const Key('ev_home_section_collections')), findsNothing);
        expect(find.byKey(const Key('ev_home_section_docs')), findsNothing);
      },
    );

    testWidgets(
      'handles null data safely, resolves GUID zone metadata, avoids full-page hover rebuild, exposes refresh error banner, clears on session switch, and suppresses paper scrolled video',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _FakePreferences(const LocalPreferences(theme: ThemeMode.paper, backgroundVideo: true));
        final accounts = _FakeAccounts();
        final playback = _FakePlayback();
        final immersionBackend = _FakeImmersionPlayback();
        final stage = EvStageController();
        final shell = EvShellController(
          zones: const [
            ZoneTile(id: 'lib-guid-anime-01', name: '新番馆', iconKey: 'nav_anime', colorSlot: 0, total: 20, unit: '部'),
          ],
        );

        // 1. services.data == null -> renders safe empty state without crashing on home!.
        final nullServices = EmbyViewServices(
          preferences: prefs,
          accounts: accounts,
          sessionId: 'sess-empty',
          data: null,
          playback: playback,
          immersion: immersionBackend,
        );
        final immersion = Immersion(stage: stage, services: nullServices);
        addTearDown(() async {
          immersion.dispose();
          stage.dispose();
          shell.dispose();
          await immersionBackend.close();
          await prefs.close();
          await accounts.close();
        });

        Widget buildWith(EmbyViewServices services) => MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(1440, 900)),
            child: EvThemeScope(
              preferences: prefs,
              child: EvScope(
                services: services,
                stage: stage,
                immersion: immersion,
                shell: shell,
                child: Scaffold(
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      EvStage(controller: stage, immersion: immersion, enableMotion: false),
                      const EvHomePage(enableAnimations: false),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.pumpWidget(buildWith(nullServices));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_home_empty')), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 2. Bind session 1 with real GUID libraryId in hero recommendation.
        var failNext = false;
        final data1 = _FakeHomeData(
          builder: (sort) async {
            if (failNext) throw Exception('refresh failed');
            return HomeData(
              recommendations: [
                HomeRecommendation(
                  card: _makeCard(
                    id: 'guid_hero',
                    title: 'GUID 番剧推荐',
                    kind: MediaKind.series,
                    libraryId: 'lib-guid-anime-01',
                  ),
                  reason: RecommendationReason.daily,
                ),
              ],
              recentMovies: HomeShelf(
                id: 'recent',
                title: '最近添加',
                items: [_makeCard(id: 'm1', title: '电影甲'), _makeCard(id: 'm2', title: '电影乙')],
              ),
              series: HomeShelf(
                id: 'series',
                title: '剧集',
                items: [_makeCard(id: 's1', title: '剧集甲', kind: MediaKind.series)],
              ),
            );
          },
        );
        final services1 = EmbyViewServices(
          preferences: prefs,
          accounts: accounts,
          sessionId: 'sess-1',
          data: data1,
          playback: playback,
          immersion: immersionBackend,
        );
        unawaited(immersion.rebind(services1));
        await tester.pumpWidget(buildWith(services1));
        await tester.pumpAndSettle();

        // Hero resolves library label from shell.zones by GUID.
        expect(find.descendant(of: find.byKey(const Key('ev_hero_reason')), matching: find.text('新番馆')), findsOneWidget);

        // 3. Hovering a card does not trigger full-page EvHomePage rebuild.
        var homeRebuilds = 0;
        final prevHook = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
          prevHook?.call(e, builtOnce);
          if (e.widget is EvHomePage) homeRebuilds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = prevHook);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        final recentCard = find.descendant(of: find.byKey(const Key('ev_home_section_recent')), matching: find.byType(EvCard)).first;
        await mouse.moveTo(tester.getCenter(recentCard));
        await tester.pump(const Duration(milliseconds: 450));
        await mouse.moveTo(const Offset(10, 10));
        await tester.pump(const Duration(milliseconds: 100));
        expect(homeRebuilds, 0);

        // 4. Paper theme scrolled down hover does not request background video (allowVideo: false).
        await tester.drag(find.byKey(const Key('ev_home_scroller')), const Offset(0, -500));
        await tester.pumpAndSettle();
        await tester.ensureVisible(recentCard);
        await tester.pumpAndSettle();
        await mouse.moveTo(tester.getCenter(recentCard));
        await tester.pump(const Duration(seconds: 2));
        expect(data1.themeMediaCalls, isEmpty);
        await mouse.moveTo(const Offset(10, 10));
        await tester.pump(const Duration(milliseconds: 50));

        // 5. Refresh failure keeps existing sections and triggers W7.4 offline notice capsule.
        failNext = true;
        await prefs.update(const LocalPreferences(theme: ThemeMode.paper, seriesSort: ShelfSort.score));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_home_sections')), findsOneWidget);
        expect(find.byKey(const Key('ev_home_error')), findsNothing);
        expect(shell.notice?.kind, EvNoticeKind.offline);

        failNext = false;
        shell.triggerConnectionRetry();
        await tester.pumpAndSettle();
        expect(shell.notice, isNull);

        // 6. Switching sessionId clears previous _home and enters loading skeletons immediately.
        final sess2Completer = Completer<HomeData>();
        final data2 = _FakeHomeData(builder: (_) => sess2Completer.future);
        final services2 = EmbyViewServices(
          preferences: prefs,
          accounts: accounts,
          sessionId: 'sess-2',
          data: data2,
          playback: playback,
          immersion: immersionBackend,
        );
        unawaited(immersion.rebind(services2));
        await tester.pumpWidget(buildWith(services2));
        await tester.pump();
        expect(find.byKey(const Key('ev_home_skeletons')), findsOneWidget);
        expect(find.byKey(const Key('ev_home_sections')), findsNothing);

        sess2Completer.complete(
          HomeData(
            recommendations: [
              HomeRecommendation(card: _makeCard(id: 's2_h', title: '新会话推荐'), reason: RecommendationReason.daily),
            ],
            recentMovies: HomeShelf(id: 'r2', title: '电影', items: [_makeCard(id: 's2_m', title: '新会话电影')]),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('新会话电影'), findsOneWidget);

        // 7. Standalone EvHero circular '+' button invokes onToggleFavorite callback.
        var favTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1440, 900)),
              child: EvThemeScope(
                themeMode: ThemeMode.cinema,
                child: EvHero(
                  recommendations: [
                    HomeRecommendation(
                      card: _makeCard(id: 'fav_test', title: '片单测试'),
                      reason: RecommendationReason.daily,
                    ),
                  ],
                  enableAutoRotate: false,
                  onToggleFavorite: () => favTaps++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ev_hero_favorite_btn')));
        await tester.pump();
        expect(favTaps, 1);
      },
    );

    testWidgets(
      'feature spread distributes all available portrait posters evenly across tilted columns without adjacent duplication',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Verify column assignment for both 6-poster (shortHighRated) and 9-poster (uhdDolbyVision) spreads.
        for (final count in const [6, 9]) {
          final refs = [for (var i = 0; i < count; i++) _FakeArtworkRef('fp_$i')];
          final cols = [for (var ci = 0; ci < 7; ci++) EvFeatureSpread.postersForColumn(refs, ci, 6)];
          final visibleIds = {for (final col in cols) for (final r in col.take(4)) r.id};
          expect(visibleIds.length, count, reason: 'All $count posters should appear across the wall');
          for (var ci = 0; ci < 6; ci++) {
            expect(cols[ci].first.id, isNot(equals(cols[ci + 1].first.id)),
                reason: 'Adjacent columns $ci and ${ci + 1} should not start with the same poster');
          }
        }

        // Verify rendered widget displays all 6 portrait posters inside the tilted wall.
        final sixCards = [for (var i = 0; i < 6; i++) _makeCard(id: 'short_$i', title: '高分短片 $i', posterAspect: 2 / 3)];
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1440, 900)),
              child: EvThemeScope(
                themeMode: ThemeMode.cinema,
                child: Scaffold(
                  body: Center(
                    child: EvFeatureSpread(
                      spread: FeatureSpread(
                        feature: HomeFeature.shortHighRated,
                        posters: sixCards,
                        total: sixCards.length,
                        query: _featureQuery(HomeFeature.shortHighRated),
                      ),
                      title: '100 分钟以内\n的高分电影',
                      accentColor: EvTheme.cinema.movie,
                      doodleIcon: EvIcons.illClock,
                      enableAnimations: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final wallImages = tester.widgetList<Image>(
          find.descendant(of: find.byKey(const Key('ev_feature_wall_shortHighRated')), matching: find.byType(Image)),
        );
        final renderedKeys = {
          for (final img in wallImages)
            if (img.key is ValueKey<String>) (img.key as ValueKey<String>).value.split('_').last,
        };
        for (var i = 0; i < 6; i++) {
          expect(renderedKeys, contains('$i'), reason: 'Poster short_$i must be rendered in feature spread wall');
        }
        expect(renderedKeys.length, 6);
      },
    );

    testWidgets(
      'hovering a card with backdrop at home top (scrollProgress == 0) keeps EvStage sharp without blur in cinema and paper themes',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
          final h = _createHarness(initialPrefs: LocalPreferences(theme: mode));
          await tester.pumpWidget(_wrapHome(h, enableAnimations: false));
          await tester.pumpAndSettle();

          expect(h.stage.mode, EvStageMode.hero);
          expect(h.stage.scrollProgress, 0.0);

          final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: Offset.zero);
          final cwSection = find.byKey(const Key('ev_home_section_continue'));
          final cwCards = find.descendant(of: cwSection, matching: find.byType(EvCard));
          final targetTopLeft = tester.getTopLeft(cwCards.at(1));
          await mouse.moveTo(targetTopLeft + const Offset(40, 24));
          await tester.pump(const Duration(milliseconds: 450));
          await tester.pump(const Duration(milliseconds: 300));

          // Stage swapped to hovered card's clear backdrop with zero veil blur, zero blurfill, zero frame blur.
          expect(h.stage.scrollProgress, 0.0);
          expect(h.stage.activeBackdropKey, contains('home_test_bg_cw_2'));
          expect(find.byKey(const Key('ev_stage_blurfill')), findsNothing);
          expect(find.byKey(const Key('ev_stage_veil_fill')), findsNothing);
          final frameBlur = tester.widget<ImageFiltered>(find.byKey(const Key('ev_stage_frame_blur')));
          expect(frameBlur.enabled, isFalse);

          await mouse.removePointer();
          await tester.pumpWidget(const SizedBox.shrink());
          await h.dispose();
        }
      },
    );

    testWidgets(
      'keyboard focus on home row 1 keeps page at top and swaps hero, lower shelves scroll into view, and moving back up restores top',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final h = _createHarness();
        addTearDown(h.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1440, 900)),
              child: Scaffold(
                body: EvShell(
                  services: h.services,
                  controller: h.shell,
                  stage: h.stage,
                  immersion: h.immersion,
                  configureWindow: false,
                  enableStageMotion: false,
                  homeBuilder: (_) => const EvHomePage(enableAnimations: false),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final scroller = tester.widget<SingleChildScrollView>(find.byKey(const Key('ev_home_scroller'))).controller!;
        final heroFinder = find.byKey(const Key('ev_hero'));
        expect(scroller.offset, closeTo(0.0, 0.5));

        // Direct ArrowDown focuses first row card without scrolling down.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(scroller.offset, closeTo(0.0, 0.5));
        expect(
          FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EvCard>()?.card.id,
          'hero_resume',
        );

        // ArrowRight moves to 2nd card in row 1 -> stays at top, hero & stage follow focus after 0.4s.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(scroller.offset, closeTo(0.0, 0.5));
        expect(
          FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EvCard>()?.card.id,
          'cw_2',
        );
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump(const Duration(milliseconds: 300));
        expect(scroller.offset, closeTo(0.0, 0.5));
        expect(find.descendant(of: heroFinder, matching: find.text('星际穿越')), findsOneWidget);
        expect(h.stage.activeBackdropKey, contains('home_test_bg_cw_2'));

        // ArrowDown from row 1 to lower sections scrolls the page down to bring them into view.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(scroller.offset, greaterThan(100.0));

        // ArrowUp back to row 1 scrolls the page back to the top so the full hero is exposed.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(scroller.offset, closeTo(0.0, 1.0));
        expect(
          FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EvCard>()?.card.id,
          isIn(['hero_resume', 'cw_2']),
        );
      },
    );
  });
}
