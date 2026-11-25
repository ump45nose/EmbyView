import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/material.dart' hide Page, ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_page.dart';
import 'package:moonfin/embyview/ui/home/ev_home_page.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/quicklook/ev_quicklook.dart';
import 'package:moonfin/embyview/ui/wall/ev_wall_page.dart';
import 'package:moonfin/embyview/ui/zone/ev_zone_page.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(this.id, {this.aspectRatio = 16 / 9, this.width = 1920, this.height = 1080})
    : cacheKey = 'ql_test_$id',
      image = MemoryImage(_kPngBytes);

  @override final String id;
  @override final String cacheKey;
  @override final ImageProvider<Object> image;
  @override final double? aspectRatio;
  @override final int? width;
  @override final int? height;
}

class _FakePreviewRef implements PreviewRef {
  const _FakePreviewRef({required this.id, required this.name});
  @override final String id;
  @override final String name;
  @override Duration? get duration => null;
}

class _FakePreferences implements EmbyViewPreferences {
  _FakePreferences([LocalPreferences initial = const LocalPreferences()]) : _current = initial;
  LocalPreferences _current;
  final _changes = StreamController<LocalPreferences>.broadcast();

  @override LocalPreferences get current => _current;
  @override Stream<LocalPreferences> get changes => _changes.stream;
  @override Future<void> update(LocalPreferences value) async {
    _current = value;
    _changes.add(value);
  }
  Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccounts implements EmbyViewAccounts {
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final _snapshot = const AccountSnapshot(
    phase: AccountPhase.signedIn,
    current: AccountProfile(id: 'sfw', displayName: 'sfw'),
    profiles: [AccountProfile(id: 'sfw', displayName: 'sfw')],
    sessionId: 'ql-sess-1',
  );
  @override AccountSnapshot get snapshot => _snapshot;
  @override Stream<AccountSnapshot> get changes => _changes.stream;
  Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlaybackSession implements PlaybackSession {
  _FakePlaybackSession(this.target);
  final PlayTarget target;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();
  @override PlaybackSnapshot get snapshot => PlaybackSnapshot(generation: 1, target: target);
  @override Stream<PlaybackSnapshot> get changes => _changes.stream;
  @override Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF000000));
  @override Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayback implements EmbyViewPlayback {
  final List<PlayTarget> openedTargets = [];
  @override Future<void> prepare(String itemId) async {}
  @override PlaybackSession open(PlayTarget target) {
    openedTargets.add(target);
    return _FakePlaybackSession(target);
  }
}

class _FakeImmersionPlayback implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast();
  ImmersionSnapshot _snapshot = const ImmersionSnapshot();
  final List<PreviewRef?> showVideoCalls = [];

  @override ImmersionSnapshot get snapshot => _snapshot;
  @override Stream<ImmersionSnapshot> get changes => _changes.stream;
  @override Widget videoSurface({Key? key}) => Container(key: const Key('fake_immersion_video_surface'), color: const Color(0xFF101820));

  @override
  Future<void> showMutedVideo(PreviewRef? video) async {
    showVideoCalls.add(video);
    _snapshot = ImmersionSnapshot(video: video == null ? PreviewState.idle : PreviewState.ready);
    _changes.add(_snapshot);
  }

  @override Future<void> playTheme(PreviewRef? song) async {}
  @override Future<void> setThemeMuted(bool muted) async {}
  @override Future<void> stop() async {
    _snapshot = const ImmersionSnapshot();
    _changes.add(_snapshot);
  }
  Future<void> close() => _changes.close();
}

class _FakeSubtitles implements EmbyViewSubtitles {
  _FakeSubtitles(this.byId);
  final Map<String, SubtitleAvailability> byId;
  final List<String> calls = [];
  final _jobs = StreamController<List<SeasonJob>>.broadcast();

  @override
  Future<SubtitleAvailability> availability(String itemId) async {
    calls.add(itemId);
    return byId[itemId] ?? const SubtitleAvailability();
  }

