import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moonfin/playback/mpv_player_registry.dart';
import 'package:moonfin/util/app_exit.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/entry.dart';
import 'package:moonfin/embyview/ui/detail/ev_detail_page.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_controls.dart';
import 'package:moonfin/embyview/ui/player/ev_player_page.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_credits_overlay.dart';
import 'package:moonfin/embyview/ui/player/overlays/ev_player_toast.dart';
import 'package:moonfin/embyview/ui/shell/ev_menu_channel.dart';

final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _FakeArt implements ArtworkRef {
  _FakeArt(this.id) : cacheKey = 'p5_$id', image = MemoryImage(_kPngBytes);
  @override final String id, cacheKey;
  @override final ImageProvider<Object> image;
  @override double? get aspectRatio => 16 / 9;
  @override int? get width => 1;
  @override int? get height => 1;
}

class _TestSession implements PlaybackSession {
  _TestSession(this._snapshot, {this.onThumbnail, this.onClose});
  final Future<void> Function()? onClose;

  PlaybackSnapshot _snapshot;
  final Future<ThumbnailFrame?> Function(Duration position)? onThumbnail;
  final _ctrl = StreamController<PlaybackSnapshot>.broadcast();

  final List<Duration> seekByCalls = [];
  final List<Duration> seekCalls = [];
  final List<double> volumeCalls = [];
  final List<bool> muteCalls = [];
  final List<bool> fullscreenCalls = [];
  final List<bool> anime4kCalls = [];
  final List<double?> compareSplits = [];
  final List<bool> playNextFinish = [];
  int pauseCalls = 0, resumeCalls = 0, retryOpenCalls = 0, dismissCreditsCalls = 0, closeCalls = 0;

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
  @override Future<void> selectSecondarySubtitle(String? trackId) async => emit(_copy(secondarySubtitleId: trackId, clearSecondary: trackId == null));
  @override Future<void> setAnime4k(bool enabled) async => anime4kCalls.add(enabled);
  @override Future<void> setAnime4kComparison(double? split) async => compareSplits.add(split);
  @override Future<void> setPictureInPicture(bool enabled) async => emit(_copy(pip: enabled));
  @override Future<void> setFullscreen(bool enabled) async { fullscreenCalls.add(enabled); emit(_copy(fullscreen: enabled)); }
  @override Future<void> playNext({bool finishCurrent = false}) async => playNextFinish.add(finishCurrent);
  @override Future<void> dismissCreditsPrompt() async { dismissCreditsCalls++; emit(_copy(creditsPrompt: CreditsPromptState.dismissed)); }
  @override Future<ThumbnailFrame?> thumbnailAt(Duration position) async => onThumbnail != null ? onThumbnail!(position) : null;
  @override Future<void> retryOpen() async { retryOpenCalls++; emit(_copy(phase: PlaybackPhase.preparing)); }
  @override Future<void> close() async { closeCalls++; await onClose?.call(); await _ctrl.close(); }

