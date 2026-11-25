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
    this.seasonId,
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
  final String? seasonId;
  final int? episodeNumber;
}

class PlayTarget {
  const PlayTarget({
    required this.itemId,
    this.startAt,
    this.seriesId,
    this.seasonId,
    this.episodeNumber,
  });

  final String itemId;
  final Duration? startAt;
  final String? seriesId;
  final String? seasonId;
  final int? episodeNumber;
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
  });

  final MediaCard card;
  final String? tagline;
  final List<String> studios;
  final int? episodeCount;
  final ResumeCard? resume;
  final PlayTarget? playTarget;
  final List<String> embeddedSubtitleLanguages;
  final List<MediaCard> collectionItems;
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
}

abstract interface class WallListing {
  WallInfo get info;
  Future<Page<MediaCard>> page({required int offset, required int limit});
}
