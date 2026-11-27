import 'package:moonfin/embyview/embyview.dart';

final RegExp _kSeasonNumberRe = RegExp(
  r'^(?:s|sea|season|季|第)[-_\s]*(\d{1,2})(?:\s*季)?$',
  caseSensitive: false,
);
final RegExp _kGenericEpisodeTitleRe = RegExp(
  r'^(?:第\s*(\d+)\s*集|episode\s*(\d*))$',
  caseSensitive: false,
);
final RegExp _kEnglishChapterNumberRe = RegExp(
  r'^chapter\s*[-_#:]?\s*(\d+)$',
  caseSensitive: false,
);
final RegExp _kEnglishPartNumberRe = RegExp(
  r'^part\s*[-_#:]?\s*(\d+)$',
  caseSensitive: false,
);
final RegExp _kEnglishSceneNumberRe = RegExp(
  r'^scene\s*[-_#:]?\s*(\d+)$',
  caseSensitive: false,
);
final RegExp _kEnglishActNumberRe = RegExp(
  r'^act\s*[-_#:]?\s*(\d+)$',
  caseSensitive: false,
);

const Map<String, String> _kEnglishChapterNames = {
  'intro': '片头',
  'introduction': '片头',
  'opening': '片头',
  'opening credits': '片头',
  'opening theme': '片头曲',
  'op': '片头',
  'outro': '片尾',
  'ending': '片尾',
  'credits': '片尾',
  'end credits': '片尾',
  'closing credits': '片尾',
  'ending theme': '片尾曲',
  'ed': '片尾',
  'prologue': '序幕',
  'epilogue': '尾声',
  'recap': '前情提要',
  'previously': '前情提要',
  'previously on': '前情提要',
  'preview': '下集预告',
  'next episode': '下集预告',
  'next episode preview': '下集预告',
  'teaser': '预告',
  'title': '片名',
  'title card': '片名',
  'main titles': '片头',
  'post-credits': '片尾彩蛋',
  'post credits': '片尾彩蛋',
  'after credits': '片尾彩蛋',
  'stinger': '片尾彩蛋',
  'intermission': '中场休息',
};

/// Formats a chapter title for Chinese UI display, localizing generic English
/// placeholders (e.g. `Chapter 1`, `Intro`, `Credits`) while preserving custom titles.
String? evFormatChapterLabel(String? rawName, {int? index}) {
  final trimmed = rawName?.trim() ?? '';
  if (trimmed.isEmpty) {
    return index != null && index >= 0 ? '第 ${index + 1} 章' : null;
  }
  final chapterMatch = _kEnglishChapterNumberRe.firstMatch(trimmed);
  if (chapterMatch != null) {
    final num = int.tryParse(chapterMatch.group(1)!);
    return num != null ? '第 $num 章' : trimmed;
  }
  final normalized = trimmed.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final mapped = _kEnglishChapterNames[normalized];
  if (mapped != null) return mapped;
  final partMatch = _kEnglishPartNumberRe.firstMatch(trimmed);
  if (partMatch != null) {
    final num = int.tryParse(partMatch.group(1)!);
    return num != null ? '第 $num 部分' : trimmed;
  }
  final sceneMatch = _kEnglishSceneNumberRe.firstMatch(trimmed);
  if (sceneMatch != null) {
    final num = int.tryParse(sceneMatch.group(1)!);
    return num != null ? '场景 $num' : trimmed;
  }
  final actMatch = _kEnglishActNumberRe.firstMatch(trimmed);
  if (actMatch != null) {
    final num = int.tryParse(actMatch.group(1)!);
    return num != null ? '第 $num 幕' : trimmed;
  }
  return trimmed;
}

