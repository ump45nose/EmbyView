import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/palette/ev_command_palette.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArt implements ArtworkRef {
  _FakeArt(this.id) : cacheKey = 'palette_test_$id', image = MemoryImage(_kPngBytes);
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
  _FakeAccounts()
      : _snapshot = const AccountSnapshot(
          phase: AccountPhase.signedIn,
          current: AccountProfile(id: 'sfw', displayName: 'sfw'),
          profiles: [AccountProfile(id: 'sfw', displayName: 'sfw')],
          sessionId: 'sess-1',
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
  List<String> genres = const ['科幻'],
  Duration duration = const Duration(minutes: 120),
  int? episodeNumber,
  bool withPoster = true,
}) => MediaCard(
  id: id,
  kind: kind,
  libraryId: libraryId,
  title: title,
  year: year,
  genres: genres,
  duration: duration,
  episodeNumber: episodeNumber,
  art: withPoster
      ? CardArtwork(
          poster: ArtworkPlan(layers: [ArtworkLayer(source: _FakeArt(id), fit: ArtworkFit.cover)], fallbackTitle: title),
        )
      : CardArtwork(poster: ArtworkPlan(fallbackTitle: title)),
);

List<ZoneTile> _defaultZones() => const [
  ZoneTile(id: 'anime', name: '番剧', iconKey: 'nav_anime', colorSlot: 0, total: 12, unit: '部'),
  ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 733, unit: '部'),
  ZoneTile(id: 'tv', name: '剧集', iconKey: 'nav_tv', colorSlot: 2, total: 92, unit: '部'),
];

List<ResumeCard> _sampleResumes() => [
  ResumeCard(
    card: _card('r1', '王者天下', libraryId: 'anime', kind: MediaKind.series, episodeNumber: 9, duration: const Duration(minutes: 24)),
    target: const PlayTarget(itemId: 'r1_ep9', seriesId: 'r1', episodeNumber: 9, startAt: Duration(minutes: 15)),
    position: const Duration(minutes: 15),
    duration: const Duration(minutes: 24),
  ),
  ResumeCard(
    card: _card('r2', '盗梦空间', duration: const Duration(minutes: 148)),
    target: const PlayTarget(itemId: 'r2', startAt: Duration(minutes: 107)),
    position: const Duration(minutes: 107),
    duration: const Duration(minutes: 148),
  ),
  ResumeCard(
    card: _card('r3', '黑暗骑士', duration: const Duration(minutes: 152)),
    target: const PlayTarget(itemId: 'r3', startAt: Duration(minutes: 120)),
    position: const Duration(minutes: 120),
    duration: const Duration(minutes: 152),
  ),
  ResumeCard(
    card: _card('r4', '星际穿越', duration: const Duration(minutes: 169)),
    target: const PlayTarget(itemId: 'r4', startAt: Duration(minutes: 100)),
    position: const Duration(minutes: 100),
    duration: const Duration(minutes: 169),
  ),
  ResumeCard(
    card: _card('r5', '第五部超出限制', duration: const Duration(minutes: 100)),
    target: const PlayTarget(itemId: 'r5', startAt: Duration(minutes: 50)),
    position: const Duration(minutes: 50),
    duration: const Duration(minutes: 100),
  ),
];

class _FakeData implements EmbyViewData {
  _FakeData({
    this.resumes = const [],
    this.zoneList = const [],
    this.catalog = const [],
    this.randomCards = const {},
    this.onSearch,
  });

  List<ResumeCard> resumes;
  List<ZoneTile> zoneList;
  List<MediaCard> catalog;
  Map<String, MediaCard> randomCards;
  Future<SearchResults> Function(String text, int limit)? onSearch;

  final List<int> continueLimits = [];
  final List<({String text, int limit})> searchCalls = [];
  final List<String> randomZoneCalls = [];
  int zonesCalls = 0;

  @override
  Future<Page<ResumeCard>> continueWatching({String? zoneId, int offset = 0, int limit = 20}) async {
    continueLimits.add(limit);
    final items = resumes.skip(offset).take(limit).toList();
    return Page(items: items, total: resumes.length);
  }

