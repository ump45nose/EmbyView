import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/home/ev_hero.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/zone/ev_zone_page.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(
    this.id, {
    this.aspectRatio = 2 / 3,
    this.width = 600,
    this.height = 900,
  }) : cacheKey = 'zone_test_$id',
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
  _FakePreferences([LocalPreferences initial = const LocalPreferences()]) : _current = initial;

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
    sessionId: 'zone-sess-1',
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

class _FakeZoneDataService implements EmbyViewData {
  _FakeZoneDataService({
    required this.zoneBuilder,
    this.randomBuilder,
    this.zoneTiles = const [],
  });

  final Future<ZoneData> Function(String zoneId) zoneBuilder;
  final Future<MediaCard?> Function(String zoneId)? randomBuilder;
  final List<ZoneTile> zoneTiles;

  final List<String> zoneCalls = [];
  final List<String> randomCalls = [];

  @override
  Future<ZoneData> zone(String zoneId) {
    zoneCalls.add(zoneId);
    return zoneBuilder(zoneId);
  }

  @override
  Future<MediaCard?> randomInZone(String zoneId) {
    randomCalls.add(zoneId);
    return randomBuilder != null ? randomBuilder!(zoneId) : Future<MediaCard?>.value(null);
  }

  @override
  Future<List<ZoneTile>> zones() async => zoneTiles;

  @override
  Future<ThemeMedia> themeMedia(String itemId) async => const ThemeMedia();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaCard _makeCard({
  required String id,
  required String title,
  MediaKind kind = MediaKind.movie,
  String? libraryId = 'movie',
  int year = 2024,
  double score = 8.6,
  List<String> genres = const ['科幻', '剧情'],
  Duration? duration = const Duration(minutes: 122),
  int? childCount,
  MediaQuality? quality,
  int? episodeNumber,
}) {
  final bgRef = _FakeArtworkRef('bg_$id', aspectRatio: 16 / 9, width: 1920, height: 1080);
  final posterRef = _FakeArtworkRef('poster_$id', aspectRatio: 2 / 3, width: 600, height: 900);
  return MediaCard(
    id: id,
    kind: kind,
    libraryId: libraryId,
    title: title,
    year: year,
    score: score,
    genres: genres,
    duration: duration,
    overview: '这是《$title》的简介内容，用于验证分区页英雄区和卡片渲染。',
    childCount: childCount,
    quality: quality,
    episodeNumber: episodeNumber,
    art: CardArtwork(
      landscape: ArtworkPlan(layers: [ArtworkLayer(source: bgRef, fit: ArtworkFit.cover)], fallbackTitle: title),
      poster: ArtworkPlan(
        layers: [ArtworkLayer(source: posterRef)],
        fallbackTitle: title,
        stack: kind == MediaKind.collection
            ? [_FakeArtworkRef('stk1_$id'), _FakeArtworkRef('stk2_$id')]
            : const [],
      ),
      stage: ArtworkPlan(layers: [ArtworkLayer(source: bgRef, fit: ArtworkFit.cover)], fallbackTitle: title),
      backdrops: [bgRef],
    ),
  );
}

WallQuery _zoneQuery(String zoneId, {WallSort sort = WallSort.title, String? genreId}) => (
  scope: WallScope.zone(zoneId),
  sort: sort,
  watched: WatchFilter.all,
  genreId: genreId,
  years: null,
  technology: null,
);

List<ZoneTile> _allSixZoneTiles() => const [
  ZoneTile(id: 'anime', name: '番剧', iconKey: 'nav_anime', colorSlot: 0, total: 12, unit: '部', episodeTotal: 348),
  ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 733, unit: '部'),
  ZoneTile(id: 'tv', name: '剧集', iconKey: 'nav_tv', colorSlot: 2, total: 92, unit: '部', episodeTotal: 2937),
  ZoneTile(id: 'doc', name: '纪录片', iconKey: 'nav_doc', colorSlot: 3, total: 14, unit: '部', episodeTotal: 208),
  ZoneTile(id: 'box', name: '合集', iconKey: 'nav_box', colorSlot: 4, total: 37, unit: '个'),
  ZoneTile(id: 'custom_dv', name: '杜比视界', iconKey: 'spark', colorSlot: 6, total: 58, unit: '部'),
];

