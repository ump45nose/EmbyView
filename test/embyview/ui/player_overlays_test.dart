import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_credits_overlay.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_pause_overlay.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_player_toast.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_seek_feedback.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(this.id)
    : cacheKey = 'overlay_test_$id',
      image = MemoryImage(_kPngBytes);

  @override
  final String id;
  @override
  final String cacheKey;
  @override
  final ImageProvider<Object> image;
  @override
  double? get aspectRatio => 16 / 9;
  @override
  int? get width => 1920;
  @override
  int? get height => 1080;
}

Widget _wrap({
  required Widget child,
  ThemeMode themeMode = ThemeMode.cinema,
  Size size = const Size(1440, 900),
}) {
  return MediaQuery(
    data: MediaQueryData(size: size),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: EvThemeScope(
        themeMode: themeMode,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(fit: StackFit.expand, children: [child]),
        ),
      ),
    ),
  );
}

MediaCard _sampleEpisode({
  String id = 'ep-9',
  int? episodeNumber = 9,
  String title = '决战前夜',
  String? overview = '城墙上的火把一盏接一盏熄灭了，天亮之前必须越过那道山脊。',
  bool withLogo = true,
  bool withStage = true,
}) {
  final logo = withLogo ? _FakeArtworkRef('logo-$id') : null;
  final stage = withStage
      ? ArtworkPlan(
          layers: [
            ArtworkLayer(
              source: _FakeArtworkRef('stage-$id'),
              fit: ArtworkFit.cover,
            ),
          ],
        )
      : const ArtworkPlan();
  return MediaCard(
    id: id,
    kind: MediaKind.episode,
    title: title,
    episodeNumber: episodeNumber,
    duration: const Duration(minutes: 24),
    overview: overview,
    art: CardArtwork(logo: logo, stage: stage),
  );
}

PlaybackSnapshot _sampleSnapshot({
  int generation = 1,
  MediaCard? item,
  MediaCard? nextEpisode,
  Duration position = const Duration(minutes: 10),
  Duration? duration = const Duration(minutes: 24),
  PlaybackPhase phase = PlaybackPhase.paused,
  CreditsPromptState creditsPrompt = CreditsPromptState.countingDown,
}) {
  final ep = item ?? _sampleEpisode();
  return PlaybackSnapshot(
    generation: generation,
    target: PlayTarget(
      itemId: ep.id,
      episodeNumber: ep.episodeNumber,
    ),
    item: ep,
    phase: phase,
    position: position,
    duration: duration,
    nextEpisode: nextEpisode,
    creditsPrompt: creditsPrompt,
  );
}