  @override Stream<List<SeasonJob>> get jobs => _jobs.stream;
  Future<void> close() => _jobs.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWallListing implements WallListing {
  _FakeWallListing(this.items) : info = WallInfo(total: items.length);
  final List<MediaCard> items;
  @override final WallInfo info;
  @override
  Future<Page<MediaCard>> page({required int offset, required int limit}) async {
    final end = (offset + limit).clamp(0, items.length);
    final slice = offset >= items.length ? const <MediaCard>[] : items.sublist(offset, end);
    return Page<MediaCard>(items: slice, total: items.length, nextOffset: end < items.length ? end : null);
  }
}

class _FakeData implements EmbyViewData {
  _FakeData({
    this.homeData,
    this.zoneData,
    this.wallItems = const [],
    this.detailData,
    this.seasonsData = const [],
    this.episodesBySeason = const {},
    this.similarItems = const [],
    this.themeById = const {},
    this.qualityById = const {},
  });

  final HomeData? homeData;
  final ZoneData? zoneData;
  final List<MediaCard> wallItems;
  final MediaDetail? detailData;
  final List<SeasonSummary> seasonsData;
  final Map<String, SeasonEpisodes> episodesBySeason;
  final List<MediaCard> similarItems;
  final Map<String, ThemeMedia> themeById;
  final Map<String, MediaQuality> qualityById;

