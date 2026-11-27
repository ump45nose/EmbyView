import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../contracts/accounts.dart';
import '../contracts/common.dart';
import '../contracts/media.dart';
import '../contracts/preferences.dart';
import '../contracts/subtitles.dart';

/// Device choices are independent of Moonfin's per-user preference scope.
class MachinePreferences implements EmbyViewPreferences {
  MachinePreferences._(
    this._store,
    this._secrets,
    this._folder,
    this._defaults,
    this._loadDefaultZones,
  ) {
    try {
      final raw = _store.getString(_key);
      _current = _decode(raw == null ? {} : jsonDecode(raw) as Map);
    } catch (_) {
      _current = LocalPreferences(zones: _defaults);
    }
  }

  static const _key = 'embyview.machine.v1';
  static Future<MachinePreferences> open({
    SharedPreferences? store,
    FlutterSecureStorage secrets = const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
    MethodChannel folder = const MethodChannel('embyview/media_folder'),
    List<ZonePreference> defaultZones = const [],
    Future<List<ZonePreference>> Function()? loadDefaultZones,
  }) async {
    final result = MachinePreferences._(
      store ?? await SharedPreferences.getInstance(),
      secrets,
      folder,
      List.unmodifiable(defaultZones),
      loadDefaultZones,
    );
    await result.mediaFolderStatus();
    return result;
  }

  final SharedPreferences _store;
  final FlutterSecureStorage _secrets;
  final MethodChannel _folder;
  final List<ZonePreference> _defaults;
  final Future<List<ZonePreference>> Function()? _loadDefaultZones;
  final _changes = StreamController<LocalPreferences>.broadcast(sync: true);
  late LocalPreferences _current;
  Future<void> _write = Future.value();
  @override
  LocalPreferences get current => _current;
  @override
  Stream<LocalPreferences> get changes => _changes.stream;

  Future<void> _save(FutureOr<LocalPreferences> Function() value) {
    final operation = _write.then((_) async {
      final candidate = _decode(
        _encode(await value()),
        mediaFolder: _current.mediaFolder,
      );
      try {
        if (!await _store.setString(_key, jsonEncode(_encode(candidate)))) {
          throw StateError('Preference write rejected');
        }
      } catch (_) {
        throw const EmbyViewFailure('无法保存本机设置，请重试。', retryable: true);
      }
      _current = candidate;
      _changes.add(_current);
    });
    _write = operation.catchError((_) {});
    return operation;
  }

  @override
  Future<void> update(LocalPreferences value) => _save(() => value);
  LocalPreferences _withZones(List<ZonePreference> zones) => _decode({
    ..._encode(_current),
    'zones': zones.map(_zoneJson).toList(),
  }, mediaFolder: _current.mediaFolder);

  Future<List<ZonePreference>> _editableZones({bool reset = false}) async {
    if (!reset && _current.zones.isNotEmpty) return _current.zones;
    try {
      return List.unmodifiable(await _loadDefaultZones?.call() ?? _defaults);
    } catch (error) {
      if (error is EmbyViewFailure) rethrow;
      throw const EmbyViewFailure('无法读取默认片库，设置未更改。', retryable: true);
    }
  }

  @override
  Future<void> saveZone(ZonePreference value) => _save(() async {
    final zones = [...await _editableZones()];
    final index = zones.indexWhere((z) => z.id == value.id);
    if (index < 0) {
      zones.add(value);
    } else {
      zones[index] = value;
    }
    return _withZones(zones);
  });
  @override
  Future<void> removeCustomZone(String zoneId) => _save(
    () async => _withZones(
      (await _editableZones())
          .where((z) => z.id != zoneId || !z.custom)
          .toList(),
    ),
  );
  @override
  Future<void> reorderZones(List<String> ids) => _save(() async {
    final remaining = {for (final z in await _editableZones()) z.id: z};
    final ordered = <ZonePreference>[];
    for (final id in ids) {
      final z = remaining.remove(id);
      if (z != null) ordered.add(z);
    }
    return _withZones([...ordered, ...remaining.values]);
  });
  @override
  Future<void> resetZones() =>
      _save(() async => _withZones(await _editableZones(reset: true)));