  @override
  Future<List<ZoneTile>> zones() async {
    zonesCalls++;
    return zoneList;
  }

  @override
  Future<MediaCard?> randomInZone(String zoneId) async {
    randomZoneCalls.add(zoneId);
    return randomCards[zoneId];
  }

  @override
  Future<SearchResults> search(String text, {String? zoneId, int offset = 0, int limit = 20}) async {
    searchCalls.add((text: text, limit: limit));
    if (onSearch != null) return onSearch!(text, limit);
    final q = text.trim().toLowerCase();
    final hits = catalog.where((c) => c.title.toLowerCase().contains(q)).take(limit).toList();
    if (hits.isEmpty) return const SearchResults();
    return SearchResults(
      bestMatch: hits.first,
      groups: [
        if (hits.length > 1)
          SearchGroup(libraryId: 'movie', name: '电影', items: hits.skip(1).toList(), total: hits.length - 1),
      ],
      total: hits.length,
    );
  }

  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({
    LocalPreferences prefs = const LocalPreferences(),
    List<ResumeCard>? resumes,
    List<ZoneTile>? shellZones,
    List<ZoneTile>? dataZones,
    List<MediaCard>? catalog,
    Map<String, MediaCard>? randomCards,
    Future<SearchResults> Function(String text, int limit)? onSearch,
  })  : prefs = _FakePrefs(prefs),
        accounts = _FakeAccounts(),
        playback = _FakePlayback(),
        immersionBackend = _FakeImmersion(),
        data = _FakeData(
          resumes: resumes ?? _sampleResumes(),
          zoneList: dataZones ?? _defaultZones(),
          catalog: catalog ??
              [
                _card('m1', '盗梦空间', year: 2010, genres: const ['科幻', '悬疑']),
                _card('m2', '盗梦侦探', year: 2006, genres: const ['动画', '悬疑']),
                _card('m3', '黑暗骑士', year: 2008, genres: const ['动作']),
              ],
          randomCards: randomCards ??
              {
                'movie': _card('rand_movie', '随机电影'),
                'anime': _card('rand_anime', '随机番剧'),
              },
          onSearch: onSearch,
        ) {
    services = EmbyViewServices(
      preferences: this.prefs,
      accounts: accounts,
      sessionId: 'sess-1',
      data: data,
      playback: playback,
      immersion: immersionBackend,
    );
    stage = EvStageController();
    immersion = Immersion(stage: stage, services: services);
    shell = EvShellController(zones: shellZones ?? _defaultZones());
  }

  final _FakePrefs prefs;
  final _FakeAccounts accounts;
  final _FakePlayback playback;
  final _FakeImmersion immersionBackend;
  final _FakeData data;
  late final EmbyViewServices services;
  late final EvStageController stage;
  late final Immersion immersion;
  late final EvShellController shell;

  Future<void> dispose() async {
    immersion.dispose();
    stage.dispose();
    shell.dispose();
    await prefs.close();
    await accounts.close();
    await immersionBackend.close();
  }

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
}