Map<String, ZoneData> _buildSixZonesData() {
  final tiles = {for (final t in _allSixZoneTiles()) t.id: t};

  ZoneData makeZone(
    String id, {
    required int addedThisMonth,
    required MediaKind kind,
    required bool withResume,
    required List<String> genreNames,
  }) {
    final tile = tiles[id]!;
    final hero1 = _makeCard(
      id: '${id}_hero_1',
      title: '${tile.name}精选一',
      kind: kind,
      libraryId: id.startsWith('custom_') ? 'movie' : id,
      score: 9.1,
      genres: genreNames,
      childCount: kind == MediaKind.collection ? 4 : (kind == MediaKind.series ? 2 : null),
      quality: const MediaQuality(resolution: '4K', videoRange: 'Dolby Vision'),
    );
    final hero2 = _makeCard(
      id: '${id}_hero_2',
      title: '${tile.name}精选二',
      kind: kind,
      libraryId: id.startsWith('custom_') ? 'movie' : id,
      score: 8.8,
      genres: genreNames,
      childCount: kind == MediaKind.collection ? 3 : null,
    );
    final cwCard = _makeCard(
      id: '${id}_cw_1',
      title: '${tile.name}续看条目',
      kind: kind,
      libraryId: id.startsWith('custom_') ? 'movie' : id,
      episodeNumber: kind == MediaKind.series ? 5 : null,
      duration: const Duration(minutes: 45),
    );
    final resume = withResume
        ? [
            ResumeCard(
              card: cwCard,
              target: PlayTarget(
                itemId: '${id}_cw_ep5',
                startAt: const Duration(minutes: 20),
                episodeNumber: kind == MediaKind.series ? 5 : null,
              ),
              position: const Duration(minutes: 20),
              duration: const Duration(minutes: 45),
            ),
          ]
        : const <ResumeCard>[];

    final latestItems = [
      _makeCard(
        id: '${id}_lat_1',
        title: '${tile.name}最新甲',
        kind: kind,
        libraryId: id.startsWith('custom_') ? 'movie' : id,
        childCount: kind == MediaKind.collection ? 3 : null,
      ),
      _makeCard(
        id: '${id}_lat_2',
        title: '${tile.name}最新乙',
        kind: kind,
        libraryId: id.startsWith('custom_') ? 'movie' : id,
        childCount: kind == MediaKind.collection ? 5 : null,
      ),
    ];
    final highItems = [
      hero1,
      hero2,
    ];

    return ZoneData(
      zone: tile,
      all: _zoneQuery(id),
      addedThisMonth: addedThisMonth,
      recommendations: [
        HomeRecommendation(card: hero1, reason: RecommendationReason.daily),
        HomeRecommendation(card: hero2, reason: RecommendationReason.daily),
      ],
      continueWatching: resume,
      latest: HomeShelf(
        id: 'latest',
        title: '最近添加',
        items: latestItems,
        more: _zoneQuery(id, sort: WallSort.added),
        total: tile.total,
      ),
      highRated: HomeShelf(
        id: 'score',
        title: '高分精选',
        items: highItems,
        more: _zoneQuery(id, sort: WallSort.score),
        total: 24,
      ),
      genres: [
        for (final g in genreNames)
          HomeShelf(
            id: 'genre_$g',
            title: g,
            items: [
              _makeCard(
                id: '${id}_${g}_1',
                title: '${tile.name}$g代表作',
                kind: kind,
                libraryId: id.startsWith('custom_') ? 'movie' : id,
                genres: [g],
                childCount: kind == MediaKind.collection ? 3 : null,
              ),
            ],
            more: _zoneQuery(id, sort: WallSort.score, genreId: g),
            total: 16,
          ),
      ],
      genreCounts: [
        for (var i = 0; i < genreNames.length; i++)
          FacetOption<String>(value: genreNames[i], label: genreNames[i], count: 16 - i * 3),
      ],
      collage: [
        for (var i = 0; i < 6; i++) _FakeArtworkRef('col_${id}_$i'),
      ],
    );
  }

  return {
    'anime': makeZone('anime', addedThisMonth: 3, kind: MediaKind.series, withResume: true, genreNames: ['奇幻', '动作']),
    'movie': makeZone('movie', addedThisMonth: 18, kind: MediaKind.movie, withResume: true, genreNames: ['科幻', '悬疑']),
    'tv': makeZone('tv', addedThisMonth: 7, kind: MediaKind.series, withResume: true, genreNames: ['剧情', '犯罪']),
    'doc': makeZone('doc', addedThisMonth: 2, kind: MediaKind.series, withResume: false, genreNames: ['自然']),
    'box': makeZone('box', addedThisMonth: 4, kind: MediaKind.collection, withResume: false, genreNames: ['经典系列']),
    'custom_dv': makeZone('custom_dv', addedThisMonth: 9, kind: MediaKind.movie, withResume: true, genreNames: ['杜比精选']),
  };
}

