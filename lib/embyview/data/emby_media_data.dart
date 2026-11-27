// dart format width=120
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:server_emby/server_emby.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/utils/bounded_concurrency.dart';

import '../contracts/common.dart';
import '../contracts/media.dart';
import 'backdrop_text_selector.dart';
import 'media_mapper.dart';
import 'title_index.dart';

/// One instance belongs to exactly one authorized server/user session.
/// Its owner disposes it before replacing the authenticated client.
class EmbyMediaData implements EmbyViewData, BrowseCacheInvalidator {
  EmbyMediaData({
    required EmbyMediaServerClient client,
    String? serverId,
    String? Function()? activeServerId,
    List<ZonePreference> Function()? zonePreferences,
    Transliterate? transliterate,
    DateTime Function()? now,
    SharedPreferences? indexStorage,
    BackdropTextDetector? backdropTextDetector,
  }) : _client = client,
       _serverId = serverId,
       _activeServerId = activeServerId,
       _user = client.userId,
       _initialServer = client.baseUrl,
       _lastBaseUrl = client.baseUrl,
       _token = client.accessToken,
       _zonePreferences = zonePreferences ?? (() => const []),
       _transliterate = transliterate ?? MacPinyin.transliterate,
       _now = now ?? DateTime.now,
       _providedStorage = indexStorage {
    _check();
    _backdrops = BackdropTextSelector(
      storage: () => _storage,
      cacheKey: _backdropTextCacheKey,
      detector: backdropTextDetector,
    );
    _mapper = MediaMapper(
      serverUrl: () => _client.baseUrl,
      serverId: _serverId,
      user: _user!,
      token: _token!,
      orderBackdrops: _backdrops.order,
    );
  }

  final EmbyMediaServerClient _client;
  final String? _serverId;
  final String? Function()? _activeServerId;
  final String? _user;
  final String _initialServer;
  String _lastBaseUrl;
  final String? _token;
  final List<ZonePreference> Function() _zonePreferences;
  final Transliterate _transliterate;
  final DateTime Function() _now;
  final SharedPreferences? _providedStorage;
  Future<SharedPreferences>? _storageLoad;
  Future<SharedPreferences> get _storage =>
      _storageLoad ??= _providedStorage == null ? SharedPreferences.getInstance() : Future.value(_providedStorage);
  Future<void>? _restoreLoad;
  String get _cacheIdentity => _serverId ?? _initialServer;
  String get _cacheKey => "embyview.index.v1.${base64Url.encode(utf8.encode(jsonEncode([_cacheIdentity, _user])))}";
  String get _backdropTextCacheKey =>
      "embyview.backdrop_text.v1.${base64Url.encode(utf8.encode(jsonEncode([_cacheIdentity, _user])))}";
  String get _versionChoiceCacheKey =>
      "embyview.version_picks.v1.${base64Url.encode(utf8.encode(jsonEncode([_cacheIdentity, _user])))}";
  final CancelToken _cancel = CancelToken();
  late final BackdropTextSelector _backdrops;
  late final MediaMapper _mapper;
  bool _disposed = false;
  int _revision = 0;
  final _zoneCache = <String, Future<ZoneData>>{};
  final _facetCache = <Object, Future<WallFacets>>{};
  final _wallCache = <Object, Future<WallListing>>{};
  final _titleWalls = <Object, _Wall>{};
  final _requestWaiters = Queue<Completer<void>>();
  int _activeRequests = 0;

  @override
  void invalidateBrowseCache() => _invalidateBrowse();

  void _invalidateBrowse() {
    _revision++;
    _zoneCache.clear();
    _facetCache.clear();
    _wallCache.clear();
    _titleWalls.clear();
  }

  Object _queryKey(WallQuery q, {bool includeSort = true}) => (
    switch (q.scope) {
      ZoneWallScope(:final zoneId) => ('zone', zoneId),
      FeatureWallScope(:final feature) => ('feature', feature),
    },
    includeSort ? q.sort : null,
    q.watched,
    q.genreId,
    q.years?.from,
    q.years?.to,
    q.technology,
  );

  // Futures coalesce concurrent loads too. A failed or invalidated load cannot
  // populate the cache for a newer revision.
  Future<T> _cached<K, T>(Map<K, Future<T>> cache, K key, Future<T> Function() load) async {
    _check();
    await _preferences();
    _check();
    _refreshIndexInBackground();
    final revision = _revision;
    final cached = cache[key];
    final future = cached ?? load();
    if (cached == null) {
      if (cache.length >= 64) cache.remove(cache.keys.first);
      cache[key] = future;
    }
    try {
      final result = await future;
      _check();
      if (revision != _revision) {
        return await _cached(cache, key, load);
      }
      return result;
    } catch (_) {
      if (identical(cache[key], future)) cache.remove(key);
      rethrow;
    }
  }

  // Bound actual HTTP requests, including nested facet and shelf loads.
  Future<T> _boundedRequest<T>(Future<T> Function() request) async {
    if (_activeRequests < 4) {
      _activeRequests++;
    } else {
      final waiter = Completer<void>();
      _requestWaiters.add(waiter);
      await waiter.future;
    }
    try {
      _check();
      return await request();
    } finally {
      if (_requestWaiters.isNotEmpty) {
        _requestWaiters.removeFirst().complete();
      } else {
        _activeRequests--;
      }
    }
  }

  String? _preferenceKey;
  Future<List<Json>>? _viewLoad;
  List<Json> _visibleViews = const [];
  Future<List<_IndexItem>>? _indexLoad;
  List<_IndexItem>? _index;
  DateTime? _indexedAt;
  DateTime? _lastRefreshAttempt;
  int _userDataRevision = 0;
  static const _indexRefreshInterval = Duration(minutes: 5);

  void _refreshIndexInBackground() {
    if (_index == null || _indexedAt == null || _indexLoad != null) return;
    final last = _lastRefreshAttempt ?? _indexedAt!;
    if (_now().toUtc().difference(last) < _indexRefreshInterval) return;
    _lastRefreshAttempt = _now().toUtc();
    unawaited(_catalog(refresh: true).then<void>((_) {}, onError: (Object _) {
      // Browsing can keep using the index; failed sync is retried after the
      // interval, while authorization failures still invalidate via _get.
    }));
  }
  final List<String> _recent = [];
  final Map<String, List<Json>> _collectionArt = {};
  final Map<String, ({String id, String name})> _movieToCollection = {};
  bool _collectionIndexReady = false;
  bool _boxsetMembershipLoaded = false;
  Future<void>? _boxsetMembershipLoad;
  Map<String, String>? _versionPicks;
  VersionTasteProfile? _lastVersionTaste;
  Future<void>? _versionPicksLoad;
  final Set<String> _forbiddenScopes = {};

