import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/wall/ev_alpha_bar.dart';
import 'package:moonfin/embyview/ui/wall/ev_wall_page.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(this.id)
    : cacheKey = 'wall_test_$id',
      image = MemoryImage(_kPngBytes);

  @override final String id;
  @override final String cacheKey;
  @override final ImageProvider<Object> image;
  @override double? get aspectRatio => 2 / 3;
  @override int? get width => 400;
  @override int? get height => 600;
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
  final _snapshot = const AccountSnapshot(
    phase: AccountPhase.signedIn,
    current: AccountProfile(id: 'sfw', displayName: 'sfw'),
    profiles: [AccountProfile(id: 'sfw', displayName: 'sfw')],
    sessionId: 'sess-wall',
  );
  final _changes = StreamController<AccountSnapshot>.broadcast();

  @override AccountSnapshot get snapshot => _snapshot;
  @override Stream<AccountSnapshot> get changes => _changes.stream;

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WallEntry {
  const _WallEntry({required this.card, required this.initial, this.is4k = false});
  final MediaCard card;
  final String initial;
  final bool is4k;
}

class _RecordingWallListing implements WallListing {
  _RecordingWallListing({required this.info, required this.itemBuilder});
  @override final WallInfo info;
  final MediaCard Function(int index) itemBuilder;
  final List<({int offset, int limit})> pageRequests = [];

  @override
  Future<Page<MediaCard>> page({required int offset, required int limit}) async {
    pageRequests.add((offset: offset, limit: limit));
    final end = math.min(info.total, offset + limit);
    return Page<MediaCard>(
      items: [for (var i = offset; i < end; i++) itemBuilder(i)],
      total: info.total,
      nextOffset: end < info.total ? end : null,
    );
  }
}

class _FakeWallData implements EmbyViewData {
  _FakeWallData({required this.entries});
  final List<_WallEntry> entries;
  final List<WallQuery> openWallCalls = [];
  final List<WallQuery> facetsCalls = [];
  final List<_RecordingWallListing> listings = [];

  List<_WallEntry> _filter(WallQuery query) {
    final list = entries.where((e) {
      if (query.watched == WatchFilter.unplayed && e.card.played == true) return false;
      if (query.watched == WatchFilter.played && e.card.played != true) return false;
      if (query.watched == WatchFilter.favorite && e.card.favorite != true) return false;
      if (query.genreId != null && !e.card.genres.contains(query.genreId)) return false;
      if (query.years != null) {
        final y = e.card.year;
        if (y == null) return false;
        if (query.years!.from != null && y < query.years!.from!) return false;
        if (query.years!.to != null && y > query.years!.to!) return false;
      }
      if (query.technology == TechFilter.uhd4k && !e.is4k) return false;
      return true;
    }).toList();

    switch (query.sort) {
      case WallSort.title:
        list.sort((a, b) {
          final ag = a.initial == '#' ? 1 : 0, bg = b.initial == '#' ? 1 : 0;
          final c = ag != bg ? ag.compareTo(bg) : a.initial.compareTo(b.initial);
          return c != 0 ? c : a.card.id.compareTo(b.card.id);
        });
      case WallSort.score:
        list.sort((a, b) => (b.card.score ?? 0).compareTo(a.card.score ?? 0));
      case WallSort.year:
        list.sort((a, b) => (b.card.year ?? 0).compareTo(a.card.year ?? 0));
      case WallSort.added:
      case WallSort.random:
        break;
    }
    return list;
  }