  @override
  Future<bool> authorizeMediaFolder({required String embyRoot}) async {
    if (!embyRoot.startsWith('/')) {
      throw const EmbyViewFailure('请填写 Emby 的绝对媒体根路径。');
    }
    try {
      final result = await _folder.invokeMapMethod<String, dynamic>(
        'authorize',
        {'embyRoot': embyRoot},
      );
      if (result?['cancelled'] == true) return false;
      _publishFolder(_folderStatus(result ?? {}, embyRoot));
      return _current.mediaFolder.state == MediaFolderState.authorized;
    } on MissingPluginException {
      throw const EmbyViewFailure('当前环境未提供媒体目录授权。');
    } on PlatformException {
      throw const EmbyViewFailure('无法授权媒体目录，请重新选择。', retryable: true);
    }
  }

  @override
  Future<MediaFolderStatus> mediaFolderStatus() async {
    try {
      final result = await _folder.invokeMapMethod<String, dynamic>('status');
      _publishFolder(
        _folderStatus(result ?? {}, _current.mediaFolder.embyRoot),
      );
    } on MissingPluginException {
      _publishFolder(
        const MediaFolderStatus(state: MediaFolderState.unconfigured),
      );
    } on PlatformException {
      _publishFolder(
        MediaFolderStatus(
          state: MediaFolderState.invalid,
          embyRoot: _current.mediaFolder.embyRoot,
          reason: '无法读取目录授权，请重新选择。',
        ),
      );
    }
    return _current.mediaFolder;
  }

  MediaFolderStatus _folderStatus(Map<String, dynamic> value, String root) {
    final state = value['authorized'] == true
        ? MediaFolderState.authorized
        : _enum(
            MediaFolderState.values,
            value['state'],
            value['stale'] == true
                ? MediaFolderState.invalid
                : MediaFolderState.unconfigured,
          );
    return MediaFolderStatus(
      state: state,
      embyRoot: value['embyRoot'] as String? ?? root,
      localRoot: state == MediaFolderState.authorized
          ? value['path'] as String?
          : null,
      writable: state == MediaFolderState.authorized
          ? value['writable'] as bool?
          : null,
      reason: value['reason'] as String?,
    );
  }

  void _publishFolder(MediaFolderStatus status) {
    _current = _decode(_encode(_current), mediaFolder: status);
    _changes.add(_current);
  }

  String _secretKey(SecretKind kind, [Uri? translationBase]) {
    final name = 'embyview.secret.${kind.name}';
    if (kind != SecretKind.openAi) return name;
    final origin = (translationBase ?? parseTranslationBaseUrl(_current.translationBaseUrl))?.origin;
    if (origin == null) throw const EmbyViewFailure('请在设置中填写有效的翻译服务地址。', code: 'subtitle_translation_url');
    // Existing installations used the unqualified key for the official OpenAI service.
    return origin == Uri.parse(defaultTranslationBaseUrl).origin ? name : '$name.$origin';
  }

  Future<String?> readTranslationKey(Uri base) => _readKey(_secretKey(SecretKind.openAi, base));

  /// Internal subtitle/provider port; never exported through the UI contract.
  Future<String?> readSecret(SecretKind kind) => _readKey(_secretKey(kind));

  Future<String?> _readKey(String key) async {
    try {
      return await _secrets.read(key: key);
    } catch (_) {
      throw const EmbyViewFailure('无法读取钥匙串，请检查系统授权。', retryable: true);
    }
  }

  @override
  Future<Set<SecretKind>> configuredSecrets() async => Set.unmodifiable({
    for (final kind in SecretKind.values)
      if ((await readSecret(kind))?.isNotEmpty == true) kind,
  });

