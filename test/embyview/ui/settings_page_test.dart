import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_page.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_widgets.dart';
import 'package:moonfin/embyview/ui/settings/ev_zone_editor.dart';

const List<ZonePreference> _kDefaultZones = [
  ZonePreference(
    id: 'lib_anime',
    name: '番剧',
    iconKey: 'nav_anime',
    colorSlot: 0,
    rule: ZoneRule.library('lib_anime'),
    custom: false,
  ),
  ZonePreference(
    id: 'lib_movie',
    name: '电影',
    iconKey: 'nav_movie',
    colorSlot: 1,
    rule: ZoneRule.library('lib_movie'),
    custom: false,
  ),
  ZonePreference(
    id: 'lib_tv',
    name: '剧集',
    iconKey: 'nav_tv',
    colorSlot: 2,
    rule: ZoneRule.library('lib_tv'),
    custom: false,
  ),
];

const ZoneFacets _kFacets = ZoneFacets(
  libraries: [
    FacetOption(value: 'lib_anime', label: '番剧', count: 12),
    FacetOption(value: 'lib_movie', label: '电影', count: 733),
    FacetOption(value: 'lib_tv', label: '剧集', count: 92),
  ],
  genres: [
    FacetOption(value: 'g_scifi', label: '科幻', count: 84),
    FacetOption(value: 'g_action', label: '动作', count: 112),
    FacetOption(value: 'g_anim', label: '动画', count: 48),
  ],
  technologies: [
    FacetOption(value: TechFilter.uhd4k, label: '4K', count: 156),
    FacetOption(value: TechFilter.dolbyVision, label: '杜比视界', count: 42),
    FacetOption(value: TechFilter.hdr, label: 'HDR', count: 89),
    FacetOption(value: TechFilter.surround51, label: '5.1', count: 310),
  ],
);

class _FakePreferences implements EmbyViewPreferences {
  _FakePreferences({
    LocalPreferences? initial,
    Set<SecretKind>? configuredSecrets,
    MediaFolderStatus? authorizedFolderResult,
  }) : _current = initial ?? const LocalPreferences(zones: _kDefaultZones),
       _secrets = {...?configuredSecrets}..remove(SecretKind.openAi),
       _translationOrigins = {
         if (configuredSecrets?.contains(SecretKind.openAi) == true)
           Uri.parse(initial?.translationBaseUrl ?? defaultTranslationBaseUrl).origin,
       },
       _authorizedFolderResult =
           authorizedFolderResult ??
           const MediaFolderStatus(
             state: MediaFolderState.authorized,
             embyRoot: '/mnt/media',
             localRoot: '/Volumes/Media',
             writable: true,
           );

  LocalPreferences _current;
  final Set<SecretKind> _secrets;
  final Set<String> _translationOrigins;
  Completer<void>? preferenceWrite;
  Completer<Set<SecretKind>>? nextSecretsRead;
  bool failNextSecretWrite = false;
  final MediaFolderStatus _authorizedFolderResult;
  final _changes = StreamController<LocalPreferences>.broadcast();

  final List<LocalPreferences> updateCalls = [];
  final List<ZonePreference> saveZoneCalls = [];
  final List<String> removeZoneCalls = [];
  final List<List<String>> reorderCalls = [];
  int resetZonesCalls = 0;
  final List<String> authorizeCalls = [];
  int mediaFolderStatusCalls = 0;
  final List<(SecretKind, String?)> setSecretCalls = [];

  @override
  LocalPreferences get current => _current;

  @override
  Stream<LocalPreferences> get changes => _changes.stream;

  void _emit(LocalPreferences next) {
    _current = next;
    _changes.add(next);
  }

  LocalPreferences _clone({
    List<ZonePreference>? zones,
    MediaFolderStatus? mediaFolder,
  }) => LocalPreferences(
    theme: _current.theme,
    navigation: _current.navigation,
    seriesSort: _current.seriesSort,
    chooseUserOnStartup: _current.chooseUserOnStartup,
    backgroundVideo: _current.backgroundVideo,
    backgroundVideoDelay: _current.backgroundVideoDelay,
    detailTrailerDelay: _current.detailTrailerDelay,
    themeMusic: _current.themeMusic,
    themeVolume: _current.themeVolume,
    quickLook: _current.quickLook,
    hideUnwatchedOverview: _current.hideUnwatchedOverview,
    preResolve115: _current.preResolve115,
    readAheadBytes: _current.readAheadBytes,
    autoPlayNext: _current.autoPlayNext,
    anime4kForAnime: _current.anime4kForAnime,
    anime4kForOther: _current.anime4kForOther,
    subtitleLanguages: _current.subtitleLanguages,
    autoSelectChineseSubtitle: _current.autoSelectChineseSubtitle,
    subtitleSources: _current.subtitleSources,
    translationBaseUrl: _current.translationBaseUrl,
    translationModel: _current.translationModel,
    monthlyBudgetMicros: _current.monthlyBudgetMicros,
    mediaFolder: mediaFolder ?? _current.mediaFolder,
    zones: zones ?? _current.zones,
  );

  @override
  Future<void> update(LocalPreferences value) async {
    updateCalls.add(value);
    await preferenceWrite?.future;
    _emit(value);
  }

  @override
  Future<void> saveZone(ZonePreference value) async {
    saveZoneCalls.add(value);
    final next = [..._current.zones];
    final idx = next.indexWhere((z) => z.id == value.id);
    if (idx >= 0) {
      next[idx] = value;
    } else {
      next.add(value);
    }
    _emit(_clone(zones: List.unmodifiable(next)));
  }

  @override
  Future<void> removeCustomZone(String zoneId) async {
    removeZoneCalls.add(zoneId);
    final next = _current.zones
        .where((z) => z.id != zoneId || !z.custom)
        .toList();
    _emit(_clone(zones: List.unmodifiable(next)));
  }

