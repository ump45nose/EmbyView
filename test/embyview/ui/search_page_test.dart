import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/search/ev_search_page.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArt implements ArtworkRef {
  _FakeArt(this.id) : cacheKey = 'search_test_$id', image = MemoryImage(_kPngBytes);
  @override final String id;
  @override final String cacheKey;
  @override final ImageProvider<Object> image;
  @override double? get aspectRatio => 2 / 3;
  @override int? get width => 600;
  @override int? get height => 900;
}

class _FakePrefs implements EmbyViewPreferences {
  _FakePrefs([this._current = const LocalPreferences()]);
  LocalPreferences _current;
  final _changes = StreamController<LocalPreferences>.broadcast();
  @override LocalPreferences get current => _current;
  @override Stream<LocalPreferences> get changes => _changes.stream;
  @override Future<void> update(LocalPreferences value) async { _current = value; _changes.add(value); }
  Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccounts implements EmbyViewAccounts {
  _FakeAccounts(String sessionId)
      : _snapshot = AccountSnapshot(
          phase: AccountPhase.signedIn,
          current: AccountProfile(id: sessionId, displayName: sessionId),
          profiles: [AccountProfile(id: sessionId, displayName: sessionId)],
          sessionId: sessionId,
        );
  final AccountSnapshot _snapshot;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  @override AccountSnapshot get snapshot => _snapshot;
  @override Stream<AccountSnapshot> get changes => _changes.stream;
  Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSession implements PlaybackSession {
  _FakeSession(this.target);
  final PlayTarget target;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();
  @override PlaybackSnapshot get snapshot => PlaybackSnapshot(generation: 1, target: target);
  @override Stream<PlaybackSnapshot> get changes => _changes.stream;
  @override Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF000000));
  @override Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayback implements EmbyViewPlayback {
  final List<PlayTarget> opened = [];
  @override Future<void> prepare(String itemId) async {}
  @override PlaybackSession open(PlayTarget target) { opened.add(target); return _FakeSession(target); }
}

class _FakeImmersion implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast();
  @override ImmersionSnapshot get snapshot => const ImmersionSnapshot();
  @override Stream<ImmersionSnapshot> get changes => _changes.stream;
  @override Widget videoSurface({Key? key}) => const SizedBox.shrink();
  @override Future<void> showMutedVideo(PreviewRef? video) async {}
  @override Future<void> playTheme(PreviewRef? song) async {}
  @override Future<void> setThemeMuted(bool muted) async {}
  @override Future<void> stop() async {}
  Future<void> close() => _changes.close();
}

MediaCard _card(
  String id,
  String title, {
  String libraryId = 'movie',
  MediaKind kind = MediaKind.movie,
  int year = 2010,
  double score = 9.0,
  List<String> genres = const ['科幻', '悬疑'],
  Duration duration = const Duration(minutes: 148),
  MediaQuality? quality,
  String? overview,
}) {
  final p = _FakeArt('p_$id'), b = _FakeArt('b_$id');
  return MediaCard(
    id: id,
    kind: kind,
    libraryId: libraryId,
    title: title,
    year: year,
    score: score,
    genres: genres,
    duration: duration,
    overview: overview ?? '$title 的剧情简介。',
    quality: quality ?? const MediaQuality(resolution: '4K', videoRange: 'Dolby Vision', audioLabel: '5.1', origin: MediaOrigin.direct115),
    art: CardArtwork(
      poster: ArtworkPlan(layers: [ArtworkLayer(source: p, fit: ArtworkFit.cover)], fallbackTitle: title),
      stage: ArtworkPlan(layers: [ArtworkLayer(source: b, fit: ArtworkFit.cover)], fallbackTitle: title),
      backdrops: [b],
    ),
  );
}

class _CatalogItem {
  const _CatalogItem({
    required this.card,
    required this.libraryName,
    this.originalTitle = '',
    this.initials = '',
    this.actors = const [],
  });
  final MediaCard card;
  final String libraryName;
  final String originalTitle;
  final String initials;
  final List<String> actors;
}

