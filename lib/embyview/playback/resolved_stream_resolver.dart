import 'package:playback_core/playback_core.dart';

import 'source_resolution.dart';

typedef ResolvedSourceCallback = void Function(
  dynamic item,
  StreamResolutionResult result,
  Duration playbackInfo,
  ResolvedPlaybackAddress? address,
);

/// Decorates Moonfin's authenticated PlaybackInfo negotiation. Only the signed
/// address is cached; each actual playback obtains its own Emby session ID.
class EmbyViewStreamResolver extends MediaStreamResolver {
  EmbyViewStreamResolver({
    required this.delegate,
    required this.cache,
    required this.server,
    required this.user,
    required this.userAgent,
    this.prefetchEnabled = true,
    this.onResolved,
  });
  final MediaStreamResolver delegate;
  final PlaybackRedirectCache cache;
  final String server;
  final String user;
  final String userAgent;
  bool prefetchEnabled;
  ResolvedSourceCallback? onResolved;
  final _keys = <StreamResolutionResult, PlaybackSourceKey>{};

  PlaybackSourceKey? keyFor(StreamResolutionResult value) => _keys[value];
  void forget() => _keys.clear();

  @override
  Future<StreamResolutionResult> resolve(
    dynamic mediaItem, {
    Map<String, dynamic>? deviceProfile,
    int? maxStreamingBitrate,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int? startTimeTicks,
    String? mediaSourceId,
    bool enableDirectPlay = true,
    bool enableDirectStream = true,
    bool enableTranscoding = true,
  }) async {
    final watch = Stopwatch()..start();
    final result = await delegate.resolve(
      mediaItem,
      deviceProfile: deviceProfile,
      maxStreamingBitrate: maxStreamingBitrate,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      startTimeTicks: startTimeTicks,
      mediaSourceId: mediaSourceId,
      enableDirectPlay: enableDirectPlay,
      enableDirectStream: enableDirectStream,
      enableTranscoding: enableTranscoding,
    );
    final infoTime = watch.elapsed;
    final source = Uri.parse(result.streamUrl);
    final serverUri = Uri.parse(server);
    final remote =
        result.playMethod == StreamPlayMethod.directPlay &&
        !result.isLocalMedia &&
        result.liveStreamId == null &&
        (source.scheme == 'http' || source.scheme == 'https') &&
        !PlaybackRedirectCache.sameOrigin(source, serverUri);
    ResolvedPlaybackAddress? address;
    PlaybackSourceKey? key;
    if (remote) {
      key = PlaybackSourceKey(
        server: server,
        user: user,
        item: MediaStreamResolver.extractItemId(mediaItem),
        mediaSource: result.mediaSourceId,
        userAgent: userAgent,
      );
      if (prefetchEnabled) {
        address = await cache.resolve(key, source, headers: result.requestHeaders);
      }
    }
    final uri = address?.uri ?? PlaybackRedirectCache.authorizedUri(source, serverUri);
    final headers =
        address?.headers ??
        PlaybackRedirectCache.authorizedHeaders(uri, serverUri, result.requestHeaders, userAgent);
    final resolved = StreamResolutionResult(
      streamUrl: uri.toString(),
      mediaSourceId: result.mediaSourceId,
      liveStreamId: result.liveStreamId,
      playSessionId: result.playSessionId,
      requestHeaders: headers,
      playMethod: result.playMethod,
      container: result.container,
      videoRangeType: result.videoRangeType,
      mediaType: result.mediaType,
      normalizationGainDb: result.normalizationGainDb,
      externalSubtitles: result.externalSubtitles,
      embeddedTextSubtitles: result.embeddedTextSubtitles,
      mediaStreams: result.mediaStreams,
      selectedAudioStreamIndex: result.selectedAudioStreamIndex,
      selectedSubtitleStreamIndex: result.selectedSubtitleStreamIndex,
      transcodingReasons: result.transcodingReasons,
      hybridAudioUrl: result.hybridAudioUrl,
      serverOfferedDirectPlay: result.serverOfferedDirectPlay,
      directPlayRequested: result.directPlayRequested,
      sourceBitrate: result.sourceBitrate,
      isLocalMedia: result.isLocalMedia,
      timelineOffset: result.timelineOffset,
      seeksThroughServer: result.seeksThroughServer,
      reopenAfterPause: result.reopenAfterPause,
    );
    if (key != null) {
      if (_keys.length > 32) _keys.remove(_keys.keys.first);
      _keys[resolved] = key;
    }
    onResolved?.call(mediaItem, resolved, infoTime, address);
    return resolved;
  }
}
