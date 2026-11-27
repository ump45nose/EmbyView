import 'package:flutter/painting.dart';

import 'common.dart';

enum ShelfSort { added, score, title }

enum WallSort { title, added, year, score, random }

enum WatchFilter { all, unplayed, played, favorite }

enum TechFilter { uhd4k, dolbyVision, hdr, surround51 }

enum HomeFeature { shortHighRated, uhdDolbyVision }

enum MediaKind { movie, series, episode, collection }

enum MediaOrigin { direct115, nasLocal }

enum ArtworkFit { contain, cover }

enum RecommendationReason { continueWatching, daily }

/// An authorized image capability. No URL or authorization header is exposed.
abstract interface class ArtworkRef {
  String get id;
  String get cacheKey;
  ImageProvider<Object> get image;
  double? get aspectRatio;
  int? get width;
  int? get height;
}

/// An authorized media capability, consumed by ImmersionPlayback.
abstract interface class PreviewRef {
  String get id;
  String get name;
  Duration? get duration;
}

class ArtworkLayer {
  const ArtworkLayer({
    required this.source,
    this.fit = ArtworkFit.contain,
    this.blurred = false,
    this.logo,
    this.text,
  });

  final ArtworkRef source;
  final ArtworkFit fit;
  final bool blurred;
  final ArtworkRef? logo;
  final String? text;
}

/// Try [layers] in order, then render the supplied color and title.
class ArtworkPlan {
  const ArtworkPlan({
    this.layers = const [],
    this.fallbackColor = 0xff292522,
    this.fallbackTitle = '',
    this.stack = const [],
  });

  final List<ArtworkLayer> layers;
  final int fallbackColor;
  final String fallbackTitle;

  /// At most two back posters selected by the data adapter.
  final List<ArtworkRef> stack;
}

class CardArtwork {
  const CardArtwork({
    this.landscape = const ArtworkPlan(),
    this.poster = const ArtworkPlan(),
    this.stage = const ArtworkPlan(),
    this.backdrops = const [],
    this.logo,
  });

  final ArtworkPlan landscape;
  final ArtworkPlan poster;
  final ArtworkPlan stage;
  final List<ArtworkRef> backdrops;
  final ArtworkRef? logo;
}

class MediaQuality {
  const MediaQuality({
    this.resolution,
    this.videoRange,
    this.audioLabel,
    this.origin,
  });

  final String? resolution;
  final String? videoRange;
  final String? audioLabel;
  final MediaOrigin? origin;
}

class MediaCard {
  const MediaCard({
    required this.id,
    required this.kind,
    required this.title,
    this.libraryId,
    this.year,
    this.score,
    this.genres = const [],
    this.duration,
    this.rating,
    this.overview,
    this.childCount,
    this.quality,
    this.art = const CardArtwork(),
    this.played,
    this.unplayedCount,
    this.favorite,
    this.seriesId,
    this.seriesName,
    this.seasonId,
    this.seasonNumber,
    this.episodeNumber,
  });

  final String id;
  final MediaKind kind;
  final String? libraryId;
  final String title;
  final int? year;
  final double? score;
  final List<String> genres;
  final Duration? duration;
  final String? rating;
  final String? overview;
  final int? childCount;
  final MediaQuality? quality;
  final CardArtwork art;
  final bool? played;
  final int? unplayedCount;
  final bool? favorite;
  final String? seriesId;
  final String? seriesName;
  final String? seasonId;
  final int? seasonNumber;
  final int? episodeNumber;
}

class PlayTarget {
  const PlayTarget({
    required this.itemId,
    this.startAt,
    this.seriesId,
    this.seasonId,
    this.episodeNumber,
    this.mediaSourceId,
    this.queueItemIds = const [],
  });

  final String itemId;
  final Duration? startAt;
  final String? seriesId;
  final String? seasonId;
  final int? episodeNumber;
  final String? mediaSourceId;
  final List<String> queueItemIds;
}

class ResumeCard {
  const ResumeCard({
    required this.card,
    required this.target,
    required this.position,
    this.duration,
  });

  final MediaCard card;
  final PlayTarget target;
  final Duration position;
  final Duration? duration;
}