  @override Future<HomeData> home({required ShelfSort seriesSort}) async => homeData ?? const HomeData();
  @override Future<List<ZoneTile>> zones() async => homeData?.zones ?? const [];
  @override Future<ZoneData> zone(String zoneId) async => zoneData!;
  @override Future<WallListing> openWall(WallQuery query) async => _FakeWallListing(wallItems);
  @override Future<WallFacets> wallFacets(WallQuery query) async => const WallFacets();
  @override Future<MediaDetail> detail(String itemId) async => detailData!;
  @override Future<List<SeasonSummary>> seasons(String seriesId) async => seasonsData;
  @override Future<SeasonEpisodes> episodes(String seriesId, String seasonId) async => episodesBySeason[seasonId]!;
  @override Future<List<PersonCredit>> people(String itemId) async => const [];
  @override Future<List<MediaCard>> similar(String itemId, {int limit = 16}) async => similarItems;
  @override Future<List<ArtworkRef>> safeEpisodeStills(String seriesId) async => const [];
  @override Future<ThemeMedia> themeMedia(String itemId) async => themeById[itemId] ?? const ThemeMedia();
  @override Future<MediaQuality?> quality(String itemId) async => qualityById[itemId];
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaCard _makeCard({
  required String id,
  required String title,
  MediaKind kind = MediaKind.movie,
  int year = 2024,
  double score = 8.7,
  List<String> genres = const ['科幻', '动作'],
  Duration? duration = const Duration(minutes: 132),
  String? rating = 'PG-13',
  String? overview = '一段关于深空探索与人类命运的史诗旅程，涵盖跨星系迁徙、时间悖论与归途抉择，用来验证多行简介在双主题和大屏分辨率下的排布表现。',
  int? childCount,
  MediaQuality? quality,
  bool withLogo = false,
}) {
  final bg = _FakeArtworkRef('bg_$id');
  final poster = _FakeArtworkRef('p_$id', aspectRatio: 2 / 3, width: 600, height: 900);
  final logo = withLogo ? _FakeArtworkRef('logo_$id', aspectRatio: 3.0, width: 900, height: 300) : null;
  return MediaCard(
    id: id,
    kind: kind,
    libraryId: 'movie',
    title: title,
    year: year,
    score: score,
    genres: genres,
    duration: duration,
    rating: rating,
    overview: overview,
    childCount: childCount,
    quality: quality,
    art: CardArtwork(
      landscape: ArtworkPlan(layers: [ArtworkLayer(source: bg, fit: ArtworkFit.cover)], fallbackTitle: title),
      poster: ArtworkPlan(layers: [ArtworkLayer(source: poster)], fallbackTitle: title),
      stage: ArtworkPlan(layers: [ArtworkLayer(source: bg, fit: ArtworkFit.cover)], fallbackTitle: title),
      backdrops: [bg],
      logo: logo,
    ),
  );
}

WallQuery _zoneQuery(String zoneId) => (
  scope: WallScope.zone(zoneId),
  sort: WallSort.title,
  watched: WatchFilter.all,
  genreId: null,
  years: null,
  technology: null,
);

Future<void> _focusWidget(WidgetTester tester, Finder widgetFinder) async {
  final target = find.descendant(of: widgetFinder, matching: find.byType(MouseRegion)).first;
  Focus.of(tester.element(target)).requestFocus();
  await tester.pump();
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('C4.6: Home EvCard space opens QuickLook without mis-triggering play, Enter plays, Space/Esc closes', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final prefs = _FakePreferences();
    final accounts = _FakeAccounts();
    final playback = _FakePlayback();
    final immersionPlayback = _FakeImmersionPlayback();
    final stage = EvStageController();
    final shell = EvShellController();
    final detailOpens = <String>[];
    shell.onOpenDetail = detailOpens.add;

    final resumeCard = _makeCard(
      id: 'm_resume',
      title: '星际迷航',
      quality: const MediaQuality(resolution: '4K', videoRange: 'Dolby Vision', audioLabel: 'Atmos', origin: MediaOrigin.direct115),
    );
    final resume = ResumeCard(
      card: resumeCard,
      target: const PlayTarget(itemId: 'm_resume', startAt: Duration(minutes: 42)),
      position: const Duration(minutes: 42),
      duration: const Duration(minutes: 132),
    );
    final movieCard = _makeCard(id: 'm_recent', title: '沙丘前传');
    final data = _FakeData(
      homeData: HomeData(
        recommendations: [HomeRecommendation(card: movieCard, reason: RecommendationReason.daily)],
        continueWatching: [resume],
        recentMovies: HomeShelf(id: 'recent', title: '最近添加', items: [movieCard]),
      ),
    );
    final services = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 's1',
      data: data, playback: playback, immersion: immersionPlayback,
    );
    final immersion = Immersion(stage: stage, services: services);
    final controller = EvQuickLookController();
    final playedCalls = <(PlayTarget, Rect?)>[];

    addTearDown(() async {
      controller.dispose();
      immersion.dispose();
      stage.dispose();
      shell.dispose();
      await immersionPlayback.close();
      await prefs.close();
      await accounts.close();
    });

    await tester.pumpWidget(MaterialApp(
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: services, stage: stage, immersion: immersion, shell: shell,
          child: EvQuickLookHost(
            controller: controller,
            onPlayTarget: (target, _, origin) => playedCalls.add((target, origin)),
            child: const EvHomePage(enableAnimations: false),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Focus the Continue Watching EvCard and press Space.
    final resumeFinder = find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'm_resume');
    await _focusWidget(tester, resumeFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(controller.isOpen, isTrue);
    expect(find.byKey(const Key('ev_quicklook_overlay')), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);
    expect(playback.openedTargets, isEmpty);
    expect(detailOpens, isEmpty);
    expect(playedCalls, isEmpty);

    // Space again closes QuickLook.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(find.byKey(const Key('ev_quicklook_overlay')), findsNothing);

    // Re-open with Space, then press Enter -> closes QuickLook and triggers play with resume target & media rect.
    await _focusWidget(tester, resumeFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(playedCalls, hasLength(1));
    expect(playedCalls.single.$1.itemId, 'm_resume');
    expect(playedCalls.single.$1.startAt, const Duration(minutes: 42));
    expect(playedCalls.single.$2, isNotNull);
    expect(playedCalls.single.$2!.width, greaterThan(400));

    // Focus regular movie card -> shows 「播放」, NumpadEnter plays, and Esc/Close button close it.
    final recentFinder = find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'm_recent');
    await _focusWidget(tester, recentFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isTrue);
    expect(find.text('播放'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(find.byKey(const Key('ev_quicklook_overlay')), findsNothing);

    await _focusWidget(tester, recentFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(playedCalls, hasLength(2));
    expect(playedCalls.last.$1.itemId, 'm_recent');
    expect(tester.takeException(), isNull);
  });

  testWidgets('C4.6: ZonePage and WallPage EvCards open QuickLook, Detail button and backdrop close work', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final prefs = _FakePreferences();
    final accounts = _FakeAccounts();
    final playback = _FakePlayback();
    final immersionPlayback = _FakeImmersionPlayback();
    final stage = EvStageController();
    final shell = EvShellController();
    final detailOpens = <String>[];
    shell.onOpenDetail = detailOpens.add;

    final zCard = _makeCard(id: 'z_movie', title: '专区电影');
    final wCard = _makeCard(id: 'w_movie', title: '海报墙电影');
    final zoneTile = const ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 10, unit: '部');
    final data = _FakeData(
      zoneData: ZoneData(
        zone: zoneTile,
        all: _zoneQuery('movie'),
        recommendations: [HomeRecommendation(card: zCard, reason: RecommendationReason.daily)],
        latest: HomeShelf(id: 'latest', title: '最近添加', items: [zCard]),
      ),
      wallItems: [wCard],
    );
    final services = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 's1',
      data: data, playback: playback, immersion: immersionPlayback,
    );
    final immersion = Immersion(stage: stage, services: services);
    final controller = EvQuickLookController();

    addTearDown(() async {
      controller.dispose();
      immersion.dispose();
      stage.dispose();
      shell.dispose();
      await immersionPlayback.close();
      await prefs.close();
      await accounts.close();
    });

    // 1. ZonePage
    await tester.pumpWidget(MaterialApp(
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: services, stage: stage, immersion: immersion, shell: shell,
          child: EvQuickLookHost(
            controller: controller,
            child: const EvZonePage(zoneId: 'movie', enableAnimations: false),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final zoneCardFinder = find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'z_movie');
    await _focusWidget(tester, zoneCardFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(controller.isOpen, isTrue);
    expect(playback.openedTargets, isEmpty);
    expect(detailOpens, isEmpty);

    // Click Detail button -> closes QuickLook and invokes shell.onOpenDetail.
    await tester.tap(find.byKey(const Key('ev_quicklook_detail_btn')));
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(detailOpens, ['z_movie']);

    // 2. WallPage
    final wallTaps = <String>[];
    final wallPlays = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: services, stage: stage, immersion: immersion, shell: shell,
          child: EvQuickLookHost(
            controller: controller,
            child: EvWallPage(
              initialQuery: _zoneQuery('movie'),
              title: '电影',
              onOpenItem: (c) => wallTaps.add(c.id),
              onPlayItem: (c) => wallPlays.add(c.id),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final wallCardFinder = find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'w_movie');
    await _focusWidget(tester, wallCardFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(controller.isOpen, isTrue);
    expect(wallTaps, isEmpty);
    expect(wallPlays, isEmpty);

    // Tap external backdrop scrim -> closes QuickLook.
    await tester.tapAt(const Offset(24, 24));
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C4.6: DetailPage EpisodeCard (via resolveFocusTarget) & Similar EvCard both open QuickLook', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final prefs = _FakePreferences();
    final accounts = _FakeAccounts();
    final playback = _FakePlayback();
    final immersionPlayback = _FakeImmersionPlayback();
    final stage = EvStageController();
    final shell = EvShellController();

    final seriesCard = _makeCard(id: 's_main', title: '王者天下', kind: MediaKind.series, childCount: 1);
    final epCard = _makeCard(id: 'ep_1', title: '无名少年', kind: MediaKind.episode, duration: const Duration(minutes: 25));
    final simCard = _makeCard(id: 'sim_1', title: '相似番剧');
    const season = SeasonSummary(id: 'sea_1', name: '第 1 季', number: 1, total: 1);
    final ep = EpisodeCard(card: epCard, episodeNumber: 1, played: true, still: epCard.art.landscape);
    final data = _FakeData(
      detailData: MediaDetail(card: seriesCard, episodeCount: 1),
      seasonsData: const [season],
      episodesBySeason: {'sea_1': SeasonEpisodes(season: season, episodes: [ep], playedCount: 1)},
      similarItems: [simCard],
    );
    final services = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 's1',
      data: data, playback: playback, immersion: immersionPlayback,
    );
    final immersion = Immersion(stage: stage, services: services);
    final controller = EvQuickLookController();
    final detailPlayCalls = <String>[];
    final detailOpenCalls = <String>[];

    addTearDown(() async {
      controller.dispose();
      immersion.dispose();
      stage.dispose();
      shell.dispose();
      await immersionPlayback.close();
      await prefs.close();
      await accounts.close();
    });

    await tester.pumpWidget(MaterialApp(
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: services, stage: stage, immersion: immersion, shell: shell,
          child: EvQuickLookHost(
            controller: controller,
            resolveFocusTarget: (ctx) {
              final epWidget = ctx.findAncestorWidgetOfExactType<EvEpisodeCard>();
              if (epWidget == null) return null;
              final ro = ctx.findRenderObject();
              final rect = ro is RenderBox && ro.hasSize ? (ro.localToGlobal(Offset.zero) & ro.size) : null;
              return EvQuickLookTarget(card: epWidget.card, origin: rect);
            },
            child: EvDetailPage(
              itemId: 's_main',
              enableAnimations: false,
              onOpenItem: detailOpenCalls.add,
              onPlayTarget: (t, _, _) => detailPlayCalls.add(t.itemId),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 1. Episode card resolved via resolveFocusTarget
    final epFinder = find.byType(EvEpisodeCard).first;
    await _focusWidget(tester, epFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isTrue);
    expect(controller.current?.card.id, 'ep_1');
    expect(detailPlayCalls, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);

    // 2. Similar EvCard resolved via default EvCard ancestor fallback
    final simFinder = find.byWidgetPredicate((w) => w is EvCard && w.card.id == 'sim_1');
    await _focusWidget(tester, simFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(controller.isOpen, isTrue);
    expect(controller.current?.card.id, 'sim_1');
    expect(detailOpenCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Media video/artwork, Logo fallback, quality merge, and subtitle states (complete/partial/canGenerate/null)', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final prefs = _FakePreferences();
    final accounts = _FakeAccounts();
    final immersionPlayback = _FakeImmersionPlayback();
    final stage = EvStageController();
    final shell = EvShellController();

    final clip = const _FakePreviewRef(id: 'clip_1', name: '片段');
    final trailer = const _FakePreviewRef(id: 'tr_2', name: '预告');

    final cComplete = _makeCard(id: 'c_ok', title: '有中字片', withLogo: true);
    final cPartial = _makeCard(id: 'c_part', title: '部分中字片', withLogo: false);
    final cGen = _makeCard(
      id: 'c_gen',
      title: '可生成片',
      quality: const MediaQuality(resolution: '4K', videoRange: 'HDR', origin: MediaOrigin.nasLocal),
    );

    final data = _FakeData(
      themeById: {
        'c_ok': ThemeMedia(backgroundVideo: clip),
        'c_part': ThemeMedia(trailer: trailer),
      },
      qualityById: {
        'c_ok': const MediaQuality(resolution: '4K', videoRange: 'Dolby Vision', audioLabel: 'Atmos', origin: MediaOrigin.direct115),
        'c_part': const MediaQuality(resolution: '4K', origin: MediaOrigin.nasLocal),
      },
    );
    final subtitles = _FakeSubtitles({
      'c_ok': const SubtitleAvailability(chinese: ChineseSubtitleState.complete, nasTrackCount: 1),
      'c_part': const SubtitleAvailability(chinese: ChineseSubtitleState.partial),
      'c_gen': const SubtitleAvailability(chinese: ChineseSubtitleState.canGenerate),
    });

    final services = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 's1',
      data: data, immersion: immersionPlayback, subtitles: subtitles,
    );
    final immersion = Immersion(stage: stage, services: services);
    final controller = EvQuickLookController();

    addTearDown(() async {
      controller.dispose();
      immersion.dispose();
      stage.dispose();
      shell.dispose();
      await subtitles.close();
      await immersionPlayback.close();
      await prefs.close();
      await accounts.close();
    });

    await tester.pumpWidget(MaterialApp(
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: services, stage: stage, immersion: immersion, shell: shell,
          child: EvQuickLookHost(controller: controller, child: const SizedBox.expand()),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 1. Complete subtitle + backgroundVideo + Logo + merged 4K DV Atmos 115
    controller.open(EvQuickLookTarget(card: cComplete));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ev_quicklook_artwork')), findsOneWidget);
    expect(immersionPlayback.showVideoCalls.last, clip);
    expect(find.byKey(const Key('fake_immersion_video_surface')), findsOneWidget);
    expect(find.byKey(ValueKey<String>('ev_quicklook_logo_${cComplete.art.logo!.cacheKey}')), findsOneWidget);
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('DOLBY VISION'), findsOneWidget);
    expect(find.text('Atmos'), findsOneWidget);
    expect(find.text('115 直连'), findsOneWidget);
    expect(find.text('中字已就绪 · NAS 外挂'), findsOneWidget);
    expect(find.text('115 直连 · 首帧约 1.7 秒'), findsOneWidget);

    // Closing stops video
    controller.close();
    await tester.pumpAndSettle();
    expect(immersionPlayback.showVideoCalls.last, isNull);

    // 2. Partial subtitle + trailer fallback + fallback bold title + NAS origin
    controller.open(EvQuickLookTarget(card: cPartial));
    await tester.pumpAndSettle();
    expect(immersionPlayback.showVideoCalls.last, trailer);
    expect(find.byKey(const Key('ev_quicklook_title')), findsOneWidget);
    expect(find.text('部分中字 · 可补全'), findsOneWidget);
    expect(find.text('NAS 本地 · 直接播放'), findsOneWidget);

    // 3. canGenerate subtitle + fallback to card.quality when data.quality returns null + close button
    controller.open(EvQuickLookTarget(card: cGen));
    await tester.pumpAndSettle();
    expect(find.text('没有中字 · 可一键 AI 生成'), findsOneWidget);
    expect(find.text('HDR'), findsOneWidget);
    expect(find.text('NAS 本地 · 直接播放'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ev_quicklook_close_btn')));
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);

    // 4. Embedded Chinese subtitle + backgroundVideo == false skips video preview
    await prefs.update(const LocalPreferences(backgroundVideo: false));
    final prevCalls = immersionPlayback.showVideoCalls.length;
    subtitles.byId['c_emb'] = const SubtitleAvailability(chinese: ChineseSubtitleState.complete, hasEmbeddedChinese: true);
    controller.open(EvQuickLookTarget(card: _makeCard(id: 'c_emb', title: '内嵌字幕片')));
    await tester.pumpAndSettle();
    expect(find.text('中字已就绪 · 内嵌'), findsOneWidget);
    expect(immersionPlayback.showVideoCalls.length, prevCalls);
    controller.close();
    await tester.pumpAndSettle();

    // 5. subtitles == null hides subtitle pill completely
    final noSubServices = EmbyViewServices(
      preferences: prefs, accounts: accounts, sessionId: 's1',
      data: data, immersion: immersionPlayback, subtitles: null,
    );
    await tester.pumpWidget(MaterialApp(
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: noSubServices, stage: stage, immersion: immersion, shell: shell,
          child: EvQuickLookHost(controller: controller, child: const SizedBox.expand()),
        ),
      ),
    ));
    controller.open(EvQuickLookTarget(card: cComplete));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_quicklook_sub_pill')), findsNothing);
    expect(find.byKey(const Key('ev_quicklook_origin_pill')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Guards: quickLook == false, isSuppressed, EditableText do not intercept Space; dispose restores key handler', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    // ignore: deprecated_member_use
    final initialHandler = ServicesBinding.instance.keyEventManager.keyMessageHandler;

    final prefs = _FakePreferences(const LocalPreferences(quickLook: false));
    final accounts = _FakeAccounts();
    final stage = EvStageController();
    final shell = EvShellController();
    final services = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: 's1');
    final immersion = Immersion(stage: stage, services: services);
    final controller = EvQuickLookController();

    addTearDown(() async {
      controller.dispose();
      immersion.dispose();
      stage.dispose();
      shell.dispose();
      await prefs.close();
      await accounts.close();
    });

    final card = _makeCard(id: 'g1', title: '测试卡片');
    var cardPlayCount = 0;
    var suppressed = false;
    final textController = TextEditingController();
    final textFocus = FocusNode();
    addTearDown(() {
      textController.dispose();
      textFocus.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: services, stage: stage, immersion: immersion, shell: shell,
          child: EvQuickLookHost(
            controller: controller,
            isSuppressed: () => suppressed,
            child: Column(
              children: [
                EvCard(card: card, style: EvCardStyle.poster, width: 180, onPlay: () => cardPlayCount++),
                SizedBox(
                  width: 240,
                  child: EditableText(
                    controller: textController,
                    focusNode: textFocus,
                    style: const TextStyle(color: Color(0xFFFFFFFF)),
                    cursorColor: const Color(0xFFFFFFFF),
                    backgroundCursorColor: const Color(0xFF888888),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 1. quickLook == false -> Space reaches EvCard._handleKey and QuickLook stays closed.
    await _focusWidget(tester, find.byType(EvCard));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(cardPlayCount, 1);

    // 2. Enable quickLook, but suppress via isSuppressed -> does not open.
    await prefs.update(const LocalPreferences(quickLook: true));
    suppressed = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.isOpen, isFalse);
    expect(cardPlayCount, 2);

    // 3. Unsuppress, focus EditableText -> Space does not open QuickLook.
    suppressed = false;
    textFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.isOpen, isFalse);

    // 4. Unmount EvQuickLookHost -> restores original keyMessageHandler cleanly.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // ignore: deprecated_member_use
    expect(ServicesBinding.instance.keyEventManager.keyMessageHandler, same(initialHandler));
    expect(tester.takeException(), isNull);
  });

  for (final themeMode in [ThemeMode.cinema, ThemeMode.paper]) {
    for (final size in [const Size(1440, 900), const Size(2560, 1440)]) {
      testWidgets('No overflow in ${themeMode.name} theme at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await _setViewport(tester, size);
        final prefs = _FakePreferences(LocalPreferences(theme: themeMode, backgroundVideo: false));
        final accounts = _FakeAccounts();
        final stage = EvStageController();
        final shell = EvShellController();
        final card = _makeCard(
          id: 'ov_${themeMode.name}',
          title: '非常长的电影标题用于双主题与高分屏布局溢出检查',
          quality: const MediaQuality(
            resolution: '4K', videoRange: 'Dolby Vision', audioLabel: 'Dolby Atmos', origin: MediaOrigin.direct115,
          ),
        );
        final subtitles = _FakeSubtitles({
          card.id: const SubtitleAvailability(chinese: ChineseSubtitleState.complete, hasAiChinese: true),
        });
        final services = EmbyViewServices(
          preferences: prefs, accounts: accounts, sessionId: 's1', subtitles: subtitles,
        );
        final immersion = Immersion(stage: stage, services: services);
        final controller = EvQuickLookController();

        addTearDown(() async {
          controller.dispose();
          immersion.dispose();
          stage.dispose();
          shell.dispose();
          await subtitles.close();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(MaterialApp(
          home: EvThemeScope(
            preferences: prefs,
            child: EvScope(
              services: services, stage: stage, immersion: immersion, shell: shell,
              child: EvQuickLookHost(controller: controller, child: const SizedBox.expand()),
            ),
          ),
        ));
        controller.open(EvQuickLookTarget(card: card, origin: const Rect.fromLTWH(120, 420, 200, 300)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_quicklook_window')), findsOneWidget);
        expect(find.text('中字已就绪 · AI 中字'), findsOneWidget);
        expect(find.text('115 直连 · 首帧约 1.7 秒'), findsOneWidget);
        final overviewWidget = tester.widget<Text>(find.byKey(const Key('ev_quicklook_overview')));
        expect(overviewWidget.maxLines, 3);
        expect(overviewWidget.overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Regressions: single logo (strips stage logo/text), 56rem + 2.2:1 + 2-column layout, and overlapping hosts zero leak', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    // ignore: deprecated_member_use
    final initialHandler = ServicesBinding.instance.keyEventManager.keyMessageHandler;

    final prefs = _FakePreferences(const LocalPreferences(backgroundVideo: false));
    final accounts = _FakeAccounts();
    final stage = EvStageController();
    final shell = EvShellController();
    final services = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: 's1');
    final immersion = Immersion(stage: stage, services: services);
    final ctrlA = EvQuickLookController(), ctrlB = EvQuickLookController();

    addTearDown(() async {
      ctrlA.dispose(); ctrlB.dispose(); immersion.dispose(); stage.dispose(); shell.dispose();
      await prefs.close(); await accounts.close();
    });

    final bg = _FakeArtworkRef('stage_bg');
    final logo = _FakeArtworkRef('stage_logo', aspectRatio: 3.0, width: 900, height: 300);
    final card = MediaCard(
      id: 'dup_logo_card', kind: MediaKind.movie, title: '双标测试片', year: 2025, score: 9.0,
      overview: '测试舞台图层带 logo 与文字时底层 EvArtwork 不重复渲染。',
      art: CardArtwork(
        stage: ArtworkPlan(layers: [ArtworkLayer(source: bg, fit: ArtworkFit.cover, logo: logo, text: '双标测试片')], fallbackColor: 0xFF112233, fallbackTitle: '双标测试片'),
        backdrops: [bg], logo: logo,
      ),
    );

    final showA = ValueNotifier<bool>(true), showB = ValueNotifier<bool>(false);
    addTearDown(() { showA.dispose(); showB.dispose(); });

    await tester.pumpWidget(MaterialApp(
      home: EvThemeScope(
        preferences: prefs,
        child: EvScope(
          services: services, stage: stage, immersion: immersion, shell: shell,
          child: ValueListenableBuilder<bool>(
            valueListenable: showA,
            builder: (_, aOn, _) => ValueListenableBuilder<bool>(
              valueListenable: showB,
              builder: (_, bOn, _) => Stack(children: [
                if (aOn) EvQuickLookHost(controller: ctrlA, child: const SizedBox.expand()),
                if (bOn) EvQuickLookHost(controller: ctrlB, child: Center(child: EvCard(card: card, style: EvCardStyle.poster, width: 180))),
              ]),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Mount Host B while Host A is still alive (overlapping lifecycle), then dispose Host A first.
    showB.value = true;
    await tester.pumpAndSettle();
    showA.value = false;
    await tester.pumpAndSettle();

    // Host B must still intercept Space before EvCard._handleKey.
    await _focusWidget(tester, find.byType(EvCard));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(ctrlB.isOpen, isTrue);

    // 1. Single logo: EvArtwork plan has stripped logo/text, and only one logo Image exists inside media.
    final artWidget = tester.widget<EvArtwork>(find.byKey(const Key('ev_quicklook_artwork')));
    expect(artWidget.plan.layers.single.logo, isNull);
    expect(artWidget.plan.layers.single.text, isNull);
    expect(artWidget.plan.fallbackColor, 0xFF112233);
    expect(find.byKey(ValueKey<String>('ev_quicklook_logo_${logo.cacheKey}')), findsOneWidget);
    expect(find.byKey(ValueKey<String>('ev_art_logo_0_${logo.cacheKey}')), findsNothing);

    // 2. Layout: 56rem width (896px at 1440), 2.2:1 media ratio, two-column body with vertically stacked actions on right.
    final scale = EvScale.fromSize(const Size(1440, 900));
    final winRect = tester.getRect(find.byKey(const Key('ev_quicklook_window')));
    expect(winRect.width, closeTo(scale.rem(56.0), 0.5));
    final mediaRect = tester.getRect(find.byKey(const Key('ev_quicklook_artwork')));
    expect(mediaRect.width / mediaRect.height, closeTo(2.2, 0.02));

    final ovRect = tester.getRect(find.byKey(const Key('ev_quicklook_overview')));
    final actRect = tester.getRect(find.byKey(const Key('ev_quicklook_actions')));
    final playRect = tester.getRect(find.byKey(const Key('ev_quicklook_play_btn')));
    final detailRect = tester.getRect(find.byKey(const Key('ev_quicklook_detail_btn')));
    final closeRect = tester.getRect(find.byKey(const Key('ev_quicklook_close_btn')));
    expect(actRect.left, greaterThan(ovRect.left));
    expect(detailRect.top, greaterThanOrEqualTo(playRect.bottom));
    expect(closeRect.top, greaterThanOrEqualTo(detailRect.bottom));

    // 3. Unmount remaining Host B -> original keyMessageHandler restored cleanly.
    showB.value = false;
    await tester.pumpAndSettle();
    // ignore: deprecated_member_use
    expect(ServicesBinding.instance.keyEventManager.keyMessageHandler, same(initialHandler));
    expect(tester.takeException(), isNull);
  });
}
