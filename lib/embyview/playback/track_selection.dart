import 'dart:ui' as ui;

import '../../data/models/series_track_preference.dart';
import '../../util/audio_track_logic.dart';
import '../../util/language_matching.dart';
import '../../util/playback_track_selection.dart';
import '../../util/subtitle_track_logic.dart';
import '../contracts/preferences.dart';

typedef TrackLanguageRank = ({int index, int tier});

int compareTrackLanguageRank(TrackLanguageRank a, TrackLanguageRank b) {
  final byIndex = a.index.compareTo(b.index);
  return byIndex != 0 ? byIndex : a.tier.compareTo(b.tier);
}

final _cantoneseHint = RegExp(
  r'(?:^|[\s_.\-(\[])(?:yue|cantonese)(?:$|[\s_.\-)\]])|粤|粵',
  caseSensitive: false,
);
final _traditionalHint = RegExp(
  r'(?:^|[\s_.\-(\[])(?:hant|cht|zht|tc|tw|hk|mo|traditional)(?:$|[\s_.\-)\]])|繁[体體]',
  caseSensitive: false,
);
final _simplifiedHint = RegExp(
  r'(?:^|[\s_.\-(\[])(?:hans|chs|zhs|sc|cn|sg|simplified)(?:$|[\s_.\-)\]])|[简簡][体體]',
  caseSensitive: false,
);

String _baseIso3(String? raw) {
  final cleaned = raw?.trim().toLowerCase().replaceAll('_', '-') ?? '';
  if (cleaned.isEmpty || cleaned == 'und') return '';
  final primary = cleaned.split('-').first;
  return switch (primary) {
    'zh' || 'chi' || 'zho' || 'cmn' || 'chs' || 'cht' || 'zhs' || 'zht' => 'zho',
    'yue' => 'yue',
    'jp' => 'jpn',
    _ => toIso3Language(normalizeLanguage(primary)),
  };
}

bool _isCantonese(String? language, String? title) {
  final lang = language?.trim().toLowerCase().replaceAll('_', '-') ?? '';
  if (lang == 'yue' || lang.startsWith('yue-') || lang == 'zh-yue' || lang.startsWith('zh-yue-')) {
    return true;
  }
  final iso3 = _baseIso3(lang);
  if (iso3.isNotEmpty && iso3 != 'zho') return false;
  return title != null && _cantoneseHint.hasMatch(title);
}

String? _chineseScript(String? language, String? title) {
  final lang = language?.trim().toLowerCase().replaceAll('_', '-') ?? '';
  if (_traditionalHint.hasMatch(lang)) return 'hant';
  if (_simplifiedHint.hasMatch(lang)) return 'hans';
  if (title != null && title.isNotEmpty) {
    if (_traditionalHint.hasMatch(title)) return 'hant';
    if (_simplifiedHint.hasMatch(title)) return 'hans';
  }
  return null;
}

int? _matchSingleLanguage(
  String canonicalPref, {
  String? language,
  String? title,
  required bool allowZhHantFallback,
  required bool allowGenericZhForHant,
}) {
  if (canonicalPref == 'yue') {
    return _isCantonese(language, title) ? 0 : null;
  }
  final iso3 = _baseIso3(language);
  if (canonicalPref == 'zh') {
    if (_isCantonese(language, title)) return null;
    if (iso3 != 'zho') return null;
    final script = _chineseScript(language, title);
    if (script == 'hant') return allowZhHantFallback ? 1 : null;
    return 0;
  }
  if (canonicalPref == 'zh-hant') {
    if (_isCantonese(language, title)) return null;
    if (iso3 != 'zho') return null;
    final script = _chineseScript(language, title);
    if (script == 'hant') return 0;
    if (script == 'hans') return null;
    return allowGenericZhForHant ? 1 : null;
  }
  final prefIso3 = _baseIso3(canonicalPref);
  if (prefIso3.isEmpty) return null;
  return iso3 == prefIso3 ? 0 : null;
}