class _ZoneHarness {
  _ZoneHarness({
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
  final _FakeZoneDataService data;
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

_ZoneHarness _createHarness({
  LocalPreferences initialPrefs = const LocalPreferences(),
  Map<String, ZoneData>? zonesMap,
  Future<ZoneData> Function(String zoneId)? zoneBuilder,
  Future<MediaCard?> Function(String zoneId)? randomBuilder,
  ValueChanged<String>? onOpenDetail,
  VoidCallback? onOpenSearch,
  String initialZoneId = 'movie',
  String sessionId = 'zone-sess-1',
}) {
  final map = zonesMap ?? _buildSixZonesData();
  final prefs = _FakePreferences(initialPrefs);
  final accounts = _FakeAccounts();
  final data = _FakeZoneDataService(
    zoneTiles: _allSixZoneTiles(),
    zoneBuilder: zoneBuilder ?? (id) async => map[id]!,
    randomBuilder: randomBuilder ??
        (id) async => _makeCard(
          id: 'random_$id',
          title: '随机影片_$id',
          libraryId: id.startsWith('custom_') ? 'movie' : id,
        ),
  );
  final playback = _FakePlayback();
  final services = EmbyViewServices(
    preferences: prefs,
    accounts: accounts,
    sessionId: sessionId,
    data: data,
    playback: playback,
  );
  final stage = EvStageController();
  final immersion = Immersion(stage: stage, services: services);
  final shell = EvShellController(
    initial: EvZoneDestination(initialZoneId),
    zones: _allSixZoneTiles(),
    onOpenDetail: onOpenDetail,
    onOpenSearch: onOpenSearch,
  );
  return _ZoneHarness(
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

Widget _wrapInScope(
  _ZoneHarness h,
  Widget child, {
  Size size = const Size(1440, 900),
  EmbyViewServices? servicesOverride,
}) {
  final services = servicesOverride ?? h.services;
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: EvThemeScope(
        preferences: services.preferences,
        child: EvScope(
          services: services,
          stage: h.stage,
          immersion: h.immersion,
          shell: h.shell,
          child: Scaffold(
            body: ListenableBuilder(
              listenable: h.shell,
              builder: (context, _) => Stack(
                fit: StackFit.expand,
                children: [
                  EvStage(controller: h.stage, immersion: h.immersion, enableMotion: false),
                  child,
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: EvTopBar(
                      zones: h.shell.zones,
                      activeTabId: h.shell.current.activeTabId,
                      autoTuck: false,
                      scrolled: h.shell.scrolled,
                      topFade: h.shell.topFade,
                      showBack: h.shell.showBack,
                      titlePlate: h.shell.titlePlate,
                      rightActions: h.shell.rightActions,
                      enableWindowDrag: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('playback completion silently refreshes zone data for the current account', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = _buildSixZonesData()['movie']!;
    final refresh = Completer<ZoneData>();
    var calls = 0;
    final h = _createHarness(zoneBuilder: (_) async => ++calls == 1 ? original : refresh.future);
    addTearDown(h.dispose);
    await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: 'movie', enableAnimations: false)));
    await tester.pumpAndSettle();
    h.shell.notifyPlaybackEnded(EvPlaybackEnded('other-user', h.data, const [PlayTarget(itemId: 'movie')]));
    await tester.pump();
    expect(calls, 1);
    h.shell.notifyPlaybackEnded(EvPlaybackEnded(h.services.sessionId, h.data, const [PlayTarget(itemId: 'movie')]));
    await tester.pump();
    expect(calls, 2);
    expect(find.byKey(const Key('ev_zone_skeletons')), findsNothing);
    refresh.complete(original);
    await tester.pumpAndSettle();
    expect(h.data.zoneCalls, ['movie', 'movie']);
  });

  group('C3.11 EvZonePage', () {
    testWidgets(
      'opens all 5 default zones + 1 custom zone, updates title plate, ambient color, hero, and shelf card styles',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final map = _buildSixZonesData();
        final h = _createHarness(zonesMap: map, initialZoneId: 'anime');
        addTearDown(h.dispose);

        final orderedIds = ['anime', 'movie', 'tv', 'doc', 'box', 'custom_dv'];

        for (final zoneId in orderedIds) {
          final expected = map[zoneId]!;
          await tester.pumpWidget(_wrapInScope(h, EvZonePage(zoneId: zoneId, enableAnimations: false)));
          await tester.pumpAndSettle();

          // Top bar title plate matches zone metadata (icon, name, total, unit, addedThisMonth).
          final plate = h.shell.titlePlate;
          expect(plate, isNotNull, reason: 'Zone $zoneId should install titlePlate');
          expect(plate!.iconKey, expected.zone.iconKey);
          expect(plate.title, expected.zone.name);
          expect(plate.colorSlot, expected.zone.colorSlot);
          expect(plate.total, expected.zone.total);
          expect(plate.unit, expected.zone.unit);
          expect(plate.addedThisMonth, expected.addedThisMonth);

          // Top bar renders title plate text & 3 permanent action buttons.
          final plateFinder = find.byKey(const Key('ev_topbar_title_plate'));
          expect(plateFinder, findsOneWidget);
          expect(find.descendant(of: plateFinder, matching: find.text(expected.zone.name)), findsOneWidget);
          expect(
            find.descendant(of: plateFinder, matching: find.text('本月新增 ${expected.addedThisMonth}')),
            findsOneWidget,
          );
          expect(h.shell.rightActions.length, 3);
          expect(find.byKey(const Key('ev_zone_action_all')), findsOneWidget);
          expect(find.byKey(const Key('ev_zone_action_random')), findsOneWidget);
          expect(find.byKey(const Key('ev_zone_action_search')), findsOneWidget);

          // Stage ambient color & backdrop synchronized.
          expect(h.stage.ambientColor, EvTheme.cinema.zoneColor(expected.zone.colorSlot));
          expect(h.stage.activeBackdropKey, contains('zone_test_bg_${zoneId}_hero_1'));

          // First-screen EvHero uses `<zoneName>精选` as default reason label.
          final heroFinder = find.byKey(const Key('ev_hero'));
          expect(heroFinder, findsOneWidget);
          expect(find.byType(EvHero), findsOneWidget);
          expect(find.descendant(of: heroFinder, matching: find.text('${expected.zone.name}精选')), findsOneWidget);
          expect(find.descendant(of: heroFinder, matching: find.text('${expected.zone.name}精选一')), findsOneWidget);

          // Continue watching shelf: present only when non-empty, always landscape.
          final cwFinder = find.byKey(const Key('ev_zone_section_continue'));
          if (expected.continueWatching.isNotEmpty) {
            expect(cwFinder, findsOneWidget);
            final cwShelf = tester.widget<EvShelf>(cwFinder);
            expect(cwShelf.style, EvCardStyle.landscape);
            expect(cwShelf.title, zoneId == 'anime' ? '继续追番' : '继续观看');
          } else {
            expect(cwFinder, findsNothing);
          }

          // Card styles: box -> collection, doc -> landscape, others -> poster.
          final expectedStyle = zoneId == 'box'
              ? EvCardStyle.collection
              : (zoneId == 'doc' ? EvCardStyle.landscape : EvCardStyle.poster);
          final latestShelf = tester.widget<EvShelf>(find.byKey(const Key('ev_zone_section_latest')));
          final highShelf = tester.widget<EvShelf>(find.byKey(const Key('ev_zone_section_high_rated')));
          expect(latestShelf.style, expectedStyle);
          expect(highShelf.style, expectedStyle);
          expect(latestShelf.moreLabel, '看看这 ${expected.zone.total} ${expected.zone.unit}');
          expect(highShelf.moreLabel, '看看这 24 ${expected.zone.unit}');

          // Genre shelf and bottom All-section present in order.
          final firstGenre = expected.genres.first;
          final genreFinder = find.byKey(Key('ev_zone_section_genre_${firstGenre.id}'));
          expect(genreFinder, findsOneWidget);
          expect(tester.widget<EvShelf>(genreFinder).style, expectedStyle);
          expect(find.byKey(const Key('ev_zone_section_all')), findsOneWidget);
          expect(find.text('全部${expected.zone.name}'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        expect(h.data.zoneCalls, orderedIds);

        // Leaving page clears titlePlate, rightActions, and ambientColor.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(h.shell.titlePlate, isNull);
        expect(h.shell.rightActions, isEmpty);
        expect(h.stage.ambientColor, isNull);
      },
    );

    testWidgets(
      'top-bar actions trigger openWall, randomInZone (detail & EvPlayer fallback), search, and shelf/all-section wall links',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final openedDetails = <String>[];
        var searchCount = 0;
        final map = _buildSixZonesData();
        final h = _createHarness(
          zonesMap: map,
          initialZoneId: 'movie',
          onOpenDetail: openedDetails.add,
          onOpenSearch: () => searchCount++,
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: 'movie', enableAnimations: false)));
        await tester.pumpAndSettle();

        // 1. 「浏览全部」 -> shell.openWall(data.all, title: data.zone.name).
        await tester.tap(find.byKey(const Key('ev_zone_action_all')));
        await tester.pump();
        expect(h.shell.current, isA<EvWallDestination>());
        final wallDest = h.shell.current as EvWallDestination;
        expect(wallDest.title, '电影');
        expect((wallDest.query.scope as ZoneWallScope).zoneId, 'movie');
        h.shell.pop();

        // Re-apply zone actions after pop reset (in real shell EvZonePage rebuilds on destination).
        await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: 'custom_dv', enableAnimations: false)));
        await tester.pumpAndSettle();

        // 2. 「随便看看」 -> calls randomInZone and opens detail when onOpenDetail is set.
        await tester.tap(find.byKey(const Key('ev_zone_action_random')));
        await tester.pumpAndSettle();
        expect(h.data.randomCalls, ['custom_dv']);
        expect(openedDetails, ['random_custom_dv']);

        // 3. 「随便看看」 falls back to EvPlayer.open when shell.onOpenDetail is null.
        h.shell.onOpenDetail = null;
        final prevBuilder = EvPlayer.pageBuilder;
        EvPlayer.pageBuilder = (context, session, {origin, art}) => GestureDetector(
          key: const Key('zone_test_player'),
          onTap: () => Navigator.of(context).pop(),
          child: const ColoredBox(color: Color(0xFF000000)),
        );
        addTearDown(() => EvPlayer.pageBuilder = prevBuilder);

        await tester.tap(find.byKey(const Key('ev_zone_action_random')));
        await tester.pumpAndSettle();
        expect(h.data.randomCalls, ['custom_dv', 'custom_dv']);
        expect(h.playback.openedTargets.single.itemId, 'random_custom_dv');
        expect(find.byKey(const Key('zone_test_player')), findsOneWidget);
        await tester.tap(find.byKey(const Key('zone_test_player')));
        await tester.pumpAndSettle();

        // 4. Circular search button -> calls shell.onOpenSearch.
        await tester.tap(find.byKey(const Key('ev_zone_action_search')));
        await tester.pump();
        expect(searchCount, 1);

        // 5. Clicking shelf 「看看这 N 部」 opens wall with shelf's query.
        await tester.ensureVisible(find.text('看看这 24 部'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('看看这 24 部'));
        await tester.pump();
        expect(h.shell.current, isA<EvWallDestination>());
        expect((h.shell.current as EvWallDestination).query.sort, WallSort.score);
        h.shell.pop();

        // 6. Clicking a genre chip in EvZoneAllSection opens wall filtered by genreId.
        final chipFinder = find.byKey(const Key('ev_zone_genre_chip_杜比精选'));
        await tester.ensureVisible(chipFinder);
        await tester.pumpAndSettle();
        await tester.tap(chipFinder);
        await tester.pump();
        expect(h.shell.current, isA<EvWallDestination>());
        expect((h.shell.current as EvWallDestination).query.genreId, '杜比精选');
      },
    );

    testWidgets(
      'syncs scroll with frosted top bar & stage veil, coordinates hover immersion, and reloads on sessionId change',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final h = _createHarness(initialZoneId: 'movie');
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: 'movie', enableAnimations: false)));
        await tester.pumpAndSettle();

        expect(h.shell.scrolled, isFalse);
        expect(h.stage.scrollProgress, 0.0);

        // Hover a card while hero is visible -> previews card in EvHero after 400ms.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        final cwSection = find.byKey(const Key('ev_zone_section_continue'));
        final cwCard = find.descendant(of: cwSection, matching: find.byType(EvCard)).first;
        await mouse.moveTo(tester.getTopLeft(cwCard) + const Offset(40, 30));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.descendant(of: find.byKey(const Key('ev_hero')), matching: find.text('电影续看条目')),
          findsOneWidget,
        );
        expect(h.stage.veilLifted, isFalse);

        // Leave card -> restores original hero recommendation.
        await mouse.moveTo(const Offset(10, 10));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.descendant(of: find.byKey(const Key('ev_hero')), matching: find.text('电影精选一')),
          findsOneWidget,
        );

        // Scroll down -> top bar frosted strip becomes visible, stage scrollProgress > 0, title plate & 3 actions remain.
        await tester.drag(find.byKey(const Key('ev_zone_scroller')), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(h.shell.scrolled, isTrue);
        expect(h.shell.topFade, greaterThan(0.5));
        expect(h.stage.scrollProgress, greaterThan(0.5));
        final frosted = tester.widget<AnimatedOpacity>(find.byKey(const Key('ev_topbar_frosted_bar')));
        expect(frosted.opacity, greaterThan(0.5));
        expect(find.byKey(const Key('ev_topbar_title_plate')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_action_all')), findsOneWidget);

        // Hover card while scrolled down -> lifts stage veil instead of hero preview.
        final latestSection = find.byKey(const Key('ev_zone_section_latest'));
        await tester.ensureVisible(latestSection);
        await tester.pumpAndSettle();
        final latestCard = find.descendant(of: latestSection, matching: find.byType(EvCard)).first;
        await mouse.moveTo(tester.getCenter(latestCard));
        await tester.pump(const Duration(milliseconds: 450));
        expect(h.stage.veilLifted, isTrue);

        await mouse.moveTo(const Offset(10, 10));
        await tester.pump(const Duration(milliseconds: 100));
        expect(h.stage.veilLifted, isFalse);

        // Changing services.sessionId re-requests data.zone(zoneId).
        final callsBefore = h.data.zoneCalls.length;
        final newServices = EmbyViewServices(
          preferences: h.prefs,
          accounts: h.accounts,
          sessionId: 'zone-sess-2',
          data: h.data,
          playback: h.playback,
        );
        await tester.pumpWidget(
          _wrapInScope(h, const EvZonePage(zoneId: 'movie', enableAnimations: false), servicesOverride: newServices),
        );
        await tester.pumpAndSettle();
        expect(h.data.zoneCalls.length, callsBefore + 1);
      },
    );

    testWidgets(
      'shows loading skeletons, handles errors with retry, and skips empty shelves',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var attempt = 0;
        final firstCompleter = Completer<ZoneData>();
        final h = _createHarness(
          initialZoneId: 'movie',
          zoneBuilder: (zoneId) {
            attempt++;
            if (attempt == 1) return firstCompleter.future;
            return Future<ZoneData>.value(
              ZoneData(
                zone: const ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 5, unit: '部'),
                all: _zoneQuery('movie'),
                latest: HomeShelf(
                  id: 'latest',
                  title: '最近添加',
                  items: [_makeCard(id: 'only_1', title: '唯一电影')],
                ),
                genres: [
                  const HomeShelf(id: 'empty_genre', title: '空类型', items: []),
                ],
              ),
            );
          },
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: 'movie', enableAnimations: false)));
        await tester.pump();
        expect(find.byKey(const Key('ev_zone_skeletons')), findsOneWidget);
        expect(find.byType(EvShelfSkeleton), findsNWidgets(2));

        // Fail first attempt -> error state + retry button shown.
        firstCompleter.completeError(Exception('network timeout'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_zone_error')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_retry_btn')), findsOneWidget);

        // Tap retry -> loads minimal ZoneData; empty shelves skipped automatically.
        await tester.tap(find.byKey(const Key('ev_zone_retry_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_zone_error')), findsNothing);
        expect(find.byKey(const Key('ev_zone_section_latest')), findsOneWidget);
        expect(find.byKey(const Key('ev_zone_section_continue')), findsNothing);
        expect(find.byKey(const Key('ev_zone_section_high_rated')), findsNothing);
        expect(find.byKey(const Key('ev_zone_section_genre_empty_genre')), findsNothing);
      },
    );

    testWidgets(
      'renders cleanly without overflow in cinema and paper themes at 1440x900 and 2560x1440 inside EvShell',
      (tester) async {
        final map = _buildSixZonesData();
        for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
          for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;

            final h = _createHarness(
              zonesMap: map,
              initialPrefs: LocalPreferences(theme: mode),
              initialZoneId: 'custom_dv',
              onOpenSearch: () {},
            );

            await tester.pumpWidget(
              MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(size: size),
                  child: EvShell(
                    services: h.services,
                    controller: h.shell,
                    configureWindow: false,
                    enableStageMotion: false,
                    zoneBuilder: (_, id) => EvZonePage(zoneId: id, enableAnimations: false),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();

            final expectedTheme = mode == ThemeMode.paper ? EvTheme.paper : EvTheme.cinema;
            final heroEl = tester.element(find.byKey(const Key('ev_hero')));
            expect(EvTheme.of(heroEl).isPaper, mode == ThemeMode.paper);
            expect(find.byKey(const Key('ev_topbar_title_plate')), findsOneWidget);
            expect(find.byKey(const Key('ev_zone_action_all')), findsOneWidget);
            expect(find.byKey(const Key('ev_zone_action_random')), findsOneWidget);
            expect(find.byKey(const Key('ev_zone_action_search')), findsOneWidget);
            expect(EvScope.of(heroEl).stage.ambientColor, expectedTheme.zoneColor(6));
            expect(tester.takeException(), isNull, reason: 'Overflow/error at $size in $mode');

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            await h.dispose();
          }
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      },
    );

    testWidgets(
      'preserves chrome & shows retryable banner on refresh/randomInZone errors, guards cross-session randomInZone, and supports real Emby GUID zones',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const guidDocId = 'f137a2dd-21bb-c1b9-9aa5-c0f6bf02a805';
        const guidBoxId = '9d42c011-77aa-41e0-8812-33cc99aa0011';
        const guidAnimeId = 'aa112233-4455-6677-8899-aabbccddeeff';

        ZoneData makeGuidZone(String id, String name, String iconKey, MediaKind kind, {bool withResume = false}) {
          final card = _makeCard(id: '${id}_c1', title: '$name条目', kind: kind, libraryId: id);
          return ZoneData(
            zone: ZoneTile(id: id, name: name, iconKey: iconKey, colorSlot: 2, total: 10, unit: '部'),
            all: _zoneQuery(id),
            recommendations: [HomeRecommendation(card: card, reason: RecommendationReason.daily)],
            continueWatching: withResume
                ? [
                    ResumeCard(
                      card: card,
                      target: PlayTarget(itemId: card.id),
                      position: const Duration(minutes: 5),
                      duration: const Duration(minutes: 24),
                    ),
                  ]
                : const [],
            latest: HomeShelf(id: 'latest', title: '最近添加', items: [card]),
          );
        }

        final guidMap = {
          guidDocId: makeGuidZone(guidDocId, '人文纪录', 'documentaries', MediaKind.series),
          guidBoxId: makeGuidZone(guidBoxId, '系列合集', 'boxsets', MediaKind.collection),
          guidAnimeId: makeGuidZone(guidAnimeId, '日漫新番', 'anime', MediaKind.series, withResume: true),
        };

        var failZoneRefresh = false;
        var failRandom = false;
        Completer<MediaCard?>? pendingRandom;
        final openedDetails = <String>[];

        final h = _createHarness(
          initialZoneId: guidDocId,
          onOpenDetail: openedDetails.add,
          zoneBuilder: (id) async {
            if (failZoneRefresh) throw Exception('zone refresh timeout');
            return guidMap[id]!;
          },
          randomBuilder: (id) {
            if (pendingRandom != null) return pendingRandom.future;
            if (failRandom) return Future<MediaCard?>.error(Exception('random failed'));
            return Future<MediaCard?>.value(_makeCard(id: 'rand_$id', title: '随机命中'));
          },
        );
        addTearDown(h.dispose);

        // 1. Real Emby GUID zones infer card styles & anime continue label from iconKey/MediaKind.
        await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: guidDocId, enableAnimations: false)));
        await tester.pumpAndSettle();
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_zone_section_latest'))).style, EvCardStyle.landscape);

        await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: guidBoxId, enableAnimations: false)));
        await tester.pumpAndSettle();
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_zone_section_latest'))).style, EvCardStyle.collection);

        await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: guidAnimeId, enableAnimations: false)));
        await tester.pumpAndSettle();
        expect(tester.widget<EvShelf>(find.byKey(const Key('ev_zone_section_continue'))).title, '继续追番');
        expect(h.shell.titlePlate?.title, '日漫新番');

        // 2. Preference refresh failure keeps top-bar titlePlate & rightActions and shows retryable banner.
        failZoneRefresh = true;
        await h.prefs.update(
          const LocalPreferences(
            zones: [
              ZonePreference(
                id: guidAnimeId,
                name: '日漫新番改名',
                iconKey: 'anime',
                colorSlot: 0,
                rule: LibraryZoneRule(guidAnimeId),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(h.shell.titlePlate, isNotNull);
        expect(h.shell.rightActions.length, 3);
        expect(find.byKey(const Key('ev_zone_error_banner')), findsOneWidget);

        failZoneRefresh = false;
        await tester.tap(find.byKey(const Key('ev_zone_error_banner_retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_zone_error_banner')), findsNothing);

        // 3. _openRandom error surfaces retryable error banner instead of being swallowed.
        failRandom = true;
        await tester.tap(find.byKey(const Key('ev_zone_action_random')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_zone_error_banner')), findsOneWidget);
        expect(openedDetails, isEmpty);

        failRandom = false;
        await tester.tap(find.byKey(const Key('ev_zone_error_banner_retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_zone_error_banner')), findsNothing);
        expect(openedDetails, ['rand_$guidAnimeId']);

        // 4. Cross-session _openRandom race: stale result after session switch is ignored.
        pendingRandom = Completer<MediaCard?>();
        await tester.tap(find.byKey(const Key('ev_zone_action_random')));
        await tester.pump();

        final nextData = _FakeZoneDataService(zoneBuilder: (id) async => guidMap[id]!);
        final nextServices = EmbyViewServices(
          preferences: h.prefs,
          accounts: h.accounts,
          sessionId: 'zone-sess-next',
          data: nextData,
          playback: h.playback,
        );
        await tester.pumpWidget(
          _wrapInScope(h, const EvZonePage(zoneId: guidAnimeId, enableAnimations: false), servicesOverride: nextServices),
        );
        await tester.pumpAndSettle();

        pendingRandom.complete(_makeCard(id: 'stale_random', title: '旧会话随机'));
        await tester.pumpAndSettle();
        expect(openedDetails, ['rand_$guidAnimeId']);
      },
    );

    testWidgets(
      'switching into a loading zone clears stale previous backdrop instead of flashing default hero',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final completer = Completer<ZoneData>();
        final map = _buildSixZonesData();
        final movieData = map['movie']!;
        final h = _createHarness(zonesMap: map, zoneBuilder: (_) => completer.future, initialZoneId: 'movie');
        addTearDown(h.dispose);

        // Pre-populate global stage with an earlier page's hero backdrop (e.g. home default film).
        final staleCard = _makeCard(id: 'tokyo_godfathers', title: '东京教父');
        h.stage
          ..setMode(EvStageMode.hero)
          ..setBaseBackdrop(staleCard.art.stage);
        expect(h.stage.activeBackdropKey, contains('tokyo_godfathers'));

        await tester.pumpWidget(_wrapInScope(h, const EvZonePage(zoneId: 'movie', enableAnimations: false)));
        await tester.pump();

        // While zone data is still loading, stale backdrop must be cleared and stage ambient set to target zone.
        expect(h.stage.activeBackdrop, isNull);
        expect(h.stage.mode, EvStageMode.ambient);
        expect(h.stage.ambientColor, EvTheme.cinema.zoneColor(movieData.zone.colorSlot));

        completer.complete(movieData);
        await tester.pumpAndSettle();

        expect(h.stage.mode, EvStageMode.hero);
        expect(h.stage.activeBackdropKey, contains('zone_test_bg_movie_hero_1'));
      },
    );
  });
}
