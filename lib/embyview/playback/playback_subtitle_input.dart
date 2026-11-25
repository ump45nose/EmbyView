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
}

abstract interface class PlaybackSubtitleInput {
  PlaybackSubtitleSource? get subtitleSource;
  Stream<PlaybackSubtitleSource?> get subtitleSources;
  NativePlaybackAudioInput get audioInput;
  /// Register a playable sidecar without changing the selected subtitle.
  /// The returned ID is immediately available in the session snapshot.
  Future<String> registerExternalSubtitle(
    String url, {
    required int generation,
    String? title,
    String? language,
    String? codec,
    String? contentKey,
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