class _FakeData implements EmbyViewData {
  _FakeData({
    required this.landing,
    this.catalog = const [],
    this.onSearch,
  });

  SearchLanding landing;
  final List<_CatalogItem> catalog;
  Future<SearchResults> Function(String text, String? zoneId, int offset, int limit)? onSearch;
  final List<({String? zoneId})> landingCalls = [];
  final List<({String text, String? zoneId, int offset, int limit})> searchCalls = [];

  @override
  Future<SearchLanding> searchLanding({String? zoneId}) async {
    landingCalls.add((zoneId: zoneId));
    return landing;
  }

  @override
  Future<SearchResults> search(String text, {String? zoneId, int offset = 0, int limit = 20}) async {
    searchCalls.add((text: text, zoneId: zoneId, offset: offset, limit: limit));
    if (onSearch != null) return onSearch!(text, zoneId, offset, limit);
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return const SearchResults();
    final hits = catalog.where((c) =>
        c.card.title.toLowerCase().contains(q) ||
        c.originalTitle.toLowerCase().contains(q) ||
        c.initials.toLowerCase().startsWith(q) ||
        c.actors.any((a) => a.toLowerCase().contains(q))).toList();
    if (hits.isEmpty) return const SearchResults();
    final best = hits.first.card;
    final rest = hits.skip(1).toList();
    final byLib = <String, List<_CatalogItem>>{};
    for (final h in rest) {
      byLib.putIfAbsent(h.card.libraryId ?? 'movie', () => []).add(h);
    }
    return SearchResults(
      bestMatch: best,
      groups: [
        for (final entry in byLib.entries)
          SearchGroup(
            libraryId: entry.key,
            name: entry.value.first.libraryName,
            items: [for (final i in entry.value) i.card],
            total: entry.value.length,
          ),
      ],
      total: hits.length,
    );
  }

  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<_CatalogItem> _sampleCatalog() => [
  _CatalogItem(
    card: _card('m1', '盗梦空间', libraryId: 'movie', year: 2010, score: 9.4, overview: '造梦师潜入他人梦境植入想法。'),
    libraryName: '电影',
    originalTitle: 'Inception',
    initials: 'dmkj',
    actors: const ['莱昂纳多·迪卡普里奥', '渡边谦'],
  ),
  _CatalogItem(
    card: _card('m2', '盗梦侦探', libraryId: 'anime', kind: MediaKind.movie, year: 2006, score: 9.1),
    libraryName: '番剧',
    originalTitle: 'Paprika',
    initials: 'dmzt',
    actors: const ['林原惠美'],
  ),
  _CatalogItem(
    card: _card('m3', '黑暗骑士', libraryId: 'movie', year: 2008, score: 9.2),
    libraryName: '电影',
    originalTitle: 'The Dark Knight',
    initials: 'haqs',
    actors: const ['克里斯蒂安·贝尔', '莱昂纳多·迪卡普里奥'],
  ),
  _CatalogItem(
    card: _card('s1', '王者天下', libraryId: 'anime', kind: MediaKind.series, year: 2012, score: 8.9),
    libraryName: '番剧',
    originalTitle: 'Kingdom',
    initials: 'wztx',
    actors: const ['森田成一'],
  ),
  _CatalogItem(
    card: _card('t1', '绝命毒师', libraryId: 'tv', kind: MediaKind.series, year: 2008, score: 9.6),
    libraryName: '剧集',
    originalTitle: 'Breaking Bad',
    initials: 'jmds',
    actors: const ['布莱恩·科兰斯顿'],
  ),
];

class _Harness {
  _Harness({
    required _FakeData data,
    ThemeMode themeMode = ThemeMode.cinema,
    String sessionId = 'sess-1',
    this.onOpenDetail,
  }) : prefs = _FakePrefs(LocalPreferences(theme: themeMode)),
       accounts = _FakeAccounts(sessionId),
       playback = _FakePlayback(),
       immersionPlayback = _FakeImmersion(),
       stage = EvStageController(),
       shell = EvShellController(onOpenDetail: onOpenDetail) {
    services = EmbyViewServices(
      preferences: prefs,
      accounts: accounts,
      sessionId: sessionId,
      data: data,
      playback: playback,
      immersion: immersionPlayback,
    );
    immersion = Immersion(stage: stage, services: services);
  }

