import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/stage/ev_stage.dart';
import 'package:moonfin/embyview/ui/stage/ev_stage_controller.dart';
import 'package:moonfin/embyview/ui/stage/immersion.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

// 1x1 valid transparent PNG for synchronous MemoryImage decoding in tests.
final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

class _FakeArtworkRef implements ArtworkRef {
  _FakeArtworkRef(this.id)
    : cacheKey = 'cache:$id',
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

class _FakePreviewRef implements PreviewRef {
  const _FakePreviewRef(this.id, {this.name = '', this.duration});

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
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeData implements EmbyViewData {
  _FakeData({this.onThemeMedia});

  Future<ThemeMedia> Function(String itemId)? onThemeMedia;
  final List<String> themeMediaCalls = [];

  @override
  Future<ThemeMedia> themeMedia(String itemId) async {
    themeMediaCalls.add(itemId);
    if (onThemeMedia != null) return onThemeMedia!(itemId);
    return const ThemeMedia();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImmersionPlayback implements ImmersionPlayback {
  final _changes = StreamController<ImmersionSnapshot>.broadcast(sync: true);
  ImmersionSnapshot _snapshot = const ImmersionSnapshot();

  final List<PreviewRef?> videoCalls = [];
  final List<PreviewRef?> themeCalls = [];
  final List<bool> muteCalls = [];
  int stopCalls = 0;

  PreviewRef? activeVideo;
  PreviewRef? activeTheme;

  @override
  ImmersionSnapshot get snapshot => _snapshot;

  @override
  Stream<ImmersionSnapshot> get changes => _changes.stream;

  void _emit(ImmersionSnapshot next) {
    _snapshot = next;
    _changes.add(next);
  }

  @override
  Future<void> showMutedVideo(PreviewRef? video) async {
    videoCalls.add(video);
    activeVideo = video;
    _emit(
      ImmersionSnapshot(
        video: video == null ? PreviewState.idle : PreviewState.ready,
        theme: _snapshot.theme,
        themePosition: _snapshot.themePosition,
        themeDuration: _snapshot.themeDuration,
        themeMuted: _snapshot.themeMuted,
      ),
    );
  }

  @override
  Widget videoSurface({Key? key}) =>
      ColoredBox(key: key ?? const Key('fake_video_surface'), color: const Color(0xFFE53935));

  @override
  Future<void> playTheme(PreviewRef? song) async {
    themeCalls.add(song);
    activeTheme = song;
    _emit(
      ImmersionSnapshot(
        video: _snapshot.video,
        theme: song == null ? PreviewState.idle : PreviewState.ready,
        themePosition: Duration.zero,
        themeDuration: song?.duration,
        themeMuted: _snapshot.themeMuted,
      ),
    );
  }

  @override
  Future<void> setThemeMuted(bool muted) async {
    muteCalls.add(muted);
    _emit(
      ImmersionSnapshot(
        video: _snapshot.video,
        theme: _snapshot.theme,
        themePosition: _snapshot.themePosition,
        themeDuration: _snapshot.themeDuration,
        themeMuted: muted,
      ),
    );
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    activeVideo = null;
    activeTheme = null;
    _emit(const ImmersionSnapshot());
  }

  Future<void> close() => _changes.close();
}

MediaCard _card(String id, {bool blurred = false}) => MediaCard(
  id: id,
  kind: MediaKind.movie,
  title: '影片 $id',
  art: CardArtwork(
    stage: ArtworkPlan(
      layers: [
        ArtworkLayer(
          source: _FakeArtworkRef('bd_$id'),
          fit: ArtworkFit.cover,
          blurred: blurred,
        ),
      ],
      fallbackTitle: '影片 $id',
    ),
  ),
);

EmbyViewServices _services({
  required _FakePreferences prefs,
  required _FakeData data,
  required _FakeImmersionPlayback playback,
  String sessionId = 'session-1',
}) => EmbyViewServices(
  preferences: prefs,
  accounts: _FakeAccounts(),
  sessionId: sessionId,
  data: data,
  immersion: playback,
);

Widget _stageHarness({
  required EvStageController controller,
  Immersion? immersion,
  ThemeMode themeMode = ThemeMode.cinema,
  bool enableMotion = true,
}) => MediaQuery(
  data: const MediaQueryData(size: Size(1440, 900)),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: EvThemeScope(
      themeMode: themeMode,
      child: EvStage(
        controller: controller,
        immersion: immersion,
        enableMotion: enableMotion,
      ),
    ),
  ),
);

void main() {
  group('C3.5 card dwell, muted video fade-in, Ken Burns, and scrolled veil lift', () {
    testWidgets(
      'switches backdrop at 0.4s, fetches themeMedia & shows muted video at 1.7s, restores on leave',
      (tester) async {
        final prefs = _FakePreferences();
        final clip = const _FakePreviewRef('clip-1', name: '预告片段');
        final data = _FakeData(
          onThemeMedia: (id) async =>
              id == 'card-1' ? ThemeMedia(backgroundVideo: clip) : const ThemeMedia(),
        );
        final playback = _FakeImmersionPlayback();
        final stage = EvStageController();
        final baseCard = _card('base');
        final targetCard = _card('card-1');
        stage.setBaseBackdrop(baseCard.art.stage);

        final immersion = Immersion(
          stage: stage,
          services: _services(prefs: prefs, data: data, playback: playback),
        );

        await tester.pumpWidget(
          _stageHarness(controller: stage, immersion: immersion, enableMotion: false),
        );

        var heroSynced = 0;
        immersion.onCardHoverStart(
          targetCard,
          scrolledDown: false,
          onBackdropReady: () => heroSynced++,
        );

        // Before 0.4s: base backdrop stays, no themeMedia
        await tester.pump(const Duration(milliseconds: 350));
        expect(stage.activeBackdropKey, stageArtworkKey(baseCard.art.stage));
        expect(heroSynced, 0);
        expect(data.themeMediaCalls, isEmpty);

        // At 0.4s: stage switches to hovered card backdrop & notifies hero
        await tester.pump(const Duration(milliseconds: 60));
        expect(stage.activeBackdropKey, stageArtworkKey(targetCard.art.stage));
        expect(immersion.activePreviewItemId, 'card-1');
        expect(heroSynced, 1);
        expect(stage.veilLifted, isFalse);
        expect(data.themeMediaCalls, isEmpty);
        expect(stage.videoVisible, isFalse);

        // Before 1.7s (total 1.61s): still no video call
        await tester.pump(const Duration(milliseconds: 1200));
        expect(data.themeMediaCalls, isEmpty);
        expect(playback.videoCalls, isEmpty);

        // Cross 1.7s: calls themeMedia & showMutedVideo, fades in video & capsule
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();
        expect(data.themeMediaCalls, ['card-1']);
        expect(playback.videoCalls, [clip]);
        expect(stage.videoVisible, isTrue);
        expect(immersion.isVideoVisible, isTrue);
        expect(stage.videoLabel, isNotNull);
        expect(find.byKey(const Key('ev_stage_vlabel')), findsOneWidget);
        expect(find.text(stage.videoLabel!), findsOneWidget);

        final videoLayer = tester.widget<AnimatedOpacity>(
          find.byKey(const Key('ev_stage_video_layer')),
        );
        expect(videoLayer.opacity, 1.0);

        // Leave card: stops video and restores base backdrop
        immersion.onCardHoverEnd(cardId: 'card-1');
        await tester.pump();
        expect(stage.videoVisible, isFalse);
        expect(playback.videoCalls.last, isNull);
        expect(playback.activeVideo, isNull);
        expect(stage.activeBackdropKey, stageArtworkKey(baseCard.art.stage));
        expect(immersion.activePreviewItemId, isNull);

        immersion.dispose();
        stage.dispose();
        await playback.close();
        await prefs.close();
      },
    );

    testWidgets(
      'keeps Ken Burns active without calling showMutedVideo when backgroundVideo is absent',
      (tester) async {
        final prefs = _FakePreferences();
        final data = _FakeData(onThemeMedia: (_) async => const ThemeMedia());
        final playback = _FakeImmersionPlayback();
        final stage = EvStageController();
        final card = _card('no-video');
        stage.setBaseBackdrop(_card('base').art.stage);

        final immersion = Immersion(
          stage: stage,
          services: _services(prefs: prefs, data: data, playback: playback),
        );

        await tester.pumpWidget(
          _stageHarness(controller: stage, immersion: immersion, enableMotion: true),
        );

        immersion.onCardHoverStart(card);
        await tester.pump(const Duration(milliseconds: 450));
        expect(stage.activeBackdropKey, stageArtworkKey(card.art.stage));

        await tester.pump(const Duration(milliseconds: 1350));
        expect(data.themeMediaCalls, ['no-video']);
        expect(playback.videoCalls, isEmpty);
        expect(stage.videoVisible, isFalse);

        // Verify Ken Burns transform keeps advancing on the visible backdrop.
        final kbFinder = find.byKey(const Key('ev_stage_kenburns'));
        expect(kbFinder, findsWidgets);
        final before = tester.widget<Transform>(kbFinder.last).transform.clone();
        await tester.pump(const Duration(seconds: 3));
        final after = tester.widget<Transform>(kbFinder.last).transform.clone();
        expect(after, isNot(equals(before)));

        immersion.onCardHoverEnd(cardId: 'no-video');
        immersion.dispose();
        stage.dispose();
        await playback.close();
        await prefs.close();
      },
    );

    testWidgets(
      'scrolled down hover swaps backdrop & lifts veil without syncing hero, lowers on leave',
      (tester) async {
        final prefs = _FakePreferences();
        final data = _FakeData();
        final playback = _FakeImmersionPlayback();
        final stage = EvStageController();
        final baseCard = _card('base');
        final hoverCard = _card('scrolled-card');
        stage
          ..setBaseBackdrop(baseCard.art.stage)
          ..setScrollProgress(0.8);

        final immersion = Immersion(
          stage: stage,
          services: _services(prefs: prefs, data: data, playback: playback),
        );

        await tester.pumpWidget(
          _stageHarness(controller: stage, immersion: immersion, enableMotion: false),
        );

        var heroSynced = 0;
        immersion.onCardHoverStart(
          hoverCard,
          scrolledDown: true,
          onBackdropReady: () => heroSynced++,
        );

        await tester.pump(const Duration(milliseconds: 450));
        expect(stage.activeBackdropKey, stageArtworkKey(hoverCard.art.stage));
        expect(stage.veilLifted, isTrue);
        expect(heroSynced, 0);

        final liftedVeil = EvStage.computeVeil(
          mode: EvStageMode.hero,
          scrollProgress: 0.8,
          detailNoBlur: false,
          veilLifted: true,
          isPaper: false,
        );
        final normalVeil = EvStage.computeVeil(
          mode: EvStageMode.hero,
          scrollProgress: 0.8,
          detailNoBlur: false,
          veilLifted: false,
          isPaper: false,
        );
        expect(liftedVeil.opacity, lessThan(normalVeil.opacity));
        expect(liftedVeil.blurSigma, lessThan(normalVeil.blurSigma));

        immersion.onCardHoverEnd(cardId: 'scrolled-card');
        await tester.pump();
        expect(stage.veilLifted, isFalse);
        expect(stage.activeBackdropKey, stageArtworkKey(baseCard.art.stage));

        immersion.dispose();
        stage.dispose();
        await playback.close();
        await prefs.close();
      },
    );

    testWidgets(
      'respects backgroundVideo preference toggle and custom delay',
      (tester) async {
        final prefs = _FakePreferences(
          const LocalPreferences(
            backgroundVideo: false,
            backgroundVideoDelay: Duration(milliseconds: 1000),
          ),
        );
        final clip = const _FakePreviewRef('clip-pref');
        final data = _FakeData(
          onThemeMedia: (_) async => ThemeMedia(backgroundVideo: clip),
        );
        final playback = _FakeImmersionPlayback();
        final stage = EvStageController();
        final immersion = Immersion(
          stage: stage,
          services: _services(prefs: prefs, data: data, playback: playback),
        );

        immersion.onCardHoverStart(_card('c1'));
        await tester.pump(const Duration(milliseconds: 2000));
        expect(data.themeMediaCalls, isEmpty);
        expect(playback.videoCalls, isEmpty);

        // Enable background video with 1.0s custom delay.
        await prefs.update(
          const LocalPreferences(
            backgroundVideo: true,
            backgroundVideoDelay: Duration(milliseconds: 1000),
          ),
        );
        immersion.onCardHoverStart(_card('c2'));
        await tester.pump(const Duration(milliseconds: 1050));
        expect(data.themeMediaCalls, ['c2']);
        expect(playback.videoCalls, [clip]);

        immersion.onCardHoverEnd();
        immersion.dispose();
        stage.dispose();
        await playback.close();
        await prefs.close();
      },
    );
  });

  group('C3.6 rapid sweep, focus/player stop, single-stream, and rebind', () {
    testWidgets(
      'sweeping 10 cards at 80ms each triggers 0 themeMedia/video calls and leaves 0 dangling timers',
      (tester) async {
        final prefs = _FakePreferences();
        final data = _FakeData(
          onThemeMedia: (_) async =>
              const ThemeMedia(backgroundVideo: _FakePreviewRef('clip')),
        );
        final playback = _FakeImmersionPlayback();
        final stage = EvStageController();
        final base = _card('base');
        stage.setBaseBackdrop(base.art.stage);
        final immersion = Immersion(
          stage: stage,
          services: _services(prefs: prefs, data: data, playback: playback),
        );

        await tester.pumpWidget(
          _stageHarness(controller: stage, immersion: immersion, enableMotion: false),
        );

        for (var i = 0; i < 10; i++) {
          final card = _card('sweep-$i');
          immersion.onCardHoverStart(card);
          await tester.pump(const Duration(milliseconds: 80));
        }
        immersion.onCardHoverEnd();

        // Advance well past 1.7s to guarantee no timer leaked.
        await tester.pump(const Duration(seconds: 3));
        expect(data.themeMediaCalls, isEmpty);
        expect(playback.videoCalls, isEmpty);
        expect(stage.activeBackdropKey, stageArtworkKey(base.art.stage));
        expect(stage.videoVisible, isFalse);

        immersion.dispose();
        stage.dispose();
        await playback.close();
        await prefs.close();
      },
    );

    testWidgets(
      'discards stale in-flight themeMedia response after card hover ends',
      (tester) async {
        final completer = Completer<ThemeMedia>();
        final prefs = _FakePreferences();
        final data = _FakeData(onThemeMedia: (_) => completer.future);
        final playback = _FakeImmersionPlayback();
        final stage = EvStageController();
        final immersion = Immersion(
          stage: stage,
          services: _services(prefs: prefs, data: data, playback: playback),
        );

        immersion.onCardHoverStart(_card('slow'));
        await tester.pump(const Duration(milliseconds: 1750));
        expect(data.themeMediaCalls, ['slow']);

        // User moves away before themeMedia finishes.
        immersion.onCardHoverEnd(cardId: 'slow');
        completer.complete(
          const ThemeMedia(backgroundVideo: _FakePreviewRef('late-clip')),
        );
        await tester.pump();

        expect(playback.videoCalls, isEmpty);
        expect(stage.videoVisible, isFalse);

        immersion.dispose();
        stage.dispose();
        await playback.close();
        await prefs.close();
      },
    );

    testWidgets(
      'window blur (lifecycle != resumed) and enterPlayer immediately stop video and theme',
      (tester) async {
        final prefs = _FakePreferences();
        final data = _FakeData();
        final playback = _FakeImmersionPlayback();
        final stage = EvStageController();
        final immersion = Immersion(
          stage: stage,
          services: _services(prefs: prefs, data: data, playback: playback),
        );

        await tester.pumpWidget(
          _stageHarness(controller: stage, immersion: immersion, enableMotion: false),
        );

        // Start one muted video + one theme song.
        const video = _FakePreviewRef('v1', name: '预告');
        const song = _FakePreviewRef('s1', name: '主题曲', duration: Duration(seconds: 60));
        await immersion.showMutedVideo(video, label: '预告片 · 静音');
        await immersion.playTheme(song);
        await tester.pump();
        expect(playback.activeVideo, video);
        expect(playback.activeTheme, song);
        expect(stage.videoVisible, isTrue);

        // Window loses focus -> EvStage WidgetsBindingObserver stops everything.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        expect(immersion.isWindowActive, isFalse);
        expect(playback.stopCalls, 1);
        expect(playback.activeVideo, isNull);
        expect(playback.activeTheme, isNull);
        expect(stage.videoVisible, isFalse);

        // While window inactive, starting new previews is ignored.
        await immersion.showMutedVideo(video);
        await immersion.playTheme(song);
        expect(playback.activeVideo, isNull);
        expect(playback.activeTheme, isNull);

        // Window regains focus -> previews allowed again.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(immersion.isWindowActive, isTrue);
        await immersion.showMutedVideo(video);
        await immersion.playTheme(song);
        expect(playback.activeVideo, video);
        expect(playback.activeTheme, song);

        // Enter main player -> immediately stops video and theme.
        immersion.enterPlayer();
        await tester.pump();
        expect(immersion.isPlayerActive, isTrue);
        expect(playback.stopCalls, 2);
        expect(playback.activeVideo, isNull);
        expect(playback.activeTheme, isNull);
        expect(stage.videoVisible, isFalse);

        // Blocked while player active, restored after exitPlayer.
        await immersion.playTheme(song);
        expect(playback.activeTheme, isNull);
        immersion.exitPlayer();
        await immersion.playTheme(song);
        expect(playback.activeTheme, song);

        immersion.dispose();
        stage.dispose();
        await playback.close();
        await prefs.close();
      },
    );

    test(
      'enforces single video & single theme, forwards mute, and stops old service on rebind',
      () async {
        final prefsA = _FakePreferences();
        final dataA = _FakeData();
        final playbackA = _FakeImmersionPlayback();
        final servicesA = _services(
          prefs: prefsA,
          data: dataA,
          playback: playbackA,
          sessionId: 'acct-a',
        );

        final prefsB = _FakePreferences();
        final dataB = _FakeData();
        final playbackB = _FakeImmersionPlayback();
        final servicesB = _services(
          prefs: prefsB,
          data: dataB,
          playback: playbackB,
          sessionId: 'acct-b',
        );

        final stage = EvStageController();
        final immersion = Immersion(stage: stage, services: servicesA);

        const v1 = _FakePreviewRef('v1');
        const v2 = _FakePreviewRef('v2');
        const s1 = _FakePreviewRef('s1');
        const s2 = _FakePreviewRef('s2');

        await immersion.showMutedVideo(v1);
        await immersion.showMutedVideo(v2);
        await immersion.playTheme(s1);
        await immersion.playTheme(s2);
        await immersion.setThemeMuted(true);

        expect(playbackA.activeVideo, v2);
        expect(playbackA.activeTheme, s2);
        expect(playbackA.muteCalls, [true]);
        expect(immersion.snapshot.themeMuted, isTrue);

        // Rebind to account B -> stops account A previews and clears stage preview.
        await immersion.rebind(servicesB);
        expect(playbackA.stopCalls, 1);
        expect(playbackA.activeVideo, isNull);
        expect(playbackA.activeTheme, isNull);
        expect(stage.videoVisible, isFalse);
        expect(stage.previewBackdrop, isNull);

        // Subsequent playback targets account B only.
        await immersion.showMutedVideo(v1);
        await immersion.playTheme(s1);
        expect(playbackB.activeVideo, v1);
        expect(playbackB.activeTheme, s1);
        expect(playbackA.activeVideo, isNull);

        immersion.dispose();
        stage.dispose();
        await playbackA.close();
        await playbackB.close();
        await prefsA.close();
        await prefsB.close();
      },
    );
  });

  group('EvStage visual modes, blurred fallback, and paper theme rules', () {
    testWidgets(
      'blurred poster fill disables Ken Burns and applies blur filter',
      (tester) async {
        final stage = EvStageController();
        stage.setBaseBackdrop(_card('poster-only', blurred: true).art.stage);

        await tester.pumpWidget(
          _stageHarness(controller: stage, enableMotion: true),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const Key('ev_stage_blurfill')), findsOneWidget);
        expect(find.byKey(const Key('ev_stage_kenburns')), findsNothing);

        stage.dispose();
      },
    );

    testWidgets(
      'paper theme renders warm bottom edge fading on scroll, and detailNoBlur / ambient specs match proto',
      (tester) async {
        final stage = EvStageController();
        stage
          ..setBaseBackdrop(_card('paper').art.stage)
          ..setMode(EvStageMode.detail, detailNoBlur: true);

        await tester.pumpWidget(
          _stageHarness(
            controller: stage,
            themeMode: ThemeMode.paper,
            enableMotion: false,
          ),
        );

        expect(find.byKey(const Key('ev_stage_paper_edge')), findsOneWidget);
        expect(
          tester.widget<AnimatedOpacity>(find.byKey(const Key('ev_stage_scrim'))).opacity,
          closeTo(1.0, 1e-6),
        );

        // Scrolling fades out paper scrim & bottom warm-white edge.
        stage.setScrollProgress(0.6);
        await tester.pump();
        expect(
          tester.widget<AnimatedOpacity>(find.byKey(const Key('ev_stage_scrim'))).opacity,
          closeTo(0.4, 1e-6),
        );

        // Detail series no-blur vs paper subtle blur.
        final cinemaSeries = EvStage.computeVeil(
          mode: EvStageMode.detail,
          scrollProgress: 1.0,
          detailNoBlur: true,
          veilLifted: false,
          isPaper: false,
        );
        expect(cinemaSeries.opacity, closeTo(0.62, 1e-6));
        expect(cinemaSeries.blurSigma, 0.0);

        final paperSeries = EvStage.computeVeil(
          mode: EvStageMode.detail,
          scrollProgress: 1.0,
          detailNoBlur: true,
          veilLifted: false,
          isPaper: true,
        );
        expect(paperSeries.opacity, closeTo(0.64, 1e-6));
        expect(paperSeries.blurSigma, closeTo(22.0, 1e-6));

        // Ambient mode hides scrim and softens frame.
        stage.setMode(EvStageMode.ambient);
        await tester.pump();
        expect(
          tester.widget<AnimatedOpacity>(find.byKey(const Key('ev_stage_scrim'))).opacity,
          0.0,
        );
        expect(
          tester.widget<AnimatedOpacity>(find.byKey(const Key('ev_stage_frame'))).opacity,
          closeTo(0.14, 1e-6),
        );
        expect(find.byKey(const Key('ev_stage_frame_boundary')), findsOneWidget);

        stage.dispose();
      },
    );

    testWidgets(
      'allowVideo: false skips video timer and EvStage avoids double rebuilds on scroll',
      (tester) async {
        final prefs = _FakePreferences();
        const clip = _FakePreviewRef('clip-skip');
        final data = _FakeData(onThemeMedia: (_) async => const ThemeMedia(backgroundVideo: clip));
        final playback = _FakeImmersionPlayback();
        final stage = EvStageController();
        final immersion = Immersion(
          stage: stage,
          services: _services(prefs: prefs, data: data, playback: playback),
        );

        await tester.pumpWidget(_stageHarness(controller: stage, immersion: immersion, enableMotion: false));
        immersion.onCardHoverStart(_card('paper-scroll'), scrolledDown: true, allowVideo: false);
        await tester.pump(const Duration(milliseconds: 2000));
        expect(stage.activeBackdropKey, stageArtworkKey(_card('paper-scroll').art.stage));
        expect(data.themeMediaCalls, isEmpty);
        expect(playback.videoCalls, isEmpty);

        // Track State rebuild count via Inherited/element dirtying when scrolling.
        final stageEl = tester.element(find.byType(EvStage));
        var stageNotifications = 0;
        stage.addListener(() => stageNotifications++);
        var immersionNotifications = 0;
        immersion.addListener(() => immersionNotifications++);
        stage.setScrollProgress(0.5);
        expect(stageNotifications, 1);
        expect(immersionNotifications, 1);
        expect(stageEl.dirty, isTrue);
        await tester.pump();
        expect(stageEl.dirty, isFalse);

        immersion.onCardHoverEnd();
        immersion.dispose();
        stage.dispose();
        await playback.close();
        await prefs.close();
      },
    );
  });
}
