import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../../contracts/common.dart';
import '../../contracts/preferences.dart';
import '../../contracts/subtitles.dart';

part 'anime_sources.dart';
part 'source_downloads.dart';
part 'subtitle_providers.dart';

class SubtitleQuery {
  const SubtitleQuery({
    required this.title,
    this.originalTitle,
    this.text,
    this.year,
    this.season,
    this.episode,
    this.languages = const [],
  });

  final String title;
  final String? originalTitle;
  final String? text;
  final int? year;
  final int? season;
  final int? episode;
  final List<String> languages;

  String? get _override => _string(text);
  List<String> get _titles => {
    _override ?? title.trim(),
    if (_override == null) originalTitle?.trim(),
  }.whereType<String>().where((name) => name.isNotEmpty).toList(growable: false);

  String get _filenameQuery {
    if (_override case final text?) return text;
    final title = _titles.first;
    if (episode case final episode?) {
      final seasonMarker = season == null ? '' : 'S${season.toString().padLeft(2, '0')}';
      return '$title ${seasonMarker}E${episode.toString().padLeft(2, '0')}';
    }
    return year == null ? title : '$title $year';
  }
}

class SubtitleDownload {
  const SubtitleDownload({required this.bytes, this.language, this.format});

  final Uint8List bytes;
  final String? language;
  final String? format;
}

/// Owns the provider transport. Each panel generation uses a separate scope.
class SubtitleSources {
  SubtitleSources({required this._readSecret, http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final Future<String?> Function(SecretKind) _readSecret;
  final http.Client _client;
  final bool _ownsClient;
  final _scopes = <SubtitleSearchScope>{};
  final _repositoryIndexes = <String, (DateTime, List<String>)>{};
  bool _closed = false;

  SubtitleSearchScope openScope() {
    if (_closed) throw _expired;
    final scope = SubtitleSearchScope._(this);
    _scopes.add(scope);
    return scope;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final scope in _scopes.toList()) {
      scope.close();
    }
    _repositoryIndexes.clear();
    if (_ownsClient) _client.close();
  }
}

/// Download handles only work in the scope that returned them.
class SubtitleSearchScope {
  SubtitleSearchScope._(this._sources);

  final SubtitleSources _sources;
  final _closed = Completer<void>();
  final _random = Random.secure();
  _Downloads _candidates = {};
  int _searchVersion = 0;

  Future<List<SubtitleSearchGroup>> search(
    SubtitleQuery query, {
    Set<SubtitleSource> enabledSources = const {...SubtitleSource.values},
  }) async {
    _checkOpen();
    final version = ++_searchVersion;
    _candidates.clear();
    final _Downloads downloads = {};
    final providers = {
      SubtitleSource.xunlei: _xunlei,
      SubtitleSource.assrt: _assrt,
      SubtitleSource.openSubtitles: _openSubtitles,
      SubtitleSource.anime: _anime,
    };
    final results = await _whileOpen(
      Future.wait([
        for (final entry in providers.entries)
          if (enabledSources.contains(entry.key))
            _searchGroup(entry.key, query, entry.value, downloads)
          else
            Future.value(
              SubtitleSearchGroup(
                source: entry.key,
                failure: const EmbyViewFailure('已在设置中停用此字幕来源。', code: 'subtitle_source_disabled'),
              ),
            ),
      ]),
    );
    _checkOpen();
    if (version != _searchVersion) throw _expired;
    _candidates = downloads;
    return List.unmodifiable(results);
  }

  Future<SubtitleDownload> download(SubtitleCandidate candidate) async {
    _checkOpen();
    final entry = _candidates[candidate.id];
    if (entry == null || entry.$1 != candidate.source) throw _expired;
    final hit = entry.$2;
    try {
      final download = await _whileOpen(hit.download());
      if (_candidates[candidate.id] != entry) throw _expired;
      return download;
    } on EmbyViewFailure {
      rethrow;
    } catch (_) {
      throw const EmbyViewFailure('字幕下载失败', retryable: true);
    }
  }

  void close() {
    if (_closed.isCompleted) return;
    _closed.complete();
    _candidates.clear();
    _sources._scopes.remove(this);
  }