  PlaybackSnapshot _copy({
    int? generation,
    PlaybackPhase? phase,
    Duration? position,
    double? volume,
    bool? muted,
    String? selectedAudioId,
    String? selectedSubtitleId,
    bool clearSub = false,
    String? secondarySubtitleId,
    bool clearSecondary = false,
    ({int revision, String message})? subtitleSelectionNotice,
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
    secondarySubtitleId: clearSecondary ? null : (secondarySubtitleId ?? _snapshot.secondarySubtitleId),
    subtitleSelectionNotice: subtitleSelectionNotice,
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
  @override Future<void> prepare(String itemId, {String? mediaSourceId}) async {}
  @override PlaybackSession open(PlayTarget target) => session;
}

class _TestSubtitlePanel implements SubtitlePanel {
  _TestSubtitlePanel(this._snap, {this.onSearch});
  SubtitleSnapshot _snap;
  final Future<List<SubtitleSearchGroup>> Function(String? text)? onSearch;
  final _ctrl = StreamController<SubtitleSnapshot>.broadcast();
  int closeCalls = 0;

  @override SubtitleSnapshot get snapshot => _snap;
  @override Stream<SubtitleSnapshot> get changes => _ctrl.stream;
  void emit(SubtitleSnapshot next) { _snap = next; _ctrl.add(next); }

  @override Future<List<SubtitleSearchGroup>> search(String? text) async => onSearch != null ? onSearch!(text) : const [];
  @override Future<void> useCandidate(SubtitleCandidate candidate) async {}
  @override Future<void> startAi() async {}
  @override Future<void> cancelAi() async {}
  @override Future<void> translate(String trackId) async {}
  @override Future<void> align(String trackId) async {}
  @override Future<void> retrySave(String trackId) async {}
  @override Future<void> close() async { closeCalls++; await _ctrl.close(); }
}

class _TestSubtitles implements EmbyViewSubtitles {
  _TestSubtitles(this.panel, {this.onQuoteSeason});
  final _TestSubtitlePanel panel;
  final Future<SeasonQuote> Function(String seriesId, String seasonId)? onQuoteSeason;
  int bindCalls = 0;
  @override SubtitlePanel bind(PlaybackSession session) { bindCalls++; return panel; }
  @override Future<SubtitleAvailability> availability(String itemId) async => const SubtitleAvailability();
  @override Future<SeasonQuote> quoteSeason(String seriesId, String seasonId) async =>
      onQuoteSeason != null ? onQuoteSeason!(seriesId, seasonId) : throw UnimplementedError();
  @override Future<String> queueSeason(SeasonQuote quote) async => throw UnimplementedError();
  @override Future<AiUsage> usage() async => const AiUsage(month: '2026-11');
  @override Stream<List<SeasonJob>> get jobs => const Stream.empty();
  @override Future<void> cancelJob(String jobId, {String? episodeId}) async {}
}

class _StubPrefs implements EmbyViewPreferences {
  _StubPrefs([this._current = const LocalPreferences()]);
  final LocalPreferences _current;
  @override LocalPreferences get current => _current;
  @override Stream<LocalPreferences> get changes => const Stream.empty();
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubAccounts implements EmbyViewAccounts {
  @override AccountSnapshot get snapshot => const AccountSnapshot(
    phase: AccountPhase.signedIn,
    current: AccountProfile(id: 'alice', displayName: 'Alice'),
    profiles: [AccountProfile(id: 'alice', displayName: 'Alice')],
  );
  @override Stream<AccountSnapshot> get changes => const Stream.empty();
  @override Stream<ConnectionNoticeEvent> get connectionNotices => const Stream.empty();
  @override Future<Uri?> probeAndFailover({Duration timeout = const Duration(seconds: 5)}) async => null;
  @override Future<void> retryConnection() async {}
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubDetailData implements EmbyViewData {
  _StubDetailData(this.itemDetail);
  final MediaDetail itemDetail;

  @override Future<List<ZoneTile>> zones() async => const [];
  @override Future<MediaDetail> detail(String itemId) async => itemDetail;
  @override Future<List<PersonCredit>> people(String itemId) async => const [];
  @override Future<List<MediaCard>> similar(String itemId, {int limit = 16}) async => const [];
  @override Future<ThemeMedia> themeMedia(String itemId) async => const ThemeMedia();
  @override Future<MediaQuality?> quality(String itemId) async => itemDetail.card.quality;
  @override Future<List<SeasonSummary>> seasons(String seriesId) async => const [];
  @override Future<List<SafeEpisodeStill>> safeEpisodeStills(String seriesId) async => const [];
  @override Future<SeasonEpisodes> episodes(String seriesId, String seasonId) async => const SeasonEpisodes(
    season: SeasonSummary(id: 'sea1', number: 1, name: '第 1 季', total: 0),
    episodes: [],
    playedCount: 0,
  );
  @override Future<void> setFavorite(String itemId, bool favorite) async {}
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

class _ExitTestPlayer extends Fake implements Player {
  bool disposed = false;
  @override
  Future<void> dispose() async { disposed = true; }
}

void main() {
  testWidgets('application exit waits for playback stop, shares close with route pop and notifies only after drain', (tester) async {
    final gate = Completer<void>();
    final session = _TestSession(_initialSnap(), onClose: () => gate.future);
    final services = EmbyViewServices(preferences: _StubPrefs(), accounts: _StubAccounts(), playback: _TestPlayback(session));
    final stage = EvStageController();
    final immersion = Immersion(stage: stage, services: services);
    final shell = EvShellController();
    final events = <EvPlaybackEnded>[];
    final sub = shell.playbackEnded.listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      immersion.dispose();
      stage.dispose();
      shell.dispose();
    });
    final player = _ExitTestPlayer();
    MpvPlayerRegistry.instance.track(player);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: EvScope(services: services, stage: stage, immersion: immersion, shell: shell,
        child: Navigator(key: nav, onGenerateRoute: (_) => PageRouteBuilder<void>(
          pageBuilder: (ctx, _, _) => GestureDetector(
            key: const Key('exit_play'),
            onTap: () => unawaited(EvPlayer.open(ctx, const PlayTarget(itemId: 'ep9'), builder: (_, _, {origin, art}) => const SizedBox.expand())),
            child: const Text('play'),
          ),
        )),
      ),
    ));
    await tester.tap(find.byKey(const Key('exit_play')));
    await tester.pumpAndSettle();

    final exiting = AppExit.prepareForExit();
    await tester.pump();
    expect(session.closeCalls, 1);
    expect(player.disposed, isFalse);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(session.closeCalls, 1);
    expect(events, isEmpty);
    expect(player.disposed, isFalse);

    gate.complete();
    await tester.pumpAndSettle();
    await exiting;
    expect(player.disposed, isTrue);
    expect(session.closeCalls, 1);
    expect(events.single.targets.first.itemId, 'ep9');
    expect(EvPlayer.isOpening, isFalse);
  });

  testWidgets('player panel dispatches sidecar overlay selection and clearing to playback session', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = _TestSession(const PlaybackSnapshot(
      generation: 1, target: PlayTarget(itemId: 'movie'), phase: PlaybackPhase.playing,
      selectedSubtitleId: 'primary',
      subtitleTracks: [
        PlaybackTrack(id: 'primary', name: '中文', source: PlaybackTrackSource.embedded, format: 'ass'),
        PlaybackTrack(id: 'secondary', name: 'English', source: PlaybackTrackSource.nas, format: 'srt', supportsSecondarySubtitle: true),
      ],
    ));
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1),
      child: Directionality(textDirection: TextDirection.ltr,
        child: EvThemeScope(themeMode: ThemeMode.cinema,
          child: EvPlayerPage(session: session, initialPanelOpen: true))),
    ));
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('ev_sub_secondary_secondary'));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(session.snapshot.selectedSubtitleId, 'primary');
    expect(session.snapshot.secondarySubtitleId, 'secondary');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(session.snapshot.secondarySubtitleId, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('subtitle failure uses the existing toast once on the active playback', (tester) async {
    final session = _TestSession(_initialSnap()._withPhase(PlaybackPhase.playing));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1.0),
        child: Directionality(textDirection: TextDirection.ltr,
          child: EvThemeScope(themeMode: ThemeMode.cinema,
            child: EvPlayerPage(session: session))),
      ),
    );
    await tester.pump(const Duration(milliseconds: 900));
    const notice = (revision: 1, message: '字幕加载失败，已切回 原轨');
    session.emit(session._copy(subtitleSelectionNotice: notice));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(notice.message), findsOneWidget);
    session.emit(session._copy(subtitleSelectionNotice: notice));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3400));
    expect(tester.widget<EvPlayerToast>(find.byType(EvPlayerToast)).visible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });

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

  testWidgets('P0 regression: buildStageFourTestShell detail mouse click inherits paper theme & subtitles in root Navigator and restores play button focus on Esc', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final bg = _FakeArt('detail_bg');
    final movieCard = MediaCard(
      id: 'm1', kind: MediaKind.movie, title: '纸面影院测试片', year: 2026,
      duration: const Duration(minutes: 120), overview: '测试从详情页点击播放按钮进入播放器。',
      quality: const MediaQuality(origin: MediaOrigin.nasLocal, resolution: '4K'),
      art: CardArtwork(
        stage: ArtworkPlan(layers: [ArtworkLayer(source: bg, fit: ArtworkFit.cover)], fallbackTitle: '纸面影院测试片'),
        backdrops: [bg],
      ),
    );
    final detail = MediaDetail(card: movieCard, playTarget: const PlayTarget(itemId: 'm1'));
    final session = _TestSession(_initialSnap()._withPhase(PlaybackPhase.playing));
    final subPanel = _TestSubtitlePanel(const SubtitleSnapshot(generation: 1, cues: null));
    final subtitles = _TestSubtitles(subPanel);
    final services = EmbyViewServices(
      sessionId: 'sess-p0-paper',
      preferences: _StubPrefs(const LocalPreferences(theme: ThemeMode.paper, detailTrailerDelay: null, themeMusic: false)),
      accounts: _StubAccounts(),
      data: _StubDetailData(detail),
      playback: _TestPlayback(session),
      subtitles: subtitles,
    );

    // Mount buildStageFourTestShell UNDER root Navigator (matching real app router topology).
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1.0),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (_, _, _) => buildStageFourTestShell(services: services, initialDetailId: 'm1'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(EvDetailPage), findsOneWidget);
    expect(find.byKey(const Key('ev_detail_play_btn')), findsOneWidget);

    // Ensure play button is NOT focused before mouse tap.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    bool isPlayBtnFocused() {
      final ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return false;
      var matched = false;
      if (ctx.widget.key == const Key('ev_detail_play_btn')) return true;
      ctx.visitAncestorElements((el) {
        if (el.widget.key == const Key('ev_detail_play_btn')) {
          matched = true;
          return false;
        }
        return true;
      });
      return matched;
    }
    expect(isPlayBtnFocused(), isFalse);

    // Mouse tap directly on unfocused ev_detail_play_btn -> EvPlayer.open on root Navigator.
    await tester.tap(find.byKey(const Key('ev_detail_play_btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byType(EvPlayerPage), findsOneWidget);
    expect(subtitles.bindCalls, 1);
    final playerEl = tester.element(find.byType(EvPlayerPage));
    expect(EvTheme.of(playerEl).isPaper, isTrue);

    // Verify terracotta play button (paper theme) and full subtitle panel (AI card + online search).
    final playBox = tester.widget<AnimatedContainer>(
      find.descendant(of: find.byKey(const Key('ev_player_play_pause')), matching: find.byType(AnimatedContainer)),
    );
    expect((playBox.decoration as BoxDecoration).color, const Color(0xFFB5532F));

    await tester.tap(find.byKey(const Key('ev_player_tab_subs')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byKey(const Key('ev_ai_card')), findsOneWidget);
    expect(find.byKey(const Key('ev_sub_online_search')), findsOneWidget);

    // Esc closes panel, second Esc exits player -> focus returns precisely to ev_detail_play_btn.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(EvPlayerPage), findsNothing);
    expect(find.byType(EvDetailPage), findsOneWidget);
    expect(isPlayBtnFocused(), isTrue);
  });

  testWidgets('P0/P1 regression: closing panel with mouse while search input focused immediately restores Space & Esc player shortcuts', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final session = _TestSession(_initialSnap()._withPhase(PlaybackPhase.playing));
    final subPanel = _TestSubtitlePanel(const SubtitleSnapshot(generation: 1, cues: null));
    final subtitles = _TestSubtitles(subPanel);
    var closed = 0;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1.0),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: EvPlayerPage(
              session: session,
              subtitles: subtitles,
              initialPanelOpen: true,
              initialPanelTab: 'subs',
              onClose: () => closed++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    // Focus the search box inside the panel.
    await tester.ensureVisible(find.byKey(const Key('ev_sub_search_input')));
    await tester.tap(find.byKey(const Key('ev_sub_search_input')));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ev_sub_search_focus');

    // Close panel via mouse click on ev_panel_close (not Esc).
    await tester.tap(find.byKey(const Key('ev_panel_close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    // Space and Esc must work immediately on the main player.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(session.pauseCalls, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('P1 regression: generation switch with same duration clears thumbnail, filters stale subtitle/AI snapshot, cancels in-flight requests, and triggers compare sweep when comparison becomes available', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final thumbCompleters = <Completer<ThumbnailFrame?>>[];
    final searchCompleters = <Completer<List<SubtitleSearchGroup>>>[];
    final quoteCompleters = <Completer<SeasonQuote>>[];

    final session = _TestSession(
      _initialSnap()._withPhase(PlaybackPhase.playing),
      onThumbnail: (_) {
        final c = Completer<ThumbnailFrame?>();
        thumbCompleters.add(c);
        return c.future;
      },
    );
    const gen1Cue = SubtitleCue(
      id: 'g1c1', start: Duration(minutes: 4), end: Duration(minutes: 6),
      text: 'Old line', translation: '旧集对白不应残留',
    );
    final subPanel = _TestSubtitlePanel(
      const SubtitleSnapshot(
        generation: 1,
        selectedTrackId: 'ai_1',
        tracks: [SubtitleTrackState(trackId: 'ai_1', origin: SubtitleOrigin.ai, active: true)],
        ai: AiRun(
          generation: 1, state: AiRunState.generating, startedAt: Duration(minutes: 4),
          coverageEnd: Duration(minutes: 10), cues: [gen1Cue],
        ),
        cues: null,
      ),
      onSearch: (_) {
        final c = Completer<List<SubtitleSearchGroup>>();
        searchCompleters.add(c);
        return c.future;
      },
    );
    final subtitles = _TestSubtitles(
      subPanel,
      onQuoteSeason: (_, _) {
        final c = Completer<SeasonQuote>();
        quoteCompleters.add(c);
        return c.future;
      },
    );

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1.0),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: EvPlayerPage(session: session, subtitles: subtitles, initialPanelOpen: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Trigger scrub bar hover thumbnail and resolve it on gen 1.
    final scrubRect = tester.getRect(find.byKey(const Key('ev_player_scrub_bar')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(Offset(scrubRect.left + scrubRect.width * 0.4, scrubRect.top + 8));
    await tester.pump(const Duration(milliseconds: 50));
    expect(thumbCompleters, isNotEmpty);
    thumbCompleters.first.complete(ThumbnailFrame(image: _FakeArt('gen1_thumb'), position: const Duration(minutes: 9)));
    await tester.pump();
    expect(find.byKey(const ValueKey('ev_trick_img_p5_gen1_thumb')), findsOneWidget);

    // Start in-flight season quote on gen 1 (and auto-search is also pending on gen 1).
    await tester.ensureVisible(find.byKey(const Key('ev_ai_season')));
    await tester.tap(find.byKey(const Key('ev_ai_season')));
    await tester.pump();
    expect(quoteCompleters.length, 1);
    expect(searchCompleters.length, 1);
    expect(find.byKey(const Key('ev_player_aurora')), findsOneWidget);

    // Advance to generation 2 with the EXACT SAME 24m duration (no gen-2 subtitle snapshot emitted yet).
    session.emit(session._copy(generation: 2, phase: PlaybackPhase.playing));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Gen-1 thumbnail cleared, gen-1 aurora & AI generating state filtered out, quoting indicator reset.
    expect(find.byKey(const ValueKey('ev_trick_img_p5_gen1_thumb')), findsNothing);
    expect(find.byKey(const Key('ev_player_aurora')), findsNothing);
    expect(find.text('未开启'), findsOneWidget);
    expect(find.text('正在估算整季费用…'), findsNothing);

    // Completing stale gen-1 search & quoteSeason futures MUST NOT pollute gen-2 UI.
    searchCompleters.first.complete(const [
      SubtitleSearchGroup(
        source: SubtitleSource.xunlei,
        candidates: [SubtitleCandidate(id: 'stale1', source: SubtitleSource.xunlei, name: '旧集幽灵字幕')],
      ),
    ]);
    quoteCompleters.first.complete(const SeasonQuote(
      id: 'stale_q', seriesId: 's1', seasonId: 'sea1', seasonName: '旧季报价',
      episodeIds: ['ep1'], completedCount: 0, pendingCount: 1, estimatedCostMicros: 100000, budget: BudgetState.available,
    ));
    await tester.pump();
    expect(find.text('旧集幽灵字幕'), findsNothing);
    expect(find.byKey(const Key('ev_ai_season_quote')), findsNothing);

    // Anime4K active with unavailable comparison first, then comparison becomes available -> triggers auto-sweep once.
    session.emit(session._copy(
      generation: 2,
      anime4k: const Anime4kSnapshot(supported: true, requested: true, state: Anime4kState.active, comparison: ComparisonState.unavailable),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<IgnorePointer>(find.byKey(const Key('ev_anime4k_compare_overlay'))).ignoring, isTrue);

    session.emit(session._copy(
      generation: 2,
      anime4k: const Anime4kSnapshot(supported: true, requested: true, state: Anime4kState.active, comparison: ComparisonState.available),
    ));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.widget<IgnorePointer>(find.byKey(const Key('ev_anime4k_compare_overlay'))).ignoring, isFalse);
  });

  testWidgets('dismissing credits via 看完片尾 shows OSD controls immediately and auto-hides after 3.2s idle', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final session = _TestSession(_initialSnap()._withPhase(PlaybackPhase.playing));

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1.0),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: EvPlayerPage(session: session),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    // Wait past 3.2s idle so controls auto-hide before credits prompt arrives.
    await tester.pump(const Duration(milliseconds: 3400));
    expect(tester.widget<EvPlayerControls>(find.byType(EvPlayerControls)).visible, isFalse);

    // Enter credits countdown -> controls stay hidden during credits.
    session.emit(session._copy(creditsPrompt: CreditsPromptState.countingDown));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 950));
    expect(tester.widget<EvPlayerControls>(find.byType(EvPlayerControls)).visible, isFalse);

    // Click 看完片尾 -> controls & logo/title appear immediately.
    await tester.tap(find.byKey(const Key('ev_credits_stay')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(session.dismissCreditsCalls, 1);
    expect(tester.widget<EvPlayerControls>(find.byType(EvPlayerControls)).visible, isTrue);

    // After 3.2s idle, controls auto-hide again.
    await tester.pump(const Duration(milliseconds: 3300));
    expect(tester.widget<EvPlayerControls>(find.byType(EvPlayerControls)).visible, isFalse);
  });

  testWidgets('Esc and EvMenuAction.back close open player settings panel first even when focus left player node', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final session = _TestSession(_initialSnap()._withPhase(PlaybackPhase.playing));
    var closed = 0;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1.0),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: EvPlayerPage(
              session: session,
              initialPanelOpen: true,
              initialPanelTab: 'video',
              onClose: () => closed++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Simulate focus leaving EvPlayerPage's FocusNode (e.g. rootScope / PlatformView / mouse click).
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    // First Esc must close the panel without exiting playback.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 200));
    expect(closed, 0);
    expect(tester.widget<EvCreditsVideoFrame>(find.byType(EvCreditsVideoFrame)).panelOpen, isFalse);

    // Re-open panel and trigger EvMenuAction.back via shell controller: still closes panel first.
    await tester.tap(find.byKey(const Key('ev_player_tab_subs')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<EvCreditsVideoFrame>(find.byType(EvCreditsVideoFrame)).panelOpen, isTrue);

    final shell = EvShellController();
    addTearDown(shell.dispose);
    expect(shell.handleMenuAction(EvMenuAction.back), isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(closed, 0);
    expect(tester.widget<EvCreditsVideoFrame>(find.byType(EvCreditsVideoFrame)).panelOpen, isFalse);

    // Next Esc exits playback.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('control bar chapters button opens chapters tab and tapping a chapter seeks session', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final base = _initialSnap()._withPhase(PlaybackPhase.playing);
    final session = _TestSession(
      PlaybackSnapshot(
        generation: base.generation,
        target: base.target,
        item: base.item,
        phase: PlaybackPhase.playing,
        position: const Duration(minutes: 3),
        duration: base.duration,
        bufferedUntil: base.bufferedUntil,
        chapters: const [
          ChapterMark(start: Duration.zero, name: 'Intro'),
          ChapterMark(start: Duration(minutes: 2), name: 'Chapter 2'),
          ChapterMark(start: Duration(minutes: 12), name: '决战时刻'),
        ],
        audioTracks: base.audioTracks,
        subtitleTracks: base.subtitleTracks,
        selectedAudioId: base.selectedAudioId,
        selectedSubtitleId: base.selectedSubtitleId,
      ),
    );

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), devicePixelRatio: 1.0),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: EvPlayerPage(session: session),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    await tester.tap(find.byKey(const Key('ev_player_tab_chapters')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byKey(const Key('ev_panel_chapters_tab')), findsOneWidget);
    expect(find.text('片头'), findsOneWidget);
    expect(find.text('第 2 章'), findsOneWidget);
    expect(find.text('决战时刻'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ev_chapter_row_2')));
    await tester.pump();
    expect(session.seekCalls, [const Duration(minutes: 12)]);

    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });
}

extension on PlaybackSnapshot {
  PlaybackSnapshot _withPhase(PlaybackPhase nextPhase) => PlaybackSnapshot(
    generation: generation, target: target, item: item, phase: nextPhase,
    firstFrameLatency: firstFrameLatency, position: position, duration: duration,
    bufferedUntil: bufferedUntil, quality: quality, chapters: chapters,
    audioTracks: audioTracks, subtitleTracks: subtitleTracks,
    selectedAudioId: selectedAudioId, selectedSubtitleId: selectedSubtitleId,
    volume: volume, muted: muted, nextEpisode: nextEpisode, creditsPrompt: creditsPrompt,
    fullscreenSupported: fullscreenSupported, fullscreen: fullscreen,
    pictureInPictureSupported: pictureInPictureSupported, pictureInPicture: pictureInPicture,
    anime4k: anime4k,
  );
}
