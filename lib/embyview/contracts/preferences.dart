import 'media.dart';
import 'subtitles.dart';

enum ThemeMode { cinema, paper, automatic }

enum NavigationStyle { icon, iconAndText, text }

enum SecretKind { openAi, gemini, assrt, openSubtitles }

enum TranslationProvider { gemini, openAi }

enum MediaFolderState { unconfigured, authorized, denied, unmounted, invalid }

class MediaFolderStatus {
  const MediaFolderStatus({
    required this.state,
    this.embyRoot = '/mnt/media',
    this.localRoot,
    this.writable,
    this.reason,
  });

  final MediaFolderState state;
  final String embyRoot;
  final String? localRoot;
  final bool? writable;
  final String? reason;
}

class LocalPreferences {
  const LocalPreferences({
    this.theme = ThemeMode.cinema,
    this.navigation = NavigationStyle.icon,
    this.seriesSort = ShelfSort.added,
    this.chooseUserOnStartup = true,
    this.backgroundVideo = true,
    this.backgroundVideoDelay = const Duration(milliseconds: 1700),
    this.detailTrailerDelay = const Duration(seconds: 12),
    this.themeMusic = true,
    this.themeVolume = 0.35,
    this.quickLook = true,
    this.hideUnwatchedOverview = true,
    this.preResolve115 = true,
    this.readAheadBytes = 256 * 1024 * 1024,
    this.autoPlayNext = true,
    this.anime4kForAnime = true,
    this.anime4kForOther = false,
    this.subtitleLanguages = const ['zh', 'ja', 'en'],
    this.autoSelectChineseSubtitle = true,
    this.subtitleSources = const {
      SubtitleSource.xunlei,
      SubtitleSource.assrt,
      SubtitleSource.openSubtitles,
      SubtitleSource.anime,
    },
    this.translationProvider = TranslationProvider.gemini,
    this.monthlyBudgetMicros = 30000000,
    this.mediaFolder = const MediaFolderStatus(
      state: MediaFolderState.unconfigured,
    ),
    this.zones = const [],
  });

  final ThemeMode theme;
  final NavigationStyle navigation;
  final ShelfSort seriesSort;
  final bool chooseUserOnStartup;
  final bool backgroundVideo;
  final Duration backgroundVideoDelay;

  /// Null disables detail trailers. Supported delays are 8, 12 and 20 seconds.
  final Duration? detailTrailerDelay;
  final bool themeMusic;
  final double themeVolume;
  final bool quickLook;
  final bool hideUnwatchedOverview;
  final bool preResolve115;
  final int readAheadBytes;
  final bool autoPlayNext;
  final bool anime4kForAnime;
  final bool anime4kForOther;
  final List<String> subtitleLanguages;
  final bool autoSelectChineseSubtitle;
  final Set<SubtitleSource> subtitleSources;
  final TranslationProvider translationProvider;
  final int monthlyBudgetMicros;
  final MediaFolderStatus mediaFolder;
  final List<ZonePreference> zones;
}

abstract interface class EmbyViewPreferences {
  LocalPreferences get current;
  Stream<LocalPreferences> get changes;
  Future<void> update(LocalPreferences value);
  Future<void> saveZone(ZonePreference value);
  Future<void> removeCustomZone(String zoneId);
  Future<void> reorderZones(List<String> ids);
  Future<void> resetZones();
  Future<bool> authorizeMediaFolder({required String embyRoot});
  Future<MediaFolderStatus> mediaFolderStatus();
  Future<Set<SecretKind>> configuredSecrets();
  Future<void> setSecret(SecretKind kind, String? value);
}
