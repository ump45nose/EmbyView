import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/entry.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/ev_player_page.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_credits_overlay.dart';

class _TestSession implements PlaybackSession {
  _TestSession(this._snapshot);

  PlaybackSnapshot _snapshot;
  final _ctrl = StreamController<PlaybackSnapshot>.broadcast();

  final List<Duration> seekByCalls = [];
  final List<Duration> seekCalls = [];
  final List<double> volumeCalls = [];
  final List<bool> muteCalls = [];
  final List<bool> fullscreenCalls = [];
  final List<bool> anime4kCalls = [];
  final List<double?> compareSplits = [];
  final List<bool> playNextFinish = [];
  int pauseCalls = 0, resumeCalls = 0, dismissCreditsCalls = 0, closeCalls = 0;

  @override PlaybackSnapshot get snapshot => _snapshot;
  @override Stream<PlaybackSnapshot> get changes => _ctrl.stream;

  void emit(PlaybackSnapshot next) {
    _snapshot = next;
    _ctrl.add(next);
  }

  @override Widget videoSurface({Key? key}) => ColoredBox(key: key ?? const Key('fake_video'), color: const Color(0xFF101018));
  @override Future<void> resume() async { resumeCalls++; emit(_copy(phase: PlaybackPhase.playing)); }
  @override Future<void> pause() async { pauseCalls++; emit(_copy(phase: PlaybackPhase.paused)); }
  @override Future<void> seek(Duration pos) async { seekCalls.add(pos); emit(_copy(position: pos)); }
  @override Future<void> seekBy(Duration delta) async { seekByCalls.add(delta); emit(_copy(position: _snapshot.position + delta)); }
  @override Future<void> setVolume(double fraction) async { volumeCalls.add(fraction); emit(_copy(volume: fraction)); }
  @override Future<void> setMuted(bool muted) async { muteCalls.add(muted); emit(_copy(muted: muted)); }
  @override Future<void> selectAudio(String trackId) async => emit(_copy(selectedAudioId: trackId));
  @override Future<void> selectSubtitle(String? trackId) async => emit(_copy(selectedSubtitleId: trackId, clearSub: trackId == null));
  @override Future<void> setAnime4k(bool enabled) async => anime4kCalls.add(enabled);
  @override Future<void> setAnime4kComparison(double? split) async => compareSplits.add(split);
  @override Future<void> setPictureInPicture(bool enabled) async => emit(_copy(pip: enabled));
  @override Future<void> setFullscreen(bool enabled) async { fullscreenCalls.add(enabled); emit(_copy(fullscreen: enabled)); }
  @override Future<void> playNext({bool finishCurrent = false}) async => playNextFinish.add(finishCurrent);
  @override Future<void> dismissCreditsPrompt() async { dismissCreditsCalls++; emit(_copy(creditsPrompt: CreditsPromptState.dismissed)); }
  @override Future<ThumbnailFrame?> thumbnailAt(Duration position) async => null;
  @override Future<void> close() async { closeCalls++; await _ctrl.close(); }

  PlaybackSnapshot _copy({
    int? generation,
    PlaybackPhase? phase,
    Duration? position,
    double? volume,
    bool? muted,
    String? selectedAudioId,
    String? selectedSubtitleId,
    bool clearSub = false,
    bool? pip,
    bool? fullscreen,
    CreditsPromptState? creditsPrompt,
    Anime4kSnapshot? anime4k,
  }) => PlaybackSnapshot(
    generation: generation ?? _snapshot.generation,
    target: _snapshot.target,
    item: _snapshot.item,
    phase: phase ?? _snapshot.phase,
    firstFrameLatency: _snapshot.firstFrameLatency,
    position: position ?? _snapshot.position,
    duration: _snapshot.duration,
    bufferedUntil: _snapshot.bufferedUntil,
    quality: _snapshot.quality,
    chapters: _snapshot.chapters,
    audioTracks: _snapshot.audioTracks,
    subtitleTracks: _snapshot.subtitleTracks,
    selectedAudioId: selectedAudioId ?? _snapshot.selectedAudioId,
    selectedSubtitleId: clearSub ? null : (selectedSubtitleId ?? _snapshot.selectedSubtitleId),
    volume: volume ?? _snapshot.volume,
    muted: muted ?? _snapshot.muted,
    nextEpisode: _snapshot.nextEpisode,
    creditsPrompt: creditsPrompt ?? _snapshot.creditsPrompt,
    fullscreenSupported: true,
    fullscreen: fullscreen ?? _snapshot.fullscreen,
    pictureInPictureSupported: true,
    pictureInPicture: pip ?? _snapshot.pictureInPicture,
    anime4k: anime4k ?? _snapshot.anime4k,
  );
}

class _TestPlayback implements EmbyViewPlayback {
  _TestPlayback(this.session);
  final _TestSession session;
  @override Future<void> prepare(String itemId) async {}
  @override PlaybackSession open(PlayTarget target) => session;
}