/// Formats a playback timestamp as `h:mm:ss` when `>= 1 hour` or `m:ss` otherwise.
String evFormatPlayerTime(Duration d) {
  final totalSeconds = d.isNegative ? 0 : d.inSeconds;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = (totalSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Formats a local wall-clock time as `H:mm` (e.g. `21:42`, `9:05`).
String evFormatClockTime(DateTime dt) =>
    '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';

/// Formats an AI subtitle lead duration (e.g. `3 分 32 秒`, `45 秒`, `2 分`).
String evFormatLeadDuration(Duration d) {
  final total = d.isNegative ? 0 : d.inSeconds;
  final m = total ~/ 60, s = total % 60;
  if (m <= 0) return '$s 秒';
  return s == 0 ? '$m 分' : '$m 分 $s 秒';
}

/// Formats the scrub bar remaining line: `-{remaining} · {endClock} 结束`.
String evFormatRemainingLine(Duration remaining, DateTime now) {
  final safe = remaining.isNegative ? Duration.zero : remaining;
  return '-${evFormatPlayerTime(safe)} · ${evFormatClockTime(now.add(safe))} 结束';
}

/// Formats the pause card remaining line: `剩 {ceilMinutes} 分钟 · {endClock} 结束`.
String evFormatPauseRemainingLine(Duration remaining, DateTime now) {
  final safe = remaining.isNegative ? Duration.zero : remaining;
  final mins = remaining.inSeconds <= 0 ? 0 : (remaining.inSeconds / 60).ceil();
  return '剩 $mins 分钟 · ${evFormatClockTime(now.add(safe))} 结束';
}

/// Formats the top-right playback technical pill summary.
String evPlayerTechSummary(MediaQuality? quality) {
  final parts = <String>[
    if (quality?.origin case MediaOrigin.direct115) '115 直连',
    if (quality?.origin case MediaOrigin.nasLocal) 'NAS 本地',
    for (final tag in [quality?.resolution, quality?.audioLabel])
      if (tag != null && tag.trim().isNotEmpty) tag.trim(),
  ];
  return parts.join(' · ');
}

/// Returns `true` when [title] is a generic placeholder such as `第 9 集` or `Episode 9`.
bool evIsGenericEpisodeTitle(String title, {int? episodeNumber}) {
  final match = _kGenericEpisodeTitleRe.firstMatch(title.trim());
  if (match == null) return false;
  final digits = match[1] ?? match[2]!;
  return episodeNumber == null || digits.isEmpty || int.tryParse(digits) == episodeNumber;
}

/// Formats a concise episode heading for pause overlays (`第 N 集 · 集名` or `第 N 集`),
/// or returns `null` for non-episodes.
String? evFormatPauseEpisodeTitle(MediaCard? item, PlayTarget target) {
  final epNum = item?.episodeNumber ?? target.episodeNumber;
  final raw = item?.title.trim() ?? '';
  if (item?.kind == MediaKind.episode || epNum != null) {
    if (epNum == null) return raw.isNotEmpty ? raw : null;
    final distinct = raw.isNotEmpty && !evIsGenericEpisodeTitle(raw, episodeNumber: epNum);
    return distinct ? '第 $epNum 集 · $raw' : '第 $epNum 集';
  }
  return null;
}

/// Formats episode (`第 X 季 · 第 Y 集` + episode title) or movie (`年份` + `时长`) meta.
({String primary, String secondary}) evPlayerEpisodeMeta(
  MediaCard? item,
  PlayTarget target,
) {
  final epNum = item?.episodeNumber ?? target.episodeNumber;
  if (item?.kind == MediaKind.episode || epNum != null) {
    final seasonNum = item?.seasonNumber ?? _parseSeasonNumber(item?.seasonId ?? target.seasonId);
    final primary = [if (seasonNum != null) '第 $seasonNum 季', if (epNum != null) '第 $epNum 集'].join(' · ');
    final raw = item?.title.trim() ?? '';
    final secondary = epNum != null && evIsGenericEpisodeTitle(raw, episodeNumber: epNum) ? '' : raw;
    return (primary: primary, secondary: secondary);
  }
  final primary = item?.year != null ? '${item!.year}' : '';
  final secs = item?.duration?.inSeconds ?? 0;
  final mins = secs > 0 ? (secs / 60).round() : 0;
  return (primary: primary, secondary: mins > 0 ? '$mins 分钟' : '');
}

int? _parseSeasonNumber(String? seasonId) {
  final match = seasonId == null ? null : _kSeasonNumberRe.firstMatch(seasonId.trim());
  final value = match == null ? null : int.tryParse(match.group(1)!);
  return value != null && value > 0 ? value : null;
}
