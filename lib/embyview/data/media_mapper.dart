// dart format width=120
import 'package:flutter/painting.dart';

import '../contracts/internal/authorized_resources.dart';
import '../contracts/media.dart';
import '../../data/models/aggregated_item.dart';

typedef Json = Map<String, dynamic>;
List<Json> records(dynamic value) =>
    (value is List ? value : const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
List<Json> itemRecords(dynamic value) => records(value is Map ? value['Items'] : value);
Duration? ticks(dynamic value) => value is num ? Duration(microseconds: value.toInt() ~/ 10) : null;
int? integer(dynamic value) => (value as num?)?.toInt();

class MediaMapper {
  MediaMapper({required this.server, required this.user, required this.token});
  final String server;
  final String user;
  final String token;
  String get scope => '$server|$user';

  ArtworkRef? image(Json item, String type, {int index = 0}) {
    final tags = item['ImageTags'] as Map? ?? const {};
    final backdrops = item['BackdropImageTags'] as List? ?? const [];
    final tag = type == 'Backdrop' ? (index < backdrops.length ? backdrops[index] : null) : tags[type];
    if (tag == null) return null;
    final id = item['Id'].toString();
    final suffix = type == 'Backdrop' ? '/$index' : '';
    final uri =
        Uri.parse('${server.replaceFirst(RegExp(r'/$'), '')}/Items/${Uri.encodeComponent(id)}/Images/$type$suffix')
            .replace(
              queryParameters: {
                'tag': tag.toString(),
                'maxWidth': type == 'Backdrop' ? '1920' : '900',
                // NetworkImage's cache key omits headers. Include the user in
                // the resource identity without putting credentials in its URL.
                'UserId': user,
              },
            );
    final key = '$scope|$id|$type|$index|$tag';
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
    final logo =
        image(item, 'Logo') ??
        (parent == null ? null : image(parent, 'Logo')) ??
        (item['ParentLogoItemId'] == null
            ? null
            : image({
                'Id': item['ParentLogoItemId'],
                'ImageTags': {'Logo': item['ParentLogoImageTag']},
              }, 'Logo'));
    var backs = <ArtworkRef>[
      for (var i = 0; i < (item['BackdropImageTags'] as List? ?? const []).length; i++)
        image(item, 'Backdrop', index: i)!,
    ];
    if (backs.isEmpty && parent != null) {
      backs = artwork(parent).backdrops.toList();
    }
    if (backs.isEmpty && item['ParentBackdropItemId'] != null) {
      final inherited = {'Id': item['ParentBackdropItemId'], 'BackdropImageTags': item['ParentBackdropImageTags']};
      for (var i = 0; i < (item['ParentBackdropImageTags'] as List? ?? const []).length; i++) {
        final ref = image(inherited, 'Backdrop', index: i);
        if (ref != null) backs.add(ref);
      }
    }
    final backdrop = backs.firstOrNull;
    ArtworkPlan plan(List<ArtworkLayer> layers, {List<ArtworkRef> stack = const []}) =>
        ArtworkPlan(layers: List.unmodifiable(layers), fallbackTitle: title, stack: stack);
    return CardArtwork(
      landscape: plan([
        if (thumb != null) ArtworkLayer(source: thumb),
        if (backdrop != null)
          ArtworkLayer(source: backdrop, fit: ArtworkFit.cover, logo: logo, text: logo == null ? title : null),
        if (backdrop != null && logo != null) ArtworkLayer(source: backdrop, fit: ArtworkFit.cover, text: title),
      ]),
      poster: plan([
        if (primary != null) ArtworkLayer(source: primary),
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
        if (primary != null) ArtworkLayer(source: primary),
        if (back != null) ArtworkLayer(source: back, fit: ArtworkFit.cover, text: label),
      ],
    );
  }

  AggregatedItem aggregate(Json item) => AggregatedItem(id: item['Id'].toString(), serverId: server, rawData: item);

  MediaQuality? quality(Json item) {
    final streams = records(records(item['MediaSources']).firstOrNull?['MediaStreams'] ?? item['MediaStreams']);
    final media = aggregate({...item, 'MediaStreams': streams});
    final audio = streams.where((s) => s['Type'] == 'Audio').toList();
    final selected = audio.where((s) => s['IsDefault'] == true).firstOrNull ?? audio.firstOrNull;
    final label = selected?['Title'].toString().toLowerCase().contains('atmos') == true
        ? 'Atmos'
        : const {6: '5.1', 8: '7.1'}[media.audioChannels];
    final videoRange = const {
      'dolbyvision': '杜比视界',
      'dovi': '杜比视界',
      'hdr10': 'HDR10',
      'hdr10plus': 'HDR10+',
      'hyperloggamma': 'HLG',
      'hlg': 'HLG',
      'hdr': 'HDR',
    }[media.hdrType?.toLowerCase()];
    return media.videoResolution == null && label == null && videoRange == null
        ? null
        : MediaQuality(resolution: media.videoResolution, videoRange: videoRange, audioLabel: label);
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
