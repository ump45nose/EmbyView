import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:playback_emby/playback_emby.dart';
import 'package:server_core/server_core.dart';
import 'package:server_emby/server_emby.dart';

import '../embyview.dart';
import '../playback/playback_subtitle_input.dart';
import '../playback/source_resolution.dart';
import 'model/subtitle_document.dart';
import 'store/subtitle_store.dart';

typedef SubtitleItem = ({
  Map<String, dynamic> item,
  PlaybackSubtitleSource source,
  List<Map<String, dynamic>> streams,
  Duration? duration,
  int? audioIndex,
});

class EmbySubtitleLibrary implements SubtitleIndexPort {
  EmbySubtitleLibrary(this.client, {String Function()? resolveBaseUrl})
    : _resolveBaseUrl = resolveBaseUrl {
    configureServerDio(_requests);
  }

  final EmbyMediaServerClient client;
  final String Function()? _resolveBaseUrl;
  final _requests = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: false,
    ),
  );

  void _syncBaseUrl() {
    final next = _resolveBaseUrl?.call();
    if (next != null && next.isNotEmpty && next != client.baseUrl) {
      client.baseUrl = next;
    }
  }

  Future<SubtitleItem> item(String id, [String? sourceId]) async {
    _syncBaseUrl();
    final item = await client.itemsApi.getItem(id, fields: 'Path,MediaSources,MediaStreams,OriginalTitle');
    final resolved = await EmbyMediaStreamResolver(client)
        .resolve(item, mediaSourceId: sourceId, enableTranscoding: false);
    final sources = _rows(item['MediaSources']);
    final source = sources.where((row) => row['Id'] == resolved.mediaSourceId).firstOrNull;
    final address = Uri.parse(resolved.streamUrl);
    final server = Uri.parse(client.baseUrl);
    final ticks = (source?['RunTimeTicks'] ?? item['RunTimeTicks']) as num?;
    return (
      item: item,
      source: PlaybackSubtitleSource(
        generation: 0,
        target: PlayTarget(itemId: id),
        mediaSourceId: resolved.mediaSourceId,
        address: PlaybackRedirectCache.authorizedUri(address, server),
        headers: PlaybackRedirectCache.authorizedHeaders(
          address,
          server,
          resolved.requestHeaders,
          embyViewPlaybackUserAgent,
        ),
        userAgent: embyViewPlaybackUserAgent,
        itemFilePath: item['Path'] as String?,
        mediaSourceFilePath: source?['Path'] as String?,
      ),
      streams: resolved.mediaStreams,
      duration: ticks == null ? null : Duration(microseconds: ticks ~/ 10),
      audioIndex: resolved.selectedAudioStreamIndex,
    );
  }

  Future<SubtitleAvailability> availability(SubtitleItem item, SubtitleStore store) async {
    final scan = await store.scan(SubtitleMedia.fromPlayback(item.source, duration: item.duration));
    final embedded = <String?>[], external = <String?>[];
    for (final stream in item.streams.where((row) => row['Type'] == 'Subtitle' && row['IsForced'] != true)) {
      final language = stream['Language'] as String?;
      if (stream['IsExternal'] != true) {
        embedded.add(language);
      } else if (isChineseSubtitle(language)) {
        final match = scan.nasTracks.isEmpty
            ? null
            : scan.matchExternal(
                language: language,
                filename: stream['Path'] as String?,
                document: await document(item, stream),
              );
        if (match == null || match.isComplete) external.add(language);
      }
    }
    return scan.availability(
      embeddedLanguages: embedded,
      embyExternalLanguages: external,
      mediaKnown: item.streams.isNotEmpty,
    );
  }

  Future<SubtitleDocument?> document(SubtitleItem item, Map<String, dynamic> stream, {bool matching = false}) async {
    final index = stream['Index'], codec = normalizeSubtitleFormat((stream['Codec'] ?? '').toString());
    if (index is! num || (stream['IsTextSubtitleStream'] != true && !textSubtitleFormats.contains(codec))) {
      return null;
    }
    final itemId = Uri.encodeComponent(item.source.target.itemId);
    final sourceId = Uri.encodeComponent(item.source.mediaSourceId);
    final endpoint = '/Videos/$itemId/$sourceId/Subtitles/${index.toInt()}';
    final raw = stream['DeliveryUrl'] as String?;
    for (final (address, format) in [
      if (raw != null && textSubtitleFormats.contains(codec)) (raw, codec),
      if (textSubtitleFormats.contains(codec)) ('$endpoint/Stream.$codec', codec),
      if (!matching && codec != 'srt') ('$endpoint/Stream.srt', 'srt'),
    ]) {
      try {
        final response = await _requests.get<List<int>>(_url(address), options: _options(ResponseType.bytes));
        final doc = SubtitleDocument.parse(response.data!, format: format, language: stream['Language'] as String?);
        if (doc.hasTimings || matching) return doc;
      } catch (_) {
        // Some text codecs are available only as server-converted SRT.
      }
    }
    return null;
  }

  @override
  Future<void> notify(SubtitleMedia media, String embyPath) async {
    await _requests.post<void>(
      _url('/Library/Media/Updated'),
      options: _options(ResponseType.plain),
      data: {
        'Updates': [
          {'Path': embyPath, 'UpdateType': 'Created'},
        ],
      },
    );
  }

  @override
  Future<bool> matches(SubtitleMedia media, String embyPath, SubtitleDocument expected) async {
    final current = await item(media.itemId, media.mediaSourceId);
    if (current.source.mediaSourceId != media.mediaSourceId) return false;
    String normalized(SubtitleDocument doc) =>
        utf8.decode(doc.playbackBytes).replaceFirst('\uFEFF', '').replaceAll('\r\n', '\n');
    for (final stream in current.streams.where((row) => row['Type'] == 'Subtitle' && row['IsExternal'] == true)) {
      final path = stream['Path'] as String?;
      if (path != null && p.posix.basename(path) != p.posix.basename(embyPath)) {
        continue;
      }
      final actual = await document(current, stream, matching: true);
      if (actual?.format == expected.format && normalized(actual!) == normalized(expected)) {
        return true;
      }
    }
    return false;
  }

  String _url(String value) {
    _syncBaseUrl();
    final server = Uri.parse(client.baseUrl);
    final address = Uri.parse(value);
    final uri = address.hasAuthority
        ? address
        : Uri.parse('${client.baseUrl}/').resolve(value.replaceFirst(RegExp(r'^/(?:emby/)?'), ''));
    if (!PlaybackRedirectCache.sameOrigin(uri, server)) {
      throw const FormatException('Unexpected subtitle origin');
    }
    return uri.toString();
  }

  Options _options(ResponseType type) => Options(
    responseType: type,
    headers: {
      'Authorization': buildServerAuthorizationHeader(
        scheme: 'Emby',
        deviceInfo: client.deviceInfo,
        accessToken: client.accessToken,
      ),
      'X-Emby-Token': client.accessToken,
    },
  );

  void close() {
    _requests.close(force: true);
    client.dispose();
  }
}

Iterable<Map<String, dynamic>> _rows(Object? value) => (value as List? ?? []).whereType<Map<String, dynamic>>();
