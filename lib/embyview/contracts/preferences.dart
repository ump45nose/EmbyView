import 'accounts.dart';
import 'media.dart';
import 'subtitles.dart';

enum ThemeMode { cinema, paper, automatic }

enum NavigationStyle { icon, iconAndText, text }

enum SecretKind { openAi, assrt, openSubtitles }

enum SubtitleAutoMode { always, foreignOnly, off }

enum DefaultVersionRule { bestQuality, lastSimilar, smallestSize }

String defaultVersionRuleLabel(DefaultVersionRule rule) => switch (rule) {
  DefaultVersionRule.bestQuality => '画质最高',
  DefaultVersionRule.lastSimilar => '上次选的同类',
  DefaultVersionRule.smallestSize => '体积最小',
};

String defaultVersionRuleSentenceLabel(DefaultVersionRule rule) => switch (rule) {
  DefaultVersionRule.bestQuality => '画质最高',
  DefaultVersionRule.lastSimilar => '上次选的同类版本',
  DefaultVersionRule.smallestSize => '体积最小',
};

typedef LanguageOption = ({String code, String label});

const List<LanguageOption> defaultAudioLanguageOptions = [
  (code: 'zh', label: '中文'),
  (code: 'yue', label: '粤语'),
  (code: 'ja', label: '日语'),
  (code: 'en', label: '英语'),
  (code: 'ko', label: '韩语'),
  (code: 'fr', label: '法语'),
  (code: 'de', label: '德语'),
  (code: 'es', label: '西班牙语'),
];

const List<LanguageOption> defaultSubtitleLanguageOptions = [
  (code: 'zh', label: '简体中文'),
  (code: 'zh-hant', label: '繁体中文'),
  (code: 'ja', label: '日语'),
  (code: 'en', label: '英文'),
  (code: 'ko', label: '韩语'),
  (code: 'fr', label: '法语'),
  (code: 'de', label: '德语'),
  (code: 'es', label: '西班牙语'),
];

/// Normalizes a user preference language code into EmbyView's canonical form.
String? normalizePreferenceLanguageCode(String? raw) {
  final value = raw?.trim().toLowerCase().replaceAll('_', '-') ?? '';
  if (value.isEmpty || value == 'und' || value == 'auto' || value == 'none') {
    return null;
  }
  return switch (value) {
    'zh' || 'zh-cn' || 'zh-sg' || 'zh-hans' || 'chi' || 'zho' || 'cmn' || 'chs' || 'zhs' => 'zh',
    'zh-tw' || 'zh-hk' || 'zh-mo' || 'zh-hant' || 'cht' || 'zht' => 'zh-hant',
    'yue' || 'zh-yue' => 'yue',
    'ja' || 'jpn' || 'jp' => 'ja',
    'en' || 'eng' => 'en',
    'ko' || 'kor' => 'ko',
    'fr' || 'fra' || 'fre' => 'fr',
    'de' || 'deu' || 'ger' => 'de',
    'es' || 'spa' => 'es',
    _ => value,
  };
}

String audioLanguageLabel(String code) {
  final normalized = normalizePreferenceLanguageCode(code) ?? code;
  for (final option in defaultAudioLanguageOptions) {
    if (option.code == normalized) return option.label;
  }
  return normalized == 'zh-hant' ? '中文' : code;
}

String subtitleLanguageLabel(String code) {
  final normalized = normalizePreferenceLanguageCode(code) ?? code;
  for (final option in defaultSubtitleLanguageOptions) {
    if (option.code == normalized) return option.label;
  }
  return normalized == 'yue' ? '粤语' : code;
}

const defaultTranslationBaseUrl = 'https://api.openai.com/v1';
const defaultTranslationModel = 'gpt-5.4-mini';