class _TestSubtitlePanel implements SubtitlePanel {
  _TestSubtitlePanel(this._snap);
  SubtitleSnapshot _snap;
  final _ctrl = StreamController<SubtitleSnapshot>.broadcast();
  int closeCalls = 0;

  @override SubtitleSnapshot get snapshot => _snap;
  @override Stream<SubtitleSnapshot> get changes => _ctrl.stream;
  void emit(SubtitleSnapshot next) { _snap = next; _ctrl.add(next); }

  @override Future<List<SubtitleSearchGroup>> search(String? text) async => const [];
  @override Future<void> useCandidate(SubtitleCandidate candidate) async {}
  @override Future<void> startAi() async {}
  @override Future<void> cancelAi() async {}
  @override Future<void> translate(String trackId) async {}
  @override Future<void> align(String trackId) async {}
  @override Future<void> retrySave(String trackId) async {}
  @override Future<void> close() async { closeCalls++; await _ctrl.close(); }
}

class _TestSubtitles implements EmbyViewSubtitles {
  _TestSubtitles(this.panel);
  final _TestSubtitlePanel panel;
  int bindCalls = 0;
  @override SubtitlePanel bind(PlaybackSession session) { bindCalls++; return panel; }
  @override Future<SubtitleAvailability> availability(String itemId) async => const SubtitleAvailability();
  @override Future<SeasonQuote> quoteSeason(String seriesId, String seasonId) async => throw UnimplementedError();
  @override Future<String> queueSeason(SeasonQuote quote) async => throw UnimplementedError();
  @override Future<AiUsage> usage() async => const AiUsage(month: '2026-11');
  @override Stream<List<SeasonJob>> get jobs => const Stream.empty();
  @override Future<void> cancelJob(String jobId, {String? episodeId}) async {}
}