  void _checkOpen() {
    if (_closed.isCompleted) throw _expired;
  }

  Future<T> _whileOpen<T>(Future<T> work) => Future.any([work, _closed.future.then<T>((_) => throw _expired)]);

  Future<SubtitleSearchGroup> _searchGroup(
    SubtitleSource source,
    SubtitleQuery query,
    Future<List<_ProviderHit>> Function(SubtitleQuery) load,
    _Downloads downloads,
  ) async {
    if (query._titles.isEmpty) return SubtitleSearchGroup(source: source);
    try {
      final hits = await load(query);
      int rank(_ProviderHit hit) => _rank(query, hit.match, hit.language, hit.releaseGroup);
      hits.sort((a, b) => rank(b).compareTo(rank(a)));
      final candidates = <SubtitleCandidate>[];
      for (final hit in hits.where((hit) => !hit.name.toLowerCase().endsWith('.ttml')).take(60)) {
        final candidate = SubtitleCandidate(
          id: base64UrlEncode(List.generate(18, (_) => _random.nextInt(256))),
          source: source,
          name: hit.name,
          language: hit.language,
          format: hit.format,
          releaseGroup: hit.releaseGroup,
        );
        candidates.add(candidate);
        downloads[candidate.id] = (source, hit);
      }
      return SubtitleSearchGroup(source: source, candidates: List.unmodifiable(candidates));
    } catch (error) {
      return SubtitleSearchGroup(
        source: source,
        failure: error is EmbyViewFailure ? error : const EmbyViewFailure('查询字幕失败', retryable: true),
      );
    }
  }

  Future<String> _secret(SecretKind kind, String name) async {
    final value = _string(await _sources._readSecret(kind).timeout(_requestTimeout));
    if (value == null) throw EmbyViewFailure('缺少 $name', code: 'missing_credentials');
    return value;
  }

  Future<_Object> _getJson(Uri uri, {Map<String, String> headers = const {}, Map<String, Object>? body}) async {
    final response = await _request(uri, headers: {'Accept': 'application/json', ...headers}, body: body);
    final data = _object(jsonDecode(utf8.decode(response.bodyBytes)));
    if (data.isEmpty) throw _invalidResponse;
    return data;
  }

  Future<http.Response> _request(
    Uri uri, {
    Map<String, String> headers = const {},
    Map<String, Object>? body,
    Set<String>? downloadDomains,
  }) async {
    for (var redirect = 0; redirect <= 4; redirect++) {
      _checkOpen();
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.port != 443 ||
          (downloadDomains != null && !_isProviderHost(uri, downloadDomains))) {
        throw const EmbyViewFailure('字幕来源返回了无效的地址');
      }
      final request = http.AbortableRequest(body == null ? 'GET' : 'POST', uri, abortTrigger: _closed.future);
      request.followRedirects = false;
      request.headers.addAll({'User-Agent': 'EmbyView v1.0', ...headers});
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final response = await _sources._client.send(request).timeout(_requestTimeout);
      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        final bytes = await _collect(response.stream.timeout(_requestTimeout), _fileLimit);
        _checkOpen();
        return http.Response.bytes(bytes, status, headers: response.headers);
      }
      await response.stream.listen((_) {}).cancel();
      final location = response.headers['location'];
      if (location == null || status < 300 || status >= 400) {
        throw EmbyViewFailure('字幕来源请求失败 ($status)', code: 'http_$status', retryable: status == 429 || status >= 500);
      }
      final redirected = uri.resolve(location);
      if (downloadDomains == null &&
          (redirected.host != uri.host || (body != null && status != 307 && status != 308))) {
        throw const EmbyViewFailure('字幕来源返回了无效的跳转');
      }
      uri = redirected;
    }
    throw const EmbyViewFailure('字幕来源跳转过多');
  }
}

const _requestTimeout = Duration(seconds: 20);
const _expired = EmbyViewFailure('字幕候选已失效，请重新搜索', code: 'expired_candidate');
const _invalidResponse = EmbyViewFailure('字幕来源返回的数据无效', retryable: true);

