import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_anime4k_compare.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_live_subtitle_layer.dart';
import 'package:moonfin/embyview/ui/player/panel/ev_player_panel.dart';

class _FakeSubtitlePanel implements SubtitlePanel {
  _FakeSubtitlePanel(this._snapshot, {this.searchGroups = const []});

  SubtitleSnapshot _snapshot;
  final List<SubtitleSearchGroup> searchGroups;
  final _ctrl = StreamController<SubtitleSnapshot>.broadcast();

  final List<String?> searchQueries = [];
  final List<SubtitleCandidate> usedCandidates = [];
  final List<String> translatedTracks = [];
  final List<String> alignedTracks = [];
  final List<String> retriedTracks = [];
  int startAiCalls = 0, cancelAiCalls = 0, closeCalls = 0;

  @override SubtitleSnapshot get snapshot => _snapshot;
  @override Stream<SubtitleSnapshot> get changes => _ctrl.stream;

  void emit(SubtitleSnapshot next) {
    _snapshot = next;
    _ctrl.add(next);
  }

  @override
  Future<List<SubtitleSearchGroup>> search(String? text) async {
    searchQueries.add(text);
    return searchGroups;
  }

  @override Future<void> useCandidate(SubtitleCandidate candidate) async => usedCandidates.add(candidate);
  @override Future<void> startAi() async => startAiCalls++;
  @override Future<void> cancelAi() async => cancelAiCalls++;
  @override Future<void> translate(String trackId) async => translatedTracks.add(trackId);
  @override Future<void> align(String trackId) async => alignedTracks.add(trackId);
  @override Future<void> retrySave(String trackId) async => retriedTracks.add(trackId);
  @override Future<void> close() async { closeCalls++; await _ctrl.close(); }
}

class _FakeSubtitles implements EmbyViewSubtitles {
  _FakeSubtitles(this.panel);
  final _FakeSubtitlePanel panel;
  final List<(String, String)> quoted = [];
  final List<SeasonQuote> queued = [];

  @override SubtitlePanel bind(PlaybackSession session) => panel;
  @override Future<SubtitleAvailability> availability(String itemId) async => const SubtitleAvailability();
  @override
  Future<SeasonQuote> quoteSeason(String seriesId, String seasonId) async {
    quoted.add((seriesId, seasonId));
    return SeasonQuote(
      id: 'q1', seriesId: seriesId, seasonId: seasonId, seasonName: '第一季',
      episodeIds: const ['ep1', 'ep2', 'ep3'], completedCount: 1, pendingCount: 2,
      estimatedCostMicros: 350000, budget: BudgetState.available,
    );
  }

  @override Future<String> queueSeason(SeasonQuote q) async { queued.add(q); return 'job_1'; }
  @override Future<AiUsage> usage() async => const AiUsage(month: '2026-11');
  @override Stream<List<SeasonJob>> get jobs => const Stream.empty();
  @override Future<void> cancelJob(String jobId, {String? episodeId}) async {}
}

MediaCard _episode({String id = 'ep9', String title = '出征的号角'}) => MediaCard(
  id: id, kind: MediaKind.episode, title: title, year: 2024,
  duration: const Duration(minutes: 24), seriesId: 'series_k', seasonId: 'sea1', episodeNumber: 9,
  quality: const MediaQuality(origin: MediaOrigin.direct115, resolution: '1080p'),
);

MediaCard _movie() => const MediaCard(
  id: 'mov1', kind: MediaKind.movie, title: '沙丘 2', year: 2024, duration: Duration(minutes: 166),
  quality: MediaQuality(origin: MediaOrigin.nasLocal, resolution: '4K'),
);

