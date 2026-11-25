import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_controls.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_format.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_scrub_bar.dart';
import 'package:moonfin/embyview/ui/player/open/ev_player_opening.dart';

// 1x1 valid PNG pixel for offline widget tests.
final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _TestArtworkRef implements ArtworkRef {
  _TestArtworkRef(this.id) : image = MemoryImage(_kPngBytes);

  @override
  final String id;

  @override
  String get cacheKey => 'player_test_$id';

  @override
  final ImageProvider<Object> image;

  @override
  double? get aspectRatio => 16 / 9;

  @override
  int? get width => 1;

  @override
  int? get height => 1;
}

CardArtwork _sampleArt({bool withLogo = true}) => CardArtwork(
  stage: ArtworkPlan(
    layers: [ArtworkLayer(source: _TestArtworkRef('stage'))],
    fallbackTitle: '王者天下',
  ),
  logo: withLogo ? _TestArtworkRef('logo') : null,
);

MediaCard _sampleEpisode({
  String id = 'ep9',
  String title = '出征的号角',
  String? seasonId = 'sea1',
  int? episodeNumber = 9,
  MediaOrigin origin = MediaOrigin.direct115,
  bool withLogo = true,
}) => MediaCard(
  id: id,
  kind: MediaKind.episode,
  title: title,
  year: 2024,
  duration: const Duration(minutes: 24),
  seriesId: 'series_kingdom',
  seasonId: seasonId,
  episodeNumber: episodeNumber,
  quality: MediaQuality(
    origin: origin,
    resolution: '1080p',
    videoRange: 'SDR',
    audioLabel: '日语 AAC',
  ),
  art: _sampleArt(withLogo: withLogo),
);

MediaCard _sampleMovie({MediaOrigin origin = MediaOrigin.nasLocal}) =>
    MediaCard(
      id: 'mov1',
      kind: MediaKind.movie,
      title: '沙丘 2',
      year: 2024,
      duration: const Duration(minutes: 166),
      quality: MediaQuality(
        origin: origin,
        resolution: '4K',
        videoRange: 'Dolby Vision',
        audioLabel: 'Atmos',
      ),
      art: _sampleArt(),
    );