Uri? parseTranslationBaseUrl(String value) {
  final text = value.trim().replaceFirst(RegExp(r'/+$'), '');
  if (RegExp(r'[\s\\]').hasMatch(text)) return null;
  try {
    final base = Uri.parse(text);
    if (!['https', 'http'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        base.port < 1 ||
        base.port > 65535) {
      return null;
    }
    return base;
  } on FormatException {
    return null;
  }
}

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

const Object _keepPreferenceField = Object();

class LocalPreferences {
  const LocalPreferences({
    this.theme = ThemeMode.cinema,
    this.navigation = NavigationStyle.icon,
    this.seriesSort = ShelfSort.added,
    this.chooseUserOnStartup = true,
    this.onboardingDismissed = false,
    this.autoSwitchServerAddress = true,
    this.serverAddresses = const {},
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
    this.defaultVersionRule = DefaultVersionRule.bestQuality,
    this.warnHighBitrateOnExternalNetwork = true,
    this.anime4kForAnime = true,
    this.anime4kForOther = false,
    this.audioLanguages = const [],
    this.subtitleLanguages = const ['zh', 'ja', 'en'],
    this.subtitleAutoMode = SubtitleAutoMode.always,
    this.subtitleSources = const {
      SubtitleSource.xunlei,
      SubtitleSource.assrt,
      SubtitleSource.openSubtitles,
      SubtitleSource.anime,
    },
    this.translationBaseUrl = defaultTranslationBaseUrl,
    this.translationModel = defaultTranslationModel,
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
  final bool onboardingDismissed;
  final bool autoSwitchServerAddress;
  final Map<String, List<ServerAddressEntry>> serverAddresses;
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
  final DefaultVersionRule defaultVersionRule;
  final bool warnHighBitrateOnExternalNetwork;
  final bool anime4kForAnime;
  final bool anime4kForOther;

  /// Ordered preferred audio language codes. Empty means follow the media default.
  final List<String> audioLanguages;
  final List<String> subtitleLanguages;
  final SubtitleAutoMode subtitleAutoMode;
  final Set<SubtitleSource> subtitleSources;
  final String translationBaseUrl;
  final String translationModel;
  final int monthlyBudgetMicros;
  final MediaFolderStatus mediaFolder;
  final List<ZonePreference> zones;

  LocalPreferences copyWith({
    ThemeMode? theme,
    NavigationStyle? navigation,
    ShelfSort? seriesSort,
    bool? chooseUserOnStartup,
    bool? onboardingDismissed,
    bool? autoSwitchServerAddress,
    Map<String, List<ServerAddressEntry>>? serverAddresses,
    bool? backgroundVideo,
    Duration? backgroundVideoDelay,
    Object? detailTrailerDelay = _keepPreferenceField,
    bool? themeMusic,
    double? themeVolume,
    bool? quickLook,
    bool? hideUnwatchedOverview,
    bool? preResolve115,
    int? readAheadBytes,
    bool? autoPlayNext,
    DefaultVersionRule? defaultVersionRule,
    bool? warnHighBitrateOnExternalNetwork,
    bool? anime4kForAnime,
    bool? anime4kForOther,
    List<String>? audioLanguages,
    List<String>? subtitleLanguages,
    SubtitleAutoMode? subtitleAutoMode,
    Set<SubtitleSource>? subtitleSources,
    String? translationBaseUrl,
    String? translationModel,
    int? monthlyBudgetMicros,
    MediaFolderStatus? mediaFolder,
    List<ZonePreference>? zones,
  }) => LocalPreferences(
    theme: theme ?? this.theme,
    navigation: navigation ?? this.navigation,
    seriesSort: seriesSort ?? this.seriesSort,
    chooseUserOnStartup: chooseUserOnStartup ?? this.chooseUserOnStartup,
    onboardingDismissed: onboardingDismissed ?? this.onboardingDismissed,
    autoSwitchServerAddress:
        autoSwitchServerAddress ?? this.autoSwitchServerAddress,
    serverAddresses: serverAddresses ?? this.serverAddresses,
    backgroundVideo: backgroundVideo ?? this.backgroundVideo,
    backgroundVideoDelay: backgroundVideoDelay ?? this.backgroundVideoDelay,
    detailTrailerDelay: identical(detailTrailerDelay, _keepPreferenceField)
        ? this.detailTrailerDelay
        : detailTrailerDelay as Duration?,
    themeMusic: themeMusic ?? this.themeMusic,
    themeVolume: themeVolume ?? this.themeVolume,
    quickLook: quickLook ?? this.quickLook,
    hideUnwatchedOverview:
        hideUnwatchedOverview ?? this.hideUnwatchedOverview,
    preResolve115: preResolve115 ?? this.preResolve115,
    readAheadBytes: readAheadBytes ?? this.readAheadBytes,
    autoPlayNext: autoPlayNext ?? this.autoPlayNext,
    defaultVersionRule: defaultVersionRule ?? this.defaultVersionRule,
    warnHighBitrateOnExternalNetwork:
        warnHighBitrateOnExternalNetwork ?? this.warnHighBitrateOnExternalNetwork,
    anime4kForAnime: anime4kForAnime ?? this.anime4kForAnime,
    anime4kForOther: anime4kForOther ?? this.anime4kForOther,
    audioLanguages: audioLanguages ?? this.audioLanguages,
    subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
    subtitleAutoMode: subtitleAutoMode ?? this.subtitleAutoMode,
    subtitleSources: subtitleSources ?? this.subtitleSources,
    translationBaseUrl: translationBaseUrl ?? this.translationBaseUrl,
    translationModel: translationModel ?? this.translationModel,
    monthlyBudgetMicros: monthlyBudgetMicros ?? this.monthlyBudgetMicros,
    mediaFolder: mediaFolder ?? this.mediaFolder,
    zones: zones ?? this.zones,
  );
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