Future<void> _sendCombo(WidgetTester tester, LogicalKeyboardKey modifier, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  testWidgets('opens with Cmd+K and Ctrl+K, closes with Esc/scrim, resets stale query', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final h = _Harness();
    addTearDown(h.dispose);
    var beforeOpenCount = 0;

    await tester.pumpWidget(h.wrap(EvCommandPaletteHost(
      onBeforeOpen: () => beforeOpenCount++,
      child: const SizedBox.expand(),
    )));
    await tester.pumpAndSettle();

    expect(find.byType(EvCommandPaletteOverlay), findsNothing);

    // Open with Cmd+K
    await _sendCombo(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyK);
    expect(find.byType(EvCommandPaletteOverlay), findsOneWidget);
    expect(beforeOpenCount, 1);
    expect(find.text('搜影片，或输入命令（主题、设置、切换用户…）'), findsOneWidget);

    // Enter query then close with Esc
    await tester.enterText(find.byKey(const Key('ev_palette_input')), '盗梦');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(find.text('影片'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(EvCommandPaletteOverlay), findsNothing);

    // Reopen with Ctrl+K: query must be cleared, showing default groups
    await _sendCombo(tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyK);
    expect(find.byType(EvCommandPaletteOverlay), findsOneWidget);
    expect(beforeOpenCount, 2);
    final editable = tester.widget<EditableText>(find.byKey(const Key('ev_palette_input')));
    expect(editable.controller.text, isEmpty);
    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('命令'), findsOneWidget);

    // Close by tapping scrim
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(EvCommandPaletteOverlay), findsNothing);

    // Open and toggle closed via Cmd+K
    await _sendCombo(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyK);
    expect(find.byType(EvCommandPaletteOverlay), findsOneWidget);
    await _sendCombo(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyK);
    expect(find.byType(EvCommandPaletteOverlay), findsNothing);
  });

  testWidgets('empty query shows up to 4 continue watching items and opens EvPlayer on select', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final h = _Harness();
    addTearDown(h.dispose);
    final ctrl = EvCommandPaletteController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(h.wrap(EvCommandPaletteHost(
      controller: ctrl,
      child: const SizedBox.expand(),
    )));
    ctrl.open();
    await tester.pumpAndSettle();

    expect(h.data.continueLimits, contains(4));
    expect(find.text('继续观看'), findsOneWidget);
    expect(find.text('王者天下'), findsOneWidget);
    expect(find.text('第 9 集 · 剩 9 分钟'), findsOneWidget);
    expect(find.text('盗梦空间'), findsOneWidget);
    expect(find.text('剩 41 分钟'), findsOneWidget);
    expect(find.text('星际穿越'), findsOneWidget);
    expect(find.text('第五部超出限制'), findsNothing);

    // Press Enter to execute first highlighted item (王者天下) -> EvPlayer.open
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(ctrl.isOpen, isFalse);
    expect(h.playback.opened, hasLength(1));
    expect(h.playback.opened.first.itemId, 'r1_ep9');
    expect(find.byKey(const Key('ev_minimal_player_page')), findsOneWidget);

    // Close minimal player cleanly
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('onPlayTarget overrides default EvPlayer.open for continue watching items', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final h = _Harness();
    addTearDown(h.dispose);
    final ctrl = EvCommandPaletteController();
    addTearDown(ctrl.dispose);
    final played = <PlayTarget>[];

    await tester.pumpWidget(h.wrap(EvCommandPaletteHost(
      controller: ctrl,
      onPlayTarget: (target, _, _) => played.add(target),
      child: const SizedBox.expand(),
    )));
    ctrl.open();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_resume_r2')));
    await tester.pumpAndSettle();
    expect(ctrl.isOpen, isFalse);
    expect(played.map((t) => t.itemId), ['r2']);
    expect(h.playback.opened, isEmpty);
  });

  testWidgets('executes all commands with expected effects and shell fallbacks', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final h = _Harness(
      prefs: const LocalPreferences(
        theme: ThemeMode.cinema,
        navigation: NavigationStyle.icon,
        themeVolume: 0.42,
      ),
      resumes: const [],
    );
    addTearDown(h.dispose);

    final openedDetails = <String>[];
    var searchOpened = 0, settingsOpened = 0, usersOpened = 0, zonesManaged = 0;
    h.shell
      ..onOpenDetail = openedDetails.add
      ..onOpenSearch = () { searchOpened++; }
      ..onOpenSettings = () { settingsOpened++; }
      ..onOpenUsers = () { usersOpened++; }
      ..onManageZones = () { zonesManaged++; };

    final ctrl = EvCommandPaletteController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(h.wrap(EvCommandPaletteHost(
      controller: ctrl,
      child: const SizedBox.expand(),
    )));

    Future<void> openAndTap(String itemKey) async {
      ctrl.open();
      await tester.pumpAndSettle();
      final finder = find.byKey(ValueKey<String>('ev_palette_item_$itemKey'));
      expect(finder, findsOneWidget);
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(ctrl.isOpen, isFalse);
    }

    // 1. Theme toggle: cinema -> paper -> cinema (no 'Anthropic' copy)
    ctrl.open();
    await tester.pumpAndSettle();
    expect(find.text('继续观看'), findsNothing);
    expect(find.text('换成纸面主题'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_theme')));
    await tester.pumpAndSettle();
    expect(h.prefs.current.theme, ThemeMode.paper);
    expect(h.prefs.current.themeVolume, 0.42); // preserved

    ctrl.open();
    await tester.pumpAndSettle();
    expect(find.text('换成影院主题'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_theme')));
    await tester.pumpAndSettle();
    expect(h.prefs.current.theme, ThemeMode.cinema);

    // 2. Navigation style cycle: icon -> iconAndText -> text -> icon
    ctrl.open();
    await tester.pumpAndSettle();
    expect(find.text('导航样式改为「图标 + 文字」'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_nav')));
    await tester.pumpAndSettle();
    expect(h.prefs.current.navigation, NavigationStyle.iconAndText);

    ctrl.open();
    await tester.pumpAndSettle();
    expect(find.text('导航样式改为「文字」'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_nav')));
    await tester.pumpAndSettle();
    expect(h.prefs.current.navigation, NavigationStyle.text);

    ctrl.open();
    await tester.pumpAndSettle();
    expect(find.text('导航样式改为「图标」'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_nav')));
    await tester.pumpAndSettle();
    expect(h.prefs.current.navigation, NavigationStyle.icon);

    // 3. Add zone (shell.onManageZones fallback)
    await openAndTap('cmd_add_zone');
    expect(zonesManaged, 1);

    // 4. Open search (⌘ F)
    ctrl.open();
    await tester.pumpAndSettle();
    expect(find.text('⌘ F'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_search')));
    await tester.pumpAndSettle();
    expect(searchOpened, 1);

    // 5. Open settings (⌘ ,)
    ctrl.open();
    await tester.pumpAndSettle();
    expect(find.text('⌘ ,'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_settings')));
    await tester.pumpAndSettle();
    expect(settingsOpened, 1);

    // 6. Switch users
    await openAndTap('cmd_users');
    expect(usersOpened, 1);

    // 7. Random movie (prefers movie zone, opens detail)
    await openAndTap('cmd_random');
    expect(h.data.randomZoneCalls, ['movie']);
    expect(openedDetails, ['rand_movie']);

    // 8. Go to each zone (shell.openZone fallback)
    await openAndTap('cmd_zone_anime');
    expect(h.shell.current, const EvZoneDestination('anime'));

    await openAndTap('cmd_zone_tv');
    expect(h.shell.current, const EvZoneDestination('tv'));
  });

  testWidgets('falls back to data.zones() and explicit host callbacks override shell callbacks', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final h = _Harness(
      resumes: const [],
      shellZones: const [],
      dataZones: const [
        ZoneTile(id: 'anime', name: '番剧', iconKey: 'nav_anime', colorSlot: 0, total: 12, unit: '部'),
      ],
    );
    addTearDown(h.dispose);

    final openedZones = <String>[];
    final openedDetails = <String>[];
    var added = 0;
    final ctrl = EvCommandPaletteController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(h.wrap(EvCommandPaletteHost(
      controller: ctrl,
      onAddZone: () => added++,
      onOpenZone: openedZones.add,
      onOpenDetail: openedDetails.add,
      child: const SizedBox.expand(),
    )));

    ctrl.open();
    await tester.pumpAndSettle();
    expect(h.data.zonesCalls, 1);
    expect(find.text('前往番剧'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_zone_anime')));
    await tester.pumpAndSettle();
    expect(openedZones, ['anime']);

    // Random falls back to first zone ('anime') when no movie zone exists
    ctrl.open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_random')));
    await tester.pumpAndSettle();
    expect(h.data.randomZoneCalls, ['anime']);
    expect(openedDetails, ['rand_anime']);

    // Explicit onAddZone overrides shell.onManageZones
    ctrl.open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('ev_palette_item_cmd_add_zone')));
    await tester.pumpAndSettle();
    expect(added, 1);
  });

  testWidgets('searches movies with debounce, generation guard, keyboard loop, hover, and empty state', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final slowCompleter = Completer<SearchResults>();
    final h = _Harness(
      resumes: const [],
      onSearch: (text, limit) {
        if (text == '旧查询') return slowCompleter.future;
        if (text == '盗梦') {
          return Future.value(SearchResults(
            bestMatch: _card('m1', '盗梦空间', year: 2010, genres: const ['科幻']),
            groups: [
              SearchGroup(libraryId: 'anime', name: '番剧', items: [
                _card('m2', '盗梦侦探', year: 2006, genres: const ['动画']),
              ], total: 1),
            ],
            total: 2,
          ));
        }
        return Future.value(const SearchResults());
      },
    );
    addTearDown(h.dispose);

    final openedDetails = <String>[];
    final ctrl = EvCommandPaletteController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(h.wrap(EvCommandPaletteHost(
      controller: ctrl,
      onOpenDetail: openedDetails.add,
      child: const SizedBox.expand(),
    )));

    ctrl.open();
    await tester.pumpAndSettle();

    // Start a slow search, then replace with a newer query before slow completes
    await tester.enterText(find.byKey(const Key('ev_palette_input')), '旧查询');
    await tester.pump(const Duration(milliseconds: 160));
    await tester.enterText(find.byKey(const Key('ev_palette_input')), '盗梦');
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();

    // Complete stale request after newer request already succeeded
    slowCompleter.complete(SearchResults(bestMatch: _card('stale', '过期影片')));
    await tester.pumpAndSettle();

    expect(find.text('过期影片'), findsNothing);
    expect(find.text('影片'), findsOneWidget);
    expect(find.text('盗梦空间'), findsOneWidget);
    expect(find.text('2010 · 科幻'), findsOneWidget);
    expect(find.text('盗梦侦探'), findsOneWidget);
    expect(find.text('2006 · 动画'), findsOneWidget);
    expect(h.data.searchCalls.last.limit, 6);

    // ArrowDown moves highlight to 盗梦侦探 (index 1), ArrowDown wraps to 盗梦空间 (index 0), ArrowUp wraps to 盗梦侦探 (index 1)
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(ctrl.isOpen, isFalse);
    expect(openedDetails, ['m2']);

    // Reopen and verify empty match message & pinyin command match
    ctrl.open();
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ev_palette_input')), '不存在的任何词xyz');
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的影片或命令'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('ev_palette_input')), 'shezhi');
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(find.text('打开设置'), findsOneWidget);
  });

  testWidgets('mouse hover syncs highlighted item and standalone overlay handles keyboard', (tester) async {
    await _setViewport(tester, const Size(1440, 900));
    final h = _Harness(resumes: const []);
    addTearDown(h.dispose);
    var closed = 0, settingsOpened = 0;

    await tester.pumpWidget(h.wrap(EvCommandPaletteOverlay(
      onClose: () => closed++,
      onOpenSettings: () => settingsOpened++,
    )));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    final settingsRow = find.byKey(const ValueKey<String>('ev_palette_item_cmd_settings'));
    await tester.ensureVisible(settingsRow);
    await gesture.moveTo(tester.getCenter(settingsRow));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(settingsOpened, 1);
    expect(closed, 1);
  });

  testWidgets('renders cleanly across cinema/paper themes and 1440x900 & 2560x1440 with zero Anthropic copy', (tester) async {
    for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
      for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
        await _setViewport(tester, size);
        final h = _Harness(prefs: LocalPreferences(theme: mode));
        final ctrl = EvCommandPaletteController();

        await tester.pumpWidget(h.wrap(EvCommandPaletteHost(
          controller: ctrl,
          child: const SizedBox.expand(),
        )));
        ctrl.open();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'No overflow/exception at $size in $mode');
        expect(find.byType(EvCommandPaletteOverlay), findsOneWidget);

        // Verify no 'Anthropic' copy leaks anywhere in rendered Text widgets
        final allTexts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText() ?? '');
        for (final text in allTexts) {
          expect(text.toLowerCase(), isNot(contains('anthropic')), reason: 'Leaked copy in $mode at $size: $text');
        }

        // Scroll through keyboard loop to bottom & back to top without overflow
        for (var i = 0; i < 16; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        expect(tester.takeException(), isNull);

        ctrl.dispose();
        await h.dispose();
      }
    }
  });
}