/// Removes trailing Emby collection suffix `（系列）` or `(系列)`.
String stripCollectionTitleSuffix(String name) =>
    name.trim().replaceFirst(RegExp(r'[（(]系列[)）]\s*$'), '').trim();

class CollectionMembership {
  const CollectionMembership({
    required this.id,
    required this.name,
    required this.position,
    required this.total,
    this.items = const [],
  });

  final String id;
  final String name;
  final int position;
  final int total;
  final List<MediaCard> items;

  String get displayName => stripCollectionTitleSuffix(name);
}

class CollectionItem {
  const CollectionItem({
    required this.card,
    this.resume,
    this.played = false,
  });

  final MediaCard card;
  final ResumeCard? resume;
  final bool played;

  double? get resumeFraction {
    final res = resume;
    if (res == null) return null;
    final total = res.duration ?? card.duration;
    if (total == null || total <= Duration.zero) return null;
    return (res.position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  bool get isDone => played || card.played == true || (resumeFraction ?? 0.0) > 0.85;
  bool get isInProgress => !isDone && resume != null && resume!.position > Duration.zero;
}

class CollectionDetail {
  const CollectionDetail({
    required this.card,
    required this.rawName,
    this.items = const [],
  });

  final MediaCard card;
  final String rawName;
  final List<CollectionItem> items;

  String get displayName => stripCollectionTitleSuffix(rawName.isNotEmpty ? rawName : card.title);
}

enum CollectionNextActionKind { resume, continueNext, catchUp, startFromFirst }

class CollectionNextTarget {
  const CollectionNextTarget({
    required this.item,
    required this.index,
    required this.kind,
  });

  final CollectionItem item;
  final int index;
  final CollectionNextActionKind kind;

  String get verb => switch (kind) {
    CollectionNextActionKind.resume => '继续',
    CollectionNextActionKind.continueNext => '接着看',
    CollectionNextActionKind.catchUp => '补看',
    CollectionNextActionKind.startFromFirst => '从头看',
  };

  String get buttonLabel => '${verb}第 ${index + 1} 部';
}

/// Picks the primary action item and verb for a collection page:
/// - Any in-progress film -> 「继续第 k 部」
/// - None watched (or all watched) -> 「从头看第 1 部」
/// - First unwatched immediately follows a watched film -> 「接着看第 k 部」
/// - Earlier film(s) skipped while later ones watched -> 「补看第 k 部」
CollectionNextTarget? selectCollectionNextTarget(List<CollectionItem> items) {
  if (items.isEmpty) return null;
  final seen = items.where((x) => x.isDone).length;
  var index = items.indexWhere((x) => x.isInProgress);
  if (index >= 0) {
    return CollectionNextTarget(
      item: items[index],
      index: index,
      kind: CollectionNextActionKind.resume,
    );
  }
  index = items.indexWhere((x) => !x.isDone);
  if (index < 0) {
    return CollectionNextTarget(
      item: items.first,
      index: 0,
      kind: CollectionNextActionKind.startFromFirst,
    );
  }
  if (seen == 0) {
    return CollectionNextTarget(
      item: items[index],
      index: index,
      kind: CollectionNextActionKind.startFromFirst,
    );
  }
  if (index > 0 && items[index - 1].isDone) {
    return CollectionNextTarget(
      item: items[index],
      index: index,
      kind: CollectionNextActionKind.continueNext,
    );
  }
  return CollectionNextTarget(
    item: items[index],
    index: index,
    kind: CollectionNextActionKind.catchUp,
  );
}

enum PersonWorkRole { actor, director, writer, producer }

String personRoleFilterLabel(PersonWorkRole role) => switch (role) {
  PersonWorkRole.actor => '出演',
  PersonWorkRole.director => '执导',
  PersonWorkRole.writer => '编剧',
  PersonWorkRole.producer => '制片',
};

String personRoleIdentityLabel(PersonWorkRole role) => switch (role) {
  PersonWorkRole.actor => '演员',
  PersonWorkRole.director => '导演',
  PersonWorkRole.writer => '编剧',
  PersonWorkRole.producer => '制片人',
};

PersonWorkRole? parsePersonWorkRole(String? raw) {
  final value = raw?.trim().toLowerCase() ?? '';
  return switch (value) {
    'actor' || '主演' || '演员' => PersonWorkRole.actor,
    'director' || '导演' => PersonWorkRole.director,
    'writer' || '编剧' => PersonWorkRole.writer,
    'producer' || '制片' || '制片人' => PersonWorkRole.producer,
    _ => null,
  };
}

class PersonWork {
  const PersonWork({
    required this.card,
    required this.role,
    this.roles = const {},
    this.character,
  });

  final MediaCard card;
  final PersonWorkRole role;
  final Set<PersonWorkRole> roles;
  final String? character;

  Set<PersonWorkRole> get allRoles => roles.isEmpty ? {role} : roles;
  bool hasRole(PersonWorkRole value) => allRoles.contains(value);
}

class PersonDetail {
  const PersonDetail({
    required this.id,
    required this.name,
    this.primaryRole,
    this.portrait,
    this.birthDateUtc,
    this.birthPlace,
    this.overview,
    this.works = const [],
  });

  final String id;
  final String name;
  final String? primaryRole;
  final ArtworkRef? portrait;
  final DateTime? birthDateUtc;
  final String? birthPlace;
  final String? overview;
  final List<PersonWork> works;
}

/// Returns the ordered list of distinct roles actually present in [works].
List<PersonWorkRole> personWorkFilterKinds(List<PersonWork> works) {
  const order = [
    PersonWorkRole.actor,
    PersonWorkRole.director,
    PersonWorkRole.writer,
    PersonWorkRole.producer,
  ];
  return [
    for (final role in order)
      if (works.any((w) => w.hasRole(role))) role,
  ];
}

/// Computes the identity kicker label for [person], e.g. `演员` or `导演 · 制片人`.
String personIdentityLabel(PersonDetail person) {
  final kinds = personWorkFilterKinds(person.works);
  if (kinds.isNotEmpty) {
    return kinds.map(personRoleIdentityLabel).join(' · ');
  }
  final parsed = parsePersonWorkRole(person.primaryRole) ?? PersonWorkRole.actor;
  return personRoleIdentityLabel(parsed);
}

/// Formats a person work's card subtitle: 「饰 角色 · 年份」 or 「导演 · 年份」.
String formatPersonWorkSubtitle(PersonWork work, {PersonWorkRole? activeFilter}) {
  final effectiveRole = activeFilter != null && work.hasRole(activeFilter) ? activeFilter : work.role;
  String roleText;
  if (effectiveRole == PersonWorkRole.actor) {
    final cleaned = (work.character ?? '')
        .replaceAllMapped(
          RegExp(r'\s*\((voice|uncredited)\)', caseSensitive: false),
          (m) => m.group(1)!.toLowerCase() == 'voice' ? '（配音）' : '',
        )
        .trim();
    roleText = cleaned.isNotEmpty ? '饰 $cleaned' : '';
  } else {
    roleText = personRoleIdentityLabel(effectiveRole);
  }
  return [
    if (roleText.isNotEmpty) roleText,
    if (work.card.year != null) '${work.card.year}',
  ].join(' · ');
}

/// Formats an Emby UTC birthday timestamp in the local timezone (or a supplied
/// [localOffset] for deterministic testing), e.g. `1974 年 11 月 11 日出生 · 52 岁`.
String formatPersonBirthDate(
  DateTime birthDateUtc, {
  DateTime? now,
  Duration? localOffset,
}) {
  final utc = birthDateUtc.isUtc ? birthDateUtc : birthDateUtc.toUtc();
  final local = localOffset != null ? utc.add(localOffset) : utc.toLocal();
  final refUtc = (now ?? DateTime.now()).toUtc();
  final ref = localOffset != null ? refUtc.add(localOffset) : refUtc.toLocal();
  var age = ref.year - local.year;
  if (ref.month < local.month || (ref.month == local.month && ref.day < local.day)) {
    age--;
  }
  final base = '${local.year} 年 ${local.month} 月 ${local.day} 日出生';
  return age > 0 ? '$base · $age 岁' : base;
}

class MediaVersion {
  const MediaVersion({
    required this.id,
    required this.name,
    required this.resolution,
    this.width,
    this.height,
    this.videoRange,
    this.videoCodec,
    this.audioLabel,
    this.sizeBytes,
    this.bitrateBps,
    this.origin = MediaOrigin.nasLocal,
    this.fileName,
    this.embeddedSubtitleLanguages = const [],
  });

  final String id;
  final String name;
  final String resolution;
  final int? width;
  final int? height;
  final String? videoRange;
  final String? videoCodec;
  final String? audioLabel;
  final int? sizeBytes;
  final int? bitrateBps;
  final MediaOrigin origin;
  final String? fileName;
  final List<String> embeddedSubtitleLanguages;

  bool get is4k =>
      resolution.toUpperCase() == '4K' ||
      resolution.toUpperCase() == '2160P' ||
      (width ?? 0) >= 3800 ||
      (height ?? 0) >= 2000;

  double? get sizeGb =>
      sizeBytes != null && sizeBytes! > 0 ? sizeBytes! / (1024.0 * 1024.0 * 1024.0) : null;

  double? get bitrateMbps =>
      bitrateBps != null && bitrateBps! > 0 ? bitrateBps! / 1000000.0 : null;

  bool get isHighBitrate => (bitrateMbps ?? 0.0) > 40.0;

  String get buttonSubtitle =>
      (videoRange != null && videoRange!.trim().isNotEmpty) ? videoRange!.trim() : name;

  String get formattedSizeGb => sizeGb == null ? '' : '${sizeGb!.toStringAsFixed(1)} GB';

  String get formattedBitrateMbps {
    final mbps = bitrateMbps;
    if (mbps == null) return '';
    return mbps >= 10 ? '${mbps.round()} Mbps' : '${mbps.toStringAsFixed(1)} Mbps';
  }

  MediaQuality toQuality() => MediaQuality(
    resolution: resolution,
    videoRange: videoRange,
    audioLabel: audioLabel,
    origin: origin,
  );
}

class VersionTasteProfile {
  const VersionTasteProfile({
    this.resolution,
    this.videoRange,
    this.origin,
    this.preferSmall = false,
  });

  factory VersionTasteProfile.fromVersion(MediaVersion version) => VersionTasteProfile(
    resolution: version.resolution,
    videoRange: version.videoRange,
    origin: version.origin,
    preferSmall: !version.is4k && (version.sizeGb ?? 999) < 12,
  );

  final String? resolution;
  final String? videoRange;
  final MediaOrigin? origin;
  final bool preferSmall;
}

int _versionResolutionRank(MediaVersion v) {
  if (v.is4k) return 4000;
  final upper = v.resolution.toUpperCase();
  if (upper.contains('1080') || (v.height ?? 0) >= 1000) return 1080;
  if (upper.contains('720') || (v.height ?? 0) >= 680) return 720;
  return v.height ?? v.width ?? 0;
}

int _versionHdrRank(MediaVersion v) {
  final r = v.videoRange?.toLowerCase() ?? '';
  if (r.contains('杜比') || r.contains('dolby') || r.contains('dovi')) return 4;
  if (r.contains('hdr10+')) return 3;
  if (r.contains('hdr') || r.contains('hlg')) return 2;
  return 0;
}

int _compareVersionQualityDesc(MediaVersion a, MediaVersion b) {
  final res = _versionResolutionRank(b).compareTo(_versionResolutionRank(a));
  if (res != 0) return res;
  final hdr = _versionHdrRank(b).compareTo(_versionHdrRank(a));
  if (hdr != 0) return hdr;
  final br = (b.bitrateBps ?? 0).compareTo(a.bitrateBps ?? 0);
  if (br != 0) return br;
  return (b.sizeBytes ?? 0).compareTo(a.sizeBytes ?? 0);
}

/// Selects the effective version among [versions] according to per-item memory
/// first, then the user's [rule] (`bestQuality`, `lastSimilar`, `smallestSize`).
MediaVersion? selectDefaultMediaVersion(
  List<MediaVersion> versions, {
  required String ruleName,
  String? rememberedId,
  VersionTasteProfile? lastTaste,
}) {
  if (versions.isEmpty) return null;
  if (rememberedId != null && rememberedId.isNotEmpty) {
    for (final v in versions) {
      if (v.id == rememberedId) return v;
    }
  }
  final ordered = [...versions];
  if (ruleName == 'smallestSize') {
    ordered.sort((a, b) {
      final as = a.sizeBytes ?? a.bitrateBps ?? 1 << 60;
      final bs = b.sizeBytes ?? b.bitrateBps ?? 1 << 60;
      final c = as.compareTo(bs);
      return c != 0 ? c : _compareVersionQualityDesc(a, b);
    });
    return ordered.first;
  }
  if (ruleName == 'lastSimilar' && lastTaste != null) {
    int score(MediaVersion v) {
      var s = 0;
      if (lastTaste.resolution != null &&
          v.resolution.toLowerCase() == lastTaste.resolution!.toLowerCase()) {
        s += 4;
      }
      final wantHdr = lastTaste.videoRange != null && lastTaste.videoRange!.isNotEmpty;
      final hasHdr = v.videoRange != null && v.videoRange!.isNotEmpty;
      if (wantHdr == hasHdr) {
        s += 3;
        if (wantHdr && v.videoRange == lastTaste.videoRange) s += 1;
      }
      if (lastTaste.origin != null && v.origin == lastTaste.origin) s += 2;
      if (lastTaste.preferSmall && !v.is4k) s += 1;
      return s;
    }

    ordered.sort((a, b) {
      final sc = score(b).compareTo(score(a));
      return sc != 0 ? sc : _compareVersionQualityDesc(a, b);
    });
    return ordered.first;
  }
  ordered.sort(_compareVersionQualityDesc);
  return ordered.first;
}

class MediaDetail {
  const MediaDetail({
    required this.card,
    this.tagline,
    this.studios = const [],
    this.episodeCount,
    this.resume,
    this.playTarget,
    this.embeddedSubtitleLanguages = const [],
    this.collectionItems = const [],
    this.collection,
    this.versions = const [],
    this.rememberedVersionId,
    this.lastVersionTaste,
  });

  final MediaCard card;
  final String? tagline;
  final List<String> studios;
  final int? episodeCount;
  final ResumeCard? resume;
  final PlayTarget? playTarget;
  final List<String> embeddedSubtitleLanguages;
  final List<MediaCard> collectionItems;
  final CollectionMembership? collection;
  final List<MediaVersion> versions;
  final String? rememberedVersionId;
  final VersionTasteProfile? lastVersionTaste;
}

class SeasonSummary {
  const SeasonSummary({
    required this.id,
    required this.name,
    this.number,
    required this.total,
    this.art,
  });

  final String id;
  final String name;
  final int? number;
  final int total;
  final ArtworkRef? art;
}

class EpisodeCard {
  const EpisodeCard({
    required this.card,
    required this.episodeNumber,
    this.played,
    this.resumePosition,
    this.still = const ArtworkPlan(),
  });

  final MediaCard card;
  final int? episodeNumber;
  final bool? played;
  final Duration? resumePosition;
  final ArtworkPlan still;
}

class SeasonEpisodes {
  const SeasonEpisodes({
    required this.season,
    required this.episodes,
    required this.playedCount,
  });

  final SeasonSummary season;
  final List<EpisodeCard> episodes;
  final int playedCount;
}

class PersonCredit {
  const PersonCredit({
    required this.id,
    required this.name,
    required this.role,
    this.character,
    this.avatar,
  });

  final String id;
  final String name;
  final String role;
  final String? character;
  final ArtworkRef? avatar;
}

class ChapterMark {
  const ChapterMark({required this.start, this.name});

  final Duration start;
  final String? name;
}

sealed class WallScope {
  const WallScope();
  const factory WallScope.zone(String zoneId) = ZoneWallScope;
  const factory WallScope.feature(HomeFeature feature) = FeatureWallScope;
}

final class ZoneWallScope extends WallScope {
  const ZoneWallScope(this.zoneId);
  final String zoneId;
}

final class FeatureWallScope extends WallScope {
  const FeatureWallScope(this.feature);
  final HomeFeature feature;
}

class YearRange {
  const YearRange({this.from, this.to})
    : assert(from == null || to == null || from <= to);
  final int? from;
  final int? to;
}

typedef WallQuery = ({
  WallScope scope,
  WallSort sort,
  WatchFilter watched,
  String? genreId,
  YearRange? years,
  TechFilter? technology,
});

class WallInfo {
  const WallInfo({required this.total, this.letterOffsets = const {}});

  final int total;
  final Map<String, int> letterOffsets;
}

class FacetOption<T> {
  const FacetOption({required this.value, required this.label, this.count});

  final T value;
  final String label;
  final int? count;
}

class WallFacets {
  const WallFacets({
    this.sorts = const [],
    this.watched = const [],
    this.genres = const [],
    this.years = const [],
    this.technologies = const [],
  });

  final List<FacetOption<WallSort>> sorts;
  final List<FacetOption<WatchFilter>> watched;
  final List<FacetOption<String>> genres;
  final List<FacetOption<YearRange>> years;
  final List<FacetOption<TechFilter>> technologies;
}

class ZoneFacets {
  const ZoneFacets({
    this.libraries = const [],
    this.genres = const [],
    this.technologies = const [],
  });

  final List<FacetOption<String>> libraries;
  final List<FacetOption<String>> genres;
  final List<FacetOption<TechFilter>> technologies;
}

sealed class ZoneRule {
  const ZoneRule();
  const factory ZoneRule.library(String libraryId) = LibraryZoneRule;
  const factory ZoneRule.genre(String genreId) = GenreZoneRule;
  const factory ZoneRule.technology(TechFilter technology) = TechnologyZoneRule;
}

final class LibraryZoneRule extends ZoneRule {
  const LibraryZoneRule(this.libraryId);
  final String libraryId;
}

final class GenreZoneRule extends ZoneRule {
  const GenreZoneRule(this.genreId);
  final String genreId;
}

final class TechnologyZoneRule extends ZoneRule {
  const TechnologyZoneRule(this.technology);
  final TechFilter technology;
}

class ZonePreference {
  const ZonePreference({
    required this.id,
    required this.name,
    required this.iconKey,
    required this.colorSlot,
    required this.rule,
    this.custom = true,
  });

  final String id;
  final String name;
  final String iconKey;
  final int colorSlot;
  final ZoneRule rule;
  final bool custom;
}

class ZoneTile {
  const ZoneTile({
    required this.id,
    required this.name,
    required this.iconKey,
    required this.colorSlot,
    this.art,
    this.representative,
    required this.total,
    required this.unit,
    this.episodeTotal,
  });

  final String id;
  final String name;
  final String iconKey;
  final int colorSlot;
  final ArtworkRef? art;
  final MediaCard? representative;
  final int total;
  final String unit;
  final int? episodeTotal;
}

class HomeShelf {
  const HomeShelf({
    required this.id,
    required this.title,
    required this.items,
    this.more,
    this.total,
  });

  final String id;
  final String title;
  final List<MediaCard> items;
  final WallQuery? more;
  final int? total;
}

class HomeRecommendation {
  const HomeRecommendation({
    required this.card,
    required this.reason,
    this.resume,
  });

  final MediaCard card;
  final RecommendationReason reason;
  final ResumeCard? resume;
}

class FeatureSpread {
  const FeatureSpread({
    required this.feature,
    required this.posters,
    required this.total,
    required this.query,
  });

  final HomeFeature feature;
  final List<MediaCard> posters;
  final int total;
  final WallQuery query;
}

class HomeData {
  const HomeData({
    this.recommendations = const [],
    this.continueWatching = const [],
    this.zones = const [],
    this.recentMovies,
    this.anime,
    this.series,
    this.collections,
    this.documentaries,
    this.shortHighRated,
    this.uhdDolbyVision,
  });

  final List<HomeRecommendation> recommendations;
  final List<ResumeCard> continueWatching;
  final List<ZoneTile> zones;
  final HomeShelf? recentMovies;
  final HomeShelf? anime;
  final HomeShelf? series;
  final HomeShelf? collections;
  final HomeShelf? documentaries;
  final FeatureSpread? shortHighRated;
  final FeatureSpread? uhdDolbyVision;
}

class ZoneData {
  const ZoneData({
    required this.zone,
    required this.all,
    this.addedThisMonth = 0,
    this.recommendations = const [],
    this.continueWatching = const [],
    this.latest,
    this.highRated,
    this.genres = const [],
    this.genreCounts = const [],
    this.collage = const [],
  });

  final ZoneTile zone;
  final WallQuery all;
  final int addedThisMonth;
  final List<HomeRecommendation> recommendations;
  final List<ResumeCard> continueWatching;
  final HomeShelf? latest;
  final HomeShelf? highRated;
  final List<HomeShelf> genres;
  final List<FacetOption<String>> genreCounts;

  /// At most nine already-selected posters.
  final List<ArtworkRef> collage;
}

class SearchLanding {
  const SearchLanding({this.recentTerms = const [], this.shelves = const []});

  final List<String> recentTerms;
  final List<HomeShelf> shelves;
}

class SearchGroup {
  const SearchGroup({
    required this.libraryId,
    required this.name,
    required this.items,
    required this.total,
    this.nextOffset,
  });

  final String libraryId;
  final String name;
  final List<MediaCard> items;
  final int total;
  final int? nextOffset;
}

class SearchResults {
  const SearchResults({
    this.bestMatch,
    this.groups = const [],
    this.total = 0,
    this.nextOffset,
  });

  final MediaCard? bestMatch;
  final List<SearchGroup> groups;
  final int total;
  final int? nextOffset;
}

class ThemeMedia {
  const ThemeMedia({this.songs = const [], this.backgroundVideo, this.trailer});

  final List<PreviewRef> songs;
  final PreviewRef? backgroundVideo;
  final PreviewRef? trailer;
}

class SafeEpisodeStill {
  const SafeEpisodeStill({
    required this.image,
    this.seasonNumber,
    this.episodeNumber,
    this.seasonName,
  });

  final ArtworkRef image;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? seasonName;
}

abstract interface class EmbyViewData {
  Future<HomeData> home({required ShelfSort seriesSort});
  Future<List<ZoneTile>> zones();
  Future<ZoneData> zone(String zoneId);
  Future<MediaCard?> randomInZone(String zoneId);
  Future<WallListing> openWall(WallQuery query);
  Future<WallFacets> wallFacets(WallQuery query);
  Future<ZoneFacets> customZoneFacets();
  Future<MediaDetail> detail(String itemId);
  Future<List<SeasonSummary>> seasons(String seriesId);
  Future<SeasonEpisodes> episodes(String seriesId, String seasonId);
  Future<List<PersonCredit>> people(String itemId);
  Future<List<MediaCard>> similar(String itemId, {int limit = 16});
  Future<MediaQuality?> quality(String itemId);
  Future<List<ChapterMark>> chapters(String itemId, {String? mediaSourceId});
  Future<ThemeMedia> themeMedia(String itemId);
  Future<List<SafeEpisodeStill>> safeEpisodeStills(String seriesId);
  Future<Page<ResumeCard>> continueWatching({
    String? zoneId,
    int offset = 0,
    int limit = 20,
  });
  Future<SearchLanding> searchLanding({String? zoneId});
  Future<SearchResults> search(
    String text, {
    String? zoneId,
    int offset = 0,
    int limit = 20,
  });
  Future<void> setFavorite(String itemId, bool favorite);
  Future<void> setPlayed(String itemId, bool played);
  Future<CollectionDetail> collection(String collectionId);
  Future<PersonDetail> person(
    String personId, {
    String? name,
    String? roleHint,
    MediaCard? sourceItem,
  });
  Future<void> rememberMediaVersion(String itemId, MediaVersion version);
}

abstract interface class BrowseCacheInvalidator {
  void invalidateBrowseCache();
}

abstract interface class WallListing {
  WallInfo get info;
  Future<Page<MediaCard>> page({required int offset, required int limit});
}
