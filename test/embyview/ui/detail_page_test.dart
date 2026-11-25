import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_page.dart';
import 'package:moonfin/embyview/ui/detail/ev_theme_capsule.dart';
import 'package:moonfin/embyview/ui/kit.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(
    this.id, {
    this.aspectRatio = 16 / 9,
    this.width = 1920,
    this.height = 1080,
  }) : cacheKey = 'detail_test_$id',
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

class _FakePreviewRef implements PreviewRef {
  const _FakePreviewRef({required this.id, required this.name, this.duration});

  @override
  final String id;
  @override
  final String name;
  @override
  final Duration? duration;
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
    sessionId: 'detail-sess-1',
  );

  @override
  AccountSnapshot get snapshot => _snapshot;

  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

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
  final List<String> prepareCalls = [];
  final List<PlayTarget> openedTargets = [];

  @override
  Future<void> prepare(String itemId) async {
    prepareCalls.add(itemId);
  }

  @override
  PlaybackSession open(PlayTarget target) {
    openedTargets.add(target);
    return _FakePlaybackSession(target);
  }
}

class _FakeImmersionPlayback implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast();
  ImmersionSnapshot _snapshot = const ImmersionSnapshot();

  final List<PreviewRef?> playThemeCalls = [];
  final List<PreviewRef?> showVideoCalls = [];
  final List<bool> muteCalls = [];
  int stopCalls = 0;

  void emit(ImmersionSnapshot next) {
    _snapshot = next;
    _changes.add(next);
  }

  @override
  ImmersionSnapshot get snapshot => _snapshot;

  @override
  Stream<ImmersionSnapshot> get changes => _changes.stream;

  @override
  Widget videoSurface({Key? key}) => ColoredBox(key: key, color: const Color(0xFF000000));

  @override
  Future<void> showMutedVideo(PreviewRef? video) async {
    showVideoCalls.add(video);
    _snapshot = ImmersionSnapshot(
      video: video == null ? PreviewState.idle : PreviewState.ready,
      theme: _snapshot.theme,
      themePosition: _snapshot.themePosition,
      themeDuration: _snapshot.themeDuration,
      themeMuted: _snapshot.themeMuted,
    );
    _changes.add(_snapshot);
  }

  @override
  Future<void> playTheme(PreviewRef? song) async {
    playThemeCalls.add(song);
    _snapshot = ImmersionSnapshot(
      video: _snapshot.video,
      theme: song == null ? PreviewState.idle : PreviewState.ready,
      themePosition: song == null ? Duration.zero : _snapshot.themePosition,
      themeDuration: song?.duration,
      themeMuted: _snapshot.themeMuted,
    );
    _changes.add(_snapshot);
  }

  @override
  Future<void> setThemeMuted(bool muted) async {
    muteCalls.add(muted);
    _snapshot = ImmersionSnapshot(
      video: _snapshot.video,
      theme: _snapshot.theme,
      themePosition: _snapshot.themePosition,
      themeDuration: _snapshot.themeDuration,
      themeMuted: muted,
    );
    _changes.add(_snapshot);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _snapshot = const ImmersionSnapshot();
    _changes.add(_snapshot);
  }

  Future<void> close() => _changes.close();
}

class _FakeSubtitles implements EmbyViewSubtitles {
  _FakeSubtitles({
    Map<String, SubtitleAvailability>? availabilityById,
    this.quoteBuilder,
  }) : _availabilityById = availabilityById ?? {};

  final Map<String, SubtitleAvailability> _availabilityById;
  final Future<SeasonQuote> Function(String seriesId, String seasonId)? quoteBuilder;
  final _jobsController = StreamController<List<SeasonJob>>.broadcast();
  List<SeasonJob> _currentJobs = const [];

  final List<String> availabilityCalls = [];
  final List<(String, String)> quoteCalls = [];
  final List<SeasonQuote> queueCalls = [];
  final List<(String, String?)> cancelCalls = [];

  void emitJobs(List<SeasonJob> jobs) {
    _currentJobs = jobs;
    _jobsController.add(jobs);
  }

  @override
  Future<SubtitleAvailability> availability(String itemId) async {
    availabilityCalls.add(itemId);
    return _availabilityById[itemId] ?? const SubtitleAvailability();
  }

  @override
  Future<SeasonQuote> quoteSeason(String seriesId, String seasonId) async {
    quoteCalls.add((seriesId, seasonId));
    if (quoteBuilder != null) return quoteBuilder!(seriesId, seasonId);
    return SeasonQuote(
      id: 'quote_${seriesId}_$seasonId',
      seriesId: seriesId,
      seasonId: seasonId,
      seasonName: '第 2 季',
      episodeIds: const ['s2_e2', 's2_e3'],
      completedCount: 1,
      pendingCount: 2,
      estimatedCostMicros: 1450000,
      budget: BudgetState.available,
      reason: '本月剩余预算充足',
    );
  }

  @override
  Future<String> queueSeason(SeasonQuote quote) async {
    queueCalls.add(quote);
    return 'job_${quote.seasonId}';
  }

  @override
  Stream<List<SeasonJob>> get jobs => Stream.multi((controller) {
    controller.add(_currentJobs);
    final sub = _jobsController.stream.listen(controller.add, onDone: controller.close);
    controller.onCancel = sub.cancel;
  }, isBroadcast: true);

  @override
  Future<void> cancelJob(String jobId, {String? episodeId}) async {
    cancelCalls.add((jobId, episodeId));
  }