  @override
  Future<void> setSecret(SecretKind kind, String? value) async {
    final key = _secretKey(kind);
    try {
      if (value == null || value.trim().isEmpty) {
        await _secrets.delete(key: key);
      } else {
        await _secrets.write(key: key, value: value.trim());
      }
    } catch (_) {
      throw const EmbyViewFailure('无法保存钥匙串，请检查系统授权。', retryable: true);
    }
  }

  Map<String, Object?> _encode(LocalPreferences p) => {
    'theme': p.theme.name,
    'navigation': p.navigation.name,
    'seriesSort': p.seriesSort.name,
    'chooseUser': p.chooseUserOnStartup,
    'onboardingDismissed': p.onboardingDismissed,
    'autoSwitchServerAddress': p.autoSwitchServerAddress,
    'serverAddresses': {
      for (final entry in p.serverAddresses.entries)
        entry.key: entry.value.map(_serverAddressJson).toList(),
    },
    'backgroundVideo': p.backgroundVideo,
    'backgroundDelay': p.backgroundVideoDelay.inMilliseconds,
    'trailerDelay': p.detailTrailerDelay?.inSeconds,
    'themeMusic': p.themeMusic,
    'themeVolume': p.themeVolume,
    'quickLook': p.quickLook,
    'hideOverview': p.hideUnwatchedOverview,
    'preResolve115': p.preResolve115,
    'readAheadBytes': p.readAheadBytes,
    'autoPlayNext': p.autoPlayNext,
    'anime4kAnime': p.anime4kForAnime,
    'anime4kOther': p.anime4kForOther,
    'audioLanguages': p.audioLanguages,
    'subtitleLanguages': p.subtitleLanguages,
    'subtitleAutoMode': p.subtitleAutoMode.name,
    'subtitleSources': p.subtitleSources.map((s) => s.name).toList(),
    'translationBaseUrl': p.translationBaseUrl,
    'translationModel': p.translationModel,
    'budget': p.monthlyBudgetMicros,
    'zones': p.zones.map(_zoneJson).toList(),
  };
  LocalPreferences _decode(
    Map stored, {
    MediaFolderStatus mediaFolder = const MediaFolderStatus(
      state: MediaFolderState.unconfigured,
    ),
  }) {
    final d = LocalPreferences(zones: _defaults);
    final p = {..._encode(d), ...stored};
    return LocalPreferences(
      theme: _enum(ThemeMode.values, p['theme'], d.theme),
      navigation: _enum(NavigationStyle.values, p['navigation'], d.navigation),
      seriesSort: _enum(ShelfSort.values, p['seriesSort'], d.seriesSort),
      chooseUserOnStartup: p['chooseUser'] as bool,
      onboardingDismissed: p['onboardingDismissed'] is bool
          ? p['onboardingDismissed'] as bool
          : d.onboardingDismissed,
      autoSwitchServerAddress: p['autoSwitchServerAddress'] is bool
          ? p['autoSwitchServerAddress'] as bool
          : d.autoSwitchServerAddress,
      serverAddresses: _decodeServerAddresses(p['serverAddresses']),
      backgroundVideo: p['backgroundVideo'] as bool,
      backgroundVideoDelay: Duration(
        milliseconds: (p['backgroundDelay'] as int).clamp(0, 60000),
      ),
      detailTrailerDelay: [8, 12, 20].contains(p['trailerDelay'])
          ? Duration(seconds: p['trailerDelay'] as int)
          : null,
      themeMusic: p['themeMusic'] as bool,
      themeVolume: (p['themeVolume'] as num).toDouble().clamp(0, 1),
      quickLook: p['quickLook'] as bool,
      hideUnwatchedOverview: p['hideOverview'] as bool,
      preResolve115: p['preResolve115'] as bool,
      readAheadBytes: (p['readAheadBytes'] as int).clamp(0, 1024 * 1024 * 1024),
      autoPlayNext: p['autoPlayNext'] as bool,
      anime4kForAnime: p['anime4kAnime'] as bool,
      anime4kForOther: p['anime4kOther'] as bool,
      audioLanguages: _decodeLanguages(
        stored.containsKey('audioLanguages') ? stored['audioLanguages'] : d.audioLanguages,
        d.audioLanguages,
      ),
      subtitleLanguages: _decodeLanguages(
        stored.containsKey('subtitleLanguages') ? stored['subtitleLanguages'] : d.subtitleLanguages,
        d.subtitleLanguages,
      ),
      subtitleAutoMode: stored.containsKey('subtitleAutoMode')
          ? _enum(SubtitleAutoMode.values, stored['subtitleAutoMode'], d.subtitleAutoMode)
          : stored['autoChinese'] is bool
          ? ((stored['autoChinese'] as bool) ? SubtitleAutoMode.always : SubtitleAutoMode.off)
          : d.subtitleAutoMode,
      subtitleSources: Set.unmodifiable(
        SubtitleSource.values.where(
          (s) => (p['subtitleSources'] as List).contains(s.name),
        ),
      ),
      translationBaseUrl: (p['translationBaseUrl'] as String?)?.trim() ?? d.translationBaseUrl,
      translationModel: (p['translationModel'] as String?)?.trim() ?? d.translationModel,
      monthlyBudgetMicros: (p['budget'] as int).clamp(0, 1000000000000),
      mediaFolder: mediaFolder,
      zones: List.unmodifiable(
        (p['zones'] as List).map((z) => _zone(z as Map)),
      ),
    );
  }