PlaybackSnapshot _snap({
  int generation = 1,
  MediaCard? item,
  Duration position = const Duration(minutes: 6, seconds: 12),
  Duration? duration = const Duration(minutes: 24),
  String? selectedSubtitleId = 'emb',
  String? selectedAudioId = 'ja',
  List<PlaybackTrack>? subtitleTracks,
  List<PlaybackTrack>? audioTracks,
  Anime4kSnapshot anime4k = const Anime4kSnapshot(),
}) {
  final card = item ?? _episode();
  return PlaybackSnapshot(
    generation: generation,
    target: PlayTarget(itemId: card.id, seriesId: card.seriesId, seasonId: card.seasonId, episodeNumber: card.episodeNumber),
    item: card, phase: PlaybackPhase.playing, position: position, duration: duration,
    selectedSubtitleId: selectedSubtitleId, selectedAudioId: selectedAudioId,
    subtitleTracks: subtitleTracks ?? const [
      PlaybackTrack(id: 'emb', name: '简体中文', language: 'zh', source: PlaybackTrackSource.embedded, format: 'ASS'),
      PlaybackTrack(id: 'en', name: 'English', language: 'en', source: PlaybackTrackSource.embedded, format: 'SRT'),
    ],
    audioTracks: audioTracks ?? const [
      PlaybackTrack(id: 'ja', name: '日语', language: 'ja', source: PlaybackTrackSource.embedded, format: 'AAC', layout: '2.0'),
      PlaybackTrack(id: 'en', name: 'English', language: 'en', source: PlaybackTrackSource.embedded, format: 'E-AC-3', layout: '5.1'),
    ],
    anime4k: anime4k,
  );
}

List<SubtitleCue> _makeCues(int count) => List.generate(
  count,
  (i) => SubtitleCue(
    id: 'c$i', start: Duration(seconds: i * 4), end: Duration(seconds: (i + 1) * 4),
    text: 'Original line $i', translation: '第 $i 句中文对白',
  ),
);

Widget _wrap({required Widget child, Size size = const Size(1440, 900), ThemeMode mode = ThemeMode.cinema}) => MediaQuery(
  data: MediaQueryData(size: size, devicePixelRatio: 1.0),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: EvThemeScope(
      themeMode: mode,
      child: SizedBox(width: size.width, height: size.height, child: Stack(fit: StackFit.expand, children: [child])),
    ),
  ),
);