class _StubPrefs implements EmbyViewPreferences {
  @override LocalPreferences get current => const LocalPreferences();
  @override Stream<LocalPreferences> get changes => const Stream.empty();
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubAccounts implements EmbyViewAccounts {
  @override AccountSnapshot get snapshot => const AccountSnapshot(phase: AccountPhase.signedIn);
  @override Stream<AccountSnapshot> get changes => const Stream.empty();
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

PlaybackSnapshot _initialSnap() {
  const ep9 = MediaCard(
    id: 'ep9', kind: MediaKind.episode, title: '出征的号角', seriesId: 's1', seasonId: 'sea1', episodeNumber: 9,
    duration: Duration(minutes: 24), overview: '决战前夜的故事。',
    quality: MediaQuality(origin: MediaOrigin.direct115, resolution: '1080p'),
  );
  const ep10 = MediaCard(id: 'ep10', kind: MediaKind.episode, title: '山脊破晓', seriesId: 's1', seasonId: 'sea1', episodeNumber: 10, overview: '新的黎明。');
  return const PlaybackSnapshot(
    generation: 1,
    target: PlayTarget(itemId: 'ep9', seriesId: 's1', seasonId: 'sea1', episodeNumber: 9),
    item: ep9,
    phase: PlaybackPhase.preparing,
    position: Duration(minutes: 5),
    duration: Duration(minutes: 24),
    bufferedUntil: Duration(minutes: 12),
    nextEpisode: ep10,
    volume: 0.7,
    audioTracks: [PlaybackTrack(id: 'ja', name: '日语', language: 'ja', source: PlaybackTrackSource.embedded)],
    subtitleTracks: [PlaybackTrack(id: 'emb', name: '简体中文', language: 'zh', source: PlaybackTrackSource.embedded)],
    selectedAudioId: 'ja',
    selectedSubtitleId: 'emb',
  );
}

void main() {
  testWidgets('full EvPlayerPage lifecycle via entry.dart registration, controls, keyboard, credits, generation reset & Esc focus restore', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    expect(embyViewRegistration.stageFivePlayer, isNotNull);

    final session = _TestSession(_initialSnap());
    final subPanel = _TestSubtitlePanel(const SubtitleSnapshot(generation: 1, cues: null));
    final subtitles = _TestSubtitles(subPanel);
    final playback = _TestPlayback(session);
    final playBtnFocus = FocusNode(debugLabel: 'detail_play_btn');
    addTearDown(playBtnFocus.dispose);

    final services = EmbyViewServices(
      preferences: _StubPrefs(),
      accounts: _StubAccounts(),
      playback: playback,
      subtitles: subtitles,
    );

    final stage = EvStageController();
    final immersion = Immersion(stage: stage, services: services);
    final shell = EvShellController();
    addTearDown(() {
      immersion.dispose();
      stage.dispose();
      shell.dispose();
    });

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1.0),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: EvScope(
              services: services,
              stage: stage,
              immersion: immersion,
              shell: shell,
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (ctx, _, _) => Center(
                    child: Focus(
                      focusNode: playBtnFocus,
                      autofocus: true,
                      child: GestureDetector(
                        key: const Key('detail_play_trigger'),
                        onTap: () => unawaited(EvPlayer.open(ctx, const PlayTarget(itemId: 'ep9'))),
                        child: const Text('播放'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(playBtnFocus.hasFocus, isTrue);

    // 1. Open stage five player through EvPlayer.open (opening shimmer repeats while preparing)
    await tester.tap(find.byKey(const Key('detail_play_trigger')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(EvPlayerPage), findsOneWidget);
    expect(subtitles.bindCalls, 1);
    expect(find.text('正在预解析 115 地址…'), findsOneWidget);

    // 2. First frame arrives -> opening overlay fades out -> OSD controls visible
    session.emit(session._copy(phase: PlaybackPhase.playing));
    await tester.pump(); // post-frame records latency
    await tester.pump(const Duration(milliseconds: 900));
    final openingOp = tester.widget<AnimatedOpacity>(find.byKey(const Key('ev_player_opening')));
    expect(openingOp.opacity, 0.0);

    // 3. Idle 3.2s hides OSD controls; pointer move brings them back
    await tester.pump(const Duration(milliseconds: 3300));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<IgnorePointer>(find.ancestor(of: find.byKey(const Key('ev_player_play_pause')), matching: find.byType(IgnorePointer)).first).ignoring, isTrue);

    final pointer = await tester.createGesture();
    await pointer.addPointer(location: const Offset(400, 400));
    await pointer.moveTo(const Offset(500, 400));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<IgnorePointer>(find.ancestor(of: find.byKey(const Key('ev_player_play_pause')), matching: find.byType(IgnorePointer)).first).ignoring, isFalse);

    // 4. Space pauses -> after 1.5s pause card appears -> Space resumes & hides card
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 700));
    expect(session.pauseCalls, 1);
    expect(tester.widget<AnimatedOpacity>(find.ancestor(of: find.byKey(const Key('ev_player_pause_card')), matching: find.byType(AnimatedOpacity)).first).opacity, 1.0);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 700));
    expect(session.resumeCalls, 1);
    expect(tester.widget<AnimatedOpacity>(find.ancestor(of: find.byKey(const Key('ev_player_pause_card')), matching: find.byType(AnimatedOpacity)).first).opacity, 0.0);

    // 5. Keyboard shortcuts: Left/Right ±10s, Up/Down volume, M mute, F fullscreen
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.seekByCalls, [const Duration(seconds: 10), const Duration(seconds: -10)]);
    expect(session.volumeCalls.length, 2);
    expect(session.muteCalls, [true]);
    expect(session.fullscreenCalls, [true]);

    // 6. Open panel -> video frame insets for panel; typing in search box does not trigger Space shortcut
    await tester.tap(find.byKey(const Key('ev_player_tab_subs')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.widget<EvCreditsVideoFrame>(find.byType(EvCreditsVideoFrame)).panelOpen, isTrue);

    await tester.ensureVisible(find.byKey(const Key('ev_sub_search_input')));
    await tester.tap(find.byKey(const Key('ev_sub_search_input')));
    await tester.pump();
    final pausesBeforeType = session.pauseCalls;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(session.pauseCalls, pausesBeforeType);
    // Esc blurs text input first, then next Esc closes panel
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<EvCreditsVideoFrame>(find.byType(EvCreditsVideoFrame)).panelOpen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.widget<EvCreditsVideoFrame>(find.byType(EvCreditsVideoFrame)).panelOpen, isFalse);

    // 7. Anime4K active triggers compare sweep; Esc closes compare
    session.emit(session._copy(anime4k: const Anime4kSnapshot(
      supported: true, requested: true, state: Anime4kState.active,
      comparison: ComparisonState.available,
      originalSize: VideoSize(width: 1920, height: 1080),
      enhancedSize: VideoSize(width: 3840, height: 2160),
    )));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<IgnorePointer>(find.byKey(const Key('ev_anime4k_compare_overlay'))).ignoring, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<IgnorePointer>(find.byKey(const Key('ev_anime4k_compare_overlay'))).ignoring, isTrue);
    expect(session.compareSplits.last, isNull);

    // 8. Credits prompt: tap 看完片尾 calls dismissCreditsPrompt; re-entering countdown auto-calls playNext(finishCurrent: true)
    session.emit(session._copy(creditsPrompt: CreditsPromptState.countingDown));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 950));
    expect(find.byKey(const Key('ev_credits_stay')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ev_credits_stay')));
    await tester.pump();
    expect(session.dismissCreditsCalls, 1);

    // Generation 2 resets state and runs credits countdown to 0
    session.emit(session._copy(generation: 2, phase: PlaybackPhase.playing, creditsPrompt: CreditsPromptState.countingDown));
    await tester.pump(); // post-frame
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 600));
    expect(session.playNextFinish, [true]);

    // 9. Final Esc exits player, closes session & subtitle panel, restores play button focus
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(EvPlayerPage), findsNothing);
    expect(session.closeCalls, 1);
    expect(subPanel.closeCalls, 1);
    expect(playBtnFocus.hasFocus, isTrue);
  });
}
