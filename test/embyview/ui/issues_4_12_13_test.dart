import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/entry.dart';
import 'package:moonfin/embyview/ui/collection/ev_collection_page.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_page.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/person/ev_person_page.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_page.dart';

final Uint8List _kPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _Art implements ArtworkRef {
  _Art(this.id) : cacheKey = 'iss_$id', image = MemoryImage(_kPng);
  @override final String id;
  @override final String cacheKey;
  @override final ImageProvider<Object> image;
  @override double? get aspectRatio => 16 / 9;
  @override int? get width => 1920;
  @override int? get height => 1080;
}

class _Prefs implements EmbyViewPreferences {
  _Prefs([this._current = const LocalPreferences()]);
  LocalPreferences _current;
  final _changes = StreamController<LocalPreferences>.broadcast();
  @override LocalPreferences get current => _current;
  @override Stream<LocalPreferences> get changes => _changes.stream;
  @override Future<void> update(LocalPreferences value) async {
    _current = value;
    _changes.add(value);
  }
  @override Future<Set<SecretKind>> configuredSecrets() async => const {};
  Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Accounts implements EmbyViewAccounts {
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final _notices = StreamController<ConnectionNoticeEvent>.broadcast();
  final _snap = const AccountSnapshot(
    phase: AccountPhase.signedIn,
    current: AccountProfile(id: 'sfw', displayName: 'sfw'),
    profiles: [AccountProfile(id: 'sfw', displayName: 'sfw')],
    sessionId: 'iss-sess',
  );
  @override AccountSnapshot get snapshot => _snap;
  @override Stream<AccountSnapshot> get changes => _changes.stream;
  @override Stream<ConnectionNoticeEvent> get connectionNotices => _notices.stream;
  Future<void> close() async {
    await _changes.close();
    await _notices.close();
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Immersion implements ImmersionPlayback {
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

class _Playback implements EmbyViewPlayback {
  final List<(String, String?)> prepared = [];
  final List<PlayTarget> opened = [];
  @override Future<void> prepare(String itemId, {String? mediaSourceId}) async {
    prepared.add((itemId, mediaSourceId));
  }
  @override PlaybackSession open(PlayTarget target) {
    opened.add(target);
    return _Session(target);
  }
}

class _Session implements PlaybackSession {
  _Session(this.target);
  final PlayTarget target;
  final _changes = StreamController<PlaybackSnapshot>.broadcast();
  @override PlaybackSnapshot get snapshot => PlaybackSnapshot(generation: 1, target: target);
  @override Stream<PlaybackSnapshot> get changes => _changes.stream;
  @override Widget videoSurface({Key? key}) => const SizedBox.shrink();
  @override Future<void> close() => _changes.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeData implements EmbyViewData {
  _FakeData({
    this.details = const {},
    this.collections = const {},
    this.persons = const {},
    this.peopleByItem = const {},
  });

  final Map<String, MediaDetail> details;
  final Map<String, CollectionDetail> collections;
  final Map<String, PersonDetail> persons;
  final Map<String, List<PersonCredit>> peopleByItem;
  final List<(String, String)> rememberedVersions = [];
  final List<(String, bool)> playedCalls = [];

  @override Future<List<ZoneTile>> zones() async => const [];
  @override Future<ZoneFacets> customZoneFacets() async => const ZoneFacets();
  @override Future<MediaDetail> detail(String itemId) async => details[itemId]!;
  @override Future<List<PersonCredit>> people(String itemId) async => peopleByItem[itemId] ?? const [];
  @override Future<List<MediaCard>> similar(String itemId, {int limit = 16}) async => const [];
  @override Future<ThemeMedia> themeMedia(String itemId) async => const ThemeMedia();
  @override Future<MediaQuality?> quality(String itemId) async => details[itemId]?.card.quality;
  @override Future<CollectionDetail> collection(String collectionId) async => collections[collectionId]!;
  @override Future<PersonDetail> person(String personId, {String? name, String? roleHint, MediaCard? sourceItem}) async =>
      persons[personId] ??
      PersonDetail(
        id: personId,
        name: name ?? '未知',
        primaryRole: roleHint,
        works: sourceItem == null
            ? const []
            : [PersonWork(card: sourceItem, role: parsePersonWorkRole(roleHint) ?? PersonWorkRole.actor)],
      );
  @override Future<void> rememberMediaVersion(String itemId, MediaVersion version) async {
    rememberedVersions.add((itemId, version.id));
  }
  @override Future<void> setPlayed(String itemId, bool played) async {
    playedCalls.add((itemId, played));
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaCard _movie(String id, String title, {int year = 2010, double score = 8.8, bool played = false}) {
  final art = _Art(id);
  return MediaCard(
    id: id,
    kind: MediaKind.movie,
    title: title,
    year: year,
    score: score,
    duration: const Duration(minutes: 148),
    overview: '$title 简介文本。',
    played: played,
    art: CardArtwork(
      poster: ArtworkPlan(layers: [ArtworkLayer(source: art, fit: ArtworkFit.cover)], fallbackTitle: title),
      landscape: ArtworkPlan(layers: [ArtworkLayer(source: art, fit: ArtworkFit.cover)], fallbackTitle: title),
      stage: ArtworkPlan(layers: [ArtworkLayer(source: art, fit: ArtworkFit.cover)], fallbackTitle: title),
      backdrops: [art],
    ),
  );
}

void main() {
  testWidgets('#13 detail series link + strip and EvCollectionPage grid vs horizontal scroll', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final m1 = _movie('22873', '蝙蝠侠：侠影之谜', year: 2005, score: 8.2, played: true);
    final m2 = _movie('22258', '黑暗骑士', year: 2008, score: 9.0);
    final m3 = _movie('22875', '黑暗骑士崛起', year: 2012, score: 8.4);

    final membership = CollectionMembership(
      id: '45707',
      name: '蝙蝠侠：黑暗骑士（系列）',
      position: 2,
      total: 3,
      items: [m1, m2, m3],
    );
    final col3 = CollectionDetail(
      card: _movie('45707', '蝙蝠侠：黑暗骑士（系列）'),
      rawName: '蝙蝠侠：黑暗骑士（系列）',
      items: [
        CollectionItem(card: m1, played: true),
        CollectionItem(card: m2),
        CollectionItem(card: m3),
      ],
    );
    final col8 = CollectionDetail(
      card: _movie('48055', '007（系列）'),
      rawName: '007（系列）',
      items: [
        for (var i = 1; i <= 8; i++)
          CollectionItem(card: _movie('b$i', '007 第 $i 部', year: 1960 + i * 3)),
      ],
    );

    final prefs = _Prefs(), accounts = _Accounts(), immersion = _Immersion(), playback = _Playback();
    final data = _FakeData(
      details: {'22258': MediaDetail(card: m2, collection: membership)},
      collections: {'45707': col3, '48055': col8},
    );
    final services = EmbyViewServices(
      preferences: prefs,
      accounts: accounts,
      sessionId: 'iss-sess',
      data: data,
      playback: playback,
      immersion: immersion,
    );

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
    }

    await tester.pumpWidget(
      MaterialApp(
        home: buildStageFourTestShell(services: services, initialDetailId: '22258'),
      ),
    );
    await settle();

    expect(find.byKey(const Key('ev_detail_collection_link')), findsOneWidget);
    expect(find.text('蝙蝠侠：黑暗骑士 系列'), findsWidgets);
    expect(find.text('第 2 / 3 部'), findsWidgets);
    expect(find.byKey(const Key('ev_detail_franchise_shelf')), findsOneWidget);
    expect(find.byKey(const Key('ev_detail_franchise_here_badge')), findsOneWidget);

    // Tap series link -> opens EvCollectionPage
    await tester.tap(find.byKey(const Key('ev_detail_collection_link')));
    await settle();

    expect(find.byKey(const Key('ev_collection_page')), findsOneWidget);
    expect(find.text('看过 1 / 3 部'), findsOneWidget);
    expect(find.text('接着看第 2 部'), findsOneWidget);
    expect(find.byKey(const Key('ev_collection_grid')), findsOneWidget);
    expect(find.byKey(const Key('ev_collection_horizontal_track')), findsNothing);

    // Long collection (> 6 items) uses horizontal scroll track
    final playedTargets = <PlayTarget>[];
    final stage = EvStageController();
    final imm = Immersion(stage: stage, services: services);
    await tester.pumpWidget(
      MaterialApp(
        home: EvThemeScope(
          preferences: prefs,
          child: EvScope(
            services: services,
            stage: stage,
            immersion: imm,
            shell: EvShellController(),
            child: EvCollectionPage(
              collectionId: '48055',
              onPlayTarget: (target, _, _) => playedTargets.add(target),
            ),
          ),
        ),
      ),
    );
    await settle();
    expect(find.byKey(const Key('ev_collection_horizontal_track')), findsOneWidget);
    expect(find.byKey(const Key('ev_collection_grid')), findsNothing);

    // Sequential play queues all 8 films
    await tester.tap(find.byKey(const Key('ev_collection_sequential_btn')));
    await tester.pump();
    expect(playedTargets, hasLength(1));
    expect(playedTargets.single.queueItemIds, ['b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8']);

    stage.dispose();
    imm.dispose();
    await prefs.close();
    await accounts.close();
    await immersion.close();
  });

  testWidgets('#12 person links on detail page and EvPersonPage filters, sorting, and fallbacks', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final m1 = _movie('22749', '盗梦空间', year: 2010, score: 8.8, played: true);
    final tv1 = MediaCard(
      id: 'tv1',
      kind: MediaKind.series,
      title: '某部剧集',
      year: 2023,
      score: 9.2,
    );
    final nolan = PersonDetail(
      id: '27673',
      name: 'Christopher Nolan',
      primaryRole: 'Director',
      birthDateUtc: DateTime.utc(1970, 7, 29, 16, 0, 0),
      birthPlace: 'London, England',
      overview: '第一行简介。\n第二行简介。\n第三行简介。\n第四行很长的简介用于触发折叠。' * 4,
      works: [
        PersonWork(card: m1, role: PersonWorkRole.director, roles: const {PersonWorkRole.director, PersonWorkRole.producer}),
        PersonWork(card: tv1, role: PersonWorkRole.producer, roles: const {PersonWorkRole.producer}),
      ],
    );

    final prefs = _Prefs(), accounts = _Accounts(), immersion = _Immersion(), playback = _Playback();
    final data = _FakeData(
      details: {'22749': MediaDetail(card: m1)},
      peopleByItem: {
        '22749': const [
          PersonCredit(id: '27673', name: 'Christopher Nolan', role: 'Director'),
          PersonCredit(id: '99999', name: '无资料演员', role: 'Actor', character: '配角'),
        ],
      },
      persons: {'27673': nolan},
    );
    final services = EmbyViewServices(
      preferences: prefs,
      accounts: accounts,
      sessionId: 'iss-sess',
      data: data,
      playback: playback,
      immersion: immersion,
    );

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
    }

    await tester.pumpWidget(
      MaterialApp(
        home: buildStageFourTestShell(services: services, initialDetailId: '22749'),
      ),
    );
    await settle();

    // Tap director name in detail hero credits -> opens EvPersonPage
    await tester.tap(find.byKey(const Key('ev_detail_credit_27673')));
    await settle();

    expect(find.byKey(const Key('ev_person_page')), findsOneWidget);
    expect(find.text('Christopher Nolan'), findsOneWidget);
    expect(find.text('导演 · 制片人'), findsOneWidget);
    expect(find.byKey(const Key('ev_person_filter_director')), findsOneWidget);
    expect(find.byKey(const Key('ev_person_filter_producer')), findsOneWidget);
    expect(find.byKey(const Key('ev_person_filter_tv')), findsOneWidget);
    // No actor chip because Nolan has no actor credits
    expect(find.byKey(const Key('ev_person_filter_actor')), findsNothing);

    // Filter to 执导 -> only 盗梦空间 shown
    await tester.tap(find.byKey(const Key('ev_person_filter_director')));
    await settle();
    expect(find.byKey(const ValueKey<String>('ev_person_work_22749')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ev_person_work_tv1')), findsNothing);

    // Missing data fallback (no portrait, no bio, fallback to source movie)
    final stage = EvStageController();
    final imm = Immersion(stage: stage, services: services);
    await tester.pumpWidget(
      MaterialApp(
        home: EvThemeScope(
          preferences: prefs,
          child: EvScope(
            services: services,
            stage: stage,
            immersion: imm,
            shell: EvShellController(),
            child: EvPersonPage(
              personId: '99999',
              personName: '无资料演员',
              roleHint: 'Actor',
              sourceItem: m1,
            ),
          ),
        ),
      ),
    );
    await settle();
    expect(find.byKey(const Key('ev_person_portrait_fallback')), findsOneWidget);
    expect(find.text('Emby 里没有这位的简介。'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ev_person_work_22749')), findsOneWidget);

    stage.dispose();
    imm.dispose();
    await prefs.close();
    await accounts.close();
    await immersion.close();
  });

  testWidgets('#4 multi-version button, popover, resume with switched version, and settings rule', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    const vUhd = MediaVersion(
      id: 'uhd',
      name: 'UHD 原盘 Remux',
      resolution: '4K',
      width: 3840,
      height: 2160,
      videoRange: '杜比视界',
      videoCodec: 'HEVC 10bit',
      audioLabel: 'TrueHD 全景声 7.1',
      sizeBytes: 65712999629,
      bitrateBps: 74000000,
      origin: MediaOrigin.direct115,
    );
    const vNas = MediaVersion(
      id: 'nas',
      name: 'H.265 压制',
      resolution: '1080p',
      width: 1920,
      height: 1080,
      videoCodec: 'HEVC',
      audioLabel: 'DTS 5.1',
      sizeBytes: 6120328397,
      bitrateBps: 5100000,
      origin: MediaOrigin.nasLocal,
    );

    final inception = _movie('22749', '盗梦空间', year: 2010, score: 8.8);
    final resume = ResumeCard(
      card: inception,
      target: const PlayTarget(itemId: '22749', startAt: Duration(minutes: 42)),
      position: const Duration(minutes: 42),
      duration: const Duration(minutes: 148),
    );

    final prefs = _Prefs(), accounts = _Accounts(), immersion = _Immersion(), playback = _Playback();
    final data = _FakeData(
      details: {
        '22749': MediaDetail(
          card: inception,
          resume: resume,
          playTarget: resume.target,
          versions: const [vUhd, vNas],
        ),
        'single': MediaDetail(card: _movie('single', '单版本电影'), versions: const [vNas]),
      },
    );
    final services = EmbyViewServices(
      preferences: prefs,
      accounts: accounts,
      sessionId: 'iss-sess',
      data: data,
      playback: playback,
      immersion: immersion,
    );

    final playedTargets = <PlayTarget>[];
    var openedPlaySettings = false;
    final stage = EvStageController();
    final imm = Immersion(stage: stage, services: services);
    await tester.pumpWidget(
      MaterialApp(
        home: EvThemeScope(
          preferences: prefs,
          child: EvScope(
            services: services,
            stage: stage,
            immersion: imm,
            shell: EvShellController(),
            child: EvDetailPage(
              itemId: '22749',
              onPlayTarget: (target, _, _) => playedTargets.add(target),
              onOpenPlaySettings: () => openedPlaySettings = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Multi-version button & facts row visible
    expect(find.byKey(const Key('ev_detail_version_btn')), findsOneWidget);
    expect(find.text('2 个版本'), findsOneWidget);
    expect(find.byKey(const Key('ev_detail_facts_version')), findsOneWidget);

    // Open popover, check >40 Mbps warning, pick NAS version
    await tester.tap(find.byKey(const Key('ev_detail_version_btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_version_popover')), findsOneWidget);
    expect(find.textContaining('外网较慢时可能卡顿'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ev_version_row_nas')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_version_popover')), findsNothing);
    expect(data.rememberedVersions, [('22749', 'nas')]);

    // Pressing Resume/Play keeps 42-minute startAt WITH newly chosen mediaSourceId='nas'
    await tester.tap(find.byKey(const Key('ev_detail_play_btn')));
    await tester.pump();
    expect(playedTargets, hasLength(1));
    expect(playedTargets.single.mediaSourceId, 'nas');
    expect(playedTargets.single.startAt, const Duration(minutes: 42));

    // Reopen popover and tap 「改默认规则」
    await tester.tap(find.byKey(const Key('ev_detail_version_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ev_version_open_settings')));
    await tester.pumpAndSettle();
    expect(openedPlaySettings, isTrue);

    // Settings -> Play pane updates DefaultVersionRule
    await tester.pumpWidget(
      MaterialApp(
        home: buildStageFourTestShell(services: services, initialSettings: EvSettingsSection.play),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('默认版本'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ev_vrule_smallestSize')));
    await tester.pumpAndSettle();
    expect(prefs.current.defaultVersionRule, DefaultVersionRule.smallestSize);

    // Single-version movie hides version button
    await tester.pumpWidget(
      MaterialApp(
        home: buildStageFourTestShell(services: services, initialDetailId: 'single'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ev_detail_version_btn')), findsNothing);
    expect(find.byKey(const Key('ev_detail_facts_version')), findsNothing);

    stage.dispose();
    imm.dispose();
    await prefs.close();
    await accounts.close();
    await immersion.close();
  });
}
