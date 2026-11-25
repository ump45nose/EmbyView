import 'package:moonfin/embyview/embyview.dart';

final RegExp _kSeasonNumberRe = RegExp(
  r'^(?:s|sea|season|季|第)?[-_\s]*(\d{1,2})(?:\s*季)?$',
  caseSensitive: false,
);
final RegExp _kGenericEpisodeTitleRe = RegExp(
  r'^(?:第\s*\d+\s*集|episode\s*\d*)$',
  caseSensitive: false,
);

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
    quality?.origin == MediaOrigin.nasLocal ? 'NAS 本地 · 直接播放' : '115 直连',
    for (final tag in [quality?.resolution, quality?.videoRange, quality?.audioLabel])
      if (tag != null && tag.trim().isNotEmpty) tag.trim(),
  ];
  return parts.join(' · ');
}

/// Returns `true` when [title] is a generic placeholder such as `第 9 集` or `Episode 9`.
bool evIsGenericEpisodeTitle(String title) =>
    _kGenericEpisodeTitleRe.hasMatch(title.trim());

/// Formats a concise episode heading for pause overlays (`第 N 集 · 集名` or `第 N 集`),
/// or returns `null` for non-episodes.
String? evFormatPauseEpisodeTitle(MediaCard? item, PlayTarget target) {
  final epNum = item?.episodeNumber ?? target.episodeNumber;
  final raw = item?.title.trim() ?? '';
  if (item?.kind == MediaKind.episode || epNum != null) {
    if (epNum == null) return raw.isNotEmpty ? raw : null;
    final distinct = raw.isNotEmpty && !evIsGenericEpisodeTitle(raw);
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
  if ((item?.kind == MediaKind.episode || epNum != null) && epNum != null) {
    final seasonNum = _parseSeasonNumber(item?.seasonId ?? target.seasonId);
    final primary = seasonNum != null ? '第 $seasonNum 季 · 第 $epNum 集' : '第 $epNum 集';
    final raw = item?.title.trim() ?? '';
    final secondary = raw.isNotEmpty && !evIsGenericEpisodeTitle(raw) ? raw : '';
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