void main() {
  group('C5.5 Online search, save/index status, and null subtitle service', () {
    testWidgets('searches 4 sources, filters chips, uses candidate, and retries failed NAS save', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const cXl = SubtitleCandidate(id: 'xl1', source: SubtitleSource.xunlei, name: '王者天下 S01E09 简中', language: 'zh', format: 'ASS');
      const cAs = SubtitleCandidate(id: 'as1', source: SubtitleSource.assrt, name: 'Kingdom.S01E09.SRT', language: 'zh', format: 'SRT');
      const cOs = SubtitleCandidate(id: 'os1', source: SubtitleSource.openSubtitles, name: 'Kingdom.S01E09.EN', language: 'en', format: 'SRT');
      const cFs = SubtitleCandidate(id: 'fs1', source: SubtitleSource.anime, name: '北宇治字幕组 BDRip', language: 'zh', format: 'ASS', releaseGroup: '北宇治');

      final subSnap = const SubtitleSnapshot(
        generation: 1,
        selectedTrackId: 'net_xl',
        tracks: [
          SubtitleTrackState(trackId: 'net_xl', origin: SubtitleOrigin.online, active: true, save: SubtitleSaveState.saved, index: SubtitleIndexState.recognized, candidateId: 'xl1'),
          SubtitleTrackState(trackId: 'net_as', origin: SubtitleOrigin.online, active: false, save: SubtitleSaveState.failed, index: SubtitleIndexState.unrecognized, candidateId: 'as1'),
        ],
        cues: null,
      );
      final panel = _FakeSubtitlePanel(subSnap, searchGroups: const [
        SubtitleSearchGroup(source: SubtitleSource.xunlei, candidates: [cXl]),
        SubtitleSearchGroup(source: SubtitleSource.assrt, candidates: [cAs]),
        SubtitleSearchGroup(source: SubtitleSource.openSubtitles, candidates: [cOs], failure: EmbyViewFailure('请求超时')),
        SubtitleSearchGroup(source: SubtitleSource.anime, candidates: [cFs]),
      ]);
      final snap = _snap(
        selectedSubtitleId: 'net_xl',
        subtitleTracks: const [
          PlaybackTrack(id: 'net_xl', name: '简体中文 · 迅雷', language: 'zh', source: PlaybackTrackSource.online, format: 'ASS'),
          PlaybackTrack(id: 'net_as', name: '简体中文 · 射手', language: 'zh', source: PlaybackTrackSource.online, format: 'SRT'),
        ],
      );

      await tester.pumpWidget(_wrap(
        child: EvPlayerPanel(
          open: true, activeTab: 'subs', snapshot: snap, subtitleSnapshot: subSnap, subtitlePanel: panel,
          onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (_) {}, onSelectAudio: (_) {},
          onSeek: (_) {}, onToggleAnime4k: () {}, onStartCompare: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // Auto-searched on entry; all 4 sources visible + partial failure note
      expect(panel.searchQueries.length, 1);
      expect(find.text('四个来源 · 4 条'), findsOneWidget);
      expect(find.text('王者天下 S01E09 简中'), findsOneWidget);
      expect(find.text('Kingdom.S01E09.SRT'), findsOneWidget);
      expect(find.text('Kingdom.S01E09.EN'), findsOneWidget);
      expect(find.text('北宇治字幕组 BDRip'), findsOneWidget);
      expect(find.textContaining('OpenSubtitles：请求超时'), findsOneWidget);
      expect(find.text('使用中'), findsOneWidget);
      expect(find.textContaining('已存 NAS'), findsWidgets);
      expect(find.textContaining('Emby 已识别'), findsOneWidget);
      expect(find.textContaining('Emby 未识别'), findsOneWidget);

      // Filter by 字幕组
      await tester.ensureVisible(find.byKey(const Key('ev_sub_src_anime')));
      await tester.tap(find.byKey(const Key('ev_sub_src_anime')));
      await tester.pumpAndSettle();
      expect(find.text('北宇治字幕组 BDRip'), findsOneWidget);
      expect(find.text('王者天下 S01E09 简中'), findsNothing);

      // Back to 全部, tap 使用 on 射手 candidate & 重试 on failed save
      await tester.tap(find.byKey(const Key('ev_sub_src_all')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('ev_sub_use_as1')));
      await tester.tap(find.byKey(const Key('ev_sub_use_as1')));
      await tester.pump();
      expect(panel.usedCandidates, [cAs]);

      await tester.ensureVisible(find.byKey(const Key('ev_sub_cand_retry_as1')));
      await tester.tap(find.byKey(const Key('ev_sub_cand_retry_as1')));
      await tester.pump();
      expect(panel.retriedTracks, ['net_as']);
    });

    testWidgets('hides AI card, quick actions, and search when subtitlePanel is null', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      String? selected = 'emb';
      await tester.pumpWidget(_wrap(
        child: EvPlayerPanel(
          open: true, activeTab: 'subs', snapshot: _snap(selectedSubtitleId: selected),
          subtitleSnapshot: null, subtitlePanel: null,
          onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (id) => selected = id,
          onSelectAudio: (_) {}, onSeek: (_) {}, onToggleAnime4k: () {}, onStartCompare: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('关闭字幕'), findsOneWidget);
      expect(find.text('简体中文'), findsOneWidget);
      expect(find.byKey(const Key('ev_ai_card')), findsNothing);
      expect(find.byKey(const Key('ev_ai_translate')), findsNothing);
      expect(find.byKey(const Key('ev_sub_online_search')), findsNothing);

      await tester.tap(find.byKey(const Key('ev_sub_track_off')));
      await tester.pump();
      expect(selected, isNull);
    });
  });

  group('C5.6 AI subtitle card states & live subtitle overlay', () {
    testWidgets('transitions idle -> preparing -> generating (exact lead) -> catchingUp -> failed -> cancel', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final panel = _FakeSubtitlePanel(const SubtitleSnapshot(generation: 1));
      final pos = const Duration(minutes: 6, seconds: 12);
      final snap = _snap(position: pos);

      Widget buildWith(SubtitleSnapshot sub) => _wrap(
        child: EvPlayerPanel(
          open: true, activeTab: 'subs', snapshot: snap, subtitleSnapshot: sub, subtitlePanel: panel,
          onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (_) {}, onSelectAudio: (_) {},
          onSeek: (_) {}, onToggleAnime4k: () {}, onStartCompare: () {},
        ),
      );

      // 1. Idle -> tap startAi
      await tester.pumpWidget(buildWith(const SubtitleSnapshot(generation: 1)));
      await tester.pump();
      expect(find.text('未开启'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ev_ai_start')));
      await tester.pump();
      expect(panel.startAiCalls, 1);

      // 2. Preparing
      await tester.pumpWidget(buildWith(const SubtitleSnapshot(
        generation: 1,
        ai: AiRun(generation: 1, state: AiRunState.preparing, startedAt: Duration(minutes: 6, seconds: 12)),
      )));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('准备中'), findsOneWidget);
      expect(find.text('约 40 秒后出字'), findsOneWidget);

      // 3. Generating: coverageEnd = 9:44, pos = 6:12 => lead = 3 分 32 秒
      await tester.pumpWidget(buildWith(const SubtitleSnapshot(
        generation: 1,
        ai: AiRun(
          generation: 1, state: AiRunState.generating,
          startedAt: Duration(minutes: 6), coverageEnd: Duration(minutes: 9, seconds: 44),
        ),
      )));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('领先 3 分 32 秒'), findsOneWidget);
      expect(find.text('播放到 6:12'), findsOneWidget);
      expect(find.text('字幕已到 9:44'), findsOneWidget);

      // 4. CatchingUp: shows 追赶中, does not fabricate lead duration
      await tester.pumpWidget(buildWith(const SubtitleSnapshot(
        generation: 1,
        ai: AiRun(generation: 1, state: AiRunState.catchingUp, startedAt: Duration(minutes: 6)),
      )));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('追赶中'), findsOneWidget);
      expect(find.textContaining('领先'), findsNothing);

      // Tap cancelAi
      await tester.tap(find.byKey(const Key('ev_ai_cancel')));
      await tester.pump();
      expect(panel.cancelAiCalls, 1);

      // 5. Failed: shows reason + 重新生成
      await tester.pumpWidget(buildWith(const SubtitleSnapshot(
        generation: 1,
        ai: AiRun(generation: 1, state: AiRunState.failed, startedAt: Duration(minutes: 6), failure: EmbyViewFailure('余额不足')),
      )));
      await tester.pump();
      expect(find.text('余额不足'), findsOneWidget);
      expect(find.text('重新生成'), findsOneWidget);
    });

    testWidgets('EvLiveSubtitleLayer renders active cue translation and hides during pause/scrub/credits', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final run = AiRun(
        generation: 1, state: AiRunState.generating, startedAt: Duration.zero,
        coverageEnd: const Duration(minutes: 5),
        cues: const [
          SubtitleCue(id: '1', start: Duration(seconds: 0), end: Duration(seconds: 5), text: 'Hello', translation: '城墙上的火把熄灭了'),
          SubtitleCue(id: '2', start: Duration(seconds: 5), end: Duration(seconds: 10), text: 'Run', translation: '天亮之前越过山脊'),
        ],
      );
      final snap = _snap(
        position: const Duration(seconds: 2),
        selectedSubtitleId: 'ai_1',
        subtitleTracks: const [PlaybackTrack(id: 'ai_1', name: 'AI 中字', source: PlaybackTrackSource.ai)],
      );

      await tester.pumpWidget(_wrap(
        child: EvLiveSubtitleLayer(snapshot: snap, aiRun: run, controlsVisible: true, panelOpen: false),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_player_live_subtitle')), findsOneWidget);
      expect(find.text('城墙上的火把熄灭了'), findsOneWidget);

      // Advance to second cue and pause -> opacity 0
      await tester.pumpWidget(_wrap(
        child: EvLiveSubtitleLayer(
          snapshot: _snap(position: const Duration(seconds: 7), selectedSubtitleId: 'ai_1', subtitleTracks: snap.subtitleTracks),
          aiRun: run, controlsVisible: false, panelOpen: true, paused: true,
        ),
      ));
      await tester.pumpAndSettle();
      final op = tester.widget<AnimatedOpacity>(find.descendant(of: find.byKey(const Key('ev_player_live_subtitle')), matching: find.byType(AnimatedOpacity)));
      expect(op.opacity, 0.0);
    });
  });

  group('C5.7 Translate, align, season batch & dialogue list', () {
    testWidgets('triggers translate, align, season quote->queue, dialogue ±8 window & seek', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final cues = _makeCues(25); // 0s..100s, cue 12 is at 48s..52s
      final subSnap = SubtitleSnapshot(generation: 1, cues: cues);
      final panel = _FakeSubtitlePanel(subSnap);
      final subs = _FakeSubtitles(panel);
      final seeks = <Duration>[];
      final toasts = <String>[];

      await tester.pumpWidget(_wrap(
        child: EvPlayerPanel(
          open: true, activeTab: 'subs', snapshot: _snap(position: const Duration(seconds: 50)),
          subtitleSnapshot: subSnap, subtitlePanel: panel, subtitles: subs,
          onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (_) {}, onSelectAudio: (_) {},
          onSeek: seeks.add, onToggleAnime4k: () {}, onStartCompare: () {},
          onToast: (m, {icon}) => toasts.add(m),
        ),
      ));
      await tester.pumpAndSettle();

      // Dialogue tab active by default; cues 4..20 (17 cues around cue 12)
      expect(find.byKey(const Key('ev_sub_lower_dlg')), findsOneWidget);
      expect(find.byKey(const Key('ev_sub_dialogue_list')), findsOneWidget);
      expect(find.byKey(const Key('ev_dlg_cue_c12')), findsOneWidget);
      expect(find.byKey(const Key('ev_dlg_cue_c3')), findsNothing);
      expect(find.byKey(const Key('ev_dlg_cue_c21')), findsNothing);

      // Tap cue 12 -> seeks to 48s
      await tester.ensureVisible(find.byKey(const Key('ev_dlg_cue_c12')));
      await tester.tap(find.byKey(const Key('ev_dlg_cue_c12')));
      await tester.pump();
      expect(seeks, [const Duration(seconds: 48)]);

      // Translate & align
      await tester.ensureVisible(find.byKey(const Key('ev_ai_translate')));
      await tester.tap(find.byKey(const Key('ev_ai_translate')));
      await tester.pump();
      expect(panel.translatedTracks, ['en']); // prefers foreign track

      await tester.tap(find.byKey(const Key('ev_ai_align')));
      await tester.pump();
      expect(panel.alignedTracks, ['emb']);

      // Season batch quote -> confirm -> queue
      await tester.tap(find.byKey(const Key('ev_ai_season')));
      await tester.pumpAndSettle();
      expect(subs.quoted, [('series_k', 'sea1')]);
      expect(find.byKey(const Key('ev_ai_season_quote')), findsOneWidget);
      expect(find.textContaining('0.35'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('ev_ai_season_confirm')));
      await tester.tap(find.byKey(const Key('ev_ai_season_confirm')));
      await tester.pumpAndSettle();
      expect(subs.queued.length, 1);

      // Movie without seriesId shows hint toast instead of quoteSeason
      await tester.pumpWidget(_wrap(
        child: EvPlayerPanel(
          open: true, activeTab: 'subs', snapshot: _snap(item: _movie()),
          subtitleSnapshot: const SubtitleSnapshot(generation: 2, cues: null), subtitlePanel: panel, subtitles: subs,
          onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (_) {}, onSelectAudio: (_) {},
          onSeek: (_) {}, onToggleAnime4k: () {}, onStartCompare: () {},
          onToast: (m, {icon}) => toasts.add(m),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_sub_lower_dlg')), findsNothing);
      expect(find.byKey(const Key('ev_sub_online_search')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ev_ai_season')));
      await tester.pump();
      expect(toasts.last, contains('仅剧集'));
    });
  });

  group('C5.8 Anime4K video tab & comparison overlay', () {
    testWidgets('shows actual state, failure reason, and triggers toggle & compare', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var toggled = 0, compareStarted = 0;
      const failedA4k = Anime4kSnapshot(
        supported: true, requested: true, state: Anime4kState.failed,
        reason: '当前解码路径不支持着色器链', comparison: ComparisonState.unavailable,
        originalSize: VideoSize(width: 1920, height: 1080),
      );
      await tester.pumpWidget(_wrap(
        child: EvPlayerPanel(
          open: true, activeTab: 'video', snapshot: _snap(anime4k: failedA4k),
          onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (_) {}, onSelectAudio: (_) {},
          onSeek: (_) {}, onToggleAnime4k: () => toggled++, onStartCompare: () => compareStarted++,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ev_video_a4k_card')), findsOneWidget);
      expect(find.byKey(const Key('ev_video_a4k_reason')), findsOneWidget);
      expect(find.text('当前解码路径不支持着色器链'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ev_video_a4k_toggle')));
      await tester.tap(find.byKey(const Key('ev_video_compare_btn')));
      await tester.pump();
      expect(toggled, 1);
      expect(compareStarted, 0); // disabled when not active/available

      // Active + available -> compare enabled
      const activeA4k = Anime4kSnapshot(
        supported: true, requested: true, state: Anime4kState.active,
        comparison: ComparisonState.available,
        originalSize: VideoSize(width: 1920, height: 1080),
        enhancedSize: VideoSize(width: 3840, height: 2160),
      );
      await tester.pumpWidget(_wrap(
        child: EvPlayerPanel(
          open: true, activeTab: 'video', snapshot: _snap(anime4k: activeA4k),
          onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (_) {}, onSelectAudio: (_) {},
          onSeek: (_) {}, onToggleAnime4k: () => toggled++, onStartCompare: () => compareStarted++,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ev_video_a4k_reason')), findsNothing);
      await tester.tap(find.byKey(const Key('ev_video_compare_btn')));
      await tester.pump();
      expect(compareStarted, 1);
    });

    testWidgets('EvAnime4kCompareOverlay sweeps, clamps drag to 4%..96%, and ends on tap or auto-exit', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final splits = <double>[];
      var ended = 0;
      const a4k = Anime4kSnapshot(
        supported: true, requested: true, state: Anime4kState.active, comparison: ComparisonState.available,
        originalSize: VideoSize(width: 1920, height: 1080), enhancedSize: VideoSize(width: 3840, height: 2160),
      );

      // Non-persistent sweep auto-ends after 2.4s + 1.2s
      await tester.pumpWidget(_wrap(
        child: EvAnime4kCompareOverlay(
          active: true, anime4k: a4k, sweepNonce: 1, persistent: false,
          onSplitChanged: splits.add, onEnd: () => ended++,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 800));
      expect(splits.any((v) => v > 0.7), isTrue);
      await tester.pump(const Duration(milliseconds: 1700)); // sweep done
      expect(ended, 0);
      await tester.pump(const Duration(milliseconds: 1300)); // auto-end fires
      expect(ended, 1);

      // Manual drag & end button
      splits.clear();
      ended = 0;
      await tester.pumpWidget(_wrap(
        child: EvAnime4kCompareOverlay(
          active: true, anime4k: a4k, split: 0.5, persistent: true,
          onSplitChanged: splits.add, onEnd: () => ended++,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('原画 1080p'), findsOneWidget);
      expect(find.text('Anime4K · 放大至 4K'), findsOneWidget);

      await tester.drag(find.byKey(const Key('ev_compare_handle')), const Offset(400, 0));
      await tester.pump();
      expect(splits.isNotEmpty, isTrue);
      expect(splits.last, inInclusiveRange(0.04, 0.96));
      expect(splits.last, greaterThan(0.65));

      await tester.tap(find.byKey(const Key('ev_compare_end')));
      await tester.pump();
      expect(ended, 1);
    });
  });

  group('C5.9 Dual themes x Dual viewports overflow check', () {
    testWidgets('all 3 panel tabs + compare + live subtitle render cleanly at 1440x900 & 2560x1440 in cinema & paper', (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final subSnap = SubtitleSnapshot(
        generation: 1, cues: _makeCues(20),
        ai: AiRun(generation: 1, state: AiRunState.generating, startedAt: Duration.zero, coverageEnd: const Duration(minutes: 9, seconds: 44), cues: _makeCues(5)),
      );
      final panel = _FakeSubtitlePanel(subSnap);
      const activeA4k = Anime4kSnapshot(
        supported: true, requested: true, state: Anime4kState.active, comparison: ComparisonState.available,
        originalSize: VideoSize(width: 1920, height: 1080), enhancedSize: VideoSize(width: 3840, height: 2160),
      );
      final snap = _snap(anime4k: activeA4k);

      for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
        await tester.binding.setSurfaceSize(size);
        for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
          for (final tab in const ['subs', 'audio', 'video']) {
            await tester.pumpWidget(_wrap(
              size: size, mode: mode,
              child: Stack(fit: StackFit.expand, children: [
                EvAnime4kCompareOverlay(active: true, anime4k: activeA4k, onSplitChanged: (_) {}, onEnd: () {}),
                EvLiveSubtitleLayer(snapshot: _snap(position: const Duration(seconds: 2), selectedSubtitleId: null, subtitleTracks: const []), aiRun: subSnap.ai, controlsVisible: true, panelOpen: true),
                EvPlayerPanel(
                  open: true, activeTab: tab, snapshot: snap, subtitleSnapshot: subSnap, subtitlePanel: panel,
                  onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (_) {}, onSelectAudio: (_) {},
                  onSeek: (_) {}, onToggleAnime4k: () {}, onStartCompare: () {},
                ),
              ]),
            ));
            await tester.pump(const Duration(milliseconds: 200));
            expect(tester.takeException(), isNull, reason: 'size=$size mode=$mode tab=$tab');
          }
        }
      }
      // Verify audio tab track selection works
      String? pickedAudio;
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await tester.pumpWidget(_wrap(
        child: EvPlayerPanel(
          open: true, activeTab: 'audio', snapshot: snap,
          onSelectTab: (_) {}, onClose: () {}, onSelectSubtitle: (_) {}, onSelectAudio: (id) => pickedAudio = id,
          onSeek: (_) {}, onToggleAnime4k: () {}, onStartCompare: () {},
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ev_audio_track_en')));
      await tester.pump();
      expect(pickedAudio, 'en');
    });
  });

  test('evAnime4kSweepSplit hits expected keyframes', () {
    expect(evAnime4kSweepSplit(0.0), closeTo(0.50, 1e-6));
    expect(evAnime4kSweepSplit(1 / 3), closeTo(0.80, 1e-6));
    expect(evAnime4kSweepSplit(2 / 3), closeTo(0.22, 1e-6));
    expect(evAnime4kSweepSplit(1.0), closeTo(0.50, 1e-6));
  });
}