/// Computes the best rank of a track against [preferredLanguages].
/// Lower `(index, tier)` wins. Returns `null` when the track does not match any
/// preferred language.
TrackLanguageRank? rankTrackLanguage(
  List<String> preferredLanguages, {
  String? language,
  String? title,
}) {
  final normalized = <String>[];
  for (final code in preferredLanguages) {
    final canonical = normalizePreferenceLanguageCode(code);
    if (canonical != null) normalized.add(canonical);
  }
  if (normalized.isEmpty) return null;
  final hasExplicitZh = normalized.contains('zh');
  final hasExplicitHant = normalized.contains('zh-hant');
  TrackLanguageRank? best;
  for (var i = 0; i < normalized.length; i++) {
    final tier = _matchSingleLanguage(
      normalized[i],
      language: language,
      title: title,
      allowZhHantFallback: !hasExplicitHant,
      allowGenericZhForHant: !hasExplicitZh,
    );
    if (tier == null) continue;
    final candidate = (index: i, tier: tier);
    if (best == null || compareTrackLanguageRank(candidate, best) < 0) {
      best = candidate;
    }
  }
  return best;
}

/// Whether [activeAudioLanguage] is considered the viewer's native audio for
/// [SubtitleAutoMode.foreignOnly].
bool isNativeAudioForSubtitlePolicy({
  required LocalPreferences prefs,
  String? activeAudioLanguage,
  String? activeAudioTitle,
  String? systemLocaleLanguage,
}) {
  final rawNative =
      prefs.audioLanguages.firstOrNull ??
      prefs.subtitleLanguages.firstOrNull ??
      systemLocaleLanguage ??
      ui.PlatformDispatcher.instance.locale.languageCode;
  final canonical = normalizePreferenceLanguageCode(rawNative);
  if (canonical == null) return false;
  final target = canonical == 'zh-hant' ? 'zh' : canonical;
  return _matchSingleLanguage(
        target,
        language: activeAudioLanguage,
        title: activeAudioTitle,
        allowZhHantFallback: true,
        allowGenericZhForHant: true,
      ) !=
      null;
}

String? _streamTitle(Map<String, dynamic> stream) {
  final title = stream['Title'] as String?;
  if (title != null && title.trim().isNotEmpty) return title;
  final display = stream['DisplayTitle'] as String?;
  if (display != null && display.trim().isNotEmpty) return display;
  return stream['Name'] as String?;
}

int _compareAudioQuality(
  Map<String, dynamic> a,
  Map<String, dynamic> b, {
  required bool preferDefaultFirst,
}) {
  if (preferDefaultFirst) {
    final aDefault = a['IsDefault'] == true;
    final bDefault = b['IsDefault'] == true;
    if (aDefault != bDefault) return aDefault ? -1 : 1;
  }
  final aChannels = (a['Channels'] as num?)?.toInt() ?? 0;
  final bChannels = (b['Channels'] as num?)?.toInt() ?? 0;
  if (aChannels != bChannels) return bChannels.compareTo(aChannels);
  if (!preferDefaultFirst) {
    final aDefault = a['IsDefault'] == true;
    final bDefault = b['IsDefault'] == true;
    if (aDefault != bDefault) return aDefault ? -1 : 1;
  }
  final aIdx = (a['Index'] as num?)?.toInt() ?? 0;
  final bIdx = (b['Index'] as num?)?.toInt() ?? 0;
  return aIdx.compareTo(bIdx);
}

int? _pickBestAudio(
  List<Map<String, dynamic>> matches, {
  bool preferDefaultFirst = false,
  int? rememberedIndex,
  String? rememberedTitle,
}) {
  if (matches.isEmpty) return null;
  if (rememberedIndex != null) {
    final exact = matches.where((s) => s['Index'] == rememberedIndex).firstOrNull;
    if (exact != null) return (exact['Index'] as num?)?.toInt();
  }
  final normTitle = rememberedTitle?.trim().toLowerCase();
  if (normTitle != null && normTitle.isNotEmpty) {
    final byTitle = matches
        .where((s) => _streamTitle(s)?.trim().toLowerCase() == normTitle)
        .firstOrNull;
    if (byTitle != null) return (byTitle['Index'] as num?)?.toInt();
  }
  final sorted = List<Map<String, dynamic>>.of(matches)
    ..sort((a, b) => _compareAudioQuality(a, b, preferDefaultFirst: preferDefaultFirst));
  return (sorted.first['Index'] as num?)?.toInt();
}