void main() {
  group('EvPauseOverlay', () {
    testWidgets('renders logo, paused eyebrow, episode title, overview, remaining & end time, and resumes on tap', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var resumed = 0;
      final fixedNow = DateTime(2026, 11, 25, 21, 5);
      final snap = _sampleSnapshot(
        position: const Duration(minutes: 9, seconds: 15),
        duration: const Duration(minutes: 24),
      );

      await tester.pumpWidget(
        _wrap(
          child: EvPauseOverlay(
            visible: true,
            snapshot: snap,
            onResume: () => resumed++,
            clock: () => fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ev_player_pause_card')), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('第 9 集 · 决战前夜'), findsOneWidget);
      expect(find.textContaining('城墙上的火把'), findsOneWidget);
      // Remaining = 14m45s -> ceil = 15 分钟; 21:05 + 14m45s = 21:19
      expect(find.text('剩 15 分钟 · 21:19 结束'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ev_player_pause_card')));
      await tester.pump();
      expect(resumed, 1);
    });

    testWidgets('formats generic episode title without duplicate name and respects movie logo rule', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Generic episode title like "第 3 集" -> only "第 3 集"
      final genericEp = _sampleEpisode(id: 'ep-3', episodeNumber: 3, title: '第 3 集');
      await tester.pumpWidget(
        _wrap(
          child: EvPauseOverlay(
            visible: true,
            snapshot: _sampleSnapshot(item: genericEp),
            clock: () => DateTime(2026, 11, 25, 8, 5),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 3 集'), findsOneWidget);

      // Movie without logo -> displays movie title
      const movieNoLogo = MediaCard(
        id: 'mov-1',
        kind: MediaKind.movie,
        title: '星际穿越',
        overview: '穿越虫洞寻找人类新家园。',
        duration: Duration(minutes: 169),
      );
      await tester.pumpWidget(
        _wrap(
          child: EvPauseOverlay(
            visible: true,
            snapshot: _sampleSnapshot(
              item: movieNoLogo,
              position: const Duration(minutes: 69),
              duration: const Duration(minutes: 169),
            ),
            clock: () => DateTime(2026, 11, 25, 8, 5),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('星际穿越'), findsOneWidget);
      expect(find.text('剩 100 分钟 · 9:45 结束'), findsOneWidget);

      // Movie with logo via art override -> logo shown, duplicate movie title omitted
      await tester.pumpWidget(
        _wrap(
          child: EvPauseOverlay(
            visible: true,
            snapshot: _sampleSnapshot(
              item: movieNoLogo,
              position: const Duration(minutes: 69),
              duration: const Duration(minutes: 169),
            ),
            art: CardArtwork(logo: _FakeArtworkRef('mov-logo')),
            clock: () => DateTime(2026, 11, 25, 8, 5),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('星际穿越'), findsNothing);
    });

    testWidgets('ignores taps when hidden', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var resumed = 0;
      await tester.pumpWidget(
        _wrap(
          child: EvPauseOverlay(
            visible: false,
            snapshot: _sampleSnapshot(),
            onResume: () => resumed++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('ev_player_pause_card')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(resumed, 0);
    });

    testWidgets('renders without overflow across cinema/paper themes and 1440x900 / 2560x1440', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final snap = _sampleSnapshot();

      for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
        for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            _wrap(
              themeMode: mode,
              size: size,
              child: EvPauseOverlay(
                visible: true,
                snapshot: snap,
                clock: () => DateTime(2026, 11, 25, 20, 0),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('ev_player_pause_card')), findsOneWidget);
        }
      }
    });
  });

  group('EvCreditsVideoFrame & EvCreditsOverlay (C5.4)', () {
    testWidgets('video frame transforms to bottom-left in credits mode and indents when panel opens', (
      tester,
    ) async {
      const size = Size(1440, 900);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var tappedMini = 0;

      // Normal full-screen
      await tester.pumpWidget(
        _wrap(
          size: size,
          child: EvCreditsVideoFrame(
            creditsActive: false,
            panelOpen: false,
            onTapMiniVideo: () => tappedMini++,
            child: const ColoredBox(
              key: Key('video_child'),
              color: Color(0xFF102030),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const Key('video_child'))), const Rect.fromLTWH(0, 0, 1440, 900));

      // Panel open inset: available area is left 1rem(16), top 1rem(16), right 30rem(480), bottom 1rem(16)
      // (944x868), inside which 16:9 video is letterboxed centered (944x531 -> top 184.5, bottom 715.5) with zero radius.
      await tester.pumpWidget(
        _wrap(
          size: size,
          child: EvCreditsVideoFrame(
            creditsActive: false,
            panelOpen: true,
            onTapMiniVideo: () => tappedMini++,
            child: const ColoredBox(
              key: Key('video_child'),
              color: Color(0xFF102030),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final panelRect = tester.getRect(find.byKey(const Key('video_child')));
      expect(panelRect.left, closeTo(16.0, 0.5));
      expect(panelRect.right, closeTo(1440.0 - 480.0, 0.5));
      expect(panelRect.width, closeTo(944.0, 0.5));
      expect(panelRect.height, closeTo(944.0 * 9 / 16, 0.5));
      expect(panelRect.top, closeTo(16.0 + (868.0 - 531.0) / 2, 0.5));
      expect(panelRect.bottom, closeTo(900.0 - 16.0 - (868.0 - 531.0) / 2, 0.5));
      expect(panelRect.width / panelRect.height, closeTo(16 / 9, 0.005));
      final panelBox = tester.widget<AnimatedContainer>(find.byKey(const Key('ev_credits_video_frame_box')));
      expect((panelBox.decoration as BoxDecoration).borderRadius, BorderRadius.zero);

      // Credits active -> shrinks to bottom-left (scale 0.36, left = 72 - 28.8 = 43.2, bottom = 900 - 36 = 864) with radius
      await tester.pumpWidget(
        _wrap(
          size: size,
          child: EvCreditsVideoFrame(
            creditsActive: true,
            panelOpen: false,
            onTapMiniVideo: () => tappedMini++,
            child: const ColoredBox(
              key: Key('video_child'),
              color: Color(0xFF102030),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final miniRect = tester.getRect(find.byKey(const Key('video_child')));
      expect(miniRect.width, closeTo(1440 * 0.36, 1.0));
      expect(miniRect.height, closeTo(900 * 0.36, 1.0));
      expect(miniRect.left, closeTo(72.0 - 28.8, 1.0));
      expect(miniRect.bottom, closeTo(900.0 - 36.0, 1.0));
      final creditsBox = tester.widget<AnimatedContainer>(find.byKey(const Key('ev_credits_video_frame_box')));
      expect((creditsBox.decoration as BoxDecoration).borderRadius, BorderRadius.circular(40.0));

      await tester.tapAt(miniRect.center);
      await tester.pump();
      expect(tappedMini, 1);
    });

    testWidgets('shows next episode info, counts down 5..0, and calls onPlayNext once after 500ms', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var playNextCalls = 0;
      var stayCalls = 0;
      final nextEp = _sampleEpisode(
        id: 'ep-10',
        episodeNumber: 10,
        title: '黎明突围',
        overview: '晨雾中号角吹响，先锋队向山谷发起了总攻。',
      );
      final snap = _sampleSnapshot(generation: 1, nextEpisode: nextEp);

      await tester.pumpWidget(
        _wrap(
          child: EvCreditsOverlay(
            visible: true,
            snapshot: snap,
            onPlayNext: () => playNextCalls++,
            onStay: () => stayCalls++,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('ev_player_credits_overlay')), findsOneWidget);
      expect(find.text('片尾 · 第 9 集'), findsOneWidget);
      expect(find.text('下一集 · 第 10 集'), findsOneWidget);
      expect(find.text('黎明突围'), findsOneWidget);
      expect(find.textContaining('晨雾中号角吹响'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('ev_credits_countdown')),
          matching: find.text('5'),
        ),
        findsOneWidget,
      );

      for (final expected in [4, 3, 2, 1, 0]) {
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.descendant(
            of: find.byKey(const Key('ev_credits_countdown')),
            matching: find.text('$expected'),
          ),
          findsOneWidget,
        );
        expect(playNextCalls, 0);
      }

      // 400ms after reaching 0 -> not yet fired
      await tester.pump(const Duration(milliseconds: 400));
      expect(playNextCalls, 0);

      // 500ms after reaching 0 -> fires once
      await tester.pump(const Duration(milliseconds: 150));
      expect(playNextCalls, 1);
      expect(stayCalls, 0);

      // Does not fire again
      await tester.pump(const Duration(seconds: 3));
      expect(playNextCalls, 1);
    });

    testWidgets('clicking 立即播放 invokes onPlayNext immediately and cancels auto-play', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var playNextCalls = 0;
      final snap = _sampleSnapshot(
        generation: 1,
        nextEpisode: _sampleEpisode(id: 'ep-10', episodeNumber: 10, title: '黎明突围'),
      );

      await tester.pumpWidget(
        _wrap(
          child: EvCreditsOverlay(
            visible: true,
            snapshot: snap,
            onPlayNext: () => playNextCalls++,
            onStay: () {},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('ev_credits_play_next')));
      await tester.pump();
      expect(playNextCalls, 1);

      // Advance well past countdown duration; must not fire a second time
      await tester.pump(const Duration(seconds: 8));
      expect(playNextCalls, 1);
    });

    testWidgets('clicking 看完片尾 invokes onStay and cancels countdown permanently', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var playNextCalls = 0;
      var stayCalls = 0;
      final snap = _sampleSnapshot(
        generation: 1,
        nextEpisode: _sampleEpisode(id: 'ep-10', episodeNumber: 10, title: '黎明突围'),
      );

      await tester.pumpWidget(
        _wrap(
          child: EvCreditsOverlay(
            visible: true,
            snapshot: snap,
            onPlayNext: () => playNextCalls++,
            onStay: () => stayCalls++,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byKey(const Key('ev_credits_stay')));
      await tester.pump();

      expect(stayCalls, 1);
      expect(playNextCalls, 0);

      await tester.pump(const Duration(seconds: 10));
      expect(playNextCalls, 0);
    });

    testWidgets('changing snapshot generation resets countdown to full seconds', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var playNextCalls = 0;
      final snap1 = _sampleSnapshot(
        generation: 1,
        item: _sampleEpisode(id: 'ep-9', episodeNumber: 9),
        nextEpisode: _sampleEpisode(id: 'ep-10', episodeNumber: 10, title: '黎明突围'),
      );
      final snap2 = _sampleSnapshot(
        generation: 2,
        item: _sampleEpisode(id: 'ep-10', episodeNumber: 10),
        nextEpisode: _sampleEpisode(id: 'ep-11', episodeNumber: 11, title: '凯旋归来'),
      );

      await tester.pumpWidget(
        _wrap(
          child: EvCreditsOverlay(
            visible: true,
            snapshot: snap1,
            onPlayNext: () => playNextCalls++,
            onStay: () {},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(
        find.descendant(
          of: find.byKey(const Key('ev_credits_countdown')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );

      // Generation advances -> countdown resets to 5 and labels update
      await tester.pumpWidget(
        _wrap(
          child: EvCreditsOverlay(
            visible: true,
            snapshot: snap2,
            onPlayNext: () => playNextCalls++,
            onStay: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('片尾 · 第 10 集'), findsOneWidget);
      expect(find.text('下一集 · 第 11 集'), findsOneWidget);
      expect(find.text('凯旋归来'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('ev_credits_countdown')),
          matching: find.text('5'),
        ),
        findsOneWidget,
      );

      // Should not fire at 3 seconds (would have fired if old timer wasn't reset)
      await tester.pump(const Duration(seconds: 3));
      expect(playNextCalls, 0);

      // Fires after remaining 2s + 500ms
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 550));
      expect(playNextCalls, 1);
    });

    testWidgets('autoTick false holds countdown and dual theme/size matrix renders cleanly', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var playNextCalls = 0;
      final snap = _sampleSnapshot(
        nextEpisode: _sampleEpisode(id: 'ep-10', episodeNumber: 10, title: '黎明突围'),
      );

      for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
        for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            _wrap(
              themeMode: mode,
              size: size,
              child: EvCreditsOverlay(
                visible: true,
                snapshot: snap,
                autoTick: false,
                onPlayNext: () => playNextCalls++,
                onStay: () {},
              ),
            ),
          );
          await tester.pump(const Duration(seconds: 6));
          expect(tester.takeException(), isNull);
          expect(playNextCalls, 0);
          expect(
            find.descendant(
              of: find.byKey(const Key('ev_credits_countdown')),
              matching: find.text('5'),
            ),
            findsOneWidget,
          );
        }
      }
    });
  });

  group('EvSeekFeedbackOverlay', () {
    double bubbleOpacity(WidgetTester tester, Key key) {
      final opacityWidget = tester.widget<Opacity>(
        find.descendant(of: find.byKey(key), matching: find.byType(Opacity)),
      );
      return opacityWidget.opacity;
    }

    testWidgets('flashes left and right bubbles on nonce increment and fades out automatically', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          child: const EvSeekFeedbackOverlay(leftNonce: 0, rightNonce: 0),
        ),
      );
      expect(bubbleOpacity(tester, const Key('ev_seek_fx_left')), 0.0);
      expect(bubbleOpacity(tester, const Key('ev_seek_fx_right')), 0.0);
      expect(find.text('-10 秒'), findsOneWidget);
      expect(find.text('+10 秒'), findsOneWidget);

      // Increment leftNonce -> left flashes, right stays hidden
      await tester.pumpWidget(
        _wrap(
          child: const EvSeekFeedbackOverlay(leftNonce: 1, rightNonce: 0),
        ),
      );
      await tester.pump(const Duration(milliseconds: 210));
      expect(bubbleOpacity(tester, const Key('ev_seek_fx_left')), greaterThan(0.8));
      expect(bubbleOpacity(tester, const Key('ev_seek_fx_right')), 0.0);

      // Complete 700ms animation -> faded out
      await tester.pump(const Duration(milliseconds: 550));
      expect(bubbleOpacity(tester, const Key('ev_seek_fx_left')), 0.0);

      // Increment rightNonce -> right flashes, left stays hidden
      await tester.pumpWidget(
        _wrap(
          child: const EvSeekFeedbackOverlay(leftNonce: 1, rightNonce: 1),
        ),
      );
      await tester.pump(const Duration(milliseconds: 210));
      expect(bubbleOpacity(tester, const Key('ev_seek_fx_right')), greaterThan(0.8));
      expect(bubbleOpacity(tester, const Key('ev_seek_fx_left')), 0.0);

      await tester.pump(const Duration(milliseconds: 550));
      expect(bubbleOpacity(tester, const Key('ev_seek_fx_right')), 0.0);
    });
  });

  group('EvPlayerToast', () {
    testWidgets('displays and hides in cinema and paper themes across viewport sizes', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));

      for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
        for (final mode in const [ThemeMode.cinema, ThemeMode.paper]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            _wrap(
              themeMode: mode,
              size: size,
              child: const EvPlayerToast(
                visible: true,
                message: 'Anime4K 已开启 · 轻量档 · 1080p → 4K',
                icon: EvIcons.ok,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('ev_player_toast')), findsOneWidget);
          expect(
            find.text('Anime4K 已开启 · 轻量档 · 1080p → 4K'),
            findsOneWidget,
          );

          final text = tester.widget<Text>(
            find.text('Anime4K 已开启 · 轻量档 · 1080p → 4K'),
          );
          expect(
            text.style?.color,
            mode == ThemeMode.paper
                ? const Color(0xFF141413)
                : const Color(0xFFF5F5F7),
          );

          // Hide toast -> opacity animates to 0
          await tester.pumpWidget(
            _wrap(
              themeMode: mode,
              size: size,
              child: const EvPlayerToast(
                visible: false,
                message: 'Anime4K 已开启 · 轻量档 · 1080p → 4K',
                icon: EvIcons.ok,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final animatedOpacity = tester.widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byKey(const Key('ev_player_toast')),
              matching: find.byType(AnimatedOpacity),
            ),
          );
          expect(animatedOpacity.opacity, 0.0);
        }
      }
    });
  });
}