  static const _fields =
      'OriginalTitle,SortName,PrimaryImageAspectRatio,Overview,Genres,GenreItems,People,Studios,Taglines,RunTimeTicks,ProductionYear,CommunityRating,UserData,MediaStreams,MediaSources,ChildCount,RecursiveItemCount,DateCreated,DateLastSaved,ParentId,SeriesId,SeasonId,IndexNumber,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentLogoItemId,ParentLogoImageTag';
  static const _featureFields = 'PrimaryImageAspectRatio,RunTimeTicks,CommunityRating,UserData';
  static const _hdrVideoTypes = ['Hdr10', 'Hdr10Plus', 'HyperLogGamma', 'DolbyVision'];
  static const _indexFields =
      'OriginalTitle,SortName,ProductionYear,GenreItems,Genres,People,UserData,DateLastSaved,PrimaryImageAspectRatio,RunTimeTicks,CommunityRating,ParentId,SeriesId,Collections';

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancel.cancel('Browse session ended');
    _backdrops.dispose();
    _index = null;
    _visibleViews = const [];
    _recent.clear();
    _collectionArt.clear();
    _movieToCollection.clear();
    _boxsetMembershipLoaded = false;
    _boxsetMembershipLoad = null;
    _versionPicks = null;
    _lastVersionTaste = null;
    _versionPicksLoad = null;
    _invalidateBrowse();
  }

  bool get _sessionMatches =>
      !_disposed &&
      _user != null &&
      _token != null &&
      _client.userId == _user &&
      _client.accessToken == _token &&
      (_serverId == null || _activeServerId == null || _activeServerId() == _serverId);

  void _syncBaseUrlIfChanged() {
    final current = _client.baseUrl;
    if (current == _lastBaseUrl) return;
    _lastBaseUrl = current;
    _invalidateBrowse();
    _viewLoad = null;
    _collectionArt.clear();
    _movieToCollection.clear();
    _collectionIndexReady = false;
    _boxsetMembershipLoaded = false;
    _boxsetMembershipLoad = null;
  }

  void _check() {
    if (!_sessionMatches) {
      dispose();
      throw const EmbyViewFailure('用户会话已改变，请重新打开页面', code: 'session_changed');
    }
    _syncBaseUrlIfChanged();
  }

  Future<dynamic> _get(String resource, {String? id, Json params = const {}}) async {
    _check();
    try {
      final result = await _boundedRequest(
        () => _client.itemsApi.browse(resource, itemId: id, parameters: params, cancelToken: _cancel),
      );
      _check();
      if (resource == 'item' && id != null) _forbiddenScopes.remove(id);
      if (resource == 'items' && params['ParentId'] != null) _forbiddenScopes.remove(params['ParentId'].toString());
      return result;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await (await _storage).remove(_cacheKey);
        await _backdrops.clearPersistedCache();
        dispose();
        throw const EmbyViewFailure('登录已失效或没有访问权限', code: 'unauthorized');
      }
      _check();
      if (e.response?.statusCode == 403) {
        _invalidateBrowse();
        final scope = const ['item', 'seasons', 'episodes'].contains(resource)
            ? id
            : resource == 'items'
            ? params['ParentId']?.toString()
            : null;
        if (scope != null) {
          _forbiddenScopes.add(scope);
          _index = _index?.where((item) => !_isForbidden(item)).toList();
          _collectionArt.clear();
          _collectionIndexReady = false;
          await (await _storage).remove(_cacheKey);
        }
        throw const EmbyViewFailure('没有访问此资源的权限', code: 'forbidden');
      }
      final network =
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout;
      throw EmbyViewFailure(
        network ? '无法连接媒体服务器，请重试' : '媒体服务器未能完成请求',
        retryable: network || (e.response?.statusCode ?? 0) >= 500,
        code: network ? 'network' : 'server',
      );
    }
  }

  Future<void> _mutate(Future<void> Function() action) async {
    _check();
    try {
      await action();
      _check();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await (await _storage).remove(_cacheKey);
        await _backdrops.clearPersistedCache();
        dispose();
        throw const EmbyViewFailure('登录已失效或没有访问权限', code: 'unauthorized');
      }
      _check();
      if (e.response?.statusCode == 403) {
        _invalidateBrowse();
        throw const EmbyViewFailure('没有访问此资源的权限', code: 'forbidden');
      }
      final network =
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout;
      throw EmbyViewFailure(
        network ? '无法连接媒体服务器，请重试' : '媒体服务器未能完成请求',
        retryable: network || (e.response?.statusCode ?? 0) >= 500,
        code: network ? 'network' : 'server',
      );
    }
  }

  Future<void> _syncUserData(String itemId, {bool? favorite, bool? played}) async {
    _userDataRevision++;
    _invalidateBrowse();
    final index = _index;
    if (index == null) return;
    var updated = false;
    for (final item in index) {
      final matchesItem = item.id == itemId;
      final matchesChild = played != null && item.raw['SeriesId']?.toString() == itemId;
      if (!matchesItem && !matchesChild) continue;
      final userData = Map<String, dynamic>.from(item.raw['UserData'] as Map? ?? const {});
      if (matchesItem && favorite != null) userData['IsFavorite'] = favorite;
      if (played != null) {
        userData['Played'] = played;
        if (played) userData['PlaybackPositionTicks'] = 0;
      }
      item.raw['UserData'] = userData;
      updated = true;
    }
    if (updated && _indexedAt != null) {
      await _saveIndex();
    }
  }

  @override
  Future<void> setFavorite(String itemId, bool favorite) async {
    await _mutate(
      () => favorite ? _client.userLibraryApi.markFavorite(itemId) : _client.userLibraryApi.unmarkFavorite(itemId),
    );
    await _syncUserData(itemId, favorite: favorite);
  }

  @override
  Future<void> setPlayed(String itemId, bool played) async {
    await _mutate(
      () => played ? _client.userLibraryApi.markPlayed(itemId) : _client.userLibraryApi.unmarkPlayed(itemId),
    );
    await _syncUserData(itemId, played: played);
  }

  Future<List<Json>> _views() => _viewLoad ??= _get('views')
      .then(itemRecords)
      .then(
        (rows) => _visibleViews = rows
            .where((e) => const ['movies', 'tvshows', 'boxsets', 'mixed', null, ''].contains(e['CollectionType']))
            .toList(),
      )
      .catchError((Object e) {
        _viewLoad = null;
        throw e;
      });

  String? _homeCategory(Json view) {
    final name = (view['Name'] as String? ?? '').toLowerCase();
    if (name.contains('纪录') || name.contains('document')) return 'documentaries';
    if (name.contains('番') || name.contains('动画') || name.contains('动漫') || name.contains('anime')) return 'anime';
    return const {'tvshows': 'series', 'boxsets': 'collections', 'movies': 'recentMovies'}[view['CollectionType']];
  }

  /// Playback uses only a visible library identity already known to browsing.
  /// Unknown ownership stays unknown; item type, genre and language are not evidence.
  bool? isAnimePlaybackItem(Map<String, dynamic> item) {
    if (!_sessionMatches) {
      return null;
    }
    final library =
        item['LibraryId']?.toString() ??
        _library(item['Id']?.toString() ?? '') ??
        _library(item['SeriesId']?.toString() ?? '');
    final view = _visibleViews.where((v) => v['Id'].toString() == library).firstOrNull;
    final category = view == null ? null : _homeCategory(view);
    return category == null ? null : category == 'anime';
  }

  String _types(Json view) => switch (view['CollectionType']) {
    'movies' => 'Movie',
    'tvshows' => 'Series',
    'boxsets' => 'BoxSet',
    _ => 'Movie,Series,BoxSet',
  };

  Future<List<ZonePreference>> defaultZonePreferences() async {
    _check();
    final views = await _views();
    _check();
    return [
      for (var i = 0; i < views.length; i++)
        ZonePreference(
          id: views[i]['Id'].toString(),
          name: views[i]['Name'] as String? ?? '',
          iconKey: views[i]['CollectionType'] == 'tvshows' ? 'series' : 'film',
          colorSlot: i % 6,
          rule: ZoneRule.library(views[i]['Id'].toString()),
          custom: false,
        ),
    ];
  }

  Future<List<ZonePreference>> _preferences() async {
    _check();
    final views = await _views();
    _check();
    final configured = _zonePreferences();
    final preferences = configured.isEmpty
        ? await defaultZonePreferences()
        : configured
              .where(
                (p) => p.rule is! LibraryZoneRule || views.any((v) => v['Id'] == (p.rule as LibraryZoneRule).libraryId),
              )
              .toList();
    final key = jsonEncode([
      for (final p in preferences) [p.id, p.name, p.iconKey, p.colorSlot, p.custom, _ruleKey(p.rule)],
    ]);
    if (_preferenceKey != null && _preferenceKey != key) _invalidateBrowse();
    _preferenceKey = key;
    return preferences;
  }

  String _ruleKey(ZoneRule rule) => switch (rule) {
    LibraryZoneRule(:final libraryId) => 'library:$libraryId',
    GenreZoneRule(:final genreId) => 'genre:$genreId',
    TechnologyZoneRule(:final technology) => 'tech:${technology.name}',
  };

  Future<ZonePreference> _preference(String id) async {
    final matches = (await _preferences()).where((p) => p.id == id);
    if (matches.isEmpty) {
      throw const EmbyViewFailure('这个分区已不存在', code: 'zone_missing');
    }
    return matches.first;
  }

  WallQuery _query(WallScope scope, {WallSort sort = WallSort.title, String? genre}) =>
      (scope: scope, sort: sort, watched: WatchFilter.all, genreId: genre, years: null, technology: null);

  void _tech(Json params, TechFilter technology) {
    switch (technology) {
      case TechFilter.uhd4k:
        params['Is4K'] = true;
      case TechFilter.dolbyVision:
      case TechFilter.hdr:
        final values = technology == TechFilter.dolbyVision ? const ['DolbyVision'] : _hdrVideoTypes;
        final current = params['ExtendedVideoTypes']?.toString().split(',');
        params['ExtendedVideoTypes'] = (current == null ? values : values.where(current.contains)).join(',');
      case TechFilter.surround51:
        params['AudioLayouts'] = '5.1';
    }
  }

  Future<Json> _params(WallQuery query) async {
    final params = <String, dynamic>{
      'Recursive': true,
      'IncludeItemTypes': 'Movie,Series,BoxSet',
      'EnableUserData': true,
      'EnableImageTypes': 'Primary,Backdrop,Logo,Thumb',
      'Fields': _fields,
    };
    switch (query.scope) {
      case ZoneWallScope(:final zoneId):
        final preference = await _preference(zoneId);
        switch (preference.rule) {
          case LibraryZoneRule(:final libraryId):
            final view = (await _views()).firstWhere((e) => e['Id'] == libraryId);
            params['ParentId'] = libraryId;
            params['IncludeItemTypes'] = _types(view);
          case GenreZoneRule(:final genreId):
            params['GenreIds'] = genreId;
          case TechnologyZoneRule(:final technology):
            params['IncludeItemTypes'] = 'Movie,Episode';
            _tech(params, technology);
        }
      case FeatureWallScope(:final feature):
        params['IncludeItemTypes'] = 'Movie';
        if (feature == HomeFeature.shortHighRated) {
          params['MinCommunityRating'] = 7;
          params['IsPlayed'] = false;
        } else {
          params['Is4K'] = true;
          _tech(params, TechFilter.dolbyVision);
        }
    }
    if (query.technology != null) {
      if (params['IncludeItemTypes'] == 'Series' || params['IncludeItemTypes'] == 'BoxSet') {
        throw const EmbyViewFailure('此分区不支持影片或单集的技术筛选', code: 'unsupported_filter');
      }
      if (params['IncludeItemTypes'] == 'Movie,Series,BoxSet') {
        params['IncludeItemTypes'] = 'Movie,Episode';
      }
      _tech(params, query.technology!);
    }
    switch (query.watched) {
      case WatchFilter.all:
        break;
      case WatchFilter.unplayed:
        params['IsPlayed'] = false;
      case WatchFilter.played:
        params['IsPlayed'] = true;
      case WatchFilter.favorite:
        params['IsFavorite'] = true;
    }
    if (query.genreId != null) {
      if (params['GenreIds'] != null && params['GenreIds'] != query.genreId) {
        // GenreIds is OR on Emby; use one query per actual conjunction below.
        throw const EmbyViewFailure('此分区只支持已选类型', code: 'unsupported_filter');
      }
      params['GenreIds'] = query.genreId;
    }
    if (query.years != null) {
      final years =
          (await _all({
                ...params,
                'Fields': 'ProductionYear',
                'SortBy': 'ProductionYear,SortName',
                'SortOrder': 'Ascending,Ascending',
              }))
              .map((e) => integer(e['ProductionYear']))
              .whereType<int>()
              .toSet()
              .where(
                (y) =>
                    (query.years!.from == null || y >= query.years!.from!) &&
                    (query.years!.to == null || y <= query.years!.to!),
              )
              .toList()
            ..sort();
      // Empty Years is ignored by Emby. An impossible year is an empty set.
      params['Years'] = years.isEmpty ? '0' : years.join(',');
    }
    final sort = switch (query.sort) {
      WallSort.title => ('SortName', 'Ascending'),
      WallSort.added => ('DateCreated,SortName', 'Descending,Ascending'),
      WallSort.year => ('ProductionYear,SortName', 'Descending,Ascending'),
      WallSort.score => ('CommunityRating,SortName', 'Descending,Ascending'),
      WallSort.random => ('Random', 'Ascending'),
    };
    params['SortBy'] = sort.$1;
    params['SortOrder'] = sort.$2;
    return params;
  }

  Future<List<Json>> _all(Json params, {String resource = 'items', String? id}) async {
    final result = <Json>[];
    var offset = 0;
    while (true) {
      final response = await _get(
        resource,
        id: id,
        params: {...params, 'StartIndex': offset, 'Limit': 500, 'EnableTotalRecordCount': true},
      );
      final page = itemRecords(response);
      result.addAll(page);
      offset += page.length;
      final total = response is Map ? integer(response['TotalRecordCount']) : null;
      if (page.isEmpty || (total != null ? offset >= total : page.length < 500)) {
        break;
      }
    }
    return result;
  }

  Future<int> _count(Json params) async {
    final result = await _get(
      'items',
      params: {...params, 'StartIndex': 0, 'Limit': 0, 'EnableTotalRecordCount': true, 'Fields': ''},
    );
    return integer((result as Map)['TotalRecordCount']) ?? itemRecords(result).length;
  }

  Future<void> _restoreIndex() => _restoreLoad ??= _readIndex();

  Future<void> _readIndex() async {
    final prefs = await _storage;
    _check();
    final saved = prefs.getString(_cacheKey);
    _recent.addAll(prefs.getStringList('$_cacheKey.terms') ?? []);
    if (saved == null) return;
    try {
      final envelope = jsonDecode(saved) as Map;
      if (envelope['fields'] != _indexFields) return;
      _indexedAt = DateTime.parse(envelope['at'] as String);
      _index = [
        for (final row in records(envelope['rows']))
          _IndexItem(row['raw'] as Json, row['library'] as String, (_) => row['latin'] as String),
      ];
    } on FormatException {
      _index = null;
    } on TypeError {
      _index = null;
    }
  }

  Future<void> _saveIndex() async {
    _check();
    await (await _storage).setString(
      _cacheKey,
      jsonEncode({
        'at': _indexedAt!.toIso8601String(),
        'fields': _indexFields,
        'rows': [
          for (final item in _index!) {'raw': item.raw, 'library': item.library, 'latin': item.title.latin},
        ],
      }),
    );
  }

  Future<List<_IndexItem>> _catalog({bool refresh = false}) async {
    _check();
    await _restoreIndex();
    if (!refresh && _index != null) {
      _refreshIndexInBackground();
      return _index!;
    }
    if (_indexLoad != null) return _indexLoad!;
    _lastRefreshAttempt = _now().toUtc();
    return _indexLoad = _refreshCatalog().whenComplete(() => _indexLoad = null);
  }

  Future<List<_IndexItem>> _refreshCatalog() async {
    final started = _now().toUtc();
    final userDataRevision = _userDataRevision;
    var changedIndex = false;
    final result = <_IndexItem>[];
    try {
      if (_index != null) _viewLoad = null;
      final views = await _views();
      final libraries = views.map((v) => v['Id'].toString()).toSet();
      if (_index?.any((e) => !libraries.contains(e.library)) == true) {
        _index = _index!.where((e) => libraries.contains(e.library)).toList();
        _indexCollections(_index!);
        _invalidateBrowse();
      }
      for (final view in views) {
        final library = view['Id'].toString();
        final params = <String, dynamic>{
          'ParentId': library,
          'Recursive': true,
          'IncludeItemTypes': _types(view) == 'Series' ? 'Series,Episode' : _types(view),
          'EnableUserData': true,
          'SortBy': 'SortName',
          'SortOrder': 'Ascending',
          'Fields': _indexFields,
          'EnableImageTypes': 'Primary',
        };
        try {
          if (_index == null) {
            final rows = await _all(params);
            result.addAll(rows.map((r) => _IndexItem(r, library, _transliterate)));
          } else {
            final prior = {for (final e in _index!.where((e) => e.library == library)) e.id: e};
            final changed = await _all({
              ...params,
              'MinDateLastSaved': _indexedAt!.subtract(const Duration(seconds: 1)).toIso8601String(),
            });
            for (final row in changed) {
              final id = row['Id'].toString();
              if (jsonEncode(prior[id]?.raw) != jsonEncode(row)) changedIndex = true;
              prior[id] = _IndexItem(row, library, _transliterate);
            }
            final visible = await _all({...params, 'Fields': 'Id,Collections'});
            for (final row in visible) {
              final id = row['Id'].toString();
              final old = prior[id];
              if (old != null && row.containsKey('Collections') &&
                  jsonEncode(old.raw['Collections']) != jsonEncode(row['Collections'])) {
                changedIndex = true;
                prior[id] = _IndexItem({...old.raw, 'Collections': row['Collections']}, library, (_) => old.title.latin);
              }
            }
            final ids = visible.map((e) => e['Id'].toString()).toSet();
            if (prior.keys.any((id) => !ids.contains(id))) {
              _invalidateBrowse();
              _index = _index!.where((e) => e.library != library || ids.contains(e.id)).toList();
              _indexCollections(_index!);
            }
            result.addAll(prior.values.where((e) => ids.contains(e.id)));
            final missing = ids.difference(prior.keys.toSet()).toList();
            if (missing.isNotEmpty) changedIndex = true;
            for (var i = 0; i < missing.length; i += 100) {
              final rows = await _all({...params, 'Ids': missing.skip(i).take(100).join(',')});
              result.addAll(rows.map((r) => _IndexItem(r, library, _transliterate)));
            }
          }
        } on EmbyViewFailure catch (error) {
          if (error.code != 'forbidden') rethrow;
        }
      }
      _check();
      result.removeWhere(_isForbidden);
      final visible = result.map((e) => e.id).toSet();
      if (_index?.any((e) => !visible.contains(e.id)) == true) _invalidateBrowse();
      // A concurrent user mutation must not be overwritten by rows fetched
      // before the write. Keep the live index and retry on the next sync.
      if (userDataRevision != _userDataRevision) {
        if (_index != null) return _index!;
        return await _refreshCatalog();
      }
      if (changedIndex) _invalidateBrowse();
      _index = result;
      _indexCollections(result);
      _indexedAt = started;
      await _saveIndex();
      return result;
    } on EmbyViewFailure catch (e) {
      _check();
      if (e.code == 'network' && _index != null) return _index!;
      rethrow;
    }
  }

  bool _isForbidden(_IndexItem item) =>
      [item.id, item.library, item.raw['ParentId'], item.raw['SeriesId']].any(_forbiddenScopes.contains);

  String? _library(String id) => _index?.where((e) => e.id == id).firstOrNull?.library;
  MediaCard _card(Json raw, {String? library, Json? parent, List<Json> collection = const []}) => _mapper.card(
    raw,
    library: library ?? _library(raw['Id'].toString()),
    parent: parent,
    collection: collection.isEmpty ? _collectionArt[raw['Id']] ?? const [] : collection,
  );

  int _collectionOrder(Json a, Json b) {
    final order = (a['SortName'] ?? a['Name']).toString().toLowerCase().compareTo(
      (b['SortName'] ?? b['Name']).toString().toLowerCase(),
    );
    return order != 0 ? order : a['Id'].toString().compareTo(b['Id'].toString());
  }

  int _collectionReleaseOrder(Json a, Json b) {
    final ay = integer(a['ProductionYear']);
    final by = integer(b['ProductionYear']);
    if (ay != null && by != null && ay != by) return ay.compareTo(by);
    if (ay != null && by == null) return -1;
    if (ay == null && by != null) return 1;
    return _collectionOrder(a, b);
  }

  void _indexCollections(List<_IndexItem> index) {
    final groups = <String, Map<String, Json>>{};
    final boxNames = <String, String>{};
    for (final item in index.where((e) => e.raw['Type'] == 'BoxSet')) {
      boxNames[item.id] = item.raw['Name'] as String? ?? '';
    }
    _movieToCollection.clear();
    for (final item in index.where((e) => e.raw['Type'] == 'Movie' || e.raw['Type'] == 'Series')) {
      for (final collection in records(item.raw['Collections'])) {
        final id = collection['Id']?.toString();
        if (id != null && !_forbiddenScopes.contains(id)) {
          (groups[id] ??= {})[item.id] = item.raw;
          _movieToCollection.putIfAbsent(
            item.id,
            () => (id: id, name: (collection['Name'] as String?)?.trim().isNotEmpty == true
                ? (collection['Name'] as String).trim()
                : (boxNames[id] ?? '')),
          );
        }
      }
    }
    _collectionArt.clear();
    for (final entry in groups.entries) {
      _collectionArt[entry.key] = entry.value.values.toList()..sort(_collectionReleaseOrder);
    }
    _collectionIndexReady = true;
  }

  Future<List<MediaCard>> _cards(List<Json> rows, {String? library}) async {
    // Reuse the light, user-scoped index rather than opening every container.
    if (!_collectionIndexReady && rows.any((e) => e['Type'] == 'BoxSet')) {
      final index = await _catalog();
      if (!_collectionIndexReady) _indexCollections(index);
    }
    return rows.map((row) => _card(row, library: library)).toList();
  }

  bool _featureMatch(Json item, HomeFeature feature) {
    final ratio = (item['PrimaryImageAspectRatio'] as num?)?.toDouble();
    if (_mapper.image(item, 'Primary') == null || ratio == null || ratio <= 0 || ratio >= 1) {
      return false;
    }
    if (feature == HomeFeature.uhdDolbyVision) {
      return true; // Server applies both predicates.
    }
    final duration = ticks(item['RunTimeTicks']);
    return duration != null &&
        duration <= const Duration(minutes: 100) &&
        (item['CommunityRating'] as num? ?? 0) >= 7 &&
        (item['UserData'] as Map?)?['Played'] == false;
  }

  @override
  Future<WallListing> openWall(WallQuery query) async {
    // Random order is fresh per opening. For a previously opened title wall,
    // validate the scope's count cheaply before reusing the sorted snapshot.
    if (query.sort == WallSort.random) return _openWall(query);
    if (query.sort == WallSort.title && query.scope is FeatureWallScope) return _openWall(query);
    final key = _queryKey(query);
    if (query.sort == WallSort.title) {
      _check();
      await _preferences();
      final previous = _titleWalls[key];
      if (previous != null) {
        final total = await _count(previous.params);
        _check();
        if (previous.revision == _revision) {
          if (total == previous.info.total) {
            _refreshIndexInBackground();
            return previous;
          }
          _invalidateBrowse();
        }
      }
    }
    return _cached(_wallCache, key, () => _openWall(query));
  }

  Future<WallListing> _openWall(WallQuery query) async {
    final frozen = query.sort == WallSort.title || query.sort == WallSort.random || query.scope is FeatureWallScope;
    final index = query.sort == WallSort.title ? await _catalog() : null;
    final params = await _params(query);
    final revision = _revision;
    List<String>? ids;
    final letters = <String, int>{};
    if (frozen) {
      var rows = await _all({
        ...params,
        'Fields': query.scope is FeatureWallScope
            ? 'PrimaryImageAspectRatio,RunTimeTicks,CommunityRating,UserData'
            : 'Id',
        if (query.sort == WallSort.random) 'SortBy': 'SortName',
      });
      if (query.sort == WallSort.random) rows.shuffle();
      if (query.scope case FeatureWallScope(:final feature)) {
        rows = rows.where((e) => _featureMatch(e, feature)).toList();
      }
      if (query.sort == WallSort.title) {
        final keys = {for (final e in index!) e.id: e};
        final titles = <String, TitleKey>{};
        TitleKey key(Json row) {
          final id = row['Id'].toString();
          return titles.putIfAbsent(id, () {
            final old = keys[id];
            final name = row['Name'] as String? ?? '';
            return old != null && (row['Name'] == null || old.raw['Name'] == name)
                ? old.title
                : TitleKey(name, _transliterate);
          });
        }

        rows.sort((a, b) {
          final ak = key(a), bk = key(b);
          final group = (ak.letter == '#' ? 1 : 0).compareTo(bk.letter == '#' ? 1 : 0);
          final order = group != 0 ? group : ak.sort.compareTo(bk.sort);
          return order != 0 ? order : a['Id'].toString().compareTo(b['Id'].toString());
        });
        for (var i = 0; i < rows.length; i++) {
          letters.putIfAbsent(key(rows[i]).letter, () => i);
        }
      }
      ids = rows.map((r) => r['Id'].toString()).toList();
    }
    final total = ids?.length ?? await _count(params);
    _check();
    if (revision != _revision) return _openWall(query);
    final key = _queryKey(query);
    if (query.sort == WallSort.title) {
      final previous = _titleWalls[key];
      if (previous != null && (previous.ids!.length != ids!.length || !previous.ids!.toSet().containsAll(ids))) {
        _invalidateBrowse();
      }
    }
    final wall = _Wall(
      this,
      query,
      params,
      ids,
      _revision,
      WallInfo(total: total, letterOffsets: Map.unmodifiable(letters)),
    );
    if (query.sort == WallSort.title) {
      if (_titleWalls.length >= 64) {
        final oldest = _titleWalls.keys.first;
        _titleWalls.remove(oldest);
        _wallCache.remove(oldest);
      }
      _titleWalls[key] = wall;
    }
    return wall;
  }

  Future<void> _validateWall(_Wall wall) async {
    _check();
    await _preferences();
    if (wall.revision != _revision) {
      throw const EmbyViewFailure('片库或分区已更新，请重新打开海报墙', retryable: true, code: 'wall_changed');
    }
  }

  Future<List<Json>> _byIds(List<String> ids) async {
    final rows = <String, Json>{};
    for (var i = 0; i < ids.length; i += 100) {
      for (final row in itemRecords(
        await _get(
          'items',
          params: {'Ids': ids.skip(i).take(100).join(','), 'Fields': _fields, 'EnableUserData': true, 'Limit': 100},
        ),
      )) {
        rows[row['Id'].toString()] = row;
      }
    }
    return ids.map((id) => rows[id]).whereType<Json>().toList();
  }

  Future<int> _queryCount(WallQuery query) async => (await openWall(query)).info.total;

  Future<List<(TechFilter, String)>> _technologyOptions(Json params) async {
    if (params['IncludeItemTypes'] == 'Series' || params['IncludeItemTypes'] == 'BoxSet') return [];
    final scope = {
      if (params['ParentId'] != null) 'ParentId': params['ParentId'],
      'Recursive': true,
      'IncludeItemTypes': params['IncludeItemTypes'] == 'Movie' ? 'Movie' : 'Movie,Episode',
    };
    Set<String> values(dynamic raw) {
      final rows = raw is List ? raw : (raw is Map ? raw['Items'] as List? : null) ?? const [];
      final out = <String>{};
      for (final e in rows) {
        if (e is Map) {
          for (final key in const ['Id', 'Value', 'Name']) {
            final v = e[key]?.toString().trim();
            if (v != null && v.isNotEmpty) out.add(v);
          }
        } else if (e != null) {
          final v = e.toString().trim();
          if (v.isNotEmpty) out.add(v);
        }
      }
      return out;
    }

    final videos = values(await _get('videoTypes', params: scope));
    final audio = values(await _get('audioLayouts', params: scope));
    return [
      (TechFilter.uhd4k, '4K'),
      if (videos.contains('DolbyVision')) (TechFilter.dolbyVision, '杜比视界'),
      if (videos.any(_hdrVideoTypes.contains)) (TechFilter.hdr, 'HDR'),
      if (audio.contains('5.1')) (TechFilter.surround51, '5.1'),
    ];
  }

  WallQuery _facet(WallQuery q, String group, Object? value) => (
    scope: q.scope,
    sort: group == 'sort' ? WallSort.score : q.sort,
    watched: group == 'watched' ? value as WatchFilter : q.watched,
    genreId: group == 'genre' ? value as String? : q.genreId,
    years: group == 'year' ? value as YearRange? : q.years,
    technology: group == 'tech' ? value as TechFilter? : q.technology,
  );

  Future<List<FacetOption<T>>> _options<T>(List<(T, String)> values, Future<int> Function(T) count) async =>
      (await mapBounded(
        values,
        4,
        (v) async => FacetOption(value: v.$1, label: v.$2, count: await count(v.$1)),
      )).whereType<FacetOption<T>>().toList();

  @override
  Future<WallFacets> wallFacets(WallQuery query) =>
      _cached(_facetCache, _queryKey(query, includeSort: false), () => _loadWallFacets(_facet(query, 'sort', null)));

  Future<WallFacets> _loadWallFacets(WallQuery query) async {
    final params = await _params(query);
    Future<List<FacetOption<String>>> genreOptions() async {
      final genres = itemRecords(
        await _get(
          'genres',
          params: {
            if (params['ParentId'] != null) 'ParentId': params['ParentId'],
            'Recursive': true,
            'IncludeItemTypes': params['IncludeItemTypes'],
          },
        ),
      );
      final rule = query.scope is ZoneWallScope ? (await _preference((query.scope as ZoneWallScope).zoneId)).rule : null;
      return _options([
        for (final g in genres)
          if (rule is! GenreZoneRule || g['Id'] == rule.genreId) (g['Id'].toString(), g['Name'] as String? ?? ''),
      ], (value) => _queryCount(_facet(query, 'genre', value)));
    }

    Future<List<FacetOption<TechFilter>>> technologyOptions() async => _options(
      await _technologyOptions(params),
      (value) => _queryCount(_facet(query, 'tech', value)),
    );

    final results = await Future.wait<Object>([
      _all({...params, 'Fields': 'ProductionYear,$_featureFields', 'Years': null}),
      _options([
        for (final w in WatchFilter.values) (w, ['全部', '未看', '已看', '收藏'][w.index]),
      ], (value) => _queryCount(_facet(query, 'watched', value))),
      genreOptions(),
      technologyOptions(),
    ]);
    final yearRows = results[0] as List<Json>;
    final yearCounts = <int, int>{};
    for (final row in yearRows) {
      if (query.scope case FeatureWallScope(:final feature)) {
        if (!_featureMatch(row, feature)) continue;
      }
      final year = integer(row['ProductionYear']);
      if (year != null) yearCounts.update(year, (n) => n + 1, ifAbsent: () => 1);
    }
    final years = yearCounts.keys.toList()..sort((a, b) => b.compareTo(a));
    return WallFacets(
      sorts: [
        for (final sort in WallSort.values)
          FacetOption(value: sort, label: ['标题', '最近添加', '年份', '评分', '随机'][sort.index]),
      ],
      watched: results[1] as List<FacetOption<WatchFilter>>,
      genres: results[2] as List<FacetOption<String>>,
      years: [
        for (final y in years)
          FacetOption(
            value: YearRange(from: y, to: y),
            label: '$y',
            count: yearCounts[y],
          ),
      ],
      technologies: results[3] as List<FacetOption<TechFilter>>,
    );
  }

  @override
  Future<ZoneFacets> customZoneFacets() async {
    final libraries = await _views();
    final genres = itemRecords(
      await _get('genres', params: {'Recursive': true, 'IncludeItemTypes': 'Movie,Series,BoxSet'}),
    );
    const base = {'Recursive': true, 'IncludeItemTypes': 'Movie,Episode'};
    return ZoneFacets(
      libraries: await _options(
        [for (final v in libraries) (v['Id'].toString(), v['Name'] as String? ?? '')],
        (id) => _count({
          'ParentId': id,
          'Recursive': true,
          'IncludeItemTypes': _types(libraries.firstWhere((v) => v['Id'] == id)),
        }),
      ),
      genres: await _options([
        for (final g in genres) (g['Id'].toString(), g['Name'] as String? ?? ''),
      ], (id) => _count({'GenreIds': id, 'Recursive': true, 'IncludeItemTypes': 'Movie,Series,BoxSet'})),
      technologies: await _options(await _technologyOptions(base), (tech) {
        final params = <String, dynamic>{...base};
        _tech(params, tech);
        return _count(params);
      }),
    );
  }

  Future<void> _prepareBackdrops(Iterable<Json> items, {Json? parent}) async {
    _check();
    final groups = [for (final item in items) _mapper.backdropCandidates(item, parent: parent)];
    if (groups.every((g) => g.length <= 1)) return;
    await _backdrops.prepare(
      groups,
      uriFor: (c) => _mapper.backdropUri(c, maxWidth: 512),
      headers: {'X-Emby-Token': _token!},
    );
    _check();
  }

  void _prefetchBackdrops(Iterable<Json> items) {
    if (_disposed || !_sessionMatches) return;
    final groups = [for (final item in items) _mapper.backdropCandidates(item)];
    if (groups.every((g) => g.length <= 1)) return;
    unawaited(
      _backdrops
          .prepare(
            groups,
            uriFor: (c) => _mapper.backdropUri(c, maxWidth: 512),
            headers: {'X-Emby-Token': _token!},
            concurrency: 2,
          )
          .catchError((_) {}),
    );
  }

  Future<({String id, String title, WallQuery more, int total, List<Json> rows, String? library})> _shelfRaw(
    String id,
    String title,
    WallQuery query, {
    int limit = 16,
  }) async {
    final listing = await openWall(query) as _Wall;
    final page = await listing._rawPage(offset: 0, limit: limit);
    return (
      id: id,
      title: title,
      more: query,
      total: listing.info.total,
      rows: page.rows,
      library: listing.params['ParentId'] as String?,
    );
  }

  Future<HomeShelf> _buildShelf(
    ({String id, String title, WallQuery more, int total, List<Json> rows, String? library}) raw,
  ) async => HomeShelf(
    id: raw.id,
    title: raw.title,
    more: raw.more,
    total: raw.total,
    items: await _cards(raw.rows, library: raw.library),
  );

  Future<HomeShelf> _shelf(String id, String title, WallQuery query, {int limit = 16}) async =>
      _buildShelf(await _shelfRaw(id, title, query, limit: limit));

  Future<ZoneTile> _tile(ZonePreference pref) async {
    final params = await _params(_query(WallScope.zone(pref.id), sort: WallSort.score));
    final result = await _get('items', params: {...params, 'Limit': 1, 'EnableTotalRecordCount': true});
    final representative = itemRecords(result).firstOrNull;
    if (representative != null) {
      await _prepareBackdrops([representative]);
    }
    final card = representative == null
        ? null
        : (await _cards([
            representative,
          ], library: pref.rule is LibraryZoneRule ? (pref.rule as LibraryZoneRule).libraryId : null)).single;
    final series = params['IncludeItemTypes'] == 'Series';
    return ZoneTile(
      id: pref.id,
      name: pref.name,
      iconKey: pref.iconKey,
      colorSlot: pref.colorSlot,
      total: integer((result as Map)['TotalRecordCount']) ?? 0,
      unit: series
          ? '部剧'
          : pref.rule is TechnologyZoneRule
          ? '部 / 集'
          : '部',
      episodeTotal: series ? await _count({...params, 'IncludeItemTypes': 'Episode'}) : null,
      representative: card,
      art: card?.art.stage.layers.firstOrNull?.source,
    );
  }

  @override
  Future<List<ZoneTile>> zones() async => [for (final p in await _preferences()) await _tile(p)];

  List<HomeRecommendation> _recommend(List<ResumeCard> resume, List<MediaCard> candidates) => [
    ...resume
        .take(3)
        .map((r) => HomeRecommendation(card: r.card, reason: RecommendationReason.continueWatching, resume: r)),
    ...candidates
        .where((c) => c.art.backdrops.isNotEmpty && !resume.any((r) => r.card.id == c.id))
        .take(math.max(0, 6 - math.min(3, resume.length)))
        .map((c) => HomeRecommendation(card: c, reason: RecommendationReason.daily)),
  ];

  List<Json> _recommendationCandidateRows(List<ResumeCard> resume, List<Json> sortedCandidates) {
    final resumeIds = resume.map((r) => r.card.id).toSet();
    final needed = math.max<int>(0, 6 - math.min<int>(3, resume.length));
    if (needed == 0) return const [];
    return sortedCandidates
        .where((row) => _mapper.backdropCandidates(row).isNotEmpty && !resumeIds.contains(row['Id'].toString()))
        .take(needed)
        .toList();
  }

  @override
  Future<ZoneData> zone(String zoneId) => _cached(_zoneCache, zoneId, () => _loadZone(zoneId));

  Future<ZoneData> _loadZone(String zoneId) async {
    final preference = await _preference(zoneId);
    final scope = WallScope.zone(zoneId);
    final params = await _params(_query(scope));
    final now = _now();
    final month = DateTime(now.year, now.month).toUtc();
    final nextMonth = DateTime(now.year, now.month + 1).toUtc();
    final results = await Future.wait<Object>([
      _shelfRaw('latest', '最近添加', _query(scope, sort: WallSort.added)),
      _shelfRaw('score', '高分精选', _query(scope, sort: WallSort.score)),
      wallFacets(_query(scope)),
      continueWatching(zoneId: zoneId),
      _tile(preference),
      _count({
        ...params,
        'MinDateCreated': month.toIso8601String(),
        'MaxDateCreated': nextMonth.subtract(const Duration(microseconds: 1)).toIso8601String(),
      }),
    ]);
    final latestRaw = results[0] as ({String id, String title, WallQuery more, int total, List<Json> rows, String? library});
    final highRaw = results[1] as ({String id, String title, WallQuery more, int total, List<Json> rows, String? library});
    final facets = results[2] as WallFacets;
    final resume = (results[3] as Page<ResumeCard>).items;
    final tile = results[4] as ZoneTile;
    final added = results[5] as int;
    final recRows = _recommendationCandidateRows(resume, highRaw.rows);
    final stageRows = <Json>[
      ...recRows,
      if (resume.isEmpty && recRows.isEmpty && latestRaw.rows.isNotEmpty) latestRaw.rows.first,
      if (resume.isEmpty && recRows.isEmpty && latestRaw.rows.isEmpty && highRaw.rows.isNotEmpty) highRaw.rows.first,
    ];
    await _prepareBackdrops(stageRows);
    final latest = await _buildShelf(latestRaw);
    final high = await _buildShelf(highRaw);
    final rawGenres = await mapBounded(
      facets.genres.where((e) => e.count != 0).toList(),
      4,
      (g) => _shelfRaw('genre:${g.value}', g.label, _query(scope, sort: WallSort.score, genre: g.value)),
    );
    final genreShelves = <HomeShelf>[];
    final prefetchRows = <Json>[...latestRaw.rows, ...highRaw.rows];
    for (final raw in rawGenres) {
      if (raw == null) continue;
      genreShelves.add(await _buildShelf(raw));
      prefetchRows.addAll(raw.rows);
    }
    _prefetchBackdrops(prefetchRows);
    return ZoneData(
      zone: tile,
      all: _query(scope),
      latest: latest,
      highRated: high,
      addedThisMonth: added,
      continueWatching: resume,
      recommendations: _recommend(resume, high.items),
      genreCounts: facets.genres,
      genres: genreShelves,
      collage: latest.items
          .map((c) => c.art.poster.layers.firstOrNull?.source)
          .whereType<ArtworkRef>()
          .take(9)
          .toList(),
    );
  }

  @override
  Future<HomeData> home({required ShelfSort seriesSort}) async {
    final views = await _views();
    final tiles = await zones();
    final prefs = await _preferences();
    ZonePreference? prefFor(Json v) =>
        prefs.where((p) => p.rule is LibraryZoneRule && (p.rule as LibraryZoneRule).libraryId == v['Id']).firstOrNull;
    final sort = [WallSort.added, WallSort.score, WallSort.title][seriesSort.index];
    final rawShelves =
        <String, ({String id, String title, WallQuery more, int total, List<Json> rows, String? library})>{};
    for (final v in views) {
      final pref = prefFor(v);
      if (pref == null) continue;
      final category = _homeCategory(v);
      if (category == null || rawShelves.containsKey(category)) continue;
      rawShelves[category] = await _shelfRaw(
        pref.id,
        pref.name,
        _query(WallScope.zone(pref.id), sort: category == 'anime' || category == 'series' ? sort : WallSort.added),
      );
    }
    final resume = (await continueWatching()).items;
    final sortedCandidates = rawShelves.values.expand((s) => s.rows).toList()
      ..sort(
        (a, b) => ((b['CommunityRating'] as num?)?.toDouble() ?? 0).compareTo(
          (a['CommunityRating'] as num?)?.toDouble() ?? 0,
        ),
      );
    final docFallbackRows = [
      for (final row in rawShelves['documentaries']?.rows ?? const <Json>[])
        if (_mapper.image(row, 'Thumb') == null) row,
    ];
    await _prepareBackdrops([
      ..._recommendationCandidateRows(resume, sortedCandidates),
      ...docFallbackRows,
    ]);
    final shelves = <String, HomeShelf>{};
    for (final entry in rawShelves.entries) {
      shelves[entry.key] = await _buildShelf(entry.value);
    }
    _prefetchBackdrops(rawShelves.values.expand((s) => s.rows));
    Future<FeatureSpread> feature(HomeFeature f) async {
      final query = _query(WallScope.feature(f), sort: WallSort.score);
      final wall = await openWall(query);
      return FeatureSpread(
        feature: f,
        posters: (await wall.page(offset: 0, limit: 16)).items,
        total: wall.info.total,
        query: query,
      );
    }

    return HomeData(
      zones: tiles,
      continueWatching: resume,
      recommendations: _recommend(
        resume,
        shelves.values.expand((s) => s.items).toList()..sort((a, b) => (b.score ?? 0).compareTo(a.score ?? 0)),
      ),
      recentMovies: shelves['recentMovies'],
      anime: shelves['anime'],
      series: shelves['series'],
      collections: shelves['collections'],
      documentaries: shelves['documentaries'],
      shortHighRated: await feature(HomeFeature.shortHighRated),
      uhdDolbyVision: await feature(HomeFeature.uhdDolbyVision),
    );
  }

  @override
  Future<MediaCard?> randomInZone(String zoneId) async {
    final params = await _params(_query(WallScope.zone(zoneId), sort: WallSort.random));
    final row = itemRecords(await _get('items', params: {...params, 'Limit': 1})).firstOrNull;
    if (row == null) return null;
    await _prepareBackdrops([row]);
    return (await _cards([row])).single;
  }

  Future<Json> _item(String id, {String? mediaSourceId}) async =>
      (await _get('item', id: id, params: {'Fields': '$_fields,Chapters,Collections,Path', 'MediaSourceId': ?mediaSourceId}) as Map)
          .cast<String, dynamic>();

  Future<void> _ensureVersionPicksLoaded() => _versionPicksLoad ??= _readVersionPicks();

  Future<void> _readVersionPicks() async {
    final prefs = await _storage;
    _check();
    final raw = prefs.getString(_versionChoiceCacheKey);
    if (raw == null || raw.isEmpty) {
      _versionPicks = {};
      return;
    }
    try {
      final decoded = jsonDecode(raw) as Map;
      final picks = <String, String>{};
      final rawPicks = decoded['picks'];
      if (rawPicks is Map) {
        for (final entry in rawPicks.entries) {
          if (entry.key is String && entry.value is String && (entry.value as String).isNotEmpty) {
            picks[entry.key as String] = entry.value as String;
          }
        }
      }
      _versionPicks = picks;
      final taste = decoded['taste'];
      if (taste is Map) {
        final originName = taste['origin'] as String?;
        _lastVersionTaste = VersionTasteProfile(
          resolution: taste['resolution'] as String?,
          videoRange: taste['videoRange'] as String?,
          origin: originName == null
              ? null
              : MediaOrigin.values.where((o) => o.name == originName).firstOrNull,
          preferSmall: taste['preferSmall'] == true,
        );
      }
    } catch (_) {
      _versionPicks = {};
      _lastVersionTaste = null;
    }
  }

  Future<void> _saveVersionPicks() async {
    _check();
    final taste = _lastVersionTaste;
    await (await _storage).setString(
      _versionChoiceCacheKey,
      jsonEncode({
        'picks': _versionPicks ?? const <String, String>{},
        if (taste != null)
          'taste': {
            'resolution': taste.resolution,
            'videoRange': taste.videoRange,
            'origin': taste.origin?.name,
            'preferSmall': taste.preferSmall,
          },
      }),
    );
  }

  @override
  Future<void> rememberMediaVersion(String itemId, MediaVersion version) async {
    _check();
    await _ensureVersionPicksLoaded();
    _check();
    (_versionPicks ??= {})[itemId] = version.id;
    _lastVersionTaste = VersionTasteProfile.fromVersion(version);
    await _saveVersionPicks();
  }

  Future<void> _ensureBoxsetMembershipLoaded() async {
    if (_boxsetMembershipLoaded) return;
    if (_boxsetMembershipLoad != null) {
      await _boxsetMembershipLoad;
      return;
    }
    final load = () async {
      try {
        final boxsets = await _all({
          'Recursive': true,
          'IncludeItemTypes': 'BoxSet',
          'Fields': 'BasicSyncInfo',
        });
        await mapBounded(boxsets, 4, (box) async {
          final boxId = box['Id']?.toString();
          if (boxId == null || boxId.isEmpty || _forbiddenScopes.contains(boxId)) return;
          final boxName = (box['Name'] as String?)?.trim() ?? '';
          try {
            final members = await _all({
              'ParentId': boxId,
              'Recursive': false,
              'IncludeItemTypes': 'Movie,Series',
              'Fields': 'ProductionYear,SortName',
            });
            for (final m in members) {
              final mid = m['Id']?.toString();
              if (mid != null && mid.isNotEmpty) {
                _movieToCollection.putIfAbsent(mid, () => (id: boxId, name: boxName));
              }
            }
          } on EmbyViewFailure {
            _check();
          }
        });
      } on EmbyViewFailure {
        _check();
      }
      _boxsetMembershipLoaded = true;
    }();
    _boxsetMembershipLoad = load;
    try {
      await load;
    } finally {
      if (identical(_boxsetMembershipLoad, load)) _boxsetMembershipLoad = null;
    }
  }

  Future<CollectionMembership?> _resolveCollectionMembership(String itemId, Json raw) async {
    String? boxId;
    String boxName = '';
    for (final c in records(raw['Collections'])) {
      final cid = c['Id']?.toString();
      if (cid != null && cid.isNotEmpty && !_forbiddenScopes.contains(cid)) {
        boxId = cid;
        boxName = (c['Name'] as String?)?.trim() ?? '';
        break;
      }
    }
    if (boxId == null) {
      final cached = _movieToCollection[itemId];
      if (cached != null && !_forbiddenScopes.contains(cached.id)) {
        boxId = cached.id;
        boxName = cached.name;
      }
    }
    if (boxId == null) {
      await _ensureBoxsetMembershipLoaded();
      final cached = _movieToCollection[itemId];
      if (cached != null && !_forbiddenScopes.contains(cached.id)) {
        boxId = cached.id;
        boxName = cached.name;
      }
    }
    if (boxId == null) return null;

    if (boxName.isEmpty) {
      try {
        final box = await _item(boxId);
        boxName = (box['Name'] as String?)?.trim() ?? '';
      } on EmbyViewFailure {
        _check();
      }
    }
    List<Json> children;
    try {
      children = await _all({
        'ParentId': boxId,
        'Recursive': false,
        'IncludeItemTypes': 'Movie,Series',
        'Fields': _fields,
        'EnableUserData': true,
        'EnableImageTypes': 'Primary,Backdrop,Logo,Thumb',
        'SortBy': 'ProductionYear,SortName',
        'SortOrder': 'Ascending,Ascending',
      });
    } on EmbyViewFailure {
      _check();
      return null;
    }
    if (children.isEmpty) return null;
    children.sort(_collectionReleaseOrder);
    _collectionArt[boxId] = children;
    for (final c in children) {
      final cid = c['Id']?.toString();
      if (cid != null && cid.isNotEmpty) {
        _movieToCollection[cid] = (id: boxId, name: boxName);
      }
    }
    final pos = children.indexWhere((c) => c['Id']?.toString() == itemId);
    if (pos < 0) return null;
    return CollectionMembership(
      id: boxId,
      name: boxName,
      position: pos + 1,
      total: children.length,
      items: children.map((e) => _card(e)).toList(),
    );
  }

  @override
  Future<CollectionDetail> collection(String collectionId) async {
    final box = await _item(collectionId);
    final children = await _all({
      'ParentId': collectionId,
      'Recursive': false,
      'IncludeItemTypes': 'Movie,Series',
      'Fields': _fields,
      'EnableUserData': true,
      'EnableImageTypes': 'Primary,Backdrop,Logo,Thumb',
      'SortBy': 'ProductionYear,SortName',
      'SortOrder': 'Ascending,Ascending',
    });
    children.sort(_collectionReleaseOrder);
    _collectionArt[collectionId] = children;
    final boxName = (box['Name'] as String?)?.trim() ?? '';
    for (final child in children) {
      final cid = child['Id']?.toString();
      if (cid != null && cid.isNotEmpty) {
        _movieToCollection[cid] = (id: collectionId, name: boxName);
      }
    }
    await _prepareBackdrops([box, if (children.isNotEmpty) children.first]);
    if (children.isNotEmpty) _prefetchBackdrops(children);
    final boxCard = _card(box, collection: children);
    final items = <CollectionItem>[
      for (final child in children) () {
        final card = _card(child);
        final userData = child['UserData'] as Map? ?? const {};
        final played = userData['Played'] == true;
        final pos = ticks(userData['PlaybackPositionTicks']);
        final resume = pos != null && pos > Duration.zero
            ? ResumeCard(
                card: card,
                target: _mapper.target(child),
                position: pos,
                duration: ticks(child['RunTimeTicks']),
              )
            : null;
        return CollectionItem(card: card, resume: resume, played: played);
      }(),
    ];
    return CollectionDetail(card: boxCard, rawName: boxName, items: items);
  }

  static DateTime? _parseEmbyUtcDate(dynamic raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    final text = raw.trim();
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;
    return parsed.isUtc ? parsed : parsed.toUtc();
  }

  @override
  Future<PersonDetail> person(
    String personId, {
    String? name,
    String? roleHint,
    MediaCard? sourceItem,
  }) async {
    _check();
    Json? rawPerson;
    try {
      final fetched = await _get(
        'item',
        id: personId,
        params: {'Fields': 'Overview,PremiereDate,ProductionLocations,PrimaryImageAspectRatio,ImageTags'},
      );
      if (fetched is Map) rawPerson = fetched.cast<String, dynamic>();
    } on EmbyViewFailure {
      _check();
    }
    final fallbackName = (rawPerson?['Name'] as String?)?.trim() ?? name?.trim() ?? '';
    if ((rawPerson == null ||
            (rawPerson['Overview'] as String?)?.trim().isEmpty != false &&
                rawPerson['PremiereDate'] == null) &&
        fallbackName.isNotEmpty) {
      try {
        final byName = await _get(
          'person',
          id: fallbackName,
          params: {'Fields': 'Overview,PremiereDate,ProductionLocations,PrimaryImageAspectRatio,ImageTags'},
        );
        if (byName is Map) {
          final merged = byName.cast<String, dynamic>();
          rawPerson = rawPerson == null ? merged : {...merged, ...rawPerson, if ((rawPerson['Overview'] as String?)?.trim().isEmpty != false) 'Overview': merged['Overview'], if (rawPerson['PremiereDate'] == null) 'PremiereDate': merged['PremiereDate'], if (rawPerson['ProductionLocations'] == null) 'ProductionLocations': merged['ProductionLocations']};
        }
      } on EmbyViewFailure {
        _check();
      }
    }

    List<Json> workRows = const [];
    try {
      workRows = await _all({
        'PersonIds': personId,
        'Recursive': true,
        'IncludeItemTypes': 'Movie,Series',
        'Fields': _fields,
        'EnableUserData': true,
        'EnableImageTypes': 'Primary,Backdrop,Logo,Thumb',
      });
    } on EmbyViewFailure {
      _check();
    }

    final resolvedName = (rawPerson?['Name'] as String?)?.trim().isNotEmpty == true
        ? (rawPerson!['Name'] as String).trim()
        : (name?.trim() ?? '');

    if (workRows.isNotEmpty) {
      final topRow = ([...workRows]
            ..sort((a, b) => ((b['CommunityRating'] as num?)?.toDouble() ?? 0)
                .compareTo((a['CommunityRating'] as num?)?.toDouble() ?? 0)))
          .first;
      await _prepareBackdrops([topRow]);
      _prefetchBackdrops(workRows);
    }

    const rolePriority = [
      PersonWorkRole.director,
      PersonWorkRole.actor,
      PersonWorkRole.writer,
      PersonWorkRole.producer,
    ];
    final works = <PersonWork>[];
    final seenIds = <String>{};
    for (final row in workRows) {
      final itemId = row['Id']?.toString() ?? '';
      if (itemId.isEmpty || !seenIds.add(itemId)) continue;
      final card = _card(row);
      final credits = records(row['People']).where((p) {
        final pid = p['Id']?.toString() ?? '';
        if (pid == personId) return true;
        if (resolvedName.isNotEmpty &&
            (p['Name'] as String?)?.trim().toLowerCase() == resolvedName.toLowerCase()) {
          return true;
        }
        return false;
      }).toList();
      final roles = <PersonWorkRole>{};
      String? character;
      for (final c in credits) {
        final parsedRole = parsePersonWorkRole(c['Type'] as String?);
        if (parsedRole != null) roles.add(parsedRole);
        if (parsedRole == PersonWorkRole.actor && (character == null || character.isEmpty)) {
          final roleText = (c['Role'] as String?)?.trim();
          if (roleText != null && roleText.isNotEmpty) character = roleText;
        }
      }
      final fallbackRole = parsePersonWorkRole(roleHint) ?? PersonWorkRole.actor;
      if (roles.isEmpty) roles.add(fallbackRole);
      final primary = rolePriority.firstWhere((r) => roles.contains(r), orElse: () => roles.first);
      works.add(PersonWork(card: card, role: primary, roles: Set.unmodifiable(roles), character: character));
    }

    if (works.isEmpty && sourceItem != null) {
      final fallbackRole = parsePersonWorkRole(roleHint) ?? PersonWorkRole.actor;
      works.add(PersonWork(card: sourceItem, role: fallbackRole, roles: {fallbackRole}));
    }

    final locations = (rawPerson?['ProductionLocations'] as List?)
        ?.whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final overview = (rawPerson?['Overview'] as String?)?.trim();
    ArtworkRef? portrait;
    if (rawPerson != null) {
      portrait = _mapper.image(rawPerson, 'Primary');
    }

    return PersonDetail(
      id: personId,
      name: resolvedName,
      primaryRole: roleHint ?? (rawPerson?['Role'] as String?) ?? (rawPerson?['Type'] as String?),
      portrait: portrait,
      birthDateUtc: _parseEmbyUtcDate(rawPerson?['PremiereDate']),
      birthPlace: locations?.firstOrNull,
      overview: overview == null || overview.isEmpty ? null : overview,
      works: List.unmodifiable(works),
    );
  }

  @override
  Future<MediaDetail> detail(String itemId) async {
    final raw = await _item(itemId);
    await _ensureVersionPicksLoaded();
    List<Json> children = [];
    if (raw['Type'] == 'BoxSet') {
      children = await _all({
        'ParentId': itemId,
        'Recursive': false,
        'IncludeItemTypes': 'Movie,Series',
        'Fields': _fields,
        'SortBy': 'ProductionYear,SortName',
        'SortOrder': 'Ascending,Ascending',
      });
    }
    if (raw['Type'] == 'BoxSet') {
      children.sort(_collectionReleaseOrder);
      _collectionArt[itemId] = children;
    }
    Json? series;
    if (raw['Type'] == 'Episode' && raw['SeriesId'] is String &&
        (raw['SeriesName'] == null || raw['ParentLogoItemId'] != raw['SeriesId'] || raw['ParentLogoImageTag'] == null)) {
      try {
        series = await _item(raw['SeriesId'] as String);
      } on EmbyViewFailure {
        _check();
        // The episode can still supply its own season, number and series name.
      }
    }
    await _prepareBackdrops([raw], parent: series);
    if (children.isNotEmpty) _prefetchBackdrops(children);
    final card = _card(raw, parent: series, collection: children);
    Json? playable = raw['Type'] == 'Movie' || raw['Type'] == 'Episode' ? raw : null;
    if (raw['Type'] == 'Series') {
      playable = itemRecords(
        await _get('nextUp', params: {'SeriesId': itemId, 'EnableResumable': true, 'Limit': 1, 'Fields': _fields}),
      ).firstOrNull;
      playable ??=
          (await _all({'Fields': _fields}, resource: 'episodes', id: itemId)
                ..sort(_episodeOrder))
              .firstOrNull;
    }
    final CollectionMembership? collection =
        raw['Type'] == 'Movie' ? await _resolveCollectionMembership(itemId, raw) : null;
    final position = playable == null ? null : ticks((playable['UserData'] as Map?)?['PlaybackPositionTicks']);
    final sources = records(raw['MediaSources']);
    final streams = records(sources.firstOrNull?['MediaStreams'] ?? raw['MediaStreams']);
    final versions = _mapper.versions(raw);
    return MediaDetail(
      card: card,
      tagline: (raw['Taglines'] as List?)?.whereType<String>().firstOrNull,
      studios: records(raw['Studios']).map((e) => e['Name'].toString()).toList(),
      episodeCount: raw['Type'] == 'Series'
          ? await _count({'ParentId': itemId, 'Recursive': true, 'IncludeItemTypes': 'Episode'})
          : null,
      playTarget: playable == null ? null : _mapper.target(playable),
      resume: playable == null || position == null || position == Duration.zero
          ? null
          : ResumeCard(
              card: card,
              target: _mapper.target(playable),
              position: position,
              duration: ticks(playable['RunTimeTicks']),
            ),
      embeddedSubtitleLanguages: streams
          .where((s) => s['Type'] == 'Subtitle' && s['IsExternal'] == false)
          .map((s) => s['Language'])
          .whereType<String>()
          .toSet()
          .toList(),
      collectionItems: children.map((e) => _card(e)).toList(),
      collection: collection,
      versions: versions,
      rememberedVersionId: _versionPicks?[itemId],
      lastVersionTaste: _lastVersionTaste,
    );
  }

  int _episodeOrder(Json a, Json b) {
    final season = (integer(a['ParentIndexNumber']) ?? 0).compareTo(integer(b['ParentIndexNumber']) ?? 0);
    return season != 0 ? season : (integer(a['IndexNumber']) ?? 0).compareTo(integer(b['IndexNumber']) ?? 0);
  }

  SeasonSummary _season(Json raw, Json series, int count) => SeasonSummary(
    id: raw['Id'].toString(),
    name: raw['Name'] as String? ?? '',
    number: integer(raw['IndexNumber']),
    total: count,
    art: _mapper.image(raw, 'Primary') ?? _mapper.image(series, 'Primary'),
  );

  @override
  Future<List<SeasonSummary>> seasons(String seriesId) async {
    final series = await _item(seriesId);
    final rows = itemRecords(await _get('seasons', id: seriesId, params: {'Fields': _fields}))
      ..sort((a, b) => (integer(a['IndexNumber']) ?? 0).compareTo(integer(b['IndexNumber']) ?? 0));
    final episodes = await _all({'Fields': 'SeasonId'}, resource: 'episodes', id: seriesId);
    return [for (final s in rows) _season(s, series, episodes.where((e) => e['SeasonId'] == s['Id']).length)];
  }

  @override
  Future<SeasonEpisodes> episodes(String seriesId, String seasonId) async {
    final series = await _item(seriesId);
    final seasons = itemRecords(await _get('seasons', id: seriesId, params: {'Fields': _fields}));
    final season = seasons.where((s) => s['Id'] == seasonId).firstOrNull;
    if (season == null) {
      throw const EmbyViewFailure('这一季已不可用', code: 'season_missing');
    }
    await _prepareBackdrops([series]);
    final rows = await _all({'SeasonId': seasonId, 'Fields': _fields}, resource: 'episodes', id: seriesId)
      ..sort(_episodeOrder);
    final cards = [
      for (final e in rows)
        EpisodeCard(
          card: _card(e, parent: series),
          episodeNumber: integer(e['IndexNumber']),
          played: (e['UserData'] as Map?)?['Played'] as bool?,
          resumePosition: ticks((e['UserData'] as Map?)?['PlaybackPositionTicks']),
          still: _mapper.still(e, series),
        ),
    ];
    return SeasonEpisodes(
      season: _season(season, series, cards.length),
      episodes: cards,
      playedCount: cards.where((e) => e.played == true).length,
    );
  }

  @override
  Future<List<PersonCredit>> people(String itemId) async => [
    for (final p in records((await _item(itemId))['People']))
      PersonCredit(
        id: p['Id'].toString(),
        name: p['Name'] as String? ?? '',
        role: p['Type'] as String? ?? '',
        character: p['Role'] as String?,
        avatar: _mapper.image({
          ...p,
          'ImageTags': {'Primary': p['PrimaryImageTag']},
        }, 'Primary'),
      ),
  ];

  @override
  Future<List<MediaCard>> similar(String itemId, {int limit = 16}) async {
    _pageBounds(0, limit);
    return _cards(itemRecords(await _get('similar', id: itemId, params: {'Limit': limit, 'Fields': _fields})));
  }

  @override
  Future<MediaQuality?> quality(String itemId) async => _mapper.quality(await _item(itemId));

  @override
  Future<List<ChapterMark>> chapters(String itemId, {String? mediaSourceId}) async {
    final raw = await _item(itemId, mediaSourceId: mediaSourceId);
    return [
      for (final c in records(raw['Chapters']))
        if (ticks(c['StartPositionTicks']) != null)
          ChapterMark(start: ticks(c['StartPositionTicks'])!, name: c['Name'] as String?),
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  @override
  Future<ThemeMedia> themeMedia(String itemId) async {
    final raw = await _get('theme', id: itemId, params: {'InheritFromParent': true}) as Map;
    final songs = itemRecords(raw['ThemeSongsResult'])
        .map((e) => _mapper.preview({...e, 'MediaType': 'Audio'}))
        .toList();
    final videos = itemRecords(raw['ThemeVideosResult'])
        .where(
          (e) =>
              e['Id'] is String &&
              (e['Id'] as String).isNotEmpty &&
              (e['RunTimeTicks'] == null || (integer(e['RunTimeTicks']) ?? 0) > 0),
        )
        .toList();
    final trailers = itemRecords(await _get('trailers', id: itemId));
    // Only local/server-indexed trailers are playable capabilities; web URLs aren't embedded.
    return ThemeMedia(
      songs: songs,
      backgroundVideo: videos.isEmpty ? null : _mapper.preview(videos.first),
      trailer: trailers.isEmpty ? null : _mapper.preview(trailers.first),
    );
  }

  @override
  Future<List<SafeEpisodeStill>> safeEpisodeStills(String seriesId) async {
    final rows = await _all({'Fields': _fields}, resource: 'episodes', id: seriesId);
    final resumable = (await _all({
      'MediaTypes': 'Video',
      'Fields': 'SeriesId',
    }, resource: 'resume')).where((e) => e['SeriesId'] == seriesId).map((e) => e['Id'].toString()).toSet();
    final stills = <SafeEpisodeStill>[];
    for (final e in rows) {
      final user = e['UserData'] as Map? ?? const {};
      if (user['Played'] != true && !resumable.contains(e['Id'].toString())) {
        continue;
      }
      final image = _mapper.image(e, 'Primary');
      if (image != null) {
        final seasonName = (e['SeasonName'] as String?)?.trim();
        stills.add(
          SafeEpisodeStill(
            image: image,
            seasonNumber: integer(e['ParentIndexNumber']),
            episodeNumber: integer(e['IndexNumber']),
            seasonName: seasonName == null || seasonName.isEmpty ? null : seasonName,
          ),
        );
      }
    }
    return stills.length < 3 ? [] : stills;
  }

  void _pageBounds(int offset, int limit) {
    if (offset < 0 || limit < 1 || limit > 500) {
      throw const EmbyViewFailure('分页范围无效', code: 'invalid_page');
    }
  }

  @override
  Future<Page<ResumeCard>> continueWatching({String? zoneId, int offset = 0, int limit = 20}) async {
    _pageBounds(offset, limit);
    Json? scope;
    if (zoneId != null) scope = await _params(_query(WallScope.zone(zoneId)));
    final params = <String, dynamic>{'MediaTypes': 'Video', 'Fields': _fields};
    if (scope?['ParentId'] != null) params['ParentId'] = scope!['ParentId'];
    final custom = scope != null && scope['ParentId'] == null;
    List<Json> rows;
    int total;
    if (custom) {
      final allowed = (await _all({...scope, 'Fields': 'Id,SeriesId'})).map((e) => e['Id'].toString()).toSet();
      final all = (await _all(
        params,
        resource: 'resume',
      )).where((e) => allowed.contains(e['Id'].toString()) || allowed.contains(e['SeriesId'])).toList();
      total = all.length;
      rows = all.skip(offset).take(limit).toList();
    } else {
      final raw = await _get(
        'resume',
        params: {...params, 'StartIndex': offset, 'Limit': limit, 'EnableTotalRecordCount': true},
      );
      rows = itemRecords(raw);
      total = integer((raw as Map)['TotalRecordCount']) ?? rows.length;
    }
    final seriesIds = rows
        .where((e) => e['Type'] == 'Episode' && e['SeriesId'] != null)
        .map((e) => e['SeriesId'].toString())
        .toSet()
        .toList();
    final series = {for (final s in await _byIds(seriesIds)) s['Id'].toString(): s};
    await _prepareBackdrops([for (final e in rows) series[e['SeriesId']] ?? e]);
    final cards = [
      for (final e in rows)
        ResumeCard(
          card: _card(series[e['SeriesId']] ?? e),
          target: _mapper.target(e),
          position: ticks((e['UserData'] as Map?)?['PlaybackPositionTicks']) ?? Duration.zero,
          duration: ticks(e['RunTimeTicks']),
        ),
    ];
    return Page(items: cards, total: total, nextOffset: offset + rows.length < total ? offset + rows.length : null);
  }

  Future<List<_IndexItem>> _searchScope(String? zoneId) async {
    final catalog = await _catalog(refresh: true);
    if (zoneId == null) return catalog;
    final params = await _params(_query(WallScope.zone(zoneId)));
    final ids = (await _all({...params, 'Fields': 'Id'})).map((r) => r['Id'].toString()).toSet();
    return catalog.where((e) => ids.contains(e.id)).toList();
  }

  @override
  Future<SearchLanding> searchLanding({String? zoneId}) async {
    _check();
    await _restoreIndex();
    final scope = zoneId == null ? null : WallScope.zone(zoneId);
    final shelves = <HomeShelf>[];
    if (scope != null) {
      shelves.add(await _shelf('recommended', '推荐看看', _query(scope, sort: WallSort.score)));
    } else {
      for (final p in (await _preferences()).take(3)) {
        shelves.add(await _shelf(p.id, p.name, _query(WallScope.zone(p.id), sort: WallSort.score)));
      }
    }
    return SearchLanding(recentTerms: List.unmodifiable(_recent), shelves: shelves);
  }

  @override
  Future<SearchResults> search(String text, {String? zoneId, int offset = 0, int limit = 20}) async {
    _pageBounds(offset, limit);
    final term = text.trim();
    if (term.isEmpty) return const SearchResults();
    final index = await _searchScope(zoneId);
    final needle = term.toLowerCase();
    final normalized = TitleKey(term, _transliterate).sort;
    final ranked = <(_IndexItem, int)>[];
    for (final e in index) {
      final name = (e.raw['Name'] as String? ?? '').toLowerCase();
      final original = (e.raw['OriginalTitle'] as String? ?? '').toLowerCase();
      final genres = (e.raw['Genres'] as List? ?? const []).whereType<String>();
      final actors = records(e.raw['People'])
          .where((p) => p['Type'] == 'Actor')
          .map((p) => p['Name'].toString().toLowerCase());
      final score = name == needle || original == needle
          ? 0
          : name.startsWith(needle) || original.startsWith(needle)
          ? 1
          : name.contains(needle) || original.contains(needle)
          ? 2
          : normalized.isNotEmpty && (e.title.initials.startsWith(normalized) || e.title.sort.contains(normalized))
          ? 3
          : genres.any((g) => g.toLowerCase() == needle) || actors.any((a) => a.contains(needle))
          ? 4
          : null;
      if (score != null) ranked.add((e, score));
    }
    ranked.sort((a, b) {
      final rank = a.$2.compareTo(b.$2);
      return rank != 0 ? rank : a.$1.title.sort.compareTo(b.$1.title.sort);
    });
    _check();
    _recent.remove(term);
    _recent.insert(0, term);
    if (_recent.length > 12) _recent.removeLast();
    await (await _storage).setStringList('$_cacheKey.terms', _recent);
    final best = ranked.firstOrNull?.$1;
    final page = ranked.skip(offset).take(limit).map((r) => r.$1).toList();
    final ids = {if (best != null) best.id, ...page.map((e) => e.id)}.toList();
    final fetched = await _byIds(ids);
    if (best != null) {
      final bestRow = fetched.where((r) => r['Id'].toString() == best.id).firstOrNull;
      if (bestRow != null) await _prepareBackdrops([bestRow]);
    }
    final cards = {for (final card in await _cards(fetched)) card.id: card};
    final views = await _views();
    final groups = <SearchGroup>[];
    for (final v in views) {
      final library = v['Id'].toString();
      final all = ranked.where((r) => r.$1.library == library && r.$1.id != best?.id).toList();
      if (all.isEmpty) continue;
      final visible = page
          .where((e) => e.library == library && e.id != best?.id)
          .map((e) => cards[e.id])
          .whereType<MediaCard>()
          .toList();
      groups.add(
        SearchGroup(
          libraryId: library,
          name: v['Name'] as String? ?? '',
          items: visible,
          total: all.length,
          nextOffset: offset + page.length < ranked.length ? offset + page.length : null,
        ),
      );
    }
    return SearchResults(
      bestMatch: best == null ? null : cards[best.id],
      groups: groups,
      total: ranked.length,
      nextOffset: offset + page.length < ranked.length ? offset + page.length : null,
    );
  }
}

class _IndexItem {
  _IndexItem(this.raw, this.library, Transliterate transliterate)
    : title = TitleKey(raw['Name'] as String? ?? '', transliterate);
  final Json raw;
  final String library;
  final TitleKey title;
  String get id => raw['Id'].toString();
}

class _Wall implements WallListing {
  _Wall(this.owner, this.query, this.params, this.ids, this.revision, this.info);
  final EmbyMediaData owner;
  final WallQuery query;
  final Json params;
  final List<String>? ids;
  final int revision;
  @override
  final WallInfo info;
  Future<({List<Json> rows, int? nextOffset})> _rawPage({required int offset, required int limit}) async {
    owner._pageBounds(offset, limit);
    await owner._validateWall(this);
    if (offset >= info.total) return (rows: const <Json>[], nextOffset: null);
    final requested = ids?.skip(offset).take(limit).toList();
    final response = requested == null
        ? await owner._get(
            'items',
            params: {...params, 'StartIndex': offset, 'Limit': limit, 'EnableTotalRecordCount': true},
          )
        : null;
    final rows = requested == null ? itemRecords(response) : await owner._byIds(requested);
    await owner._validateWall(this);
    if (requested != null && rows.length != requested.length ||
        response is Map &&
            integer(response['TotalRecordCount']) != null &&
            integer(response['TotalRecordCount']) != info.total) {
      owner._invalidateBrowse();
      throw const EmbyViewFailure('片库条目已变化，请重新打开海报墙', retryable: true, code: 'wall_changed');
    }
    return (
      rows: rows,
      nextOffset: rows.isNotEmpty && offset + rows.length < info.total ? offset + rows.length : null,
    );
  }

  @override
  Future<Page<MediaCard>> page({required int offset, required int limit}) async {
    final result = await _rawPage(offset: offset, limit: limit);
    final cards = await owner._cards(result.rows, library: params['ParentId'] as String?);
    await owner._validateWall(this);
    return Page(
      items: cards,
      total: info.total,
      nextOffset: result.nextOffset,
    );
  }
}