class _ProviderHit {
  const _ProviderHit({
    required this.name,
    required this.download,
    this.language,
    this.format,
    this.releaseGroup,
    String? match,
  }) : match = match ?? name;

  final String name;
  final String match;
  final String? language;
  final String? format;
  final String? releaseGroup;
  final Future<SubtitleDownload> Function() download;
}

typedef _Object = Map<String, dynamic>;
typedef _Downloads = Map<String, (SubtitleSource, _ProviderHit)>;

_Object _object(Object? value) => value is _Object ? value : const {};
List<_Object> _rows(Object? value) => value is List ? List.of(value.whereType<_Object>()) : [];
String? _string(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

Future<Uint8List> _collect(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > limit - bytes.length) {
      throw const EmbyViewFailure('字幕来源返回的文件过大');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

String? _language(String? language) {
  final value = language?.trim().toLowerCase().replaceAll('_', '-');
  return switch (value) {
    'chs' || 'zh-hans' || 'zh-cn' || 'zhs' || 'sc' || '简体' || '简' => 'zh-CN',
    'cht' || 'zh-hant' || 'zh-tw' || 'zht' || 'tc' || '繁體' || '繁体' || '繁' => 'zh-TW',
    'zh' || 'chi' || 'zho' || '中文' => 'zh',
    'jpn' || 'jp' || '日语' || '日文' || '日' => 'ja',
    'eng' || '英语' || '英文' || '英' => 'en',
    'kor' || '韩语' || '韩文' || '韩' => 'ko',
    null || '' => null,
    _ => value,
  };
}

final _filenameLanguage = RegExp(
  r'(?:^|[.\s_\[(-])(chs|cht|zhs|zht|zh(?:[-_](?:cn|tw|hans|hant))?|'
  r'sc|tc|jpn|ja|eng|en|简体?|繁[体體]?)(?=$|[.\s_\])(-])',
  caseSensitive: false,
);

String? _languageFromName(String name) => _language(_filenameLanguage.firstMatch(name)?.group(1));

int _rank(SubtitleQuery query, String name, String? language, [String? group]) {
  var score = _matchesTitle(query, name) ? 10 : 0;
  final season = _seasonOf(name);
  if (query.season != null && season != null) {
    score += season == query.season ? 20 : -60;
  }
  final episode = _episodeOf(name);
  if (query.episode != null && episode != null) {
    score += episode == query.episode ? 40 : -50;
  }
  if (query.year != null && name.contains(query.year.toString())) score += 5;
  final preferred = query.languages.isEmpty ? const ['zh'] : query.languages;
  final baseLanguage = language?.split('-').first;
  final match = preferred.indexWhere((value) {
    final preference = _language(value);
    return preference != null && (preference == language || preference == baseLanguage);
  });
  if (match >= 0) score += max(1, 8 - match);
  if (group == '北宇治' || group == 'SweetSub') score += 10;
  return score;
}

final _titleSeparators = RegExp(r'[^\p{L}\p{N}]', unicode: true);

String _normalizeTitle(String value) => value.toLowerCase().replaceAll(_titleSeparators, '');

final _seasonMarker = RegExp(
  r'(?:\bs0*(\d{1,2})(?:e\d|\b)|第\s*(\d{1,2})\s*[季期]|'
  r'\b(\d{1,2})(?:st|nd|rd|th)\s+season\b)',
  caseSensitive: false,
);
final _episodeMarker = RegExp(
  r'(?:(?:s\d{1,2})?e(?:p)?0*(\d{1,4})\b|第\s*(\d{1,4})\s*[集話话]|'
  r'\[0*(\d{1,3})(?:v\d+)?\]|\s-\s0*(\d{1,3})(?:v\d+)?\b)',
  caseSensitive: false,
);

int? _numberMarker(RegExp pattern, String value) {
  final match = pattern.firstMatch(value);
  if (match == null) return null;
  for (var group = 1; group <= match.groupCount; group++) {
    if (match[group] case final digits?) return int.tryParse(digits);
  }
  return null;
}

int? _seasonOf(String value) => _numberMarker(_seasonMarker, value);
int? _episodeOf(String value) => _numberMarker(_episodeMarker, value);