  @override
  Future<List<ZoneTile>> zones() async => const [
    ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 150, unit: '部'),
  ];

  @override
  Future<WallListing> openWall(WallQuery query) async {
    openWallCalls.add(query);
    final filtered = _filter(query);
    final offsets = <String, int>{};
    if (query.sort == WallSort.title) {
      for (var i = 0; i < filtered.length; i++) {
        offsets.putIfAbsent(filtered[i].initial, () => i);
      }
    }
    final listing = _RecordingWallListing(
      info: WallInfo(total: filtered.length, letterOffsets: Map.unmodifiable(offsets)),
      itemBuilder: (i) => filtered[i].card,
    );
    listings.add(listing);
    return listing;
  }

  @override
  Future<WallFacets> wallFacets(WallQuery query) async {
    facetsCalls.add(query);
    return const WallFacets(
      sorts: [
        FacetOption(value: WallSort.title, label: '标题'),
        FacetOption(value: WallSort.added, label: '最近添加'),
        FacetOption(value: WallSort.score, label: '评分'),
      ],
      watched: [
        FacetOption(value: WatchFilter.all, label: '全部', count: 150),
        FacetOption(value: WatchFilter.unplayed, label: '未看', count: 120),
        FacetOption(value: WatchFilter.played, label: '已看', count: 30),
      ],
      genres: [
        FacetOption(value: '科幻', label: '科幻', count: 84),
        FacetOption(value: '剧情', label: '剧情', count: 66),
        FacetOption(value: '悬疑', label: '悬疑', count: 0),
      ],
      years: [
        FacetOption(value: YearRange(from: 2024, to: 2024), label: '2024', count: 90),
        FacetOption(value: YearRange(from: 2020, to: 2020), label: '2020', count: 60),
      ],
      technologies: [
        FacetOption(value: TechFilter.uhd4k, label: '4K', count: 9),
        FacetOption(value: TechFilter.dolbyVision, label: '杜比视界', count: 2),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HugeFakeWallData implements EmbyViewData {
  _HugeFakeWallData({required this.total});
  final int total;
  final List<_RecordingWallListing> listings = [];
  late final Map<String, int> letterOffsets = _buildOffsets(total);

  static Map<String, int> _buildOffsets(int total) {
    const keys = [
      'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
      'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '#',
    ];
    final step = total ~/ keys.length;
    return {for (var i = 0; i < keys.length; i++) keys[i]: i * step};
  }

  @override
  Future<List<ZoneTile>> zones() async => [
    ZoneTile(id: 'huge', name: '超大片库', iconKey: 'nav_movie', colorSlot: 1, total: total, unit: '部'),
  ];

  @override
  Future<WallListing> openWall(WallQuery query) async {
    final listing = _RecordingWallListing(
      info: WallInfo(total: total, letterOffsets: query.sort == WallSort.title ? letterOffsets : const {}),
      itemBuilder: (i) => MediaCard(
        id: 'huge_$i', kind: MediaKind.movie, libraryId: 'movie',
        title: '影片 #$i', year: 2000 + (i % 25), score: 7.0 + (i % 30) * 0.1,
        genres: const ['科幻'],
        art: CardArtwork(poster: ArtworkPlan(fallbackTitle: '影片 #$i')),
      ),
    );
    listings.add(listing);
    return listing;
  }

  @override
  Future<WallFacets> wallFacets(WallQuery query) async => const WallFacets(
    sorts: [FacetOption(value: WallSort.title, label: '标题'), FacetOption(value: WallSort.score, label: '评分')],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaCard _movieCard({
  required String id, required String title,
  int year = 2024, double score = 8.2, List<String> genres = const ['剧情'],
}) => MediaCard(
  id: id, kind: MediaKind.movie, libraryId: 'movie',
  title: title, year: year, score: score, genres: genres,
  art: CardArtwork(
    poster: ArtworkPlan(layers: [ArtworkLayer(source: _FakeArtworkRef('p_$id'))], fallbackTitle: title),
    stage: ArtworkPlan(layers: [ArtworkLayer(source: _FakeArtworkRef('s_$id'))], fallbackTitle: title),
  ),
);

WallQuery _defaultQuery([String zoneId = 'movie']) => (
  scope: WallScope.zone(zoneId), sort: WallSort.title,
  watched: WatchFilter.all, genreId: null, years: null, technology: null,
);

Widget _app({required Color color, required Size size, required Widget home}) => WidgetsApp(
  color: color,
  pageRouteBuilder: <T>(settings, builder) =>
      PageRouteBuilder<T>(settings: settings, pageBuilder: (ctx, _, _) => builder(ctx)),
  builder: (_, child) => MediaQuery(data: MediaQueryData(size: size), child: child!),
  home: home,
);

Widget _hostWall({
  required EmbyViewData data, required EvShellController shell,
  required _FakePreferences prefs, required _FakeAccounts accounts,
  required WallQuery initialQuery, String? title,
  ScrollController? scrollController, Size size = const Size(1440, 900),
}) {
  final services = EmbyViewServices(preferences: prefs, accounts: accounts, sessionId: 'sess-wall', data: data);
  return _app(
    color: const Color(0xFF09090B),
    size: size,
    home: EvShell(
      services: services,
      controller: shell,
      configureWindow: false,
      enableStageMotion: false,
      wallBuilder: (_, query, wallTitle) => EvWallPage(
        initialQuery: query,
        title: wallTitle ?? title,
        scrollController: scrollController,
      ),
    ),
  );
}

void main() {
  group('C3.12 EvWallPage alpha jump, dynamic WallFacets, sort/filter & empty state', () {
    testWidgets(
      'default title sort shows A-Z bar, jumps to Chinese pinyin & # offsets, filters dynamically, and handles empty state + reset',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final entries = <_WallEntry>[
          for (var i = 0; i < 36; i++)
            _WallEntry(initial: 'A', is4k: i < 5,
                card: _movieCard(id: 'a_${i.toString().padLeft(2, '0')}', title: '阿凡达 ${i + 1}', score: 7.5 + (i % 10) * 0.1, genres: const ['科幻'])),
          for (var i = 0; i < 42; i++)
            _WallEntry(initial: 'B', is4k: i == 0,
                card: _movieCard(id: 'b_${i.toString().padLeft(2, '0')}', title: '霸王别姬 ${i + 1}', score: 8.0, genres: const ['剧情'])),
          for (var i = 0; i < 36; i++)
            _WallEntry(initial: 'D', is4k: i < 3,
                card: _movieCard(id: 'd_${i.toString().padLeft(2, '0')}', title: i == 0 ? '盗梦空间' : '大话西游 ${i + 1}', score: i == 0 ? 9.4 : 8.1, genres: const ['科幻'])),
          for (var i = 0; i < 24; i++)
            _WallEntry(initial: 'Z',
                card: _movieCard(id: 'z_${i.toString().padLeft(2, '0')}', title: i == 0 ? '拯救大兵瑞恩' : '追风筝的人 ${i + 1}', score: 8.6, genres: const ['剧情'])),
          for (var i = 0; i < 12; i++)
            _WallEntry(initial: '#',
                card: _movieCard(id: 'num_${i.toString().padLeft(2, '0')}', title: i == 0 ? '2001太空漫游' : '1917 第${i + 1}部', score: 8.9, genres: const ['科幻'])),
        ];

        final data = _FakeWallData(entries: entries);
        final prefs = _FakePreferences();
        final accounts = _FakeAccounts();
        final openedDetails = <String>[];
        final shell = EvShellController(
          initial: EvWallDestination(_defaultQuery(), title: '电影'),
          zones: const [ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 150, unit: '部')],
          onOpenDetail: openedDetails.add,
        );
        final scrollController = ScrollController();
        addTearDown(() async {
          scrollController.dispose();
          shell.dispose();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(_hostWall(
          data: data, shell: shell, prefs: prefs, accounts: accounts,
          initialQuery: _defaultQuery(), title: '电影', scrollController: scrollController,
        ));
        await tester.pumpAndSettle();

        // Stage set to ambient, shell shows back button and chrome filter action.
        final scope = EvScope.of(tester.element(find.byType(EvWallPage)));
        expect(scope.stage.mode, EvStageMode.ambient);
        expect(shell.showBack, isTrue);
        expect(find.byKey(const Key('ev_topbar_back')), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_chrome_filter_button')), findsOneWidget);

        // Default title sort shows A-Z alpha bar and loads first page.
        expect(find.byKey(const Key('ev_alpha_bar')), findsOneWidget);
        expect(find.text('150 部'), findsOneWidget);
        expect(find.text('阿凡达 1'), findsOneWidget);

        // Tap Chinese pinyin initial 'D' -> jumps to letterOffsets['D'] = 78 and loads '盗梦空间'.
        expect(data.listings.last.info.letterOffsets['D'], 78);
        await tester.tap(find.byKey(const Key('ev_alpha_letter_D')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.widget<AnimatedOpacity>(find.byKey(const Key('ev_alpha_bubble'))).opacity, 1.0);
        await tester.pumpAndSettle();
        expect(scrollController.offset, greaterThan(0));
        expect(find.text('盗梦空间'), findsOneWidget);

        // Clicking a card invokes shell.onOpenDetail.
        await tester.tap(find.byKey(const ValueKey<String>('ev_wall_card_d_00')));
        await tester.pumpAndSettle();
        expect(openedDetails, ['d_00']);

        // Tap '#' -> jumps to letterOffsets['#'] = 138 and loads '2001太空漫游'.
        expect(data.listings.last.info.letterOffsets['#'], 138);
        await tester.tap(find.byKey(const Key('ev_alpha_letter_#')));
        await tester.pumpAndSettle();
        expect(find.text('2001太空漫游'), findsOneWidget);

        // Open filter popover via top-bar chrome action even while scrolled near the bottom.
        await tester.tap(find.byKey(const Key('ev_wall_chrome_filter_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_wall_filter_popover')), findsOneWidget);

        // Options strictly match WallFacets (no hardcoded year/random sorts or hdr/surround51).
        expect(find.byKey(const Key('ev_wall_facet_sort_title')), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_facet_sort_added')), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_facet_sort_score')), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_facet_sort_year')), findsNothing);
        expect(find.byKey(const Key('ev_wall_facet_sort_random')), findsNothing);
        expect(find.byKey(const Key('ev_wall_facet_tech_uhd4k')), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_facet_tech_dolbyVision')), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_facet_tech_hdr')), findsNothing);
        expect(find.byKey(const Key('ev_wall_facet_tech_surround51')), findsNothing);

        // Switch sort to WallSort.score -> hides alpha bar, re-calls openWall, resets scroll to top.
        final beforeScore = data.openWallCalls.length;
        await tester.tap(find.byKey(const Key('ev_wall_facet_sort_score')));
        await tester.pumpAndSettle();
        expect(data.openWallCalls.length, beforeScore + 1);
        expect(data.openWallCalls.last.sort, WallSort.score);
        expect(find.byKey(const Key('ev_alpha_bar')), findsNothing);
        expect(scrollController.offset, 0.0);

        // Filter 4K (TechFilter.uhd4k) -> re-calls openWall, displays 9 filtered items + badge.
        final before4k = data.openWallCalls.length;
        await tester.tap(find.byKey(const Key('ev_wall_facet_tech_uhd4k')));
        await tester.pumpAndSettle();
        expect(data.openWallCalls.length, before4k + 1);
        expect(data.openWallCalls.last.technology, TechFilter.uhd4k);
        expect(find.text('9 部'), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_filter_badge')), findsOneWidget);
        expect(find.text('盗梦空间'), findsOneWidget);

        // Filter zero-match genre ('悬疑') -> empty state appears; close popover & clear filters.
        await tester.tap(find.byKey(const Key('ev_wall_facet_genre_悬疑')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ev_wall_popover_close')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_wall_empty_state')), findsOneWidget);
        expect(find.text('没有符合条件的电影'), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_clear_filters')), findsOneWidget);

        // Tap clear filters -> restores all 150 items and removes filter badge.
        await tester.tap(find.byKey(const Key('ev_wall_clear_filters')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_wall_empty_state')), findsNothing);
        expect(find.text('150 部'), findsOneWidget);
        expect(find.byKey(const Key('ev_wall_filter_badge')), findsNothing);
      },
    );

    testWidgets(
      'EvAlphaIndexBar hover shifts distance brightness to pointer without scaling letters',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final selected = <String>[];
        await tester.pumpWidget(
          _app(
            color: const Color(0xFFFAF9F5),
            size: const Size(1440, 900),
            home: EvThemeScope(
              themeMode: ThemeMode.paper,
              child: Center(
                child: EvAlphaIndexBar(
                  letterOffsets: const {'#': 0, 'A': 5, 'M': 50, 'Z': 99},
                  activeLetter: 'A',
                  scrolling: false,
                  onSelectLetter: selected.add,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final rectA = tester.getRect(find.byKey(const Key('ev_alpha_letter_A')));
        final rectM = tester.getRect(find.byKey(const Key('ev_alpha_letter_M')));
        final rectZ = tester.getRect(find.byKey(const Key('ev_alpha_letter_Z')));
        expect(rectA.size, rectM.size);
        expect(rectM.size, rectZ.size);
        expect(rectA.left, rectM.left);
        expect(rectM.left, rectZ.left);

        // Disabled letter ignores taps.
        await tester.tap(find.byKey(const Key('ev_alpha_letter_B')));
        await tester.pumpAndSettle();
        expect(selected, isEmpty);

        // Pointer hover raises hovered letter opacity to 1.0 without scaling.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        AnimatedOpacity opacityFor(String letter) => tester.widget<AnimatedOpacity>(
          find.descendant(of: find.byKey(Key('ev_alpha_letter_$letter')), matching: find.byType(AnimatedOpacity)),
        );

        expect(opacityFor('M').opacity, closeTo(0.26, 0.01));
        await mouse.moveTo(tester.getCenter(find.byKey(const Key('ev_alpha_letter_M'))));
        await tester.pumpAndSettle();
        expect(opacityFor('M').opacity, closeTo(1.0, 0.01));
        expect(tester.getRect(find.byKey(const Key('ev_alpha_letter_M'))).size, rectA.size);

        await tester.tap(find.byKey(const Key('ev_alpha_letter_Z')));
        await tester.pumpAndSettle();
        expect(selected, ['Z']);
      },
    );
  });

  group('C3.13 10,000-item lazy paging, 2560x1440 scroll & 5-letter jump regression', () {
    testWidgets(
      'scrolls 10,000 items from top to bottom and jumps across 5 letters with on-demand paging and accurate offsets',
      (tester) async {
        const viewport = Size(2560, 1440);
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final data = _HugeFakeWallData(total: 10000);
        final prefs = _FakePreferences();
        final accounts = _FakeAccounts();
        final shell = EvShellController(initial: EvWallDestination(_defaultQuery('huge'), title: '超大片库'));
        final scrollController = ScrollController();
        addTearDown(() async {
          scrollController.dispose();
          shell.dispose();
          await prefs.close();
          await accounts.close();
        });

        await tester.pumpWidget(_hostWall(
          data: data, shell: shell, prefs: prefs, accounts: accounts,
          initialQuery: _defaultQuery('huge'), title: '超大片库',
          scrollController: scrollController, size: viewport,
        ));
        await tester.pumpAndSettle();

        final listing = data.listings.single;
        expect(listing.info.total, 10000);
        expect(find.text('10,000 部'), findsOneWidget);
        expect(find.byKey(const ValueKey<String>('ev_wall_card_huge_0')), findsOneWidget);
        expect(listing.pageRequests.length, lessThanOrEqualTo(4));

        // Rapid top-to-bottom scroll across 10,000 items.
        final maxExtent = scrollController.position.maxScrollExtent;
        expect(maxExtent, greaterThan(100000));
        for (var step = 1; step <= 10; step++) {
          scrollController.jumpTo(maxExtent * (step / 10));
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey<String>('ev_wall_card_huge_9999')), findsOneWidget);
        expect(listing.pageRequests.length, lessThan(40));

        // 5 consecutive letter jumps across the 10,000-item wall.
        final scale = EvScale.fromSize(viewport);
        final leadOffset = scale.rem(5.5);
        for (final letter in const ['C', 'K', 'R', 'W', '#']) {
          final targetIndex = data.letterOffsets[letter]!;
          await tester.tap(find.byKey(Key('ev_alpha_letter_$letter')));
          await tester.pumpAndSettle();

          final expectedMetrics = EvWallGridMetrics.compute(
            viewportWidth: viewport.width, scale: scale, gridTopOffset: scale.rem(11.75),
          );
          final approxOffset = expectedMetrics
              .scrollOffsetForIndex(targetIndex, leadOffset: leadOffset)
              .clamp(0.0, maxExtent);
          expect(
            (scrollController.offset - approxOffset).abs(),
            lessThan(expectedMetrics.rowStride),
            reason: 'Letter $letter (index $targetIndex) landed at inaccurate scroll offset',
          );
          expect(
            find.byKey(ValueKey<String>('ev_wall_card_huge_$targetIndex')),
            findsOneWidget,
            reason: 'Letter $letter target card #$targetIndex should be visible',
          );
        }

        // Total page requests remain far below full-library scan (167 pages).
        expect(listing.pageRequests.length, lessThan(60));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
