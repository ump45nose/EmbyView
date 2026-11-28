import 'package:playback_core/playback_core.dart';

import '../contracts/media.dart';
import '../contracts/playback.dart';
import 'native_playback.dart';

/// Internal stage-two capability; none of these credentials reach page DTOs.
class PlaybackSubtitleSource {
  const PlaybackSubtitleSource({
    required this.generation,
    required this.target,
    required this.mediaSourceId,
    required this.address,
    required this.headers,
    required this.userAgent,
    this.itemFilePath,
    this.mediaSourceFilePath,
    this.subtitleSwitchFrom,
    this.subtitlesExplicitlyDisabled = false,
  });
  final int generation;
  final PlayTarget target;
  final String mediaSourceId;
  final Uri address;
  final Map<String, String> headers;
  final String userAgent;

  /// Preserve the actual .strm item path even when PlaybackInfo names an HTTP path.
  final String? itemFilePath;
  final String? mediaSourceFilePath;

  /// The source generation reopened by a subtitle selection on this media.
  final int? subtitleSwitchFrom;

  /// True when the viewer or series preference explicitly disabled subtitles.
  final bool subtitlesExplicitlyDisabled;
}

abstract interface class PlaybackSubtitleInput {
  PlaybackSubtitleSource? get subtitleSource;
  Stream<PlaybackSubtitleSource?> get subtitleSources;
  NativePlaybackAudioInput get audioInput;

  /// Changes as soon as a selection is requested, including an explicit off.
  int get subtitleSelectionRevision;

  /// Replace the previous run's row. A timeline restart follows the viewer's
  /// current choice, while an explicit start selects the new row immediately.
  /// A previously saved AI track ID may be reused as the overlay.
  Future<void> setLiveSubtitle(
    String trackId, {
    required int generation,
    required bool select,
  });

  /// Retire this run. Only a viewer still on its live row follows the handoff.
  Future<void> endLiveSubtitle(String trackId, {String? replacementId});

  /// Register a playable sidecar without changing the selected subtitle.
  /// The returned ID is immediately available in the session snapshot. If
  /// [liveTrackId] represents a saved AI sidecar, update its delivery in place.
  Future<String> registerExternalSubtitle(
    String url, {
    required int generation,
    String? title,
    String? language,
    String? codec,
    String? contentKey,
    String? liveTrackId,
    PlaybackTrackSource source = PlaybackTrackSource.online,
  });

  /// The library has identified a retained sidecar as the same subtitle now
  /// indexed by Emby. Publish one logical track under the server's ID, even
  /// if its current playback delivery is the already loaded local file.
  Future<void> reconcileIndexedSubtitle({
    required int generation,
    required String indexedTrackId,
    required String contentKey,
  });
}

String? playbackItemPath(dynamic item) {
  if (item is Map) return item['Path'] as String?;
  try {
    return item.path as String?;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> playbackItemData(dynamic item) {
  if (item is Map) return Map<String, dynamic>.from(item);
  try {
    return Map<String, dynamic>.from(item.rawData as Map);
  } catch (_) {
    return {};
  }
}

String playbackItemId(dynamic item) => item == null
    ? ''
    : item is Map
    ? (item['Id'] ?? item['id'] ?? '').toString()
    : MediaStreamResolver.extractItemId(item);