/// Selects the initial audio stream index for EmbyView playback.
///
/// Priority:
/// 1. Explicit pick for this item ([explicitIndex] / [session.explicitAudioIndex])
/// 2. Series remembered track ([seriesPref])
/// 3. In-session carried language ([session.audioLanguage])
/// 4. EmbyView [LocalPreferences.audioLanguages] (empty = follow media default)
int? selectEmbyViewAudioIndex({
  required List<Map<String, dynamic>> audioStreams,
  required LocalPreferences prefs,
  int? explicitIndex,
  SeriesTrackPreference seriesPref = SeriesTrackPreference.empty,
  SessionTrackChoices session = const SessionTrackChoices(),
}) {
  final streams = audioStreams.where((s) => s['Type'] == 'Audio' && s['Index'] != null).toList();
  if (streams.isEmpty) return null;

  final directExplicit = explicitIndex ?? session.explicitAudioIndex;
  if (directExplicit != null && streams.any((s) => s['Index'] == directExplicit)) {
    return directExplicit;
  }

  if (seriesPref.isNotEmpty) {
    final matched = matchSeriesTrackIndex(streams: streams, pref: seriesPref);
    if (matched != null) return matched;
  }

  final nonCommentary = streams.where((s) => !isCommentaryAudioStream(s)).toList();
  var candidates = nonCommentary.isNotEmpty ? nonCommentary : streams;
  final nonAd = candidates.where((s) => !isAudioDescriptionAudioStream(s)).toList();
  if (nonAd.isNotEmpty) candidates = nonAd;

  final sessionLang = session.audioLanguage?.trim();
  if (sessionLang != null && sessionLang.isNotEmpty) {
    final ranked = _matchingAudioForLanguages(candidates, [sessionLang]);
    if (ranked.isNotEmpty) {
      return _pickBestAudio(
        ranked,
        rememberedIndex: session.audioIndex,
        rememberedTitle: session.audioTitle,
      );
    }
  }

  if (prefs.audioLanguages.isNotEmpty) {
    final ranked = _matchingAudioForLanguages(candidates, prefs.audioLanguages);
    if (ranked.isNotEmpty) {
      return _pickBestAudio(ranked);
    }
  }

  return _pickBestAudio(candidates, preferDefaultFirst: true);
}

List<Map<String, dynamic>> _matchingAudioForLanguages(
  List<Map<String, dynamic>> candidates,
  List<String> languages,
) {
  TrackLanguageRank? bestRank;
  final winners = <Map<String, dynamic>>[];
  for (final stream in candidates) {
    final rank = rankTrackLanguage(
      languages,
      language: stream['Language'] as String?,
      title: _streamTitle(stream),
    );
    if (rank == null) continue;
    if (bestRank == null || compareTrackLanguageRank(rank, bestRank) < 0) {
      bestRank = rank;
      winners
        ..clear()
        ..add(stream);
    } else if (compareTrackLanguageRank(rank, bestRank) == 0) {
      winners.add(stream);
    }
  }
  return winners;
}