  Future<void> close() => _jobsController.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDetailData implements EmbyViewData {
  _FakeDetailData({
    required this.details,
    this.seasonsBySeries = const {},
    this.episodesBySeason = const {},
    this.peopleByItem = const {},
    this.similarByItem = const {},
    this.themeByItem = const {},
    this.safeStillsBySeries = const {},
    this.qualityByItem = const {},
    this.onSeasons,
    this.onSafeStills,
  });

  final Map<String, MediaDetail> details;
  final Map<String, List<SeasonSummary>> seasonsBySeries;
  final Map<String, SeasonEpisodes> episodesBySeason;
  final Map<String, List<PersonCredit>> peopleByItem;
  final Map<String, List<MediaCard>> similarByItem;
  final Map<String, ThemeMedia> themeByItem;
  final Map<String, List<ArtworkRef>> safeStillsBySeries;
  final Map<String, MediaQuality> qualityByItem;
  final Future<List<SeasonSummary>> Function(String seriesId)? onSeasons;
  final Future<List<ArtworkRef>> Function(String seriesId)? onSafeStills;

  @override
  Future<MediaDetail> detail(String itemId) async {
    final d = details[itemId];
    if (d == null) throw const EmbyViewFailure('未找到条目');
    return d;
  }

  @override
  Future<List<SeasonSummary>> seasons(String seriesId) async =>
      onSeasons != null ? onSeasons!(seriesId) : (seasonsBySeries[seriesId] ?? const []);

  @override
  Future<SeasonEpisodes> episodes(String seriesId, String seasonId) async =>
      episodesBySeason['$seriesId:$seasonId']!;

  @override
  Future<List<PersonCredit>> people(String itemId) async =>
      peopleByItem[itemId] ?? const [];

  @override
  Future<List<MediaCard>> similar(String itemId, {int limit = 16}) async =>
      (similarByItem[itemId] ?? const []).take(limit).toList();

  @override
  Future<ThemeMedia> themeMedia(String itemId) async =>
      themeByItem[itemId] ?? const ThemeMedia();

  @override
  Future<List<ArtworkRef>> safeEpisodeStills(String seriesId) async =>
      onSafeStills != null ? onSafeStills!(seriesId) : (safeStillsBySeries[seriesId] ?? const []);

  @override
  Future<MediaQuality?> quality(String itemId) async => qualityByItem[itemId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaCard _makeCard({
  required String id,
  required String title,
  MediaKind kind = MediaKind.movie,
  String? libraryId,
  int year = 2024,
  double score = 8.9,
  List<String> genres = const ['科幻', '动作', '冒险', '惊悚'],
  Duration? duration = const Duration(minutes: 148),
  String? rating = 'PG-13',
  String? overview = '一位盗梦专家在潜意识深处植入想法，踏上危险而迷人的梦境之旅。',
  int? childCount,
  MediaQuality? quality,
  bool withLogo = true,
  int backdropCount = 3,
  bool? played,
  int? episodeNumber,
}) {
  final bds = [
    for (var i = 0; i < backdropCount; i++) _FakeArtworkRef('bd_${id}_$i'),
  ];
  final poster = _FakeArtworkRef('poster_$id', aspectRatio: 2 / 3, width: 600, height: 900);
  final logo = withLogo ? _FakeArtworkRef('logo_$id', aspectRatio: 3.0, width: 900, height: 300) : null;
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
    played: played,
    episodeNumber: episodeNumber,
    art: CardArtwork(
      landscape: ArtworkPlan(
        layers: [if (bds.isNotEmpty) ArtworkLayer(source: bds.first, fit: ArtworkFit.cover)],
        fallbackTitle: title,
      ),
      poster: ArtworkPlan(
        layers: [ArtworkLayer(source: poster)],
        fallbackTitle: title,
      ),
      stage: ArtworkPlan(
        layers: [if (bds.isNotEmpty) ArtworkLayer(source: bds.first, fit: ArtworkFit.cover)],
        fallbackTitle: title,
      ),
      backdrops: bds,
      logo: logo,
    ),
  );
}

EpisodeCard _makeEpisode({
  required String id,
  required String seriesId,
  required String seasonId,
  required int number,
  required String title,
  required String overview,
  bool? played,
  Duration? resumePosition,
  Duration duration = const Duration(minutes: 45),
}) {
  final stillRef = _FakeArtworkRef('still_$id');
  final card = MediaCard(
    id: id,
    kind: MediaKind.episode,
    title: title,
    overview: overview,
    duration: duration,
    played: played,
    seriesId: seriesId,
    seasonId: seasonId,
    episodeNumber: number,
    art: CardArtwork(
      stage: ArtworkPlan(
        layers: [ArtworkLayer(source: stillRef, fit: ArtworkFit.cover)],
        fallbackTitle: title,
      ),
    ),
  );
  return EpisodeCard(
    card: card,
    episodeNumber: number,
    played: played,
    resumePosition: resumePosition,
    still: ArtworkPlan(
      layers: [ArtworkLayer(source: stillRef, fit: ArtworkFit.cover)],
      fallbackTitle: '第 $number 集',
    ),
  );
}

_FakeDetailData _buildFixtureData({
  List<ArtworkRef>? seriesSafeStills,
  PreviewRef? seriesTrailer,
  PreviewRef? movieTrailer,
  bool movieWithLogo = true,
}) {
  final movieCard = _makeCard(
    id: 'm1',
    title: '盗梦空间',
    kind: MediaKind.movie,
    libraryId: 'movie',
    year: 2010,
    score: 9.4,
    genres: const ['科幻', '动作', '悬疑', '剧情'],
    duration: const Duration(minutes: 148),
    rating: 'PG-13',
    quality: const MediaQuality(
      resolution: '4K',
      videoRange: '杜比视界',
      audioLabel: 'Atmos',
      origin: MediaOrigin.direct115,
    ),
    withLogo: movieWithLogo,
    backdropCount: 3,
  );

  final movieDetail = MediaDetail(
    card: movieCard,
    tagline: '你的头脑就是犯罪现场。',
    studios: const ['华纳兄弟', '传奇影业'],
    playTarget: const PlayTarget(itemId: 'm1'),
    embeddedSubtitleLanguages: const ['zh', 'en'],
  );

  final seriesCard = _makeCard(
    id: 's1',
    title: '王者天下',
    kind: MediaKind.series,
    libraryId: 'anime',
    year: 2012,
    score: 9.1,
    genres: const ['历史', '战争', '动作'],
    duration: const Duration(minutes: 25),
    rating: 'TV-14',
    childCount: 2,
    quality: const MediaQuality(
      resolution: '1080p',
      audioLabel: '5.1',
      origin: MediaOrigin.nasLocal,
    ),
    withLogo: false,
    backdropCount: 2,
  );

  final seriesResume = ResumeCard(
    card: seriesCard,
    target: const PlayTarget(
      itemId: 's2_e2',
      startAt: Duration(minutes: 12),
      seriesId: 's1',
      seasonId: 'sea2',
      episodeNumber: 2,
    ),
    position: const Duration(minutes: 12),
    duration: const Duration(minutes: 25),
  );

  final seriesDetail = MediaDetail(
    card: seriesCard,
    studios: const ['Studio Pierrot'],
    episodeCount: 5,
    resume: seriesResume,
    playTarget: seriesResume.target,
    embeddedSubtitleLanguages: const ['ja'],
  );

  final colCard = _makeCard(
    id: 'c1',
    title: '诺兰精选合集',
    kind: MediaKind.collection,
    libraryId: 'box',
    year: 2020,
    childCount: 2,
  );
  final colDetail = MediaDetail(
    card: colCard,
    collectionItems: [
      movieCard,
      _makeCard(id: 'm2', title: '星际穿越', libraryId: 'movie', year: 2014),
    ],
  );

  const sea1 = SeasonSummary(id: 'sea1', name: '季 1', number: 1, total: 2);
  const sea2 = SeasonSummary(id: 'sea2', name: '第 2 季', number: 2, total: 3);

  final s1Episodes = SeasonEpisodes(
    season: sea1,
    playedCount: 2,
    episodes: [
      _makeEpisode(
        id: 's1_e1',
        seriesId: 's1',
        seasonId: 'sea1',
        number: 1,
        title: '无名少年',
        overview: '战国时代的乱世开端。',
        played: true,
      ),
      _makeEpisode(
        id: 's1_e2',
        seriesId: 's1',
        seasonId: 'sea1',
        number: 2,
        title: '命运的邂逅',
        overview: '信与政初次相遇。',
        played: true,
      ),
    ],
  );

  final s2Episodes = SeasonEpisodes(
    season: sea2,
    playedCount: 1,
    episodes: [
      _makeEpisode(
        id: 's2_e1',
        seriesId: 's1',
        seasonId: 'sea2',
        number: 1,
        title: '新世代崛起',
        overview: '已经看过的第一集简介内容。',
        played: true,
      ),
      _makeEpisode(
        id: 's2_e2',
        seriesId: 's1',
        seasonId: 'sea2',
        number: 2,
        title: '静谧的战场',
        overview: '正在观看中的第二集简介内容。',
        played: false,
        resumePosition: const Duration(minutes: 12),
        duration: const Duration(minutes: 25),
      ),
      _makeEpisode(
        id: 's2_e3',
        seriesId: 's1',
        seasonId: 'sea2',
        number: 3,
        title: '剧透预警标题',
        overview: '这是一条高度剧透的未看集简介。',
        played: false,
      ),
    ],
  );

  final people = [
    PersonCredit(
      id: 'p1',
      name: '克里斯托弗·诺兰',
      role: 'Director',
      avatar: _FakeArtworkRef('av1', aspectRatio: 1, width: 200, height: 200),
    ),
    const PersonCredit(id: 'p2', name: '副导演甲', role: 'Director'),
    const PersonCredit(id: 'p3', name: '第三导演不显示在首屏', role: 'Director'),
    PersonCredit(
      id: 'p4',
      name: '莱昂纳多·迪卡普里奥',
      role: 'Actor',
      character: '柯布',
      avatar: _FakeArtworkRef('av4', aspectRatio: 1, width: 200, height: 200),
    ),
    const PersonCredit(id: 'p5', name: '约瑟夫·高登-莱维特', role: 'Actor', character: '亚瑟'),
    const PersonCredit(id: 'p6', name: '艾略特·佩吉', role: 'Actor', character: '阿里阿德涅'),
    const PersonCredit(id: 'p7', name: '汤姆·哈迪', role: 'Actor', character: '伊姆斯'),
    const PersonCredit(id: 'p8', name: '第五主演仅在演职员表', role: 'Actor', character: '齐藤'),
  ];

  final similar = [
    _makeCard(id: 'sim1', title: '星际穿越', libraryId: 'movie', year: 2014),
    _makeCard(id: 'sim2', title: '致命魔术', libraryId: 'movie', year: 2006),
    _makeCard(id: 'sim3', title: '信条', libraryId: 'movie', year: 2020),
  ];

  return _FakeDetailData(
    details: {'m1': movieDetail, 's1': seriesDetail, 'c1': colDetail},
    seasonsBySeries: {'s1': const [sea1, sea2]},
    episodesBySeason: {'s1:sea1': s1Episodes, 's1:sea2': s2Episodes},
    peopleByItem: {'m1': people, 's1': people},
    similarByItem: {'m1': similar, 's1': similar},
    themeByItem: {
      'm1': ThemeMedia(
        songs: const [
          _FakePreviewRef(id: 'song_m1', name: 'Time', duration: Duration(seconds: 100)),
        ],
        trailer: movieTrailer ??
            const _FakePreviewRef(
              id: 'tr_m1',
              name: '盗梦空间预告片',
              duration: Duration(seconds: 60),
            ),
      ),
      's1': ThemeMedia(
        songs: const [
          _FakePreviewRef(id: 'song_s1', name: 'PRIDE', duration: Duration(seconds: 90)),
        ],
        trailer: seriesTrailer,
      ),
    },
    safeStillsBySeries: {
      's1': seriesSafeStills ??
          [
            _FakeArtworkRef('safe_1'),
            _FakeArtworkRef('safe_2'),
            _FakeArtworkRef('safe_3'),
          ],
    },
  );
}

class _Harness {
  _Harness({
    required this.prefs,
    required this.accounts,
    required this.data,
    required this.playback,
    required this.immersionPlayback,
    required this.subtitles,
    required this.stage,
    required this.immersion,
    required this.shell,
    required this.services,
  });

  final _FakePreferences prefs;
  final _FakeAccounts accounts;
  final _FakeDetailData data;
  final _FakePlayback playback;
  final _FakeImmersionPlayback immersionPlayback;
  final _FakeSubtitles? subtitles;
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
    await immersionPlayback.close();
    await subtitles?.close();
  }
}

_Harness _createHarness({
  LocalPreferences initialPrefs = const LocalPreferences(),
  _FakeDetailData? data,
  _FakeSubtitles? subtitles,
  bool withSubtitles = true,
  ValueChanged<String>? onOpenDetail,
}) {
  final prefs = _FakePreferences(initialPrefs);
  final accounts = _FakeAccounts();
  final resolvedData = data ?? _buildFixtureData();
  final playback = _FakePlayback();
  final immersionPlayback = _FakeImmersionPlayback();
  final resolvedSubs = withSubtitles ? (subtitles ?? _FakeSubtitles()) : null;
  final services = EmbyViewServices(
    preferences: prefs,
    accounts: accounts,
    sessionId: 'detail-sess-1',
    data: resolvedData,
    playback: playback,
    immersion: immersionPlayback,
    subtitles: resolvedSubs,
  );
  final stage = EvStageController();
  final immersion = Immersion(stage: stage, services: services);
  final shell = EvShellController(
    zones: const [
      ZoneTile(id: 'anime', name: '番剧', iconKey: 'nav_anime', colorSlot: 0, total: 12, unit: '部'),
      ZoneTile(id: 'movie', name: '电影', iconKey: 'nav_movie', colorSlot: 1, total: 100, unit: '部'),
    ],
    onOpenDetail: onOpenDetail,
  );
  return _Harness(
    prefs: prefs,
    accounts: accounts,
    data: resolvedData,
    playback: playback,
    immersionPlayback: immersionPlayback,
    subtitles: resolvedSubs,
    stage: stage,
    immersion: immersion,
    shell: shell,
    services: services,
  );
}

Widget _wrapDetail(
  _Harness h, {
  required Widget child,
  Size size = const Size(1440, 900),
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
                child,
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: ListenableBuilder(
                    listenable: h.shell,
                    builder: (_, _) => EvTopBar(
                      zones: h.shell.zones,
                      hideTabs: h.shell.hideTabs,
                      hideAvatar: h.shell.hideAvatar,
                      showBack: h.shell.showBack,
                      scrolled: h.shell.scrolled,
                      topFade: h.shell.topFade,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('C4.1 Theme music, prepare preflight, chrome, and cleanup', () {
    testWidgets(
      'prepares playback, updates chrome, plays theme with live ring progress, mutes, and stops theme/video on leave',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final h = _createHarness(
          initialPrefs: const LocalPreferences(
            detailTrailerDelay: Duration(seconds: 8),
            themeMusic: true,
          ),
        );
        addTearDown(h.dispose);

        final showDetail = ValueNotifier<bool>(true);
        addTearDown(showDetail.dispose);

        await tester.pumpWidget(
          _wrapDetail(
            h,
            child: ValueListenableBuilder<bool>(
              valueListenable: showDetail,
              builder: (_, visible, _) => visible
                  ? const EvDetailPage(itemId: 'm1', enableAnimations: false)
                  : const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // 1. playback.prepare & immersion.playTheme invoked.
        expect(h.playback.prepareCalls, ['m1']);
        expect(h.immersionPlayback.playThemeCalls.length, 1);
        expect(h.immersionPlayback.playThemeCalls.first?.id, 'song_m1');

        // 2. Shell chrome updated for detail page.
        expect(h.shell.hideTabs, isTrue);
        expect(h.shell.hideAvatar, isTrue);
        expect(h.shell.showBack, isTrue);

        // 3. Theme capsule visible and progress ring updates with ImmersionSnapshot.
        expect(find.byKey(const Key('ev_detail_theme_capsule')), findsOneWidget);
        expect(find.text('主题曲'), findsOneWidget);

        h.immersionPlayback.emit(
          const ImmersionSnapshot(
            theme: PreviewState.ready,
            themePosition: Duration(seconds: 40),
            themeDuration: Duration(seconds: 100),
            themeMuted: false,
          ),
        );
        await tester.pump();

        final ringFinder = find.descendant(
          of: find.byKey(const Key('ev_detail_theme_ring')),
          matching: find.byType(CustomPaint),
        );
        final ringPaint = tester.widget<CustomPaint>(ringFinder);
        final ringRenderBefore = tester.renderObject(ringFinder);
        expect(ringPaint.key, isNull);
        expect((ringPaint.painter! as EvRingProgressPainter).progress, closeTo(0.4, 0.01));

        h.immersionPlayback.emit(
          const ImmersionSnapshot(
            theme: PreviewState.ready,
            themePosition: Duration(seconds: 75),
            themeDuration: Duration(seconds: 100),
            themeMuted: false,
          ),
        );
        await tester.pump();
        final ringPaint2 = tester.widget<CustomPaint>(ringFinder);
        expect(tester.renderObject(ringFinder), same(ringRenderBefore));
        expect((ringPaint2.painter! as EvRingProgressPainter).progress, closeTo(0.75, 0.01));

        // 4. Mute toggle calls setThemeMuted.
        await tester.tap(find.byKey(const Key('ev_detail_theme_mute')));
        await tester.pump();
        expect(h.immersionPlayback.muteCalls, [true]);

        await tester.tap(find.byKey(const Key('ev_detail_theme_mute')));
        await tester.pump();
        expect(h.immersionPlayback.muteCalls, [true, false]);

        // 5. Trigger trailer video so leaving verifies both stopTheme and stopVideo.
        await tester.tap(find.byKey(const Key('ev_detail_trailer_btn')));
        await tester.pump();
        expect(h.immersionPlayback.showVideoCalls.last?.id, 'tr_m1');

        // 6. Leave detail page while EvStage & EvTopBar remain mounted.
        showDetail.value = false;
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(h.immersionPlayback.playThemeCalls.last, isNull);
        expect(h.immersionPlayback.showVideoCalls.last, isNull);
        expect(h.shell.hideTabs, isFalse);
        expect(h.shell.hideAvatar, isFalse);
        expect(h.shell.showBack, isFalse);
      },
    );

    testWidgets('play button uses MediaDetail.playTarget / ResumeCard.target and stops media', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final h = _createHarness();
      addTearDown(h.dispose);

      PlayTarget? playedTarget;
      await tester.pumpWidget(
        _wrapDetail(
          h,
          child: EvDetailPage(
            itemId: 's1',
            enableAnimations: false,
            onPlayTarget: (target, art, origin) => playedTarget = target,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('ev_detail_play_btn')));
      await tester.pump();

      expect(playedTarget, isNotNull);
      expect(playedTarget!.itemId, 's2_e2');
      expect(playedTarget!.episodeNumber, 2);
      expect(h.immersionPlayback.playThemeCalls.last, isNull);
    });
  });

  group('C4.2 Movie & Series layout, themes, viewports, rotation, trailer/safe stills, episodes, hover & facts', () {
    testWidgets(
      'movie and series render cleanly with zero overflow in cinema & paper themes at 1440x900 and 2560x1440',
      (tester) async {
        for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
          for (final themeMode in const [ThemeMode.cinema, ThemeMode.paper]) {
            for (final itemId in const ['m1', 's1', 'c1']) {
              tester.view.physicalSize = size;
              tester.view.devicePixelRatio = 1.0;

              final h = _createHarness(
                initialPrefs: LocalPreferences(
                  theme: themeMode,
                  navigation: NavigationStyle.iconAndText,
                ),
              );
              await tester.pumpWidget(
                _wrapDetail(
                  h,
                  size: size,
                  child: EvDetailPage(itemId: itemId, enableAnimations: false),
                ),
              );
              await tester.pumpAndSettle();

              final scale = EvScale.fromSize(size);
              final heroRect = tester.getRect(find.byKey(const Key('ev_detail_hero')));
              expect(heroRect.height, closeTo(scale.vh(100) - scale.peek, 0.5));
              expect(
                tester.takeException(),
                isNull,
                reason: 'No overflow for $itemId in $themeMode at $size',
              );

              if (itemId == 'c1') {
                expect(find.byKey(const Key('ev_detail_collection_shelf')), findsOneWidget);
              }

              await tester.pumpWidget(const SizedBox.shrink());
              await h.dispose();
            }
          }
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      },
    );

    testWidgets(
      'movie hero metadata, director/actors cap, 7s backdrop rotation, dot click, trailer countdown, people & facts',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final h = _createHarness(
          initialPrefs: const LocalPreferences(detailTrailerDelay: Duration(seconds: 8)),
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(
          _wrapDetail(
            h,
            child: const EvDetailPage(itemId: 'm1', enableAnimations: false),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Hero content: studio pill, logo, meta, tagline, overview, credits (max 2 directors, max 4 actors).
        final heroFinder = find.byKey(const Key('ev_detail_hero'));
        expect(find.descendant(of: heroFinder, matching: find.text('华纳兄弟')), findsOneWidget);
        expect(find.byKey(const ValueKey<String>('ev_detail_logo_detail_test_logo_m1')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('9.4')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('科幻 / 动作 / 悬疑')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('4K')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('杜比视界')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('Atmos')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('115 直连')), findsOneWidget);
        expect(find.descendant(of: heroFinder, matching: find.text('你的头脑就是犯罪现场。')), findsOneWidget);

        final creditsWidget = tester.widget<Text>(find.byKey(const Key('ev_detail_credits')));
        final creditsText = creditsWidget.textSpan!.toPlainText();
        expect(creditsText, contains('克里斯托弗·诺兰、副导演甲'));
        expect(creditsText, isNot(contains('第三导演')));
        expect(creditsText, contains('莱昂纳多·迪卡普里奥、约瑟夫·高登-莱维特、艾略特·佩吉、汤姆·哈迪'));
        expect(creditsText, isNot(contains('第五主演')));

        // Initial backdrop is index 0; after 7s rotates to index 1.
        expect(h.stage.activeBackdropKey, contains('detail_test_bd_m1_0'));
        await tester.pump(const Duration(seconds: 7));
        expect(h.stage.activeBackdropKey, contains('detail_test_bd_m1_1'));

        // Trailer countdown ticked down from 8s to 1s -> 1 more second triggers trailer!
        expect(find.text('1 秒后播放预告'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('预告片播放中 · 点此停止'), findsOneWidget);
        expect(h.immersionPlayback.showVideoCalls.last?.id, 'tr_m1');

        // Clicking dot #2 stops live trailer and selects backdrop #2.
        await tester.tap(find.byKey(const Key('ev_detail_bg_dot_2')));
        await tester.pump();
        expect(h.stage.activeBackdropKey, contains('detail_test_bd_m1_2'));

        // Movie scroll veil blurs (detailNoBlur == false).
        expect(h.stage.mode, EvStageMode.detail);
        expect(h.stage.detailNoBlur, isFalse);

        // People carousel and bottom facts table exist.
        expect(find.byKey(const Key('ev_detail_people_shelf')), findsOneWidget);
        expect(find.text('第五主演仅在演职员表'), findsOneWidget);
        expect(find.byKey(const Key('ev_detail_facts')), findsOneWidget);
        expect(find.text('115 网盘 strm · 起播前预解析直连'), findsOneWidget);
        expect(find.text('148 分钟'), findsOneWidget);
      },
    );

    testWidgets(
      'safe episode stills: <3 hides pill & does not play; >=3 plays slideshow labeled 正片片段 every 3.2s',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Case A: < 3 safe stills -> no trailer pill.
        final hFew = _createHarness(
          data: _buildFixtureData(
            seriesSafeStills: [_FakeArtworkRef('only_1'), _FakeArtworkRef('only_2')],
          ),
        );
        await tester.pumpWidget(
          _wrapDetail(
            hFew,
            child: const EvDetailPage(itemId: 's1', enableAnimations: false),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_detail_trailer_btn')), findsNothing);
        expect(find.byKey(const Key('ev_detail_safe_still_label')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await hFew.dispose();

        // Case B: >= 3 safe stills -> countdown & 3.2s slideshow labeled 「正片片段」.
        final hMany = _createHarness(
          initialPrefs: const LocalPreferences(detailTrailerDelay: Duration(seconds: 8)),
          data: _buildFixtureData(
            seriesSafeStills: [
              _FakeArtworkRef('safe_a'),
              _FakeArtworkRef('safe_b'),
              _FakeArtworkRef('safe_c'),
            ],
          ),
        );
        addTearDown(hMany.dispose);

        await tester.pumpWidget(
          _wrapDetail(
            hMany,
            child: const EvDetailPage(itemId: 's1', enableAnimations: false),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('8 秒后播放片段'), findsOneWidget);
        // Tap pill early to start safe still slideshow.
        await tester.tap(find.byKey(const Key('ev_detail_trailer_btn')));
        await tester.pump();

        expect(find.byKey(const Key('ev_detail_safe_still_label')), findsOneWidget);
        expect(find.text('正片片段'), findsOneWidget);
        expect(find.text('正片片段 · 点此停止'), findsOneWidget);
        expect(hMany.stage.activeBackdropKey, contains('detail_test_safe_a'));

        await tester.pump(const Duration(milliseconds: 3200));
        expect(hMany.stage.activeBackdropKey, contains('detail_test_safe_b'));

        await tester.pump(const Duration(milliseconds: 3200));
        expect(hMany.stage.activeBackdropKey, contains('detail_test_safe_c'));

        // Tap again to stop and restore backdrop.
        await tester.tap(find.byKey(const Key('ev_detail_trailer_btn')));
        await tester.pump();
        expect(find.byKey(const Key('ev_detail_safe_still_label')), findsNothing);
        expect(hMany.stage.activeBackdropKey, contains('detail_test_bd_s1_0'));
      },
    );

    testWidgets(
      'series auto-selects first unwatched season, switches seasons, protects unwatched overview (0.6s reveal), and swaps stage backdrop on 350ms hover',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final h = _createHarness(
          initialPrefs: const LocalPreferences(
            detailTrailerDelay: null,
            hideUnwatchedOverview: true,
          ),
        );
        addTearDown(h.dispose);

        PlayTarget? epTarget;
        await tester.pumpWidget(
          _wrapDetail(
            h,
            child: EvDetailPage(
              itemId: 's1',
              enableAnimations: false,
              onPlayTarget: (t, _, _) => epTarget = t,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Series stage mode uses detailNoBlur == true.
        expect(h.stage.mode, EvStageMode.detail);
        expect(h.stage.detailNoBlur, isTrue);

        // Season 1 has all episodes watched -> auto-selected Season 2!
        expect(find.text('1 / 3 已看'), findsOneWidget);
        expect(find.byKey(const Key('ev_episode_card_s2_e1')), findsOneWidget);
        expect(find.byKey(const Key('ev_episode_card_s2_e3')), findsOneWidget);

        // EvEpisodeCard exposes public card & episode properties for W4.4 quick look.
        final epWidget = tester.widget<EvEpisodeCard>(find.byKey(const Key('ev_episode_card_s2_e3')));
        expect(epWidget.card.id, 's2_e3');
        expect(epWidget.episode.episodeNumber, 3);

        // Played checkmark only on watched episode s2_e1.
        expect(find.byKey(const Key('ev_episode_played_s2_e1')), findsOneWidget);
        expect(find.byKey(const Key('ev_episode_played_s2_e2')), findsNothing);
        expect(find.byKey(const Key('ev_episode_played_s2_e3')), findsNothing);

        // Watched (s2_e1) and in-progress (s2_e2) show overview immediately; unwatched (s2_e3) hides overview.
        expect(find.byKey(const Key('ev_episode_overview_s2_e1')), findsOneWidget);
        expect(find.byKey(const Key('ev_episode_overview_s2_e2')), findsOneWidget);
        expect(find.byKey(const Key('ev_episode_overview_s2_e3')), findsNothing);

        // Scroll down so episode cards are comfortably visible.
        await tester.drag(find.byKey(const Key('ev_detail_scroller')), const Offset(0, -350));
        await tester.pumpAndSettle();

        // Hover unwatched episode s2_e3:
        // - at 350ms: stage switches to crisp episode still (veilLifted: true)
        // - at 600ms: unwatched overview reveals!
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        final ep3Center = tester.getCenter(find.byKey(const Key('ev_episode_card_s2_e3')));
        await mouse.moveTo(ep3Center);
        await tester.pump(const Duration(milliseconds: 360));
        expect(h.stage.veilLifted, isTrue);
        expect(h.stage.activeBackdropKey, contains('detail_test_still_s2_e3'));
        expect(find.byKey(const Key('ev_episode_overview_s2_e3')), findsNothing);

        await tester.pump(const Duration(milliseconds: 260));
        expect(find.byKey(const Key('ev_episode_overview_s2_e3')), findsOneWidget);

        // Move away: overview hides, and after 900ms stage restores base backdrop.
        await mouse.moveTo(const Offset(5, 5));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('ev_episode_overview_s2_e3')), findsNothing);
        await tester.pump(const Duration(milliseconds: 750));
        expect(h.stage.veilLifted, isFalse);
        expect(h.stage.activeBackdropKey, contains('detail_test_bd_s1_0'));

        // Tap episode s2_e2 to play with resumePosition & season/episode metadata.
        await tester.tap(find.byKey(const Key('ev_episode_card_s2_e2')));
        await tester.pump();
        expect(epTarget?.itemId, 's2_e2');
        expect(epTarget?.startAt, const Duration(minutes: 12));
        expect(epTarget?.seriesId, 's1');
        expect(epTarget?.seasonId, 'sea2');
        expect(epTarget?.episodeNumber, 2);

        // Switch to Season 1 (normalized label 「第 1 季」) and verify 2 / 2 已看.
        await tester.tap(find.byKey(const Key('ev_detail_season_tab_sea1')));
        await tester.pumpAndSettle();
        expect(find.text('第 1 季'), findsOneWidget);
        expect(find.text('2 / 2 已看'), findsOneWidget);
        expect(find.byKey(const Key('ev_episode_card_s1_e1')), findsOneWidget);
      },
    );
  });

  group('C4.3 EmbyViewSubtitles season generation state machine & null-subtitles hiding', () {
    testWidgets('hides AI season button and episode subtitle badges when subtitles service is null', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final h = _createHarness(withSubtitles: false);
      addTearDown(h.dispose);

      await tester.pumpWidget(
        _wrapDetail(
          h,
          child: const EvDetailPage(itemId: 's1', enableAnimations: false),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ev_detail_ai_season_btn')), findsNothing);
      expect(find.byKey(const Key('ev_episode_sub_badge_s2_e1')), findsNothing);
      expect(find.byKey(const Key('ev_episode_sub_badge_s2_e2')), findsNothing);
      expect(find.byKey(const Key('ev_episode_sub_badge_s2_e3')), findsNothing);
    });

    testWidgets(
      'distinguishes complete vs partial availability, quotes & queues season, streams job states, and supports episode & season cancel',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var budgetExceededFirst = true;
        final subs = _FakeSubtitles(
          availabilityById: const {
            's2_e1': SubtitleAvailability(
              chinese: ChineseSubtitleState.complete,
              hasAiChinese: true,
            ),
            's2_e2': SubtitleAvailability(
              chinese: ChineseSubtitleState.partial,
              reason: '仅覆盖前半集',
            ),
            's2_e3': SubtitleAvailability(
              chinese: ChineseSubtitleState.canGenerate,
            ),
          },
          quoteBuilder: (seriesId, seasonId) async {
            if (budgetExceededFirst) {
              budgetExceededFirst = false;
              return SeasonQuote(
                id: 'quote_exceeded',
                seriesId: seriesId,
                seasonId: seasonId,
                seasonName: '第 2 季',
                episodeIds: const ['s2_e2', 's2_e3'],
                completedCount: 1,
                pendingCount: 2,
                estimatedCostMicros: 2500000,
                budget: BudgetState.exceeded,
                reason: '本月已达到 30 美元预算上限',
              );
            }
            return SeasonQuote(
              id: 'quote_ok',
              seriesId: seriesId,
              seasonId: seasonId,
              seasonName: '第 2 季',
              episodeIds: const ['s2_e2', 's2_e3'],
              completedCount: 1,
              pendingCount: 2,
              estimatedCostMicros: 1200000,
              budget: BudgetState.available,
              reason: '预计耗时约 4 分钟',
            );
          },
        );

        final h = _createHarness(
          initialPrefs: const LocalPreferences(
            navigation: NavigationStyle.iconAndText,
            detailTrailerDelay: null,
          ),
          subtitles: subs,
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(
          _wrapDetail(
            h,
            child: const EvDetailPage(itemId: 's1', enableAnimations: false),
          ),
        );
        await tester.pumpAndSettle();

        // Only s2_e1 (complete) counts toward 「1 / 3 已有」; s2_e2 (partial) shows 「部分字幕」 and does NOT count.
        expect(find.text('1 / 3 已有'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_episode_sub_badge_s2_e1')),
            matching: find.text('AI 中字'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_episode_sub_badge_s2_e2')),
            matching: find.text('部分字幕'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('ev_episode_sub_badge_s2_e3')), findsNothing);

        // Verify compact icon mode hides inline count text and keeps outer ring.
        await h.prefs.update(
          const LocalPreferences(navigation: NavigationStyle.icon, detailTrailerDelay: null),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 / 3 已有'), findsNothing);
        expect(find.byKey(const Key('ev_detail_ai_progress_ring')), findsOneWidget);

        // Switch back to iconAndText to continue interactive quote flow.
        await h.prefs.update(
          const LocalPreferences(navigation: NavigationStyle.iconAndText, detailTrailerDelay: null),
        );
        await tester.pumpAndSettle();

        // Scroll episodes bar into clear view.
        await tester.drag(find.byKey(const Key('ev_detail_scroller')), const Offset(0, -300));
        await tester.pumpAndSettle();

        // 1st click: budget exceeded quote -> confirm disabled, shows reason, close with cancel.
        await tester.tap(find.byKey(const Key('ev_detail_ai_season_btn')));
        await tester.pumpAndSettle();
        expect(subs.quoteCalls.length, 1);
        expect(find.byKey(const Key('ev_season_quote_dialog')), findsOneWidget);
        expect(find.text('\$2.50'), findsOneWidget);
        expect(find.text('已超出本月预算'), findsOneWidget);
        expect(find.text('本月已达到 30 美元预算上限'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_season_quote_confirm')));
        await tester.pump();
        expect(subs.queueCalls, isEmpty);

        await tester.tap(find.byKey(const Key('ev_season_quote_cancel')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_season_quote_dialog')), findsNothing);

        // 2nd click: budget available quote -> confirm calls queueSeason(quote).
        await tester.tap(find.byKey(const Key('ev_detail_ai_season_btn')));
        await tester.pumpAndSettle();
        expect(find.text('\$1.20'), findsOneWidget);
        expect(find.text('预算可用'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_season_quote_confirm')));
        await tester.pumpAndSettle();
        expect(subs.queueCalls.length, 1);
        expect(subs.queueCalls.single.id, 'quote_ok');

        // Stream job update 1: queued + transcribing.
        subs.emitJobs(const [
          SeasonJob(
            id: 'job_sea2',
            seriesId: 's1',
            seasonId: 'sea2',
            seasonName: '第 2 季',
            completedCount: 1,
            total: 3,
            episodes: [
              EpisodeJob(episodeId: 's2_e1', name: 'E1', state: EpisodeJobState.completed),
              EpisodeJob(episodeId: 's2_e2', name: 'E2', state: EpisodeJobState.transcribing),
              EpisodeJob(episodeId: 's2_e3', name: 'E3', state: EpisodeJobState.queued),
            ],
          ),
        ]);
        await tester.pumpAndSettle();

        expect(find.text('正在生成 1 / 3'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_episode_sub_badge_s2_e2')),
            matching: find.text('听写中'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_episode_sub_badge_s2_e3')),
            matching: find.text('排队中'),
          ),
          findsOneWidget,
        );

        // Single-episode cancel on queued s2_e3.
        await tester.tap(find.byKey(const Key('ev_episode_sub_cancel_s2_e3')));
        await tester.pump();
        expect(subs.cancelCalls, [('job_sea2', 's2_e3')]);

        // Stream job update 2: s2_e2 translating -> completed, s2_e3 translating.
        subs.emitJobs(const [
          SeasonJob(
            id: 'job_sea2',
            seriesId: 's1',
            seasonId: 'sea2',
            seasonName: '第 2 季',
            completedCount: 2,
            total: 3,
            episodes: [
              EpisodeJob(episodeId: 's2_e1', name: 'E1', state: EpisodeJobState.completed),
              EpisodeJob(episodeId: 's2_e2', name: 'E2', state: EpisodeJobState.completed),
              EpisodeJob(episodeId: 's2_e3', name: 'E3', state: EpisodeJobState.translating),
            ],
          ),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('正在生成 2 / 3'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_episode_sub_badge_s2_e2')),
            matching: find.text('AI 中字'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_episode_sub_badge_s2_e3')),
            matching: find.text('翻译中'),
          ),
          findsOneWidget,
        );

        // Season cancel button calls cancelJob(jobId) without episodeId.
        await tester.tap(find.byKey(const Key('ev_detail_ai_cancel_btn')));
        await tester.pump();
        expect(subs.cancelCalls.last, ('job_sea2', null));

        // Final failed state renders 「失败」.
        subs.emitJobs(const [
          SeasonJob(
            id: 'job_sea2',
            seriesId: 's1',
            seasonId: 'sea2',
            seasonName: '第 2 季',
            completedCount: 2,
            total: 3,
            episodes: [
              EpisodeJob(episodeId: 's2_e1', name: 'E1', state: EpisodeJobState.completed),
              EpisodeJob(episodeId: 's2_e2', name: 'E2', state: EpisodeJobState.completed),
              EpisodeJob(
                episodeId: 's2_e3',
                name: 'E3',
                state: EpisodeJobState.failed,
                failure: EmbyViewFailure('网络超时'),
              ),
            ],
          ),
        ]);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_episode_sub_badge_s2_e3')),
            matching: find.text('失败'),
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('Regressions: quality merge, immersion failure reset + countdown restart, disabled secondary buttons, concurrent series fetch', () {
    testWidgets('merges data.quality fields into card.quality, disables unwired hero buttons, and resets trailer & restarts countdown on failure', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final card = _makeCard(
        id: 'm_merge', title: '字段合并测试', backdropCount: 3,
        quality: const MediaQuality(resolution: '4K', origin: MediaOrigin.nasLocal),
      );
      final data = _FakeDetailData(
        details: {'m_merge': MediaDetail(card: card, playTarget: const PlayTarget(itemId: 'm_merge'))},
        qualityByItem: {'m_merge': const MediaQuality(videoRange: 'Dolby Vision', audioLabel: 'Atmos')},
        themeByItem: {'m_merge': const ThemeMedia(trailer: _FakePreviewRef(id: 'tr_merge', name: '预告片'))},
      );
      final h = _createHarness(
        initialPrefs: const LocalPreferences(detailTrailerDelay: Duration(seconds: 4)),
        data: data,
      );
      addTearDown(h.dispose);

      await tester.pumpWidget(_wrapDetail(h, child: const EvDetailPage(itemId: 'm_merge', enableAnimations: false)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 1. Field-level quality merge keeps card fields and adds data.quality fields.
      final heroFinder = find.byKey(const Key('ev_detail_hero'));
      expect(find.descendant(of: heroFinder, matching: find.text('4K')), findsOneWidget);
      expect(find.descendant(of: heroFinder, matching: find.text('DOLBY VISION')), findsOneWidget);
      expect(find.descendant(of: heroFinder, matching: find.text('Atmos')), findsOneWidget);
      expect(find.descendant(of: heroFinder, matching: find.text('NAS 本地')), findsOneWidget);

      // 2. Unwired secondary buttons pass null onPressed (disabled state).
      expect(tester.widget<EvButton>(find.byKey(const Key('ev_detail_favorite_btn'))).onPressed, isNull);
      expect(tester.widget<EvButton>(find.byKey(const Key('ev_detail_played_btn'))).onPressed, isNull);
      expect(tester.widget<EvButton>(find.byKey(const Key('ev_detail_more_btn'))).onPressed, isNull);

      // 3. Start trailer, emit video failure -> resets trailerLive, restarts ticking countdown, and unlocks 7s backdrop rotation.
      await tester.tap(find.byKey(const Key('ev_detail_trailer_btn')));
      await tester.pump();
      expect(find.text('预告片播放中 · 点此停止'), findsOneWidget);

      h.immersionPlayback.emit(const ImmersionSnapshot(video: PreviewState.failed));
      await tester.pump();
      expect(find.text('4 秒后播放预告'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('3 秒后播放预告'), findsOneWidget);

      // Stop manually after starting again, and verify 7s backdrop rotation is unlocked (not frozen).
      final initialBd = h.stage.activeBackdropKey;
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('1 秒后播放预告'), findsOneWidget);
      // Select dot 0 to verify countdown keeps ticking while backdrops rotate every 7s.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('预告片播放中 · 点此停止'), findsOneWidget);
      h.immersionPlayback.emit(const ImmersionSnapshot(video: PreviewState.idle));
      await tester.pump();
      expect(find.text('4 秒后播放预告'), findsOneWidget);
      // Let 3s pass (still before 4s trailer restart, and total 7s since start -> backdrop rotated!).
      await tester.pump(const Duration(seconds: 3));
      expect(h.stage.activeBackdropKey, isNot(initialBd));
      expect(find.text('1 秒后播放预告'), findsOneWidget);
    });

    testWidgets('starts seasons and safeEpisodeStills concurrently in _loadSeries', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final seasonsC = Completer<List<SeasonSummary>>();
      final stillsC = Completer<List<ArtworkRef>>();
      var seasonsStarted = false, stillsStarted = false;

      final sCard = _makeCard(id: 's_conc', title: '并发剧集', kind: MediaKind.series, childCount: 1);
      final data = _FakeDetailData(
        details: {'s_conc': MediaDetail(card: sCard)},
        onSeasons: (_) { seasonsStarted = true; return seasonsC.future; },
        onSafeStills: (_) { stillsStarted = true; return stillsC.future; },
      );
      final h = _createHarness(initialPrefs: const LocalPreferences(detailTrailerDelay: null), data: data);
      addTearDown(h.dispose);

      await tester.pumpWidget(_wrapDetail(h, child: const EvDetailPage(itemId: 's_conc', enableAnimations: false)));
      await tester.pump();
      await tester.pump();

      expect(seasonsStarted, isTrue);
      expect(stillsStarted, isTrue);

      seasonsC.complete(const []);
      stillsC.complete(const []);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