  @override
  Future<void> reorderZones(List<String> ids) async {
    reorderCalls.add(List<String>.from(ids));
    final byId = {for (final z in _current.zones) z.id: z};
    final ordered = <ZonePreference>[
      for (final id in ids)
        if (byId.containsKey(id)) byId.remove(id)!,
      ...byId.values,
    ];
    _emit(_clone(zones: List.unmodifiable(ordered)));
  }

  @override
  Future<void> resetZones() async {
    resetZonesCalls++;
    _emit(_clone(zones: _kDefaultZones));
  }

  @override
  Future<bool> authorizeMediaFolder({required String embyRoot}) async {
    authorizeCalls.add(embyRoot);
    final next = MediaFolderStatus(
      state: _authorizedFolderResult.state,
      embyRoot: embyRoot,
      localRoot: _authorizedFolderResult.localRoot,
      writable: _authorizedFolderResult.writable,
      reason: _authorizedFolderResult.reason,
    );
    _emit(_clone(mediaFolder: next));
    return next.state == MediaFolderState.authorized;
  }

  @override
  Future<MediaFolderStatus> mediaFolderStatus() async {
    mediaFolderStatusCalls++;
    return _current.mediaFolder;
  }

  @override
  Future<Set<SecretKind>> configuredSecrets() async {
    final pending = nextSecretsRead;
    nextSecretsRead = null;
    if (pending != null) return pending.future;
    return Set.unmodifiable({
      ..._secrets,
      if (_translationOrigins.contains(Uri.parse(current.translationBaseUrl).origin)) SecretKind.openAi,
    });
  }

  @override
  Future<void> setSecret(SecretKind kind, String? value) async {
    setSecretCalls.add((kind, value));
    if (failNextSecretWrite) {
      failNextSecretWrite = false;
      throw const EmbyViewFailure('无法保存钥匙串，请检查系统授权。', retryable: true);
    }
    if (kind == SecretKind.openAi) {
      final origin = Uri.parse(current.translationBaseUrl).origin;
      if (value == null) { _translationOrigins.remove(origin); } else { _translationOrigins.add(origin); }
      return;
    }
    if (value == null || value.trim().isEmpty) {
      _secrets.remove(kind);
    } else {
      _secrets.add(kind);
    }
  }

  Future<void> close() => _changes.close();
}

class _FakeAccounts implements EmbyViewAccounts {
  _FakeAccounts([AccountSnapshot? initial])
    : _snapshot =
          initial ??
          const AccountSnapshot(
            phase: AccountPhase.signedIn,
            current: AccountProfile(id: 'sfw', displayName: 'sfw'),
            profiles: [
              AccountProfile(id: 'sfw', displayName: 'sfw'),
              AccountProfile(id: 'family', displayName: '家人'),
              AccountProfile(id: 'guest', displayName: '访客'),
            ],
            serverAddress: 'http://nas.local:8096',
            serverVersion: '4.10.2',
            connection: ConnectionState.connected,
            sessionId: 'sess_sfw',
          );

  AccountSnapshot _snapshot;
  final _changes = StreamController<AccountSnapshot>.broadcast();
  final List<String> switchCalls = [];

  @override
  AccountSnapshot get snapshot => _snapshot;

  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

  @override
  Future<void> switchTo(String profileId, {String? password}) async {
    switchCalls.add(profileId);
    final next = _snapshot.profiles.where((p) => p.id == profileId).firstOrNull;
    if (next != null) {
      _snapshot = AccountSnapshot(
        phase: AccountPhase.signedIn,
        current: next,
        profiles: _snapshot.profiles,
        serverAddress: _snapshot.serverAddress,
        serverVersion: _snapshot.serverVersion,
        connection: _snapshot.connection,
        sessionId: 'sess_$profileId',
      );
      _changes.add(_snapshot);
    }
  }

  @override
  Future<void> restore() async {}

  @override
  Future<void> signIn(Uri server, String username, String password) async {}

  @override
  Future<void> signOut() async {}

  Future<void> close() => _changes.close();
}

class _FakeData implements EmbyViewData {
  _FakeData(this.preferences);

  final _FakePreferences preferences;
  int customZoneFacetsCalls = 0;

  @override
  Future<List<ZoneTile>> zones() async => [
    for (final z in preferences.current.zones)
      ZoneTile(
        id: z.id,
        name: z.name,
        iconKey: z.iconKey,
        colorSlot: z.colorSlot,
        total: switch (z.id) {
          'lib_anime' => 12,
          'lib_movie' => 733,
          'lib_tv' => 92,
          _ => 42,
        },
        unit: z.id == 'lib_tv' ? '部剧' : '部',
      ),
  ];

