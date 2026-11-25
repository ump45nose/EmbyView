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
    this.onSetFavorite,
    this.onSetPlayed,
  });

  final Map<String, MediaDetail> details;
  final Map<String, List<SeasonSummary>> seasonsBySeries;
  final Map<String, SeasonEpisodes> episodesBySeason;
  final Map<String, List<PersonCredit>> peopleByItem;
  final Map<String, List<MediaCard>> similarByItem;
  final Map<String, ThemeMedia> themeByItem;
  final Map<String, List<SafeEpisodeStill>> safeStillsBySeries;
  final Map<String, MediaQuality> qualityByItem;
  final Future<List<SeasonSummary>> Function(String seriesId)? onSeasons;
  final Future<List<SafeEpisodeStill>> Function(String seriesId)? onSafeStills;
  final Future<void> Function(String itemId, bool favorite)? onSetFavorite;
  final Future<void> Function(String itemId, bool played)? onSetPlayed;

  final List<(String, bool)> favoriteCalls = [];
  final List<(String, bool)> playedCalls = [];

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
  Future<List<SafeEpisodeStill>> safeEpisodeStills(String seriesId) async =>
      onSafeStills != null ? onSafeStills!(seriesId) : (safeStillsBySeries[seriesId] ?? const []);

  @override
  Future<MediaQuality?> quality(String itemId) async => qualityByItem[itemId];

  @override
  Future<void> setFavorite(String itemId, bool favorite) async {
    favoriteCalls.add((itemId, favorite));
    if (onSetFavorite != null) return onSetFavorite!(itemId, favorite);
  }

  @override
  Future<void> setPlayed(String itemId, bool played) async {
    playedCalls.add((itemId, played));
    if (onSetPlayed != null) return onSetPlayed!(itemId, played);
  }

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
  bool? favorite,
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
    favorite: favorite,
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
  List<SafeEpisodeStill>? seriesSafeStills,
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
            SafeEpisodeStill(image: _FakeArtworkRef('safe_1'), seasonNumber: 1, episodeNumber: 1, seasonName: '第 1 季'),
            SafeEpisodeStill(image: _FakeArtworkRef('safe_2'), seasonNumber: 1, episodeNumber: 2, seasonName: '第 1 季'),
            SafeEpisodeStill(image: _FakeArtworkRef('safe_3'), seasonNumber: 2, episodeNumber: 1, seasonName: '第 2 季'),
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
              expect(find.byKey(const Key('ev_detail_more_btn')), findsNothing);
              for (final btnKey in const [Key('ev_detail_favorite_btn'), Key('ev_detail_played_btn')]) {
                final btnFinder = find.byKey(btnKey);
                expect(btnFinder, findsOneWidget);
                final opacity = tester.widget<Opacity>(
                  find.descendant(of: btnFinder, matching: find.byType(Opacity)),
                );
                expect(opacity.opacity, 1.0, reason: '$btnKey should be clearly visible (not disabled) in $themeMode at $size');
              }
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
      'safe episode stills: <3 hides pill & does not play; >=3 plays slideshow labeled with season/episode every 3.2s at top 4.75rem',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Case A: < 3 safe stills -> no trailer pill.
        final hFew = _createHarness(
          data: _buildFixtureData(
            seriesSafeStills: [
              SafeEpisodeStill(image: _FakeArtworkRef('only_1'), seasonNumber: 1, episodeNumber: 1),
              SafeEpisodeStill(image: _FakeArtworkRef('only_2'), seasonNumber: 1, episodeNumber: 2),
            ],
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

        // Case B: >= 3 safe stills -> countdown & 3.2s slideshow with dynamic season/episode labels at top 4.75rem.
        final hMany = _createHarness(
          initialPrefs: const LocalPreferences(detailTrailerDelay: Duration(seconds: 8)),
          data: _buildFixtureData(
            seriesSafeStills: [
              SafeEpisodeStill(
                image: _FakeArtworkRef('safe_a'),
                seasonNumber: 2,
                episodeNumber: 1,
                seasonName: '第 2 季',
              ),
              SafeEpisodeStill(
                image: _FakeArtworkRef('safe_b'),
                episodeNumber: 4,
                seasonName: '季 3',
              ),
              SafeEpisodeStill(
                image: _FakeArtworkRef('safe_c'),
                episodeNumber: 7,
              ),
              SafeEpisodeStill(
                image: _FakeArtworkRef('safe_d'),
              ),
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

        final labelFinder = find.byKey(const Key('ev_detail_safe_still_label'));
        expect(labelFinder, findsOneWidget);
        final scale = EvScale.fromSize(const Size(1440, 900));
        final positioned = tester.widget<Positioned>(
          find.ancestor(of: labelFinder, matching: find.byType(Positioned)).first,
        );
        expect(positioned.top, closeTo(scale.rem(4.75), 0.01));
        expect(tester.getTopLeft(labelFinder).dy, closeTo(scale.rem(4.75), 0.5));
        expect(find.text('正片片段 · 第 2 季 第 1 集'), findsOneWidget);
        expect(find.text('正片片段 · 点此停止'), findsOneWidget);
        expect(hMany.stage.activeBackdropKey, contains('detail_test_safe_a'));

        await tester.pump(const Duration(milliseconds: 3200));
        expect(hMany.stage.activeBackdropKey, contains('detail_test_safe_b'));
        expect(find.text('正片片段 · 第 3 季 第 4 集'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 3200));
        expect(hMany.stage.activeBackdropKey, contains('detail_test_safe_c'));
        expect(find.text('正片片段 · 第 7 集'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 3200));
        expect(hMany.stage.activeBackdropKey, contains('detail_test_safe_d'));
        expect(find.text('正片片段'), findsOneWidget);

        // Tap again to stop and restore backdrop.
        await tester.tap(find.byKey(const Key('ev_detail_trailer_btn')));
        await tester.pump();
        expect(find.byKey(const Key('ev_detail_safe_still_label')), findsNothing);
        expect(hMany.stage.activeBackdropKey, contains('detail_test_bd_s1_0'));
      },
    );

    testWidgets(
      'series auto-selects first unwatched season, switches seasons, protects unwatched overview (0.6s reveal), and swaps stage backdrop on 100ms hover',
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
        // - before 100ms: rapid sweep does not switch backdrop yet
        // - at 100ms: stage switches to crisp episode still (veilLifted: true)
        // - by 400ms: top backdrop slot has faded in to 1.0, overview still hidden
        // - at 600ms: unwatched overview reveals!
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        final ep3Center = tester.getCenter(find.byKey(const Key('ev_episode_card_s2_e3')));
        await mouse.moveTo(ep3Center);
        await tester.pump(const Duration(milliseconds: 50));
        expect(h.stage.previewBackdrop, isNull);
        expect(h.stage.veilLifted, isFalse);

        await tester.pump(const Duration(milliseconds: 350));
        expect(h.stage.veilLifted, isTrue);
        expect(h.stage.previewBackdrop, isNotNull);
        expect(h.stage.activeBackdropKey, contains('detail_test_still_s2_e3'));
        expect(find.byKey(const Key('ev_episode_overview_s2_e3')), findsNothing);

        await tester.pump(const Duration(milliseconds: 220));
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

    testWidgets(
      'scrolled detail episode hover switches previewBackdrop onto top Stack slot with opacity 1.0 and soft 0.30 veil (blur 0) within 400ms in paper and cinema themes',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        for (final themeMode in const [ThemeMode.paper, ThemeMode.cinema]) {
          final h = _createHarness(
            initialPrefs: LocalPreferences(
              theme: themeMode,
              detailTrailerDelay: null,
              themeMusic: false,
            ),
          );
          // Pre-seed stage with a prior backdrop (like navigating from browse page)
          // so entering detail page puts series backdrop on slot 1, forcing first
          // episode hover to switch active slot 1 -> 0.
          h.stage.setBaseBackdrop(
            ArtworkPlan(
              layers: [ArtworkLayer(source: _FakeArtworkRef('prior_home'), fit: ArtworkFit.cover)],
              fallbackTitle: 'Home',
            ),
          );

          await tester.pumpWidget(
            _wrapDetail(
              h,
              child: const EvDetailPage(itemId: 's1', enableAnimations: false),
            ),
          );
          await tester.pumpAndSettle();

          // Scroll down past the full veil threshold (scrollProgress == 1.0) while keeping episode cards in view.
          final scroller = tester.widget<SingleChildScrollView>(
            find.byKey(const Key('ev_detail_scroller')),
          ).controller!;
          scroller.jumpTo(560);
          await tester.pumpAndSettle();
          expect(h.stage.scrollProgress, closeTo(1.0, 1e-6));

          if (themeMode == ThemeMode.paper) {
            final preVeil = tester.widget<ColoredBox>(find.byKey(const Key('ev_stage_veil_fill')));
            expect(preVeil.color.a, closeTo(0.64, 0.01));
            expect(
              find.descendant(
                of: find.byKey(const Key('ev_stage_veil')),
                matching: find.byType(BackdropFilter),
              ),
              findsOneWidget,
            );
          }

          final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: Offset.zero);

          Stack backdropStack() => tester.widget<Stack>(
            find.ancestor(
              of: find.byKey(const ValueKey<String>('ev_stage_slot_0')),
              matching: find.byType(Stack),
            ).first,
          );

          // Hover episode s2_e2 and advance exactly 400ms (100ms debounce + 300ms transition).
          await mouse.moveTo(tester.getCenter(find.byKey(const Key('ev_episode_card_s2_e2'))));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 300));

          expect(h.stage.previewBackdrop, isNotNull);
          expect(stageArtworkKey(h.stage.previewBackdrop), contains('detail_test_still_s2_e2'));
          expect(h.stage.veilLifted, isTrue);

          final topKey1 = backdropStack().children[1].key! as ValueKey<String>;
          final topSlot1 = find.byKey(topKey1);
          expect(
            find.descendant(
              of: topSlot1,
              matching: find.byKey(const ValueKey<String>('detail_test_still_s2_e2')),
            ),
            findsOneWidget,
            reason: 'New episode still must be on top Stack slot in $themeMode',
          );
          final topAnimOpacity1 = tester.widget<AnimatedOpacity>(
            find.descendant(of: topSlot1, matching: find.byType(AnimatedOpacity)),
          );
          final topFade1 = tester.widget<FadeTransition>(
            find.descendant(of: topSlot1, matching: find.byType(FadeTransition)),
          );
          expect(topAnimOpacity1.opacity, 1.0);
          expect(topFade1.opacity.value, 1.0);

          final veilFill = tester.widget<ColoredBox>(find.byKey(const Key('ev_stage_veil_fill')));
          expect(veilFill.color.a, closeTo(0.30, 0.01));
          final expectedBg = themeMode == ThemeMode.paper ? EvTheme.paper.bg : EvTheme.cinema.bg;
          expect(veilFill.color.toARGB32() & 0x00FFFFFF, expectedBg.toARGB32() & 0x00FFFFFF);
          expect(
            find.descendant(
              of: find.byKey(const Key('ev_stage_veil')),
              matching: find.byType(BackdropFilter),
            ),
            findsNothing,
          );

          // Hover a second episode s2_e3 (toggling slot again) and verify 400ms top-slot full opacity.
          await mouse.moveTo(tester.getCenter(find.byKey(const Key('ev_episode_card_s2_e3'))));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 300));

          expect(stageArtworkKey(h.stage.previewBackdrop), contains('detail_test_still_s2_e3'));
          final topKey2 = backdropStack().children[1].key! as ValueKey<String>;
          expect(topKey2, isNot(topKey1));
          final topSlot2 = find.byKey(topKey2);
          expect(
            find.descendant(
              of: topSlot2,
              matching: find.byKey(const ValueKey<String>('detail_test_still_s2_e3')),
            ),
            findsOneWidget,
          );
          expect(
            tester.widget<FadeTransition>(
              find.descendant(of: topSlot2, matching: find.byType(FadeTransition)),
            ).opacity.value,
            1.0,
          );

          // Clean up hover & timers before next iteration.
          await mouse.moveTo(const Offset(5, 5));
          await tester.pump(const Duration(milliseconds: 950));
          await tester.pumpAndSettle();
          await mouse.removePointer();
          await tester.pumpWidget(const SizedBox.shrink());
          await h.dispose();
        }
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

      // 2. More button removed; favorite & played action buttons are wired and clearly visible.
      expect(find.byKey(const Key('ev_detail_more_btn')), findsNothing);
      expect(find.byKey(const Key('ev_detail_favorite_btn')), findsOneWidget);
      expect(find.byKey(const Key('ev_detail_played_btn')), findsOneWidget);
      expect(
        tester.widget<Opacity>(
          find.descendant(of: find.byKey(const Key('ev_detail_favorite_btn')), matching: find.byType(Opacity)),
        ).opacity,
        1.0,
      );
      expect(
        tester.widget<Opacity>(
          find.descendant(of: find.byKey(const Key('ev_detail_played_btn')), matching: find.byType(Opacity)),
        ).opacity,
        1.0,
      );

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
      final stillsC = Completer<List<SafeEpisodeStill>>();
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

  group('Visual review: Favorite & Played action buttons, rollback, series refresh, and no more button', () {
    EvIcon buttonIcon(WidgetTester tester, Key key) =>
        tester.widget<EvIcon>(find.descendant(of: find.byKey(key), matching: find.byType(EvIcon)));

    Tooltip buttonTooltip(WidgetTester tester, Key key) =>
        tester.widget<Tooltip>(find.descendant(of: find.byKey(key), matching: find.byType(Tooltip)));

    testWidgets(
      'removes more button, toggles favorite icon/highlight with re-entry guard, and rolls back with error message on failure',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        Completer<void>? inFlight;
        var failNext = false;
        final movieCard = _makeCard(id: 'm_fav', title: '收藏测试电影', favorite: false, played: false);
        final data = _FakeDetailData(
          details: {'m_fav': MediaDetail(card: movieCard, playTarget: const PlayTarget(itemId: 'm_fav'))},
          onSetFavorite: (id, fav) async {
            final pending = inFlight;
            if (pending != null) return pending.future;
            if (failNext) throw const EmbyViewFailure('服务器拒绝写入');
          },
        );
        final h = _createHarness(
          initialPrefs: const LocalPreferences(detailTrailerDelay: null, themeMusic: false),
          data: data,
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapDetail(h, child: const EvDetailPage(itemId: 'm_fav', enableAnimations: false)));
        await tester.pumpAndSettle();

        const favKey = Key('ev_detail_favorite_btn');
        expect(find.byKey(const Key('ev_detail_more_btn')), findsNothing);
        expect(buttonIcon(tester, favKey).icon, EvIcons.plus);
        expect(buttonTooltip(tester, favKey).message, '加入片单');

        // Start in-flight write: optimistic switch to solid star, ignore second tap while busy.
        inFlight = Completer<void>();
        await tester.tap(find.byKey(favKey));
        await tester.pump();
        expect(buttonIcon(tester, favKey).icon, EvIcons.star);
        expect(buttonIcon(tester, favKey).icon.solid, isTrue);
        expect(buttonTooltip(tester, favKey).message, '已加入片单');
        expect(data.favoriteCalls, [('m_fav', true)]);

        await tester.tap(find.byKey(favKey));
        await tester.pump();
        expect(data.favoriteCalls.length, 1, reason: 'In-flight favorite request must ignore re-entrant taps');

        inFlight.complete();
        inFlight = null;
        await tester.pumpAndSettle();
        expect(buttonIcon(tester, favKey).icon, EvIcons.star);

        // Second tap unfavorites back to plus icon.
        await tester.tap(find.byKey(favKey));
        await tester.pumpAndSettle();
        expect(data.favoriteCalls, [('m_fav', true), ('m_fav', false)]);
        expect(buttonIcon(tester, favKey).icon, EvIcons.plus);
        expect(buttonTooltip(tester, favKey).message, '加入片单');

        // Write failure rolls back immediately and shows clear error banner, dismissible by user.
        failNext = true;
        await tester.tap(find.byKey(favKey));
        await tester.pumpAndSettle();
        expect(buttonIcon(tester, favKey).icon, EvIcons.plus);
        expect(buttonTooltip(tester, favKey).message, '加入片单');
        expect(find.byKey(const Key('ev_detail_action_error')), findsOneWidget);
        expect(find.textContaining('加入片单失败：服务器拒绝写入'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_detail_action_error_dismiss')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ev_detail_action_error')), findsNothing);
      },
    );

    testWidgets(
      'toggles played highlight on series targeting whole seriesId, refreshes episodes list, and rolls back on failure',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var seriesAllPlayed = false;
        var failNext = false;
        const sea1 = SeasonSummary(id: 'sea1', name: '第 1 季', number: 1, total: 2);
        SeasonEpisodes buildEps(bool allPlayed) => SeasonEpisodes(
          season: sea1,
          playedCount: allPlayed ? 2 : 1,
          episodes: [
            _makeEpisode(id: 'e1', seriesId: 's_play', seasonId: 'sea1', number: 1, title: '第一集', overview: '简介1', played: true),
            _makeEpisode(id: 'e2', seriesId: 's_play', seasonId: 'sea1', number: 2, title: '第二集', overview: '简介2', played: allPlayed),
          ],
        );

        final episodesMap = <String, SeasonEpisodes>{'s_play:sea1': buildEps(false)};
        final seriesCard = _makeCard(
          id: 's_play',
          title: '整剧已看测试',
          kind: MediaKind.series,
          childCount: 1,
          played: false,
          withLogo: false,
        );
        final data = _FakeDetailData(
          details: {'s_play': MediaDetail(card: seriesCard, episodeCount: 2)},
          seasonsBySeries: {'s_play': const [sea1]},
          episodesBySeason: episodesMap,
          onSetPlayed: (id, played) async {
            if (failNext) throw const EmbyViewFailure('网络异常');
            seriesAllPlayed = played;
            episodesMap['s_play:sea1'] = buildEps(seriesAllPlayed);
          },
        );
        final h = _createHarness(
          initialPrefs: const LocalPreferences(theme: ThemeMode.paper, detailTrailerDelay: null, themeMusic: false),
          data: data,
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapDetail(h, child: const EvDetailPage(itemId: 's_play', enableAnimations: false)));
        await tester.pumpAndSettle();

        const playedKey = Key('ev_detail_played_btn');
        expect(buttonTooltip(tester, playedKey).message, '标为已看');
        expect(find.text('1 / 2 已看'), findsOneWidget);
        expect(find.byKey(const Key('ev_episode_played_e2')), findsNothing);

        // Tap played -> calls setPlayed with seriesId, highlights button, refreshes episodes to 2 / 2 已看.
        await tester.tap(find.byKey(playedKey));
        await tester.pumpAndSettle();
        expect(data.playedCalls, [('s_play', true)]);
        expect(buttonTooltip(tester, playedKey).message, '已看');
        expect(find.text('2 / 2 已看'), findsOneWidget);
        expect(find.byKey(const Key('ev_episode_played_e2')), findsOneWidget);

        // Verify active highlight fill color on played button (terracotta brand color).
        final activeContainer = tester.widget<AnimatedContainer>(
          find.descendant(of: find.byKey(playedKey), matching: find.byType(AnimatedContainer)),
        );
        expect((activeContainer.decoration! as BoxDecoration).color, EvTheme.paper.brand);

        // Failing unmark rolls back to played == true and shows error message.
        failNext = true;
        await tester.tap(find.byKey(playedKey));
        await tester.pumpAndSettle();
        expect(buttonTooltip(tester, playedKey).message, '已看');
        expect(find.byKey(const Key('ev_detail_action_error')), findsOneWidget);
        expect(find.textContaining('取消已看失败：网络异常'), findsOneWidget);
      },
    );
  });

  group('Horizontal scroll rows: no system scrollbar & resting EvShelfScrollbar hidden', () {
    testWidgets(
      'detail page horizontal rows disable system scrollbars and keep EvShelfScrollbar hidden until hover or scroll',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final seriesCard = _makeCard(
          id: 's_scroll',
          title: '滚动条测试剧集',
          kind: MediaKind.series,
          childCount: 8,
          withLogo: false,
        );
        final seasons = [
          for (var i = 1; i <= 8; i++)
            SeasonSummary(id: 'sea_$i', name: '第 $i 季', number: i, total: 10),
        ];
        final episodes = SeasonEpisodes(
          season: seasons.first,
          playedCount: 2,
          episodes: [
            for (var i = 1; i <= 10; i++)
              _makeEpisode(
                id: 'ep_$i',
                seriesId: 's_scroll',
                seasonId: 'sea_1',
                number: i,
                title: '第 $i 集标题',
                overview: '第 $i 集简介内容。',
                played: i <= 2,
              ),
          ],
        );
        final similar = [
          for (var i = 1; i <= 12; i++)
            _makeCard(id: 'sim_$i', title: '相似推荐 $i', libraryId: 'movie', year: 2020 + (i % 5)),
        ];
        final people = [
          for (var i = 1; i <= 16; i++)
            PersonCredit(id: 'p_$i', name: '演职员 $i', role: i <= 2 ? 'Director' : 'Actor', character: '角色 $i'),
        ];

        final data = _FakeDetailData(
          details: {'s_scroll': MediaDetail(card: seriesCard, episodeCount: 80)},
          seasonsBySeries: {'s_scroll': seasons},
          episodesBySeason: {'s_scroll:sea_1': episodes},
          similarByItem: {'s_scroll': similar},
          peopleByItem: {'s_scroll': people},
        );
        final h = _createHarness(
          initialPrefs: const LocalPreferences(detailTrailerDelay: null, themeMusic: false),
          data: data,
        );
        addTearDown(h.dispose);

        await tester.pumpWidget(_wrapDetail(h, child: const EvDetailPage(itemId: 's_scroll', enableAnimations: false)));
        await tester.pumpAndSettle();

        // 1. No system Scrollbar or RawScrollbar anywhere on the detail page (even under macOS target platform).
        expect(find.byType(Scrollbar), findsNothing);
        expect(find.byType(RawScrollbar), findsNothing);

        // 2. All 4 horizontal SingleChildScrollViews (season tabs, episode track, similar shelf, people shelf)
        //    inherit a ScrollConfiguration with scrollbars disabled.
        final horizFinder = find.byWidgetPredicate(
          (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
        );
        expect(horizFinder, findsNWidgets(4));
        const sentinel = SizedBox.shrink();
        for (final el in tester.elementList(horizFinder)) {
          final built = ScrollConfiguration.of(el).buildScrollbar(
            el,
            sentinel,
            ScrollableDetails.horizontal(),
          );
          expect(identical(built, sentinel), isTrue);
        }

        // 3. All 3 overflowing horizontal tracks render EvShelfScrollbar with opacity 0.0 at rest.
        final episodesSection = find.byKey(const Key('ev_detail_episodes_section'));
        final similarShelf = find.byKey(const Key('ev_detail_similar_shelf'));
        final peopleShelf = find.byKey(const Key('ev_detail_people_shelf'));
        AnimatedOpacity opacityIn(Finder container) {
          final f = find.descendant(
            of: container,
            matching: find.byKey(const ValueKey('ev_shelf_scrollbar_opacity')),
          );
          expect(f, findsOneWidget);
          return tester.widget<AnimatedOpacity>(f);
        }

        expect(opacityIn(episodesSection).opacity, 0.0);
        expect(opacityIn(similarShelf).opacity, 0.0);
        expect(opacityIn(peopleShelf).opacity, 0.0);

        // 4. Horizontal scroll on episodes track reveals scrollbar transiently, then hides after idle timeout.
        final epTrack = tester.widget<SingleChildScrollView>(find.byKey(const Key('ev_detail_episodes_track')));
        epTrack.controller!.jumpTo(120);
        await tester.pump();
        expect(opacityIn(episodesSection).opacity, 1.0);
        await tester.pump(const Duration(milliseconds: 950));
        await tester.pumpAndSettle();
        expect(opacityIn(episodesSection).opacity, 0.0);

        // 5. Hover reveals scrollbar for episodes, similar, and people shelves; unhover hides again.
        final scroller = tester.widget<SingleChildScrollView>(find.byKey(const Key('ev_detail_scroller'))).controller!;
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(-10, -10));
        addTearDown(mouse.removePointer);

        Future<void> verifyHoverToggle(Finder sectionFinder) async {
          await tester.ensureVisible(sectionFinder);
          await tester.pumpAndSettle();
          expect(opacityIn(sectionFinder).opacity, 0.0);

          await mouse.moveTo(tester.getCenter(sectionFinder));
          await tester.pumpAndSettle();
          expect(opacityIn(sectionFinder).opacity, 1.0);

          await mouse.moveTo(const Offset(-10, -10));
          await tester.pumpAndSettle();
          // Wait out episode hover delay timer if triggered on episodes section.
          await tester.pump(const Duration(milliseconds: 950));
          await tester.pumpAndSettle();
          expect(opacityIn(sectionFinder).opacity, 0.0);
        }

        await verifyHoverToggle(episodesSection);
        await verifyHoverToggle(similarShelf);
        scroller.jumpTo(scroller.position.maxScrollExtent);
        await tester.pumpAndSettle();
        await verifyHoverToggle(peopleShelf);
      },
    );
  });
}