  final _FakePrefs prefs;
  final _FakeAccounts accounts;
  final _FakePlayback playback;
  final _FakeImmersion immersionPlayback;
  final EvStageController stage;
  final EvShellController shell;
  final ValueChanged<String>? onOpenDetail;
  late EmbyViewServices services;
  late Immersion immersion;

  Widget wrap(Widget child) => WidgetsApp(
    color: const Color(0xFF09090B),
    pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
      settings: settings,
      pageBuilder: (ctx, _, _) => builder(ctx),
    ),
    home: EvThemeScope(
      preferences: prefs,
      child: EvScope(
        services: services,
        stage: stage,
        immersion: immersion,
        shell: shell,
        child: child,
      ),
    ),
  );

  Future<void> dispose() async {
    immersion.dispose();
    stage.dispose();
    shell.dispose();
    await prefs.close();
    await accounts.close();
    await immersionPlayback.close();
  }
}

void main() {
  Future<void> setViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('ambient stage, autofocus search field, landing recent pills & shelves, and palette trigger', (tester) async {
    await setViewport(tester, const Size(1440, 900));
    final openedIds = <String>[];
    var paletteOpened = false;
    final recCard = _card('rec1', '星际穿越', libraryId: 'movie');
    final data = _FakeData(
      landing: SearchLanding(
        recentTerms: const ['盗梦', '王者天下'],
        shelves: [HomeShelf(id: 'hot', title: '大家都在看', items: [recCard], total: 1)],
      ),
      catalog: _sampleCatalog(),
    );
    final h = _Harness(data: data, onOpenDetail: openedIds.add);
    addTearDown(h.dispose);

    await tester.pumpWidget(h.wrap(EvSearchPage(onOpenPalette: () => paletteOpened = true)));
    await tester.pumpAndSettle();

    expect(h.stage.mode, EvStageMode.ambient);
    final editable = tester.widget<EditableText>(find.byKey(const Key('ev_search_input')));
    expect(editable.focusNode.hasFocus, isTrue);
    expect(find.text('电影、剧集、番剧、演员'), findsOneWidget);
    expect(find.text('⌘ K 命令'), findsOneWidget);
    expect(find.byKey(const Key('ev_search_clear')), findsNothing);
    expect(find.byKey(const Key('ev_search_landing')), findsOneWidget);
    expect(find.text('大家都在看'), findsOneWidget);
    expect(find.text('盗梦'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ev_search_palette_kbd')));
    await tester.pump();
    expect(paletteOpened, isTrue);

    // Tapping a recommended shelf card falls back to EvScope.shell.onOpenDetail.
    await tester.tap(find.byType(EvCard).first);
    await tester.pump();
    expect(openedIds, ['rec1']);

    // Tapping a recent term pill fills input and searches immediately.
    await tester.tap(find.byKey(const Key('ev_search_recent_0')));
    await tester.pumpAndSettle();
    expect(editable.controller.text, '盗梦');
    expect(find.byKey(const Key('ev_search_clear')), findsOneWidget);
    expect(find.byKey(const Key('ev_search_top_match')), findsOneWidget);
    expect(find.byKey(const Key('ev_search_group_anime')), findsOneWidget);

    // Clicking clear resets to landing state.
    await tester.tap(find.byKey(const Key('ev_search_clear')));
    await tester.pumpAndSettle();
    expect(editable.controller.text, isEmpty);
    expect(find.byKey(const Key('ev_search_landing')), findsOneWidget);
  });

  testWidgets('C4.4: Chinese title, pinyin initials, English original title, and actor instant search with highlight, play & detail', (tester) async {
    await setViewport(tester, const Size(1440, 900));
    final opened = <String>[];
    final played = <PlayTarget>[];
    final data = _FakeData(landing: const SearchLanding(), catalog: _sampleCatalog());
    final h = _Harness(data: data);
    addTearDown(h.dispose);

    await tester.pumpWidget(h.wrap(EvSearchPage(
      onOpenItem: opened.add,
      onPlayTarget: (target, _, _) => played.add(target),
    )));
    await tester.pumpAndSettle();

    Future<void> typeAndWait(String q) async {
      await tester.enterText(find.byKey(const Key('ev_search_input')), q);
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
    }

    // 1) Chinese title -> best match with highlighted keyword + grouped anime EvCard
    await typeAndWait('盗梦');
    expect(find.byKey(const Key('ev_search_top_match')), findsOneWidget);
    final rich = tester.widget<Text>(find.byKey(const Key('ev_search_top_match_title')));
    final spans = (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.any((sp) => sp.text == '盗梦' && sp.style?.color == EvTheme.cinema.brand), isTrue);
    expect(find.byType(EvScoreBadge), findsOneWidget);
    expect(find.text('115 直连'), findsOneWidget);
    expect(find.text('DOLBY VISION'), findsOneWidget);
    expect(find.byKey(const Key('ev_search_group_anime')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ev_search_card_anime_m2')), findsOneWidget);

    // Play & Detail on top match + tap & space-play on grouped EvCard
    await tester.tap(find.byKey(const Key('ev_search_top_play')));
    await tester.pump();
    expect(played.map((t) => t.itemId), ['m1']);

    await tester.tap(find.byKey(const Key('ev_search_top_detail')));
    await tester.pump();
    expect(opened, ['m1']);

    final cardFinder = find.byKey(const ValueKey<String>('ev_search_card_anime_m2'));
    await tester.tap(cardFinder);
    await tester.pump();
    expect(opened, ['m1', 'm2']);

    // Focus grouped card and press Space -> invokes onPlayTarget
    final cardChild = find.descendant(of: cardFinder, matching: find.byType(MouseRegion)).first;
    Focus.of(tester.element(cardChild)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(played.map((t) => t.itemId), ['m1', 'm2']);

    // 2) Pinyin initials
    await typeAndWait('dmkj');
    expect(find.text('盗梦空间'), findsOneWidget);

    // 3) English original title
    await typeAndWait('Inception');
    expect(find.text('盗梦空间'), findsOneWidget);

    // 4) Actor name -> returns best match + movie group with EvCard
    await typeAndWait('莱昂纳多');
    expect(find.text('盗梦空间'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ev_search_card_movie_m3')), findsOneWidget);
  });

  testWidgets('default play fallback invokes EvPlayer.open', (tester) async {
    await setViewport(tester, const Size(1440, 900));
    final data = _FakeData(landing: const SearchLanding(), catalog: _sampleCatalog());
    final h = _Harness(data: data);
    addTearDown(h.dispose);

    await tester.pumpWidget(h.wrap(const EvSearchPage(initialQuery: '盗梦')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ev_search_top_play')));
    await tester.pumpAndSettle();
    expect(h.playback.opened.map((t) => t.itemId), ['m1']);
    expect(find.byKey(const Key('ev_minimal_player_page')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ev_player_close')));
    await tester.pumpAndSettle();
  });

  testWidgets('empty state, load more pagination, and stale out-of-order response discard', (tester) async {
    await setViewport(tester, const Size(1440, 900));
    final slowA = Completer<SearchResults>();
    final fastB = Completer<SearchResults>();
    final data = _FakeData(
      landing: const SearchLanding(),
      onSearch: (text, _, offset, _) async {
        if (text == '慢请求') return slowA.future;
        if (text == '快请求') return fastB.future;
        if (text == '分页') {
          if (offset == 0) {
            return SearchResults(
              bestMatch: _card('p0', '分页主片'),
              groups: [SearchGroup(libraryId: 'movie', name: '电影', items: [_card('p1', '分页一')], total: 2, nextOffset: 1)],
              total: 3,
              nextOffset: 1,
            );
          }
          return SearchResults(
            bestMatch: _card('p0', '分页主片'),
            groups: [SearchGroup(libraryId: 'movie', name: '电影', items: [_card('p2', '分页二')], total: 2)],
            total: 3,
          );
        }
        return const SearchResults();
      },
    );
    final h = _Harness(data: data);
    addTearDown(h.dispose);

    await tester.pumpWidget(h.wrap(const EvSearchPage()));
    await tester.pumpAndSettle();

    // Empty state
    await tester.enterText(find.byKey(const Key('ev_search_input')), '完全不存在的片');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_search_empty')), findsOneWidget);
    expect(find.text('没有找到“完全不存在的片”'), findsOneWidget);
    expect(tester.widgetList<EvIcon>(find.byType(EvIcon)).any((i) => i.icon == EvIcons.illEmpty), isTrue);

    // Load more pagination inside a group
    await tester.enterText(find.byKey(const Key('ev_search_input')), '分页');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(find.text('分页一'), findsOneWidget);
    expect(find.byKey(const Key('ev_search_more_movie')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('ev_search_more_movie')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ev_search_more_movie')));
    await tester.pumpAndSettle();
    expect(find.text('分页一'), findsOneWidget);
    expect(find.text('分页二'), findsOneWidget);
    expect(find.byKey(const Key('ev_search_more_movie')), findsNothing);

    // Out-of-order async discard: start slowA, then start fastB, finish fastB first, then finish slowA.
    await tester.enterText(find.byKey(const Key('ev_search_input')), '慢请求');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.enterText(find.byKey(const Key('ev_search_input')), '快请求');
    await tester.pump(const Duration(milliseconds: 220));

    fastB.complete(SearchResults(bestMatch: _card('fb', '快请求命中')));
    await tester.pumpAndSettle();
    expect(find.text('快请求命中'), findsOneWidget);

    slowA.complete(SearchResults(bestMatch: _card('sa', '旧请求残留')));
    await tester.pumpAndSettle();
    expect(find.text('快请求命中'), findsOneWidget);
    expect(find.text('旧请求残留'), findsNothing);
  });

  testWidgets('account switch clears query/results and reloads searchLanding for new user', (tester) async {
    await setViewport(tester, const Size(1440, 900));
    final dataA = _FakeData(
      landing: const SearchLanding(recentTerms: ['旧用户词']),
      catalog: _sampleCatalog(),
    );
    final dataB = _FakeData(
      landing: SearchLanding(
        recentTerms: const ['新用户词'],
        shelves: [HomeShelf(id: 'u2', title: '新用户推荐', items: [_card('u2_1', '千与千寻', libraryId: 'anime')])],
      ),
    );
    final h = _Harness(data: dataA, sessionId: 'user-a');
    addTearDown(h.dispose);

    final notifier = ValueNotifier<EmbyViewServices>(h.services);
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      ValueListenableBuilder<EmbyViewServices>(
        valueListenable: notifier,
        builder: (_, svc, _) => WidgetsApp(
          color: const Color(0xFF09090B),
          pageRouteBuilder: <T>(s, b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
          home: EvThemeScope(
            preferences: h.prefs,
            child: EvScope(services: svc, stage: h.stage, immersion: h.immersion, shell: h.shell, child: const EvSearchPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ev_search_input')), '盗梦');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_search_top_match')), findsOneWidget);

    // Switch sessionId
    final accB = _FakeAccounts('user-b');
    addTearDown(accB.close);
    notifier.value = EmbyViewServices(
      preferences: h.prefs,
      accounts: accB,
      sessionId: 'user-b',
      data: dataB,
      playback: h.playback,
      immersion: h.immersionPlayback,
    );
    await tester.pumpAndSettle();

    expect(dataB.landingCalls.length, 1);
    expect(find.byKey(const Key('ev_search_top_match')), findsNothing);
    expect(find.text('新用户词'), findsOneWidget);
    expect(find.text('新用户推荐'), findsOneWidget);
    expect(tester.widget<EditableText>(find.byKey(const Key('ev_search_input'))).controller.text, isEmpty);
  });

  for (final themeMode in [ThemeMode.cinema, ThemeMode.paper]) {
    for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
      testWidgets('no overflow in ${themeMode.name} at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await setViewport(tester, size);
        final data = _FakeData(
          landing: SearchLanding(
            recentTerms: const ['盗梦空间', '宫崎骏', '4K 杜比视界'],
            shelves: [HomeShelf(id: 'rec', title: '大家都在看', items: [for (final c in _sampleCatalog()) c.card])],
          ),
          catalog: _sampleCatalog(),
        );
        final h = _Harness(data: data, themeMode: themeMode);
        addTearDown(h.dispose);

        await tester.pumpWidget(h.wrap(const EvSearchPage()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.enterText(find.byKey(const Key('ev_search_input')), '盗梦');
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_search_top_match')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Regressions: group load-more hides when items >= total or exhausted across pages, and Unicode highlight avoids RangeError', (tester) async {
    await setViewport(tester, const Size(1440, 900));
    final data = _FakeData(
      landing: const SearchLanding(),
      onSearch: (text, _, offset, _) async {
        if (text == '多组分页') {
          if (offset == 0) {
            return SearchResults(
              groups: [
                SearchGroup(libraryId: 'done', name: '已满分组', items: [_card('d1', '已满片')], total: 1, nextOffset: 2),
                SearchGroup(libraryId: 'movie', name: '电影', items: [_card('m1', '电影一')], total: 2, nextOffset: 2),
                SearchGroup(libraryId: 'anime', name: '番剧', items: [_card('a1', '番剧一')], total: 2, nextOffset: 2),
              ],
              total: 5, nextOffset: 2,
            );
          }
          // Page 2 returns only movie and exhausts global pagination (nextOffset == null).
          return SearchResults(
            groups: [SearchGroup(libraryId: 'movie', name: '电影', items: [_card('m2', '电影二')], total: 2)],
            total: 5,
          );
        }
        if (text == 'istanbul') {
          return SearchResults(bestMatch: _card('u1', 'İSTANBUL 冒险'), total: 1);
        }
        if (text == 'İ') {
          return SearchResults(bestMatch: _card('u2', 'i\u0307stanbul'), total: 1);
        }
        return const SearchResults();
      },
    );
    final h = _Harness(data: data);
    addTearDown(h.dispose);

    await tester.pumpWidget(h.wrap(const EvSearchPage()));
    await tester.pumpAndSettle();

    // 1. Group with items.length >= total hides Load More even if nextOffset != null.
    await tester.enterText(find.byKey(const Key('ev_search_input')), '多组分页');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_search_more_done')), findsNothing);
    expect(find.byKey(const Key('ev_search_more_movie')), findsOneWidget);
    expect(find.byKey(const Key('ev_search_more_anime')), findsOneWidget);

    // Loading page 2 updates all existing groups with more.nextOffset (null), clearing anime's stale button too.
    await tester.ensureVisible(find.byKey(const Key('ev_search_more_movie')));
    await tester.tap(find.byKey(const Key('ev_search_more_movie')));
    await tester.pumpAndSettle();
    expect(find.text('电影二'), findsOneWidget);
    expect(find.byKey(const Key('ev_search_more_movie')), findsNothing);
    expect(find.byKey(const Key('ev_search_more_anime')), findsNothing);

    // 2. Unicode dotted I case-mapping does not throw RangeError.
    await tester.enterText(find.byKey(const Key('ev_search_input')), 'istanbul');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_search_top_match_title')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byKey(const Key('ev_search_input')), 'İ');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_search_top_match_title')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