  Map<String, Object?> _zoneJson(ZonePreference z) => {
    'id': z.id,
    'name': z.name,
    'icon': z.iconKey,
    'color': z.colorSlot,
    'custom': z.custom,
    'rule': switch (z.rule) {
      LibraryZoneRule r => ['library', r.libraryId],
      GenreZoneRule r => ['genre', r.genreId],
      TechnologyZoneRule r => ['technology', r.technology.name],
    },
  };
  ZonePreference _zone(Map z) {
    final r = z['rule'] as List;
    final rule = switch (r[0]) {
      'library' => ZoneRule.library(r[1] as String),
      'genre' => ZoneRule.genre(r[1] as String),
      'technology' => ZoneRule.technology(
        TechFilter.values.byName(r[1] as String),
      ),
      _ => throw const FormatException('Unknown zone rule'),
    };
    return ZonePreference(
      id: z['id'] as String,
      name: z['name'] as String,
      iconKey: z['icon'] as String,
      colorSlot: z['color'] as int,
      rule: rule,
      custom: z['custom'] as bool,
    );
  }

  Map<String, Object?> _serverAddressJson(ServerAddressEntry a) => {
    'id': a.id,
    'url': a.url,
    'label': a.label,
    'subtitle': a.subtitle,
  };

  Map<String, List<ServerAddressEntry>> _decodeServerAddresses(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, List<ServerAddressEntry>>{};
    for (final entry in raw.entries) {
      final serverId = entry.key;
      final list = entry.value;
      if (serverId is! String || serverId.isEmpty || list is! List) continue;
      final parsed = <ServerAddressEntry>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id'];
        final url = item['url'];
        if (id is! String || id.isEmpty || url is! String || url.isEmpty) {
          continue;
        }
        parsed.add(
          ServerAddressEntry(
            id: id,
            url: url,
            label: item['label'] as String? ?? '',
            subtitle: item['subtitle'] as String? ?? '',
          ),
        );
      }
      if (parsed.isNotEmpty) {
        out[serverId] = List.unmodifiable(parsed);
      }
    }
    return Map.unmodifiable(out);
  }

  List<String> _decodeLanguages(Object? raw, List<String> fallback) {
    if (raw is! List) return fallback;
    final seen = <String>{};
    final out = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      final normalized = normalizePreferenceLanguageCode(item);
      if (normalized == null || !seen.add(normalized)) continue;
      out.add(normalized);
    }
    return List.unmodifiable(out);
  }

  T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  Future<void> close() async {
    await _write;
    await _changes.close();
  }
}