  @override
  Future<ZoneFacets> customZoneFacets() async {
    customZoneFacetsCalls++;
    return _kFacets;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSubtitles implements EmbyViewSubtitles {
  _FakeSubtitles({
    AiUsage? initialUsage,
    List<SeasonJob> initialJobs = const [],
  }) : _usage =
           initialUsage ??
           const AiUsage(
             month: '2026-11',
             state: AiUsageState.available,
             usedMicros: 23400000,
             budgetMicros: 100000000,
             completedEpisodes: 41,
             unmeteredCalls: 3,
             averageEpisodeMicros: 570000,
           ),
       _jobs = List<SeasonJob>.from(initialJobs);

  final AiUsage _usage;
  List<SeasonJob> _jobs;
  final _jobsController = StreamController<List<SeasonJob>>.broadcast();
  final List<String> cancelJobCalls = [];

  @override
  Future<AiUsage> usage() async => _usage;

  @override
  Stream<List<SeasonJob>> get jobs async* {
    yield List<SeasonJob>.unmodifiable(_jobs);
    yield* _jobsController.stream;
  }

  void emitJobs(List<SeasonJob> next) {
    _jobs = List<SeasonJob>.from(next);
    _jobsController.add(List<SeasonJob>.unmodifiable(_jobs));
  }

  @override
  Future<void> cancelJob(String jobId, {String? episodeId}) async {
    cancelJobCalls.add(jobId);
    _jobs = _jobs.where((j) => j.id != jobId).toList();
    _jobsController.add(List<SeasonJob>.unmodifiable(_jobs));
  }

  Future<void> close() => _jobsController.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImmersionPlayback implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast(sync: true);

  @override
  ImmersionSnapshot get snapshot => const ImmersionSnapshot();

  @override
  Stream<ImmersionSnapshot> get changes => _changes.stream;

  @override
  Future<void> showMutedVideo(PreviewRef? video) async {}

  @override
  Widget videoSurface({Key? key}) => const SizedBox.shrink();

  @override
  Future<void> playTheme(PreviewRef? song) async {}

  @override
  Future<void> setThemeMuted(bool muted) async {}

  @override
  Future<void> stop() async {}

  Future<void> close() => _changes.close();
}

Future<
  ({
    _FakePreferences prefs,
    _FakeAccounts accounts,
    _FakeData data,
    _FakeSubtitles? subtitles,
    _FakeImmersionPlayback immersionPlayback,
    EvStageController stage,
    Immersion immersion,
    EvShellController shell,
  })
>
_pumpSettings(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  LocalPreferences? initialPrefs,
  Set<SecretKind>? configuredSecrets,
  bool withSubtitles = true,
  List<SeasonJob> initialJobs = const [],
  EvSettingsSection initialSection = EvSettingsSection.account,
  bool openZoneEditorOnMount = false,
  String? editZoneId,
  VoidCallback? onOpenUsers,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final prefs = _FakePreferences(
    initial: initialPrefs,
    configuredSecrets: configuredSecrets ?? {SecretKind.openAi},
  );
  final accounts = _FakeAccounts();
  final data = _FakeData(prefs);
  final subtitles = withSubtitles
      ? _FakeSubtitles(initialJobs: initialJobs)
      : null;
  final immersionPlayback = _FakeImmersionPlayback();
  final services = EmbyViewServices(
    preferences: prefs,
    accounts: accounts,
    sessionId: 'sess_sfw',
    data: data,
    immersion: immersionPlayback,
    subtitles: subtitles,
  );
  final stage = EvStageController();
  final immersion = Immersion(stage: stage, services: services);
  final shell = EvShellController();

  addTearDown(() async {
    shell.dispose();
    immersion.dispose();
    stage.dispose();
    await immersionPlayback.close();
    await subtitles?.close();
    await accounts.close();
    await prefs.close();
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
          child: Builder(
            builder: (context) => ColoredBox(
              color: EvTheme.of(context).bg,
              child: EvSettingsPage(
                initialSection: initialSection,
                openZoneEditorOnMount: openZoneEditorOnMount,
                editZoneId: editZoneId,
                onOpenUsers: onOpenUsers,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return (
    prefs: prefs,
    accounts: accounts,
    data: data,
    subtitles: subtitles,
    immersionPlayback: immersionPlayback,
    stage: stage,
    immersion: immersion,
    shell: shell,
  );
}

void main() {
  group('C4.8 分区设置与自定义分区编辑器', () {
    testWidgets(
      'add Dolby Vision custom zone strictly from ZoneFacets, reorder, edit, delete, and reset',
      (tester) async {
        final env = await _pumpSettings(
          tester,
          initialSection: EvSettingsSection.zones,
        );

        expect(env.stage.mode, EvStageMode.ambient);
        expect(find.text('番剧'), findsOneWidget);
        expect(find.text('电影'), findsOneWidget);
        expect(find.text('剧集'), findsOneWidget);

        // Open "添加分区"
        await tester.tap(find.byKey(const Key('ev_zone_add')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_zone_editor_dialog')), findsOneWidget);
        expect(env.data.customZoneFacetsCalls, greaterThanOrEqualTo(1));

        // Verify 20 zone icons & 7 color swatches are rendered
        for (final icon in EvIcons.zoneIcons) {
          expect(find.byKey(Key('ev_zone_icon_${icon.key}')), findsOneWidget);
        }
        for (var i = 0; i < 7; i++) {
          expect(find.byKey(Key('ev_zone_color_$i')), findsOneWidget);
        }

        // Switch rule kind to technology; verify only ZoneFacets technologies appear (NO Atmos!)
        await tester.tap(find.byKey(const Key('ev_zone_rule_tab_technology')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_zone_facet_tech_uhd4k')), findsOneWidget);
        expect(
          find.byKey(const Key('ev_zone_facet_tech_dolbyVision')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('ev_zone_facet_tech_hdr')), findsOneWidget);
        expect(
          find.byKey(const Key('ev_zone_facet_tech_surround51')),
          findsOneWidget,
        );
        expect(find.textContaining('Atmos'), findsNothing);

        // Create "杜比视界" custom zone
        await tester.enterText(
          find.descendant(
            of: find.byKey(const Key('ev_zone_name_input')),
            matching: find.byType(EditableText),
          ),
          '杜比视界',
        );
        await tester.tap(find.byKey(const Key('ev_zone_icon_rocket')));
        await tester.tap(find.byKey(const Key('ev_zone_color_2')));
        await tester.tap(
          find.byKey(const Key('ev_zone_facet_tech_dolbyVision')),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('ev_zone_save')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_zone_editor_dialog')), findsNothing);
        expect(env.prefs.saveZoneCalls, hasLength(1));
        final saved = env.prefs.saveZoneCalls.single;
        expect(saved.name, '杜比视界');
        expect(saved.iconKey, 'rocket');
        expect(saved.colorSlot, 2);
        expect(saved.custom, isTrue);
        expect(
          saved.rule,
          isA<TechnologyZoneRule>().having(
            (r) => r.technology,
            'technology',
            TechFilter.dolbyVision,
          ),
        );
        expect(find.byKey(Key('ev_zone_row_${saved.id}')), findsOneWidget);

        // Reorder: move custom zone up one slot
        await tester.tap(find.byKey(Key('ev_zone_move_up_${saved.id}')));
        await tester.pumpAndSettle();
        expect(env.prefs.reorderCalls, hasLength(1));
        expect(env.prefs.reorderCalls.last, [
          'lib_anime',
          'lib_movie',
          saved.id,
          'lib_tv',
        ]);

        // Reorder: move first zone down
        await tester.tap(find.byKey(const Key('ev_zone_move_down_lib_anime')));
        await tester.pumpAndSettle();
        expect(env.prefs.reorderCalls.last, [
          'lib_movie',
          'lib_anime',
          saved.id,
          'lib_tv',
        ]);

        // Edit built-in library zone: keeps LibraryZoneRule and has no delete button
        await tester.tap(find.byKey(const Key('ev_zone_edit_lib_anime')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_zone_delete')), findsNothing);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const Key('ev_zone_name_input')),
            matching: find.byType(EditableText),
          ),
          '动画番剧',
        );
        await tester.tap(find.byKey(const Key('ev_zone_save')));
        await tester.pumpAndSettle();
        expect(env.prefs.saveZoneCalls.last.name, '动画番剧');
        expect(env.prefs.saveZoneCalls.last.custom, isFalse);
        expect(
          env.prefs.saveZoneCalls.last.rule,
          isA<LibraryZoneRule>().having(
            (r) => r.libraryId,
            'libraryId',
            'lib_anime',
          ),
        );

        // Edit custom zone & delete it
        await tester.tap(find.byKey(Key('ev_zone_edit_${saved.id}')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_zone_delete')), findsOneWidget);
        await tester.tap(find.byKey(const Key('ev_zone_delete')));
        await tester.pumpAndSettle();
        expect(env.prefs.removeZoneCalls, [saved.id]);
        expect(find.byKey(Key('ev_zone_row_${saved.id}')), findsNothing);

        // Reset zones to default
        await tester.tap(find.byKey(const Key('ev_zone_reset')));
        await tester.pumpAndSettle();
        expect(env.prefs.resetZonesCalls, 1);
        expect(env.prefs.current.zones.map((z) => z.name), ['番剧', '电影', '剧集']);
      },
    );

    testWidgets('openZoneEditorOnMount opens overlay immediately and Esc closes it', (
      tester,
    ) async {
      await _pumpSettings(
        tester,
        openZoneEditorOnMount: true,
      );
      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsNothing);
    });

    testWidgets('EvZoneEditorOverlay can be opened standalone', (tester) async {
      ZonePreference? saved;
      var closed = false;
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFFFAF9F5),
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, _) => builder(context),
          ),
          home: EvThemeScope(
            themeMode: ThemeMode.paper,
            child: EvZoneEditorOverlay(
              facets: _kFacets,
              onSave: (z) => saved = z,
              onClose: () => closed = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('ev_zone_facet_genre_g_action')));
      await tester.tap(find.byKey(const Key('ev_zone_save')));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(saved, isNotNull);
      expect(saved!.name, '动作');
      expect(
        saved!.rule,
        isA<GenreZoneRule>().having((r) => r.genreId, 'genreId', 'g_action'),
      );
    });
  });

  group('C4.9 全 10 个分组双主题双尺寸无溢出与真实契约读写', () {
    for (final (themeMode, label) in const [
      (ThemeMode.cinema, 'cinema'),
      (ThemeMode.paper, 'paper'),
    ]) {
      for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
        testWidgets(
          'all 10 sections render without overflow in $label @ ${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
            final env = await _pumpSettings(
              tester,
              size: size,
              initialPrefs: LocalPreferences(
                theme: themeMode,
                zones: _kDefaultZones,
                mediaFolder: const MediaFolderStatus(
                  state: MediaFolderState.authorized,
                  embyRoot: '/mnt/media',
                  localRoot: '/Volumes/Media',
                  writable: true,
                ),
              ),
              initialJobs: const [
                SeasonJob(
                  id: 'job_1',
                  seriesId: 's1',
                  seasonId: 'sea1',
                  seasonName: '王者天下 第 1 季',
                  completedCount: 3,
                  total: 12,
                  episodes: [
                    EpisodeJob(
                      episodeId: 'e4',
                      name: '第 4 集',
                      episodeNumber: 4,
                      state: EpisodeJobState.transcribing,
                    ),
                  ],
                ),
              ],
            );

            expect(env.stage.mode, EvStageMode.ambient);

            for (final section in EvSettingsSection.values) {
              await tester.tap(
                find.byKey(Key('ev_settings_nav_${section.name}')),
              );
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: 'Exception in section ${section.name}',
              );
              // Ensure "Anthropic" never leaks into App UI
              expect(find.textContaining('Anthropic'), findsNothing);
            }
          },
        );
      }
    }

    testWidgets('account, look, play, immerse, video preferences read & write', (
      tester,
    ) async {
      var openedUsers = false;
      final env = await _pumpSettings(
        tester,
        onOpenUsers: () => openedUsers = true,
      );

      // Account: server info, quick switch, chooseUserOnStartup, manage users
      expect(find.textContaining('nas.local:8096'), findsOneWidget);
      expect(find.textContaining('4.10.2'), findsOneWidget);
      expect(find.text('已连接'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ev_settings_profile_family')));
      await tester.pumpAndSettle();
      expect(env.accounts.switchCalls, ['family']);

      await tester.tap(find.byKey(const Key('ev_toggle_choose_user')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.chooseUserOnStartup, isFalse);

      await tester.tap(find.byKey(const Key('ev_settings_profiles_manage')));
      await tester.pumpAndSettle();
      expect(openedUsers, isTrue);

      // Look: theme (cinema / 纸面 / 昼夜自动), navigation style, shelf sort
      await tester.tap(find.byKey(const Key('ev_settings_nav_look')));
      await tester.pumpAndSettle();
      expect(find.text('纸面'), findsOneWidget);
      expect(find.text('Anthropic'), findsNothing);

      await tester.tap(find.byKey(const Key('ev_theme_card_paper')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.theme, ThemeMode.paper);

      await tester.tap(find.byKey(const Key('ev_theme_card_automatic')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.theme, ThemeMode.automatic);

      await tester.tap(find.byKey(const Key('ev_nav_style_iconAndText')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.navigation, NavigationStyle.iconAndText);

      await tester.tap(find.byKey(const Key('ev_nav_style_text')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.navigation, NavigationStyle.text);

      await tester.tap(find.byKey(const Key('ev_shelf_sort_score')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.seriesSort, ShelfSort.score);

      await tester.tap(find.byKey(const Key('ev_shelf_sort_title')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.seriesSort, ShelfSort.title);

      // Play: preResolve115, readAheadBytes, autoPlayNext
      await tester.tap(find.byKey(const Key('ev_settings_nav_play')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('ev_toggle_preresolve115')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.preResolve115, isFalse);

      await tester.tap(find.byKey(const Key('ev_readahead_1gb')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.readAheadBytes, 1024 * 1024 * 1024);

      await tester.tap(find.byKey(const Key('ev_toggle_autoplay_next')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.autoPlayNext, isFalse);

      // Immerse: bg video, delay, quickLook, detailTrailerDelay (0/8/12/20), theme music, volume, hideUnwatchedOverview
      await tester.tap(find.byKey(const Key('ev_settings_nav_immerse')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('ev_toggle_bg_video')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.backgroundVideo, isFalse);

      await tester.tap(find.byKey(const Key('ev_bg_delay_2000')));
      await tester.pumpAndSettle();
      expect(
        env.prefs.current.backgroundVideoDelay,
        const Duration(milliseconds: 2000),
      );

      await tester.tap(find.byKey(const Key('ev_toggle_quicklook')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.quickLook, isFalse);

      await tester.tap(find.byKey(const Key('ev_trailer_delay_0')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.detailTrailerDelay, isNull);

      await tester.tap(find.byKey(const Key('ev_trailer_delay_8')));
      await tester.pumpAndSettle();
      expect(
        env.prefs.current.detailTrailerDelay,
        const Duration(seconds: 8),
      );

      await tester.tap(find.byKey(const Key('ev_trailer_delay_20')));
      await tester.pumpAndSettle();
      expect(
        env.prefs.current.detailTrailerDelay,
        const Duration(seconds: 20),
      );

      await tester.tap(find.byKey(const Key('ev_toggle_theme_music')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.themeMusic, isFalse);

      await tester.tap(find.byKey(const Key('ev_theme_vol_high')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.themeVolume, closeTo(0.6, 0.001));

      await tester.tap(find.byKey(const Key('ev_toggle_hide_overview')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.hideUnwatchedOverview, isFalse);

      // Video: Anime4K toggles
      await tester.tap(find.byKey(const Key('ev_settings_nav_video')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('ev_toggle_anime4k_anime')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.anime4kForAnime, isFalse);

      await tester.tap(find.byKey(const Key('ev_toggle_anime4k_other')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.anime4kForOther, isTrue);

      // About
      await tester.tap(find.byKey(const Key('ev_settings_nav_about')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Moonfin 3.1.1'), findsOneWidget);
      expect(find.textContaining('AetherEngine'), findsOneWidget);
    });

    testWidgets('subtitles NAS folder mapping, sources, AI usage & queue, and secrets', (
      tester,
    ) async {
      final env = await _pumpSettings(
        tester,
        initialPrefs: const LocalPreferences(
          zones: _kDefaultZones,
          mediaFolder: MediaFolderStatus(
            state: MediaFolderState.unmounted,
            embyRoot: '/mnt/media',
            reason: '请先在访达中挂载 SMB 共享',
          ),
        ),
        configuredSecrets: {SecretKind.openAi},
        initialJobs: const [
          SeasonJob(
            id: 'job_kingdom',
            seriesId: 's1',
            seasonId: 'sea1',
            seasonName: '王者天下 第 1 季',
            completedCount: 3,
            total: 12,
            episodes: [
              EpisodeJob(
                episodeId: 'e4',
                name: '第 4 集',
                episodeNumber: 4,
                state: EpisodeJobState.transcribing,
              ),
            ],
          ),
        ],
      );

      // Missing secrets warning dot should be shown on sidebar
      expect(find.byKey(const Key('ev_settings_keys_badge')), findsOneWidget);

      // Subs section: sources + NAS folder authorization & recheck
      await tester.tap(find.byKey(const Key('ev_settings_nav_subs')));
      await tester.pumpAndSettle();
      expect(find.text('未挂载'), findsOneWidget);
      expect(find.textContaining('请先在访达中挂载 SMB 共享'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ev_toggle_auto_zh_sub')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.autoSelectChineseSubtitle, isFalse);

      await tester.tap(find.byKey(const Key('ev_toggle_sub_assrt')));
      await tester.pumpAndSettle();
      expect(
        env.prefs.current.subtitleSources.contains(SubtitleSource.assrt),
        isFalse,
      );

      final authBtn = find.byKey(const Key('ev_subs_authorize_folder'));
      await tester.ensureVisible(authBtn);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('ev_subs_emby_root_input')),
          matching: find.byType(EditableText),
        ),
        '/mnt/nas_media',
      );
      await tester.tap(authBtn);
      await tester.pumpAndSettle();
      expect(env.prefs.authorizeCalls, ['/mnt/nas_media']);
      expect(find.text('已挂载 · 可写'), findsOneWidget);
      expect(find.textContaining('/Volumes/Media'), findsOneWidget);

      final recheckBtn = find.byKey(const Key('ev_subs_recheck_folder'));
      await tester.ensureVisible(recheckBtn);
      await tester.tap(recheckBtn);
      await tester.pumpAndSettle();
      expect(env.prefs.mediaFolderStatusCalls, 1);

      // AI section: translation settings, budget presets + custom, usage, job cancel
      await tester.tap(find.byKey(const Key('ev_settings_nav_ai')));
      await tester.pumpAndSettle();
      expect(find.text('\$23.40 / \$100'), findsOneWidget);
      expect(find.textContaining('本月生成 41 集'), findsOneWidget);
      expect(find.textContaining('王者天下 第 1 季'), findsOneWidget);

      Finder input(String name) => find.descendant(
        of: find.byKey(Key(name)), matching: find.byType(EditableText),
      );
      final address = input('ev_ai_translation_address');
      final model = input('ev_ai_translation_model');
      expect(tester.widget<EditableText>(address).controller.text, defaultTranslationBaseUrl);
      expect(tester.widget<EditableText>(model).controller.text, defaultTranslationModel);
      expect(find.textContaining('3 次翻译未计费'), findsOneWidget);
      await tester.enterText(address, 'example.com');
      await tester.enterText(model, '');
      await tester.pump();
      await tester.tap(find.byKey(const Key('ev_ai_translation_save')));
      await tester.pumpAndSettle();
      expect(find.text('请输入有效的翻译服务地址'), findsOneWidget);
      expect(find.text('请输入翻译模型名称'), findsOneWidget);
      expect(env.prefs.current.translationBaseUrl, defaultTranslationBaseUrl);

      await tester.enterText(address, 'https://example.com/v1');
      await tester.enterText(model, 'custom-model');
      await tester.tap(find.byKey(const Key('ev_ai_translation_save')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.translationBaseUrl, 'https://example.com/v1');
      expect(env.prefs.current.translationModel, 'custom-model');
      expect(find.textContaining('当前翻译服务未计费'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ev_secret_edit_openAi')));
      await tester.pumpAndSettle();
      final translationKey = input('ev_secret_input_openAi');
      expect(tester.widget<EditableText>(translationKey).obscureText, isTrue);
      await tester.enterText(translationKey, 'example-translation-key');
      await tester.tap(find.byKey(const Key('ev_secret_save_openAi')));
      await tester.pumpAndSettle();
      expect(env.prefs.setSecretCalls.last, (SecretKind.openAi, 'example-translation-key'));

      await tester.ensureVisible(find.byKey(const Key('ev_ai_budget_50')));
      await tester.tap(find.byKey(const Key('ev_ai_budget_50')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.monthlyBudgetMicros, 50000000);
      expect(env.prefs.current.translationBaseUrl, 'https://example.com/v1');
      expect(env.prefs.current.translationModel, 'custom-model');

      final budgetInput = find.descendant(
        of: find.byKey(const Key('ev_ai_budget_input')),
        matching: find.byType(EditableText),
      );
      await tester.ensureVisible(budgetInput);
      await tester.enterText(budgetInput, '42.5');
      await tester.tap(find.byKey(const Key('ev_ai_budget_apply')));
      await tester.pumpAndSettle();
      expect(env.prefs.current.monthlyBudgetMicros, 42500000);

      final cancelJobBtn = find.byKey(const Key('ev_ai_cancel_job_job_kingdom'));
      await tester.ensureVisible(cancelJobBtn);
      await tester.pumpAndSettle();
      await tester.tap(cancelJobBtn);
      await tester.pumpAndSettle();
      expect(env.subtitles!.cancelJobCalls, ['job_kingdom']);
      expect(find.byKey(const Key('ev_ai_jobs_empty')), findsOneWidget);

      // Keys section shares the translation key and retains subtitle search keys.
      await tester.tap(find.byKey(const Key('ev_settings_nav_keys')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('ev_secret_status_openAi')),
          matching: find.text('已设置'),
        ),
        findsOneWidget,
      );
      // Fill remaining two secrets -> sidebar warning dot disappears
      for (final kind in [SecretKind.assrt, SecretKind.openSubtitles]) {
        await tester.tap(find.byKey(Key('ev_secret_edit_${kind.name}')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byKey(Key('ev_secret_input_${kind.name}')),
            matching: find.byType(EditableText),
          ),
          'token-${kind.name}',
        );
        await tester.tap(find.byKey(Key('ev_secret_save_${kind.name}')));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const Key('ev_settings_keys_badge')), findsNothing);

      // Clear OpenAI secret -> status flips to 缺少 and warning dot returns
      await tester.tap(find.byKey(const Key('ev_secret_edit_openAi')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ev_secret_clear_openAi')));
      await tester.pumpAndSettle();
      expect(env.prefs.setSecretCalls.last, (SecretKind.openAi, null));
      expect(find.byKey(const Key('ev_settings_keys_badge')), findsOneWidget);
    });

    testWidgets('translation key follows saved origin, drops old drafts, and ignores stale checks', (tester) async {
      final env = await _pumpSettings(tester, initialSection: EvSettingsSection.ai);
      Finder key(String name) => find.byKey(Key(name));
      final edit = key('ev_secret_edit_openAi'), field = key('ev_secret_input_openAi');
      final status = key('ev_secret_status_openAi');
      final address = find.descendant(of: key('ev_ai_translation_address'), matching: find.byType(EditableText));
      Finder statusText(String label) => find.descendant(of: status, matching: find.text(label));

      expect(statusText('已设置'), findsOneWidget);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(of: field, matching: find.byType(EditableText)), 'unsaved-old-key');
      await tester.enterText(address, 'https://example.com/v1');
      await tester.pump();
      expect(field, findsNothing);
      expect(tester.widget<EvButton>(edit).onPressed, isNull);
      expect(statusText('已设置'), findsNothing);

      final writing = env.prefs.preferenceWrite = Completer<void>();
      await tester.tap(key('ev_ai_translation_save'));
      await tester.pump();
      await tester.tap(key('ev_settings_nav_keys'));
      await tester.pumpAndSettle();
      expect(tester.widget<EvButton>(edit).onPressed, isNull);
      writing.complete();
      await tester.pumpAndSettle();
      expect(statusText('缺少'), findsOneWidget);
      await tester.tap(key('ev_settings_nav_ai'));
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).controller.text, isEmpty);

      final lateRead = env.prefs.nextSecretsRead = Completer<Set<SecretKind>>();
      await tester.enterText(address, defaultTranslationBaseUrl);
      await tester.pump();
      await tester.tap(key('ev_ai_translation_save'));
      await tester.pumpAndSettle();
      expect(statusText('检测中'), findsOneWidget);
      expect(tester.widget<EvButton>(edit).onPressed, isNull);

      await tester.enterText(address, 'https://example.org/v1');
      await tester.pump();
      await tester.tap(key('ev_ai_translation_save'));
      await tester.pumpAndSettle();
      expect(statusText('缺少'), findsOneWidget);
      lateRead.complete({SecretKind.openAi});
      await tester.pumpAndSettle();
      expect(statusText('缺少'), findsOneWidget);
      await tester.enterText(address, defaultTranslationBaseUrl);
      await tester.pump();
      await tester.tap(key('ev_ai_translation_save'));
      await tester.pumpAndSettle();
      expect(statusText('已设置'), findsOneWidget);
      expect(env.prefs.setSecretCalls, isEmpty);
    });

    testWidgets('failed key save keeps masked input and allows retry', (tester) async {
      final env = await _pumpSettings(tester, initialSection: EvSettingsSection.ai, configuredSecrets: {});
      final field = find.descendant(of: find.byKey(const Key('ev_secret_input_openAi')), matching: find.byType(EditableText));
      final save = find.byKey(const Key('ev_secret_save_openAi'));
      await tester.tap(find.byKey(const Key('ev_secret_edit_openAi')));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'input-to-retry');
      env.prefs.failNextSecretWrite = true;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.textContaining('无法保存钥匙串'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('ev_secret_row_openAi')), matching: find.textContaining('请重试')), findsOneWidget);
      expect(tester.widget<EditableText>(field).obscureText, isTrue);
      expect(tester.widget<EditableText>(field).controller.text, 'input-to-retry');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(find.text('已设置'), findsOneWidget);
      expect(env.prefs.setSecretCalls, List.filled(2, (SecretKind.openAi, 'input-to-retry')));
    });

    testWidgets('local model download, progress, cancel, retry and delete', (tester) async {
      const channel = MethodChannel('embyview/asr');
      final messenger = tester.binding.defaultBinaryMessenger;
      final actions = <String>[];
      const mib = 1024 * 1024;
      var state = 'notDownloaded', received = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'modelStatus':
            return {'state': state, 'totalBytes': 547 * mib, 'receivedBytes': received * mib,
              if (state == 'failed') 'error': '校验失败'};
          case 'downloadModel':
            state = 'downloading';
          case 'cancelDownload':
            state = 'notDownloaded';
          case 'deleteModel':
            state = 'notDownloaded';
            received = 0;
        }
        actions.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await _pumpSettings(tester, initialSection: EvSettingsSection.ai);
      expect(find.textContaining('547 MiB'), findsOneWidget);
      await tester.tap(find.text('下载模型'));
      await tester.pumpAndSettle();
      received = 245;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('245 / 547 MiB'), findsOneWidget);
      expect(find.textContaining('45%'), findsOneWidget);
      await tester.tap(find.text('取消下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续下载'));
      await tester.pumpAndSettle();
      state = 'failed';
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('校验失败'), findsOneWidget);
      await tester.tap(find.text('重新下载'));
      await tester.pumpAndSettle();
      state = 'ready';
      received = 547;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('已就绪'), findsOneWidget);
      await tester.tap(find.text('删除模型'));
      await tester.pumpAndSettle();
      expect(find.text('下载模型'), findsOneWidget);
      expect(actions, ['downloadModel', 'cancelDownload', 'downloadModel', 'downloadModel', 'deleteModel']);
    });

    testWidgets('AI section handles subtitles == null gracefully', (
      tester,
    ) async {
      await _pumpSettings(
        tester,
        withSubtitles: false,
        initialSection: EvSettingsSection.ai,
      );
      expect(find.byKey(const Key('ev_ai_subtitles_disabled')), findsOneWidget);
      expect(find.textContaining('未启用'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('regressions: auto swatch height, color swatch shadow order, nearest trailer delay, scroll sync & reset', (
      tester,
    ) async {
      final env = await _pumpSettings(
        tester,
        size: const Size(1440, 560),
        initialSection: EvSettingsSection.look,
        initialPrefs: const LocalPreferences(
          zones: _kDefaultZones,
          detailTrailerDelay: Duration(seconds: 15),
        ),
      );

      // 1) Auto theme preview split ColoredBoxes stretch to full swatch height (> 0)
      final autoCard = find.byKey(const Key('ev_theme_card_automatic'));
      final boxes = find.descendant(of: autoCard, matching: find.byType(ColoredBox));
      expect(boxes, findsNWidgets(2));
      for (final el in boxes.evaluate()) {
        final box = el.renderObject! as RenderBox;
        expect(box.size.height, greaterThan(60));
        expect(box.size.width, greaterThan(40));
      }

      // 2) Zone editor selected color swatch paints outer color (spread 4) before inner glassSolid (spread 2)
      await tester.tap(find.byKey(const Key('ev_settings_nav_zones')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ev_zone_add')));
      await tester.pumpAndSettle();
      final selectedSwatch = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const Key('ev_zone_color_4')),
          matching: find.byType(Container),
        ),
      );
      final shadows = (selectedSwatch.decoration! as BoxDecoration).boxShadow!;
      expect(shadows, hasLength(2));
      expect(shadows[0].spreadRadius, 4);
      expect(shadows[1].spreadRadius, 2);
      // Esc closes overlay immediately after opening via button tap
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_zone_editor_dialog')), findsNothing);

      // 3) Non-preset detailTrailerDelay (15s) nearest-matches 12s instead of falling back to 0 (关闭)
      await tester.tap(find.byKey(const Key('ev_settings_nav_immerse')));
      await tester.pumpAndSettle();
      expect(tester.widget<EvInteractive>(find.byKey(const Key('ev_trailer_delay_12'))).selected, isTrue);
      expect(tester.widget<EvInteractive>(find.byKey(const Key('ev_trailer_delay_0'))).selected, isFalse);

      // 4) Right pane vertical scroll updates shell scroll offset, and switching section resets to 0
      expect(env.shell.scrolled, isFalse);
      final paneScroll = find.byKey(const ValueKey<EvSettingsSection>(EvSettingsSection.immerse));
      await tester.drag(paneScroll, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(env.shell.scrolled, isTrue);
      expect(env.shell.topFade, greaterThan(0));

      await tester.tap(find.byKey(const Key('ev_settings_nav_look')));
      await tester.pumpAndSettle();
      expect(env.shell.scrolled, isFalse);
      expect(env.shell.topFade, 0.0);
      final lookScroll = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey<EvSettingsSection>(EvSettingsSection.look)),
      );
      expect(lookScroll.key, const ValueKey<EvSettingsSection>(EvSettingsSection.look));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey<EvSettingsSection>(EvSettingsSection.look)),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollable.position.pixels, 0.0);
    });

    testWidgets('regression: stale secrets/facets/usage responses from previous session are ignored after rebind', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final staleSecrets = Completer<Set<SecretKind>>();
      final staleFacets = Completer<ZoneFacets>();
      final staleUsage = Completer<AiUsage>();

      final prefsA = _DelayedSecretsPrefs(staleSecrets.future);
      final prefsB = _FakePreferences(configuredSecrets: {SecretKind.openAi, SecretKind.assrt, SecretKind.openSubtitles});
      final accountsA = _FakeAccounts();
      final accountsB = _FakeAccounts();
      final dataA = _DelayedFacetsData(prefsA, staleFacets.future);
      final dataB = _FakeData(prefsB);
      final subsA = _DelayedUsageSubtitles(staleUsage.future);
      final subsB = _FakeSubtitles(
        initialUsage: const AiUsage(month: '2026-11', state: AiUsageState.available, usedMicros: 5000000, budgetMicros: 30000000, completedEpisodes: 9),
      );
      final immersionPlayback = _FakeImmersionPlayback();
      final servicesA = EmbyViewServices(preferences: prefsA, accounts: accountsA, sessionId: 'sess_a', data: dataA, immersion: immersionPlayback, subtitles: subsA);
      final servicesB = EmbyViewServices(preferences: prefsB, accounts: accountsB, sessionId: 'sess_b', data: dataB, immersion: immersionPlayback, subtitles: subsB);
      final stage = EvStageController();
      final immersion = Immersion(stage: stage, services: servicesA);
      final shell = EvShellController();
      addTearDown(() async {
        shell.dispose(); immersion.dispose(); stage.dispose();
        await immersionPlayback.close(); await subsA.close(); await subsB.close();
        await accountsA.close(); await accountsB.close(); await prefsA.close(); await prefsB.close();
      });

      var active = servicesA;
      late StateSetter hostSetState;
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF09090B),
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(settings: settings, pageBuilder: (ctx, _, _) => builder(ctx)),
          home: StatefulBuilder(
            builder: (context, setState) {
              hostSetState = setState;
              return EvThemeScope(
                preferences: active.preferences,
                child: EvScope(
                  services: active, stage: stage, immersion: immersion, shell: shell,
                  child: const EvSettingsPage(initialSection: EvSettingsSection.ai),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();

      // Switch to session B before session A's async calls resolve
      hostSetState(() => active = servicesB);
      await tester.pumpAndSettle();
      expect(find.text('\$5.00 / \$30'), findsOneWidget);
      expect(find.byKey(const Key('ev_settings_keys_badge')), findsNothing);

      // Now complete stale session A futures -> must NOT overwrite session B
      staleSecrets.complete(const {});
      staleFacets.complete(const ZoneFacets(genres: [FacetOption(value: 'stale', label: '旧会话类型', count: 1)]));
      staleUsage.complete(const AiUsage(month: '2026-11', state: AiUsageState.available, usedMicros: 99000000, budgetMicros: 100000000, completedEpisodes: 99));
      await tester.pumpAndSettle();

      expect(find.text('\$5.00 / \$30'), findsOneWidget);
      expect(find.text('\$99.00 / \$100'), findsNothing);
      expect(find.byKey(const Key('ev_settings_keys_badge')), findsNothing);

      await tester.tap(find.byKey(const Key('ev_settings_nav_zones')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ev_zone_add')));
      await tester.pumpAndSettle();
      expect(find.text('旧会话类型'), findsNothing);
      expect(find.byKey(const Key('ev_zone_facet_genre_g_scifi')), findsOneWidget);
    });
  });
}

class _DelayedSecretsPrefs extends _FakePreferences {
  _DelayedSecretsPrefs(this._future);
  final Future<Set<SecretKind>> _future;
  @override Future<Set<SecretKind>> configuredSecrets() => _future;
}

class _DelayedFacetsData extends _FakeData {
  _DelayedFacetsData(super.preferences, this._future);
  final Future<ZoneFacets> _future;
  @override Future<ZoneFacets> customZoneFacets() => _future;
}

class _DelayedUsageSubtitles extends _FakeSubtitles {
  _DelayedUsageSubtitles(this._future);
  final Future<AiUsage> _future;
  @override Future<AiUsage> usage() => _future;
}
