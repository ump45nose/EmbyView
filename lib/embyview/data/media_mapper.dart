// dart format width=120
import 'package:flutter/painting.dart';

import '../contracts/internal/authorized_resources.dart';
import '../contracts/media.dart';
import '../../data/models/aggregated_item.dart';
import '../../util/subtitle_track_logic.dart' show isForcedSubtitleStream, isSdhSubtitleStream;
import 'backdrop_text_selector.dart';

typedef Json = Map<String, dynamic>;
List<Json> records(dynamic value) =>
    (value is List ? value : const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
List<Json> itemRecords(dynamic value) => records(value is Map ? value['Items'] : value);
Duration? ticks(dynamic value) => value is num ? Duration(microseconds: value.toInt() ~/ 10) : null;
int? integer(dynamic value) => (value as num?)?.toInt();

/// Compact label for the selected Emby stream. DisplayTitle also includes the
/// language and flags, so it cannot stand in for missing technical metadata.
String? embyAudioTechnicalLabel(Json? stream) {
  final codec = (stream?['Codec'] as String?)?.trim().toUpperCase();
  final rawLayout = (stream?['ChannelLayout'] as String?)?.trim().toLowerCase();
  final count = int.tryParse('${stream?['Channels']}');
  final layout = switch (rawLayout) {
    'mono' => '1.0',
    'stereo' => '2.0',
    'quad' => '4.0',
    String value when RegExp(r'^\d+\.\d+(?:\([^)]*\))?$').hasMatch(value) => value.split('(').first,
    _ => switch (count) {
      1 => '1.0',
      2 => '2.0',
      int n when n > 0 => '$n 声道',
      _ => null,
    },
  };
  final parts = [if (codec != null && codec.isNotEmpty) codec, ?layout];
  return parts.isEmpty ? null : parts.join(' ');
}

final _forcedChineseTitle = RegExp(r'(?<!非)(?:强制|強制)');
final _fullSubtitleTitle = RegExp(r'\bfull subtitles?\b|\bfull(?=\s*(?:$|[),·]))|全字幕|完整字幕', caseSensitive: false);
final _defaultSubtitleTitle = RegExp(r'(?<!non[\s-])\bdefault\b|(?<!非)(?:默认|預設)', caseSensitive: false);
final _commentarySubtitleTitle = RegExp(r'\bcommentar(?:y|ies)\b|导演评论|導演講評', caseSensitive: false);

List<String> embySubtitleQualifiers(Json stream) {
  final titles = [stream['Title'], stream['DisplayTitle']].whereType<String>().join(' · ');
  return [
    if (isForcedSubtitleStream(stream) || _forcedChineseTitle.hasMatch(titles)) '强制',
    if (_fullSubtitleTitle.hasMatch(titles)) '全字幕',
    if (isSdhSubtitleStream(stream) || titles.contains('听障') || titles.contains('聽障')) 'SDH',
    if (stream['IsCommentary'] == true || _commentarySubtitleTitle.hasMatch(titles)) '评论',
    if (stream['IsDefault'] == true || _defaultSubtitleTitle.hasMatch(titles)) '默认',
  ];
}

class MediaMapper {
  MediaMapper({
    String? server,
    String Function()? serverUrl,
    String? serverId,
    required this.user,
    required this.token,
    List<BackdropCandidate> Function(List<BackdropCandidate>)? orderBackdrops,
  }) : assert(server != null || serverUrl != null, 'Either server or serverUrl is required.'),
       _fixedServer = server,
       _serverUrl = serverUrl,
       _serverId = serverId,
       _orderBackdrops = orderBackdrops;

  final String? _fixedServer;
  final String Function()? _serverUrl;
  final String? _serverId;
  final String user;
  final String token;
  final List<BackdropCandidate> Function(List<BackdropCandidate>)? _orderBackdrops;

  String get server => _serverUrl?.call() ?? _fixedServer!;
  String get scope => '$server|$user';

  Uri backdropUri(BackdropCandidate candidate, {int maxWidth = 1920}) =>
      Uri.parse(
        '${server.replaceFirst(RegExp(r'/$'), '')}/Items/${Uri.encodeComponent(candidate.itemId)}/Images/Backdrop/${candidate.index}',
      ).replace(
        queryParameters: {
          'tag': candidate.tag,
          'maxWidth': '$maxWidth',
          // NetworkImage's cache key omits headers. Include the user in
          // the resource identity without putting credentials in its URL.
          'UserId': user,
        },
      );

  List<BackdropCandidate> backdropCandidates(Json item, {Json? parent}) {
    final ownTags = item['BackdropImageTags'] as List? ?? const [];
    final ownId = item['Id']?.toString();
    if (ownId != null && ownTags.isNotEmpty) {
      final own = <BackdropCandidate>[
        for (var i = 0; i < ownTags.length; i++)
          if (ownTags[i] != null) (itemId: ownId, index: i, tag: ownTags[i].toString()),
      ];
      if (own.isNotEmpty) return own;
    }
    if (parent != null) {
      final inherited = backdropCandidates(parent);
      if (inherited.isNotEmpty) return inherited;
    }
    final parentId = item['ParentBackdropItemId']?.toString();
    final parentTags = item['ParentBackdropImageTags'] as List? ?? const [];
    if (parentId != null && parentTags.isNotEmpty) {
      return [
        for (var i = 0; i < parentTags.length; i++)
          if (parentTags[i] != null) (itemId: parentId, index: i, tag: parentTags[i].toString()),
      ];
    }
    return const [];
  }

  ArtworkRef _backdropRef(BackdropCandidate candidate) {
    final currentServer = server;
    final uri = backdropUri(candidate);
    final key = '$currentServer|$user|${candidate.itemId}|Backdrop|${candidate.index}|${candidate.tag}';
    return AuthorizedArtworkRef(
      id: '${candidate.itemId}:Backdrop:${candidate.index}',
      cacheKey: key,
      image: NetworkImage(uri.toString(), headers: {'X-Emby-Token': token}),
    );
  }

  ArtworkRef? image(Json item, String type, {int index = 0}) {
    final tags = item['ImageTags'] as Map? ?? const {};
    final backdrops = item['BackdropImageTags'] as List? ?? const [];
    final tag = type == 'Backdrop' ? (index < backdrops.length ? backdrops[index] : null) : tags[type];
    if (tag == null) return null;
    if (type == 'Backdrop') {
      return _backdropRef((itemId: item['Id'].toString(), index: index, tag: tag.toString()));
    }
    final currentServer = server;
    final id = item['Id'].toString();
    final uri =
        Uri.parse('${currentServer.replaceFirst(RegExp(r'/$'), '')}/Items/${Uri.encodeComponent(id)}/Images/$type')
            .replace(
              queryParameters: {
                'tag': tag.toString(),
                'maxWidth': '900',
                // NetworkImage's cache key omits headers. Include the user in
                // the resource identity without putting credentials in its URL.
                'UserId': user,
              },
            );
    final key = '$currentServer|$user|$id|$type|$index|$tag';
    return AuthorizedArtworkRef(
      id: '$id:$type:$index',
      cacheKey: key,
      image: NetworkImage(uri.toString(), headers: {'X-Emby-Token': token}),
      aspectRatio: type == 'Primary' ? (item['PrimaryImageAspectRatio'] as num?)?.toDouble() : null,
    );
  }

  CardArtwork artwork(Json item, {Json? parent, List<Json> collection = const []}) {
    final title = item['Name'] as String? ?? '';
    final primary = image(item, 'Primary');
    final thumb = image(item, 'Thumb');
    final episode = item['Type'] == 'Episode';
    final parentId = item['ParentLogoItemId'];
    final inherited = parentId != null && (!episode || parentId == item['SeriesId'])
        ? image({'Id': parentId, 'ImageTags': {'Logo': item['ParentLogoImageTag']}}, 'Logo')
        : null;
    final parentLogo = parent == null || (episode && parent['Id'] != item['SeriesId']) ? null : image(parent, 'Logo');
    final logo = (episode ? null : image(item, 'Logo')) ?? parentLogo ?? inherited;
    final rawCandidates = backdropCandidates(item, parent: parent);
    final orderedCandidates = _orderBackdrops?.call(rawCandidates) ?? rawCandidates;
    final backs = <ArtworkRef>[for (final c in orderedCandidates) _backdropRef(c)];
    final backdrop = backs.firstOrNull;
    ArtworkPlan plan(List<ArtworkLayer> layers, {List<ArtworkRef> stack = const []}) =>
        ArtworkPlan(layers: List.unmodifiable(layers), fallbackTitle: title, stack: stack);
    return CardArtwork(
      landscape: plan([
        if (thumb != null) ArtworkLayer(source: thumb, fit: ArtworkFit.cover),
        if (backdrop != null)
          ArtworkLayer(source: backdrop, fit: ArtworkFit.cover, logo: logo, text: logo == null ? title : null),
        if (backdrop != null && logo != null) ArtworkLayer(source: backdrop, fit: ArtworkFit.cover, text: title),
      ]),
      poster: plan([
        if (primary != null) ArtworkLayer(source: primary, fit: ArtworkFit.cover),
        if (backdrop != null) ArtworkLayer(source: backdrop, fit: ArtworkFit.cover, text: title),
      ], stack: collection.skip(1).take(2).map((e) => image(e, 'Primary')).whereType<ArtworkRef>().toList()),
      stage: plan([
        if (backdrop != null)
          ArtworkLayer(source: backdrop, fit: ArtworkFit.cover, logo: logo, text: logo == null ? title : null),
        if (primary != null) ArtworkLayer(source: primary, fit: ArtworkFit.cover, blurred: true, text: title),
      ]),
      backdrops: List.unmodifiable(backs),
      logo: logo,
    );
  }

  ArtworkPlan still(Json episode, Json series) {
    final primary = image(episode, 'Primary');
    final back = artwork(series).backdrops.firstOrNull;
    final label = episode['IndexNumber'] == null ? episode['Name'] as String? : '第 ${episode['IndexNumber']} 集';
    return ArtworkPlan(
      fallbackTitle: label ?? '',
      layers: [
        if (primary != null) ArtworkLayer(source: primary, fit: ArtworkFit.cover),
        if (back != null) ArtworkLayer(source: back, fit: ArtworkFit.cover, text: label),
      ],
    );
  }

  AggregatedItem aggregate(Json item) =>
      AggregatedItem(id: item['Id'].toString(), serverId: _serverId ?? server, rawData: item);

  MediaQuality? quality(Json item) {
    final sources = records(item['MediaSources']);
    final firstSource = sources.firstOrNull;
    final streams = records(firstSource?['MediaStreams'] ?? item['MediaStreams']);
    return qualityFromStreams(item, streams, source: firstSource);
  }

  MediaOrigin detectMediaOrigin(Json item, {Json? source}) {
    final path = (source?['Path'] ?? item['Path'])?.toString().trim().toLowerCase() ?? '';
    final container = (source?['Container'] ?? item['Container'])?.toString().trim().toLowerCase() ?? '';
    final protocol = (source?['Protocol'])?.toString().trim().toLowerCase() ?? '';
    final isRemote = source?['IsRemote'] == true;
    if (isRemote ||
        protocol == 'http' ||
        protocol == 'https' ||
        container == 'strm' ||
        path.endsWith('.strm') ||
        path.contains('115.com') ||
        path.contains('115cdn')) {
      return MediaOrigin.direct115;
    }
    return MediaOrigin.nasLocal;
  }

  MediaQuality? qualityFromStreams(Json item, List<Json> streams, {Json? source}) {
    final media = aggregate({...item, 'MediaStreams': streams});
    final audio = streams.where((s) => s['Type'] == 'Audio').toList();
    final selected = audio.where((s) => s['IsDefault'] == true).firstOrNull ?? audio.firstOrNull;
    final label = selected?['Title'].toString().toLowerCase().contains('atmos') == true
        ? 'Atmos'
        : const {6: '5.1', 8: '7.1'}[media.audioChannels];
    final videoRange = _videoRangeLabel(media.hdrType);
    final hasSource = source != null || item['Path'] != null;
    final origin = hasSource ? detectMediaOrigin(item, source: source) : null;
    return media.videoResolution == null && label == null && videoRange == null && origin == null
        ? null
        : MediaQuality(resolution: media.videoResolution, videoRange: videoRange, audioLabel: label, origin: origin);
  }

  static String? _videoRangeLabel(String? raw) => const {
    'dolbyvision': '杜比视界',
    'dovi': '杜比视界',
    'hdr10': 'HDR10',
    'hdr10plus': 'HDR10+',
    'hyperloggamma': 'HLG',
    'hlg': 'HLG',
    'hdr': 'HDR',
  }[raw?.trim().toLowerCase()];

  static String _cleanVersionName(Json source, Json item, String resolution, String? videoCodec) {
    final rawName = (source['Name'] as String?)?.trim() ?? '';
    final itemName = (item['Name'] as String?)?.trim() ?? '';
    var cleaned = rawName;
    if (cleaned.isNotEmpty && itemName.isNotEmpty) {
      final prefixPattern = RegExp('^${RegExp.escape(itemName)}\\s*[-–—·:]\\s*', caseSensitive: false);
      cleaned = cleaned.replaceFirst(prefixPattern, '').trim();
    }
    if (cleaned.isEmpty || cleaned.toLowerCase() == itemName.toLowerCase()) {
      final parts = [if (resolution.isNotEmpty) resolution, if (videoCodec != null && videoCodec.isNotEmpty) videoCodec];
      return parts.isNotEmpty ? parts.join(' ') : (rawName.isNotEmpty ? rawName : '默认版本');
    }
    return cleaned;
  }

  static String? _formatVideoCodec(Json? videoStream) {
    if (videoStream == null) return null;
    final rawCodec = (videoStream['Codec'] as String?)?.trim().toLowerCase() ?? '';
    if (rawCodec.isEmpty) return null;
    final codec = switch (rawCodec) {
      'hevc' || 'h265' || 'h.265' => 'HEVC',
      'h264' || 'avc' || 'h.264' => 'H.264',
      'av1' => 'AV1',
      'vp9' => 'VP9',
      _ => rawCodec.toUpperCase(),
    };
    final bitDepth = integer(videoStream['BitDepth']);
    final profile = (videoStream['Profile'] as String?)?.toLowerCase() ?? '';
    final is10Bit = bitDepth == 10 || profile.contains('10');
    return is10Bit && codec == 'HEVC' ? '$codec 10bit' : codec;
  }

  static String? _formatVersionAudio(List<Json> audioStreams) {
    if (audioStreams.isEmpty) return null;
    final selected = audioStreams.where((s) => s['IsDefault'] == true).firstOrNull ?? audioStreams.first;
    final title = '${selected['DisplayTitle'] ?? ''} ${selected['Title'] ?? ''}'.toLowerCase();
    final codecRaw = (selected['Codec'] as String?)?.trim().toLowerCase() ?? '';
    final codec = switch (codecRaw) {
      'truehd' => 'TrueHD',
      'eac3' || 'ec-3' => 'EAC3',
      'ac3' => 'AC3',
      'dts' => 'DTS',
      'aac' => 'AAC',
      'flac' => 'FLAC',
      'opus' => 'Opus',
      _ => codecRaw.isNotEmpty ? codecRaw.toUpperCase() : '',
    };
    final isAtmos = title.contains('atmos') || title.contains('全景声');
    final channels = integer(selected['Channels']);
    final rawLayout = (selected['ChannelLayout'] as String?)?.trim().toLowerCase();
    final layout = switch (rawLayout) {
      'mono' => '1.0',
      'stereo' => '2.0',
      'quad' => '4.0',
      String v when RegExp(r'^\d+\.\d+').hasMatch(v) => v.split('(').first,
      _ => const {1: '1.0', 2: '2.0', 6: '5.1', 8: '7.1'}[channels],
    };
    final parts = [
      if (codec.isNotEmpty) codec,
      if (isAtmos) '全景声',
      if (layout != null && layout.isNotEmpty) layout,
    ];
    return parts.isEmpty ? embyAudioTechnicalLabel(selected) : parts.join(' ');
  }

  static String? _basename(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    final parts = path.trim().split(RegExp(r'[/\\]'));
    return parts.where((p) => p.isNotEmpty).lastOrNull;
  }

  List<MediaVersion> versions(Json item) {
    final sources = records(item['MediaSources']);
    if (sources.isEmpty) return const [];
    final out = <MediaVersion>[];
    for (final source in sources) {
      final id = source['Id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final streams = records(source['MediaStreams']);
      final effectiveStreams = streams.isNotEmpty ? streams : records(item['MediaStreams']);
      final media = aggregate({...item, 'MediaStreams': effectiveStreams});
      final video = effectiveStreams.where((s) => s['Type'] == 'Video').firstOrNull;
      final audio = effectiveStreams.where((s) => s['Type'] == 'Audio').toList();
      final width = integer(video?['Width']);
      final height = integer(video?['Height']);
      final resolution = media.videoResolution ??
          (width != null && width >= 3800 || height != null && height >= 2000
              ? '4K'
              : height != null && height >= 1000
              ? '1080p'
              : height != null && height >= 680
              ? '720p'
              : 'HD');
      final videoRange = _videoRangeLabel(media.hdrType);
      final videoCodec = _formatVideoCodec(video);
      final audioLabel = _formatVersionAudio(audio);
      final sizeBytes = integer(source['Size']);
      final bitrateBps = integer(source['Bitrate']) ?? integer(video?['BitRate']);
      final origin = detectMediaOrigin(item, source: source);
      final embeddedSubs = effectiveStreams
          .where((s) => s['Type'] == 'Subtitle' && s['IsExternal'] == false)
          .map((s) => s['Language'])
          .whereType<String>()
          .toSet()
          .toList();
      out.add(
        MediaVersion(
          id: id,
          name: _cleanVersionName(source, item, resolution, videoCodec),
          resolution: resolution,
          width: width,
          height: height,
          videoRange: videoRange,
          videoCodec: videoCodec,
          audioLabel: audioLabel,
          sizeBytes: sizeBytes,
          bitrateBps: bitrateBps,
          origin: origin,
          fileName: _basename(source['Path'] as String?),
          embeddedSubtitleLanguages: embeddedSubs,
        ),
      );
    }
    return List.unmodifiable(out);
  }

  MediaCard card(Json item, {String? library, Json? parent, List<Json> collection = const []}) {
    final media = aggregate(item);
    final data = item['UserData'] as Map? ?? const {};
    final kind = switch (item['Type']) {
      'Series' => MediaKind.series,
      'Episode' => MediaKind.episode,
      'BoxSet' => MediaKind.collection,
      _ => MediaKind.movie,
    };
    return MediaCard(
      id: item['Id'].toString(),
      kind: kind,
      libraryId: library,
      title: media.name,
      year: media.productionYear,
      score: media.communityRating,
      genres: media.genres,
      duration: media.runtime,
      rating: media.officialRating,
      overview: media.overview,
      childCount: media.childCount,
      quality: quality(item),
      art: artwork(item, parent: parent, collection: collection),
      played: data['Played'] as bool?,
      unplayedCount: media.unplayedItemCount,
      favorite: data['IsFavorite'] as bool?,
      seriesId: item['SeriesId'] as String?,
      seriesName: parent?['Name'] as String? ?? item['SeriesName'] as String?,
      seasonNumber: integer(item['ParentIndexNumber']),
      seasonId: item['SeasonId'] as String?,
      episodeNumber: integer(item['IndexNumber']),
    );
  }

  PlayTarget target(Json item) => PlayTarget(
    itemId: item['Id'].toString(),
    startAt: ticks((item['UserData'] as Map?)?['PlaybackPositionTicks']),
    seriesId: item['SeriesId'] as String?,
    seasonId: item['SeasonId'] as String?,
    episodeNumber: integer(item['IndexNumber']),
  );

  AuthorizedPreviewRef preview(Json item) {
    final id = item['Id'].toString();
    final audio = item['MediaType'] == 'Audio' || item['Type'] == 'Audio';
    final uri = Uri.parse(
      '${server.replaceFirst(RegExp(r'/$'), '')}/${audio ? 'Audio' : 'Videos'}/${Uri.encodeComponent(id)}/stream',
    ).replace(queryParameters: {'Static': 'true', 'UserId': user});
    return AuthorizedPreviewRef(
      id: id,
      name: item['Name'] as String? ?? '',
      uri: uri,
      headers: {'X-Emby-Token': token},
      duration: ticks(item['RunTimeTicks']),
    );
  }
}
