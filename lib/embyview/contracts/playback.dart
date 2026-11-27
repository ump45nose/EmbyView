import 'package:flutter/widgets.dart';

import 'common.dart';
import 'media.dart';

enum PlaybackPhase {
  preparing,
  opening,
  buffering,
  playing,
  paused,
  ended,
  failed,
}

enum PlaybackTrackSource { embedded, embyExternal, nas, online, ai }

enum CreditsPromptState { hidden, countingDown, dismissed }

enum Anime4kState { unsupported, off, pending, active, degraded, failed }

enum ComparisonState { unavailable, preparing, available }

enum PreviewState { idle, loading, ready, failed }

class PlaybackTrack {
  const PlaybackTrack({
    required this.id,
    required this.name,
    this.language,
    required this.source,
    this.format,
    this.layout,
    this.isForced = false,
    this.qualifiers = const [],
  });

  final String id;
  final String name;
  final String? language;
  final PlaybackTrackSource source;
  final String? format;
  final String? layout;
  final bool isForced;

  /// Display labels for subtitle variants reported by the server.
  final List<String> qualifiers;
}

class VideoSize {
  const VideoSize({required this.width, required this.height});

  final int width;
  final int height;
}

class Anime4kSnapshot {
  const Anime4kSnapshot({
    this.supported = false,
    this.requested = false,
    this.state = Anime4kState.unsupported,
    this.reason,
    this.comparison = ComparisonState.unavailable,
    this.comparisonSplit,
    this.originalSize,
    this.enhancedSize,
  });

  final bool supported;
  final bool requested;
  final Anime4kState state;
  final String? reason;
  final ComparisonState comparison;
  final double? comparisonSplit;
  final VideoSize? originalSize;
  final VideoSize? enhancedSize;
}

class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.generation,
    required this.target,
    this.item,
    this.phase = PlaybackPhase.preparing,
    this.firstFrameLatency,
    this.position = Duration.zero,
    this.duration,
    this.bufferedUntil = Duration.zero,
    this.mediaSourceId,
    this.quality,
    this.chapters = const [],
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.selectedAudioId,
    this.selectedSubtitleId,
    this.subtitleOverlayId,
    this.subtitleSelectionNotice,
    this.volume = 1,
    this.muted = false,
    this.nextEpisode,
    this.creditsPrompt = CreditsPromptState.hidden,
    this.creditsStart,
    this.fullscreenSupported = false,
    this.fullscreen = false,
    this.pictureInPictureSupported = false,
    this.pictureInPicture = false,
    this.anime4k = const Anime4kSnapshot(),
    this.failure,
  });

  final int generation;
  final PlayTarget target;
  final MediaCard? item;
  final PlaybackPhase phase;
  final Duration? firstFrameLatency;
  final Duration position;
  final Duration? duration;
  final Duration bufferedUntil;
  final String? mediaSourceId;
  final MediaQuality? quality;
  final List<ChapterMark> chapters;
  final List<PlaybackTrack> audioTracks;

  /// All available tracks, including registered (but not necessarily selected)
  /// sidecars. Track IDs belong to this source generation.
  final List<PlaybackTrack> subtitleTracks;
  final String? selectedAudioId;
  final String? selectedSubtitleId;

  /// The live track allowed to draw over video after native captions are off.
  final String? subtitleOverlayId;

  /// The latest failed subtitle selection, emitted once per selection revision.
  final ({int revision, String message})? subtitleSelectionNotice;
  final double volume;
  final bool muted;
  final MediaCard? nextEpisode;
  final CreditsPromptState creditsPrompt;
  final Duration? creditsStart;
  final bool fullscreenSupported;
  final bool fullscreen;
  final bool pictureInPictureSupported;
  final bool pictureInPicture;
  final Anime4kSnapshot anime4k;
  final EmbyViewFailure? failure;
}

class ThumbnailFrame {
  const ThumbnailFrame({required this.image, required this.position});

  final ArtworkRef image;
  final Duration position;
}

class ImmersionSnapshot {
  const ImmersionSnapshot({
    this.video = PreviewState.idle,
    this.theme = PreviewState.idle,
    this.themePosition = Duration.zero,
    this.themeDuration,
    this.themeMuted = false,
    this.failure,
  });

  final PreviewState video;
  final PreviewState theme;
  final Duration themePosition;
  final Duration? themeDuration;
  final bool themeMuted;
  final EmbyViewFailure? failure;
}

abstract interface class EmbyViewPlayback {
  Future<void> prepare(String itemId);
  PlaybackSession open(PlayTarget target);
}

abstract interface class PlaybackSession {
  PlaybackSnapshot get snapshot;
  Stream<PlaybackSnapshot> get changes;
  Widget videoSurface({Key? key});
  Future<void> resume();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> seekBy(Duration delta);
  Future<void> setVolume(double fraction);
  Future<void> setMuted(bool muted);
  Future<void> selectAudio(String trackId);

  /// Select an available subtitle track, or turn subtitles off with null.
  Future<void> selectSubtitle(String? trackId);
  Future<void> setAnime4k(bool enabled);
  Future<void> setAnime4kComparison(double? split);
  Future<void> setPictureInPicture(bool enabled);
  Future<void> setFullscreen(bool enabled);
  Future<void> playNext({bool finishCurrent = false});
  Future<void> dismissCreditsPrompt();
  Future<ThumbnailFrame?> thumbnailAt(Duration position);

  /// Discards any cached playback address for the current item and re-resolves
  /// a fresh stream URL before reopening playback (e.g. after a 115 HTTP 403).
  Future<void> retryOpen();
  Future<void> close();
}

abstract interface class ImmersionPlayback {
  Future<void> showMutedVideo(PreviewRef? video);
  Widget videoSurface({Key? key});
  Future<void> playTheme(PreviewRef? song);
  Future<void> setThemeMuted(bool muted);
  ImmersionSnapshot get snapshot;
  Stream<ImmersionSnapshot> get changes;
  Future<void> stop();
}