int? _pickBestSubtitleForLanguages(
  List<Map<String, dynamic>> subtitleStreams,
  List<String> languages,
) {
  final scored = <({Map<String, dynamic> stream, int originalIndex, TrackLanguageRank rank})>[];
  for (var i = 0; i < subtitleStreams.length; i++) {
    final stream = subtitleStreams[i];
    if (stream['Index'] == null) continue;
    final rank = rankTrackLanguage(
      languages,
      language: stream['Language'] as String?,
      title: _streamTitle(stream),
    );
    if (rank == null) continue;
    scored.add((stream: stream, originalIndex: i, rank: rank));
  }
  if (scored.isEmpty) return null;

  scored.sort((a, b) {
    final byRank = compareTrackLanguageRank(a.rank, b.rank);
    if (byRank != 0) return byRank;

    final aSpecial = isSpecialSubtitleStream(a.stream);
    final bSpecial = isSpecialSubtitleStream(b.stream);
    if (aSpecial != bSpecial) return aSpecial ? 1 : -1;

    final aForced = isForcedSubtitleStream(a.stream);
    final bForced = isForcedSubtitleStream(b.stream);
    if (aForced != bForced) return aForced ? 1 : -1;

    final aSdh = isSdhSubtitleStream(a.stream);
    final bSdh = isSdhSubtitleStream(b.stream);
    if (aSdh != bSdh) return aSdh ? 1 : -1;

    final aDefault = a.stream['IsDefault'] == true;
    final bDefault = b.stream['IsDefault'] == true;
    if (aDefault != bDefault) return aDefault ? -1 : 1;

    return a.originalIndex.compareTo(b.originalIndex);
  });

  return (scored.first.stream['Index'] as num?)?.toInt();
}

/// Selects the initial subtitle stream index for EmbyView playback, or `-1`
/// for explicit off.
///
/// Priority:
/// 1. Explicit pick for this item ([explicitIndex])
/// 2. Series remembered track ([seriesSubtitlePref])
/// 3. In-session carried preference ([session.subtitleEnabled] / [session.subtitleLanguage])
/// 4. EmbyView [LocalPreferences.subtitleAutoMode] & [LocalPreferences.subtitleLanguages]
int? selectEmbyViewSubtitleIndex({
  required List<Map<String, dynamic>> subtitleStreams,
  required List<Map<String, dynamic>> audioStreams,
  required LocalPreferences prefs,
  int? explicitIndex,
  SeriesTrackPreference seriesAudioPref = SeriesTrackPreference.empty,
  SeriesTrackPreference seriesSubtitlePref = SeriesTrackPreference.empty,
  SessionTrackChoices session = const SessionTrackChoices(),
  String? systemLocaleLanguage,
}) {
  if (explicitIndex != null) return explicitIndex;

  if (seriesSubtitlePref.isNone) return -1;
  if (seriesSubtitlePref.isNotEmpty) {
    final matched = matchSeriesTrackIndex(
      streams: subtitleStreams,
      pref: seriesSubtitlePref,
    );
    if (matched != null) return matched;
  }

  if (session.subtitleEnabled == false) return -1;

  final carriedLang = session.subtitleLanguage?.trim();
  if (carriedLang != null && carriedLang.isNotEmpty) {
    final matched = _pickBestSubtitleForLanguages(subtitleStreams, [carriedLang]);
    if (matched != null) return matched;
  }

  if (seriesSubtitlePref.language.isNotEmpty) {
    final matched = _pickBestSubtitleForLanguages(subtitleStreams, [seriesSubtitlePref.language]);
    if (matched != null) return matched;
  }

  if (prefs.subtitleAutoMode == SubtitleAutoMode.off) return -1;

  if (prefs.subtitleAutoMode == SubtitleAutoMode.foreignOnly) {
    final effectiveAudioIndex = selectEmbyViewAudioIndex(
      audioStreams: audioStreams,
      prefs: prefs,
      seriesPref: seriesAudioPref,
      session: session,
    );
    final activeAudio = audioStreams
        .where((s) => s['Index'] == effectiveAudioIndex)
        .firstOrNull;
    if (isNativeAudioForSubtitlePolicy(
      prefs: prefs,
      activeAudioLanguage: activeAudio?['Language'] as String?,
      activeAudioTitle: activeAudio == null ? null : _streamTitle(activeAudio),
      systemLocaleLanguage: systemLocaleLanguage,
    )) {
      return -1;
    }
  }

  if (subtitleStreams.isEmpty) return -1;

  if (prefs.subtitleLanguages.isEmpty) {
    final defaultStream = subtitleStreams
        .where((s) => s['Index'] != null && s['IsDefault'] == true)
        .firstOrNull;
    return (defaultStream?['Index'] as num?)?.toInt() ?? -1;
  }

  return _pickBestSubtitleForLanguages(subtitleStreams, prefs.subtitleLanguages) ?? -1;
}