PlaybackSnapshot _sampleSnapshot({
  int generation = 1,
  PlaybackPhase phase = PlaybackPhase.playing,
  MediaCard? item,
  Duration position = const Duration(minutes: 6, seconds: 12),
  Duration? duration = const Duration(minutes: 24),
  Duration bufferedUntil = const Duration(minutes: 13),
  Duration? firstFrameLatency,
  MediaQuality? quality,
  List<ChapterMark> chapters = const [
    ChapterMark(start: Duration(minutes: 2), name: '片头曲'),
    ChapterMark(start: Duration(minutes: 8), name: '城墙夜战'),
    ChapterMark(start: Duration(minutes: 18), name: '反击时刻'),
  ],
  MediaCard? nextEpisode,
  double volume = 0.7,
  bool muted = false,
  bool pip = false,
  bool fullscreen = false,
  Anime4kSnapshot anime4k = const Anime4kSnapshot(),
  EmbyViewFailure? failure,
}) {
  final card = item ?? _sampleEpisode();
  return PlaybackSnapshot(
    generation: generation,
    target: PlayTarget(
      itemId: card.id,
      seriesId: card.seriesId,
      seasonId: card.seasonId,
      episodeNumber: card.episodeNumber,
    ),
    item: card,
    phase: phase,
    firstFrameLatency: firstFrameLatency,
    position: position,
    duration: duration,
    bufferedUntil: bufferedUntil,
    quality: quality ?? card.quality,
    chapters: chapters,
    nextEpisode: nextEpisode,
    volume: volume,
    muted: muted,
    pictureInPicture: pip,
    fullscreen: fullscreen,
    anime4k: anime4k,
    failure: failure,
  );
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Widget _harness({
  required Widget child,
  Size size = const Size(1440, 900),
  ThemeMode mode = ThemeMode.cinema,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size, devicePixelRatio: 1.0),
      child: EvThemeScope(
        themeMode: mode,
        child: Scaffold(
          backgroundColor: const Color(0xFF000000),
          body: SizedBox(width: size.width, height: size.height, child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('ev_player_format', () {
    test('formats playback timestamps, clock times, and lead durations', () {
      expect(evFormatPlayerTime(const Duration(seconds: -5)), '0:00');
      expect(evFormatPlayerTime(Duration.zero), '0:00');
      expect(evFormatPlayerTime(const Duration(seconds: 9)), '0:09');
      expect(
        evFormatPlayerTime(const Duration(minutes: 12, seconds: 5)),
        '12:05',
      );
      expect(
        evFormatPlayerTime(const Duration(hours: 1, minutes: 3, seconds: 7)),
        '1:03:07',
      );

      expect(evFormatClockTime(DateTime(2026, 11, 25, 21, 42)), '21:42');
      expect(evFormatClockTime(DateTime(2026, 11, 25, 9, 5)), '9:05');

      expect(
        evFormatLeadDuration(const Duration(minutes: 3, seconds: 32)),
        '3 分 32 秒',
      );
      expect(evFormatLeadDuration(const Duration(seconds: 45)), '45 秒');
      expect(evFormatLeadDuration(const Duration(minutes: 2)), '2 分');
      expect(evFormatLeadDuration(const Duration(seconds: -3)), '0 秒');
    });

    test('formats remaining lines, tech summary, and episode/movie meta', () {
      final now = DateTime(2026, 11, 25, 21, 0);
      expect(
        evFormatRemainingLine(const Duration(minutes: 17, seconds: 48), now),
        '-17:48 · 21:17 结束',
      );
      expect(
        evFormatPauseRemainingLine(
          const Duration(minutes: 17, seconds: 1),
          now,
        ),
        '剩 18 分钟 · 21:17 结束',
      );
      expect(
        evFormatPauseRemainingLine(Duration.zero, now),
        '剩 0 分钟 · 21:00 结束',
      );

      expect(
        evPlayerTechSummary(
          const MediaQuality(
            origin: MediaOrigin.nasLocal,
            resolution: '4K',
            videoRange: 'Dolby Vision',
            audioLabel: 'Atmos',
          ),
        ),
        'NAS 本地 · 直接播放 · 4K · Dolby Vision · Atmos',
      );
      expect(
        evPlayerTechSummary(
          const MediaQuality(origin: MediaOrigin.direct115, resolution: '1080p'),
        ),
        '115 直连 · 1080p',
      );
      expect(evPlayerTechSummary(null), '115 直连');

      final ep = _sampleEpisode(title: '出征的号角', seasonId: 'sea1', episodeNumber: 9);
      final epMeta = evPlayerEpisodeMeta(
        ep,
        const PlayTarget(itemId: 'ep9', seasonId: 'sea1', episodeNumber: 9),
      );
      expect(epMeta.primary, '第 1 季 · 第 9 集');
      expect(epMeta.secondary, '出征的号角');

      final genericEp = _sampleEpisode(title: '第 9 集', seasonId: 'opaque_uuid');
      final genericMeta = evPlayerEpisodeMeta(
        genericEp,
        const PlayTarget(itemId: 'ep9', episodeNumber: 9),
      );
      expect(genericMeta.primary, '第 9 集');
      expect(genericMeta.secondary, '');

      final movie = _sampleMovie();
      final movieMeta = evPlayerEpisodeMeta(
        movie,
        const PlayTarget(itemId: 'mov1'),
      );
      expect(movieMeta.primary, '2024');
      expect(movieMeta.secondary, '166 分钟');
    });
  });

  group('C5.1: EvFirstFrameTracker & EvPlayerOpeningOverlay', () {
    testWidgets(
      'records UI first-frame latency on post-frame callback and logs native latency',
      (tester) async {
        var now = DateTime(2026, 11, 25, 21, 0, 0, 0);
        final logs = <String>[];
        final tracker = EvFirstFrameTracker(
          clock: () => now,
          log: logs.add,
        );
        addTearDown(tracker.dispose);

        var recordedCount = 0;
        final preparing = _sampleSnapshot(phase: PlaybackPhase.preparing);
        tracker.observe(preparing, onRecorded: () => recordedCount++);
        await tester.pump();
        expect(tracker.recorded, isFalse);
        expect(recordedCount, 0);

        now = now.add(const Duration(milliseconds: 1700));
        final playing = _sampleSnapshot(
          phase: PlaybackPhase.playing,
          firstFrameLatency: const Duration(milliseconds: 1420),
        );
        tracker.observe(playing, onRecorded: () => recordedCount++);
        await tester.pump();

        expect(tracker.recorded, isTrue);
        expect(
          tracker.uiFirstFrameLatency,
          const Duration(milliseconds: 1700),
        );
        expect(
          tracker.nativeFirstFrameLatency,
          const Duration(milliseconds: 1420),
        );
        expect(recordedCount, 1);
        expect(logs, hasLength(1));
        expect(logs.single, contains('uiFirstFrameLatency=1700ms'));
        expect(logs.single, contains('nativeFirstFrameLatency=1420ms'));

        // Generation change resets tracker for next episode.
        now = now.add(const Duration(milliseconds: 500));
        final nextGenPrep = _sampleSnapshot(
          generation: 2,
          phase: PlaybackPhase.opening,
        );
        tracker.observe(nextGenPrep);
        expect(tracker.recorded, isFalse);
      },
    );

    testWidgets(
      'EvPlayerOpeningOverlay distinguishes 115 vs NAS local copy, fades when done, and supports failed retry/back',
      (tester) async {
        final directPrep = _sampleSnapshot(
          phase: PlaybackPhase.preparing,
          item: _sampleEpisode(origin: MediaOrigin.direct115),
        );
        await tester.pumpWidget(
          _harness(
            child: EvPlayerOpeningOverlay(
              snapshot: directPrep,
              uiFirstFrameLatency: null,
              done: false,
            ),
          ),
        );
        expect(find.byKey(const Key('ev_player_opening')), findsOneWidget);
        expect(find.text('正在预解析 115 地址…'), findsOneWidget);

        // First frame ready for 115 direct stream
        await tester.pumpWidget(
          _harness(
            child: EvPlayerOpeningOverlay(
              snapshot: _sampleSnapshot(
                phase: PlaybackPhase.playing,
                item: _sampleEpisode(origin: MediaOrigin.direct115),
              ),
              uiFirstFrameLatency: const Duration(milliseconds: 1700),
              done: false,
            ),
          ),
        );
        expect(find.text('已拿到直连地址 · 首帧 1.7 秒'), findsOneWidget);

        // NAS local copy (preparing -> first frame) + wordmark fallback without logo
        final nasMovie = _sampleMovie(origin: MediaOrigin.nasLocal);
        await tester.pumpWidget(
          _harness(
            child: EvPlayerOpeningOverlay(
              snapshot: _sampleSnapshot(
                phase: PlaybackPhase.preparing,
                item: MediaCard(
                  id: nasMovie.id,
                  kind: MediaKind.movie,
                  title: '沙丘 2',
                  quality: nasMovie.quality,
                  art: _sampleArt(withLogo: false),
                ),
              ),
              uiFirstFrameLatency: null,
              done: false,
            ),
          ),
        );
        expect(find.text('Emby 静态流 · 不转码'), findsOneWidget);
        expect(find.text('沙丘 2'), findsOneWidget);

        await tester.pumpWidget(
          _harness(
            child: EvPlayerOpeningOverlay(
              snapshot: _sampleSnapshot(
                phase: PlaybackPhase.playing,
                item: nasMovie,
              ),
              uiFirstFrameLatency: const Duration(milliseconds: 1100),
              done: true,
              holdVisible: false,
            ),
          ),
        );
        expect(find.text('首帧 1.1 秒'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 900));
        final opacity = tester.widget<AnimatedOpacity>(
          find.byKey(const Key('ev_player_opening')),
        );
        expect(opacity.opacity, 0.0);

        // Failed state shows failure reason + working back & retry buttons
        var backTapped = false;
        var retryTapped = false;
        await tester.pumpWidget(
          _harness(
            child: EvPlayerOpeningOverlay(
              snapshot: _sampleSnapshot(
                phase: PlaybackPhase.failed,
                failure: const EmbyViewFailure('115 直连地址解析超时', retryable: true),
              ),
              uiFirstFrameLatency: null,
              done: false,
              onBack: () => backTapped = true,
              onRetry: () => retryTapped = true,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('115 直连地址解析超时'), findsOneWidget);
        await tester.tap(find.byKey(const Key('ev_player_opening_retry')));
        await tester.tap(find.byKey(const Key('ev_player_opening_back')));
        await tester.pump();
        expect(retryTapped, isTrue);
        expect(backTapped, isTrue);
      },
    );

    testWidgets('EvPlayerOpeningClip clips at 0.0 and removes clip at 1.0', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          child: const EvPlayerOpeningClip(
            origin: Rect.fromLTWH(100, 120, 320, 180),
            expandProgress: 0.0,
            child: ColoredBox(color: Colors.red),
          ),
        ),
      );
      expect(find.byType(ClipRRect), findsOneWidget);

      await tester.pumpWidget(
        _harness(
          child: const EvPlayerOpeningClip(
            origin: Rect.fromLTWH(100, 120, 320, 180),
            expandProgress: 1.0,
            child: ColoredBox(color: Colors.red),
          ),
        ),
      );
      expect(find.byType(ClipRRect), findsNothing);
    });
  });

  group('C5.2: EvPlayerScrubBar', () {
    testWidgets(
      'hovering and dragging invokes thumbnailAt, discards stale callbacks, shows chapter/time, and commits seek',
      (tester) async {
        final requestedPositions = <Duration>[];
        final pending = <Completer<ThumbnailFrame?>>[];
        Duration? soughtTo;
        final fixedNow = DateTime(2026, 11, 25, 21, 0);

        await tester.pumpWidget(
          _harness(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(72),
                child: EvPlayerScrubBar(
                  position: const Duration(minutes: 6),
                  duration: const Duration(minutes: 24),
                  bufferedUntil: const Duration(minutes: 14),
                  chapters: const [
                    ChapterMark(start: Duration(minutes: 2), name: '片头曲'),
                    ChapterMark(start: Duration(minutes: 8), name: '城墙夜战'),
                  ],
                  onThumbnailAt: (pos) {
                    requestedPositions.add(pos);
                    final c = Completer<ThumbnailFrame?>();
                    pending.add(c);
                    return c.future;
                  },
                  onSeek: (d) => soughtTo = d,
                  clock: () => fixedNow,
                ),
              ),
            ),
          ),
        );

        expect(find.text('6:00'), findsOneWidget);
        expect(find.text('-18:00 · 21:18 结束'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Hover at ~50% (12:00, inside chapter '城墙夜战')
        final barRect = tester.getRect(
          find.byKey(const Key('ev_player_scrub_bar')),
        );
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);

        await gesture.moveTo(Offset(barRect.left + barRect.width * 0.5, barRect.top + 10));
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byKey(const Key('ev_player_trick_preview')), findsOneWidget);
        expect(find.text('12:00'), findsOneWidget);
        expect(find.text('城墙夜战'), findsOneWidget);
        expect(requestedPositions, isNotEmpty);

        // Move again to trigger a second request and resolve them out-of-order
        await gesture.moveTo(Offset(barRect.left + barRect.width * 0.25, barRect.top + 10));
        await tester.pump(const Duration(milliseconds: 50));
        expect(pending.length, greaterThanOrEqualTo(2));

        final newestThumb = ThumbnailFrame(
          image: _TestArtworkRef('thumb_new'),
          position: const Duration(minutes: 6),
        );
        final staleThumb = ThumbnailFrame(
          image: _TestArtworkRef('thumb_stale'),
          position: const Duration(minutes: 12),
        );
        pending.last.complete(newestThumb);
        await tester.pump();
        pending.first.complete(staleThumb);
        await tester.pump();

        expect(
          find.byKey(const ValueKey('ev_trick_img_player_test_thumb_new')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ev_trick_img_player_test_thumb_stale')),
          findsNothing,
        );

        // Tap at ~75% commits seek (~18:00)
        await tester.tapAt(
          Offset(barRect.left + barRect.width * 0.75, barRect.top + 10),
        );
        await tester.pump();
        expect(soughtTo, isNotNull);
        expect(soughtTo!.inMinutes, closeTo(18, 1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'AI aurora bar preserves seek coverage gaps and shows exact lead or catchingUp copy',
      (tester) async {
        // Pure coverage gap verification
        final gappedRun = AiRun(
          generation: 1,
          state: AiRunState.generating,
          startedAt: Duration.zero,
          coverageEnd: const Duration(minutes: 9, seconds: 32),
          coverage: const [
            TimeRange(start: Duration.zero, end: Duration(minutes: 2)),
            TimeRange(
              start: Duration(minutes: 6),
              end: Duration(minutes: 9, seconds: 32),
            ),
          ],
        );
        final segments = EvPlayerScrubBar.computeAuroraSegments(
          gappedRun,
          const Duration(minutes: 6),
          const Duration(minutes: 24),
        );
        expect(segments, hasLength(2));
        expect(segments[0].$2, lessThan(segments[1].$1));

        // Widget renders aurora bar and exact lead duration tip (coverageEnd - position = 3m32s)
        await tester.pumpWidget(
          _harness(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(72),
                child: EvPlayerScrubBar(
                  position: const Duration(minutes: 6),
                  duration: const Duration(minutes: 24),
                  bufferedUntil: const Duration(minutes: 12),
                  aiRun: gappedRun,
                  flashAuroraTip: true,
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('ev_player_aurora')), findsOneWidget);
        expect(find.text('AI 中字已领先 3 分 32 秒'), findsOneWidget);

        // Catching up state shows catchingUp copy without fabricating lead time
        const catchingUpRun = AiRun(
          generation: 1,
          state: AiRunState.catchingUp,
          startedAt: Duration(minutes: 6),
          coverageEnd: Duration(minutes: 5, seconds: 50),
        );
        await tester.pumpWidget(
          _harness(
            mode: ThemeMode.paper,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(72),
                child: EvPlayerScrubBar(
                  position: const Duration(minutes: 6),
                  duration: const Duration(minutes: 24),
                  bufferedUntil: const Duration(minutes: 12),
                  aiRun: catchingUpRun,
                  flashAuroraTip: true,
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('ev_player_aurora')), findsOneWidget);
        expect(find.text('AI 中字追赶中'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('C5.3: EvPlayerControls', () {
    for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
      for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
        testWidgets(
          'renders without overflow in ${mode.name} at ${size.width.toInt()}x${size.height.toInt()} (closed & panel open)',
          (tester) async {
            _setViewport(tester, size);
            final snap = _sampleSnapshot(
              nextEpisode: _sampleEpisode(id: 'ep10', episodeNumber: 10),
              anime4k: const Anime4kSnapshot(
                supported: true,
                requested: true,
                state: Anime4kState.active,
              ),
            );
            await tester.pumpWidget(
              _harness(
                size: size,
                mode: mode,
                child: EvPlayerControls(
                  snapshot: snap,
                  visible: true,
                  panelOpen: false,
                  forcedScrubHoverFraction: 0.45,
                  onSeek: (_) {},
                  clock: () => DateTime(2026, 11, 25, 21, 0),
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 100));
            expect(tester.takeException(), isNull);
            expect(find.byKey(const Key('ev_player_back')), findsOneWidget);
            expect(find.byKey(const Key('ev_player_tech_pill')), findsOneWidget);
            expect(
              find.byKey(const Key('ev_player_bottom_title')),
              findsOneWidget,
            );
            expect(find.byKey(const Key('ev_player_play_pause')), findsOneWidget);
            expect(find.byKey(const Key('ev_player_next')), findsOneWidget);

            // Switch to panelOpen = true
            await tester.pumpWidget(
              _harness(
                size: size,
                mode: mode,
                child: EvPlayerControls(
                  snapshot: snap,
                  visible: true,
                  panelOpen: true,
                  activePanelTab: 'subs',
                  onSeek: (_) {},
                  clock: () => DateTime(2026, 11, 25, 21, 0),
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 650));
            expect(tester.takeException(), isNull);
            expect(
              find.byKey(const Key('ev_player_bottom_title')),
              findsNothing,
            );
            expect(
              find.byKey(const Key('ev_player_top_title')),
              findsOneWidget,
            );

            // Verify top & bottom bars yield space to the right panel
            final scale = EvScale.fromSize(size);
            final techRect = tester.getRect(
              find.byKey(const Key('ev_player_tech_pill')),
            );
            final scrubRect = tester.getRect(
              find.byKey(const Key('ev_player_scrub_bar')),
            );
            expect(
              techRect.right,
              lessThanOrEqualTo(size.width - scale.rem(29.0) + 1.0),
            );
            expect(scrubRect.left, closeTo(scale.rem(2.5), 1.5));
            expect(
              scrubRect.right,
              closeTo(size.width - scale.rem(31.5), 1.5),
            );
          },
        );
      }
    }

    testWidgets(
      'play/pause morph, seek spin triggers, Anime4K active-only highlight, and control callbacks',
      (tester) async {
        _setViewport(tester, const Size(1440, 900));
        var backCalls = 0;
        var togglePlayCalls = 0;
        final seekDeltas = <Duration>[];
        var muteCalls = 0;
        var nextCalls = 0;
        final panelTabs = <String>[];
        var a4kCalls = 0;
        var pipCalls = 0;
        var fullCalls = 0;
        var backdropCalls = 0;

        Widget buildControls({
          PlaybackPhase phase = PlaybackPhase.playing,
          Anime4kState a4kState = Anime4kState.pending,
          int seekLeftNonce = 0,
          int seekRightNonce = 0,
          bool pauseCardVisible = false,
          ThemeMode mode = ThemeMode.cinema,
        }) => _harness(
          mode: mode,
          child: EvPlayerControls(
            snapshot: _sampleSnapshot(
              phase: phase,
              nextEpisode: _sampleEpisode(id: 'ep10', episodeNumber: 10),
              anime4k: Anime4kSnapshot(
                supported: true,
                requested: a4kState != Anime4kState.off,
                state: a4kState,
              ),
            ),
            visible: true,
            panelOpen: false,
            pauseCardVisible: pauseCardVisible,
            seekLeftNonce: seekLeftNonce,
            seekRightNonce: seekRightNonce,
            onBack: () => backCalls++,
            onTogglePlay: () => togglePlayCalls++,
            onSeek: (_) {},
            onSeekBy: seekDeltas.add,
            onToggleMute: () => muteCalls++,
            onPlayNext: () => nextCalls++,
            onOpenPanelTab: panelTabs.add,
            onToggleAnime4k: () => a4kCalls++,
            onTogglePip: () => pipCalls++,
            onToggleFullscreen: () => fullCalls++,
            onBackdropTap: () => backdropCalls++,
          ),
        );

        await tester.pumpWidget(buildControls(a4kState: Anime4kState.pending));
        await tester.pump(const Duration(milliseconds: 50));

        // Anime4K pending MUST NOT be highlighted
        final pendingSemantics = tester.widget<Semantics>(
          find
              .descendant(
                of: find.byKey(const Key('ev_player_a4k')),
                matching: find.byType(Semantics),
              )
              .first,
        );
        expect(pendingSemantics.properties.selected, isFalse);

        // Anime4K active IS highlighted
        await tester.pumpWidget(buildControls(a4kState: Anime4kState.active));
        await tester.pump(const Duration(milliseconds: 50));
        final activeSemantics = tester.widget<Semantics>(
          find
              .descendant(
                of: find.byKey(const Key('ev_player_a4k')),
                matching: find.byType(Semantics),
              )
              .first,
        );
        expect(activeSemantics.properties.selected, isTrue);

        // Play/Pause morph switches icon key from 'pause' to 'play'
        expect(find.byKey(const ValueKey('pause')), findsOneWidget);
        await tester.pumpWidget(
          buildControls(
            phase: PlaybackPhase.paused,
            a4kState: Anime4kState.off,
            pauseCardVisible: true,
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('play')), findsOneWidget);

        // Pause card hides bottom title opacity
        final titleOpacity = tester.widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byKey(const Key('ev_player_bottom_title')),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );
        expect(titleOpacity.opacity, 0.0);

        // Nonce increment triggers spin animation without error
        await tester.pumpWidget(
          buildControls(
            a4kState: Anime4kState.off,
            seekLeftNonce: 1,
            seekRightNonce: 1,
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);

        // Tap all key buttons
        await tester.tap(find.byKey(const Key('ev_player_back')));
        await tester.tap(find.byKey(const Key('ev_player_play_pause')));
        await tester.tap(find.byKey(const Key('ev_player_back10')));
        await tester.tap(find.byKey(const Key('ev_player_fwd10')));
        await tester.tap(find.byKey(const Key('ev_player_mute')));
        await tester.tap(find.byKey(const Key('ev_player_next')));
        await tester.tap(find.byKey(const Key('ev_player_tab_subs')));
        await tester.tap(find.byKey(const Key('ev_player_tab_audio')));
        await tester.tap(find.byKey(const Key('ev_player_a4k')));
        await tester.tap(find.byKey(const Key('ev_player_pip')));
        await tester.tap(find.byKey(const Key('ev_player_fullscreen')));
        await tester.tapAt(const Offset(720, 400));
        await tester.pump(const Duration(milliseconds: 500));

        expect(backCalls, 1);
        expect(togglePlayCalls, 1);
        expect(seekDeltas, const [
          Duration(seconds: -10),
          Duration(seconds: 10),
        ]);
        expect(muteCalls, 1);
        expect(nextCalls, 1);
        expect(panelTabs, const ['subs', 'audio']);
        expect(a4kCalls, 1);
        expect(pipCalls, 1);
        expect(fullCalls, 1);
        expect(backdropCalls, 1);
      },
    );

    testWidgets('paper theme applies terracotta play button and ink active state', (
      tester,
    ) async {
      _setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        _harness(
          mode: ThemeMode.paper,
          child: EvPlayerControls(
            snapshot: _sampleSnapshot(
              anime4k: const Anime4kSnapshot(
                supported: true,
                requested: true,
                state: Anime4kState.active,
              ),
            ),
            visible: true,
            panelOpen: true,
            activePanelTab: 'subs',
            onSeek: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final playBox = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(const Key('ev_player_play_pause')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(
        (playBox.decoration as BoxDecoration).color,
        const Color(0xFFB5532F),
      );

      final a4kContainer = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const Key('ev_player_a4k')),
          matching: find.byType(Container),
        ),
      );
      expect(
        (a4kContainer.decoration as BoxDecoration).color,
        const Color(0xFF141413),
      );
    });
  });
}
