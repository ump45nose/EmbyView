part of 'subtitle_sources.dart';

const _assrtApi = 'api.assrt.net';
const _openSubtitlesApi = 'api.opensubtitles.com';
const _assrtDownloads = {'assrt.net', 'makedie.me'};

extension on SubtitleSearchScope {
  Future<List<_ProviderHit>> _xunlei(SubtitleQuery query) async {
    for (final text in {query._filenameQuery, ...query._titles}) {
      final data = await _getJson(Uri.https('api-shoulei-ssl.xunlei.com', '/oracle/subtitle', {'name': text}));
      if (data['code'] != 0 || data['data'] is! List) throw _invalidResponse;
      final hits = <_ProviderHit>[];
      for (final item in _rows(data['data'])) {
        const domains = {'geilijiasu.com', 'xunlei.com', 'sandai.net'};
        final url = _downloadUri(item['url'], domains);
        final name = _string(item['name']) ?? _string(item['simple_name']);
        if (url == null || name == null) continue;
        final languages = item['languages'];
        final language = languages is List ? _language(languages.whereType<String>().firstOrNull) : null;
        hits.add(
          _fileHit(
            url,
            name,
            query,
            domains,
            format: _format(_string(item['ext'])) ?? _fileFormat(name),
            language: language,
          ),
        );
      }
      if (hits.isNotEmpty) return hits;
    }
    return [];
  }

  Future<List<_ProviderHit>> _assrt(SubtitleQuery query) async {
    final token = await _secret(SecretKind.assrt, 'ASSRT_TOKEN');
    for (final text in {query._filenameQuery, ...query._titles}) {
      final hits = <_ProviderHit>[];
      for (final item in await _assrtRequest('search', {'q': text}, token)) {
        final id = item['id'];
        final filename = _string(item['videoname']);
        final name = _string(item['native_name']) ?? filename;
        if (id is! int || name == null) continue;
        final codes = _object(_object(item['lang'])['langlist']);
        final language = _assrtLanguage(codes) ?? _languageFromName(name);
        final format = _format(_string(item['subtype'])) ?? _fileFormat(name);
        hits.add(
          _ProviderHit(
            name: name,
            match: '$name ${filename ?? ''}',
            language: language,
            format: format,
            releaseGroup: _string(item['release_site']),
            download: () => _downloadAssrt(id, query, language, format),
          ),
        );
      }
      if (hits.isNotEmpty) return hits;
    }
    return [];
  }

  Future<List<_Object>> _assrtRequest(String action, Map<String, String> params, String token) async {
    final data = await _getJson(
      Uri.https(_assrtApi, '/v1/sub/$action', params),
      headers: {'Authorization': 'Bearer $token'},
    );
    final status = data['status'];
    if (status == 20900 || (action == 'search' && status == 101)) return const [];
    if (status == 20001) {
      throw const EmbyViewFailure('ASSRT_TOKEN 无效或已过期', code: 'invalid_credentials');
    }
    if (status == 30001 || status == 30002) {
      throw const EmbyViewFailure('射手网请求过于频繁，请稍后重试', code: 'rate_limited', retryable: true);
    }
    if (status != 0) throw _invalidResponse;
    final subtitles = _object(data['sub'])['subs'];
    if (subtitles is List) return _rows(subtitles);
    // ASSRT returns an empty JSON object `{}` (or null) when no subtitles match.
    if (subtitles == null || (subtitles is Map && subtitles.isEmpty)) return const [];
    throw _invalidResponse;
  }

  Future<SubtitleDownload> _downloadAssrt(int id, SubtitleQuery query, String? language, String? format) async {
    final token = await _secret(SecretKind.assrt, 'ASSRT_TOKEN');
    final detail = (await _assrtRequest('detail', {'id': '$id'}, token)).firstOrNull;
    if (detail == null) throw _invalidResponse;
    final files = [
      for (final file in _rows(detail['filelist']))
        if ((_string(file['f']), _downloadUri(file['url'], _assrtDownloads)) case (final String name, final Uri url)
            when _fileFormat(name) != null && _matchesEpisode(query, name))
          (name, url),
    ];
    int rank(String name) => _rank(query, name, _languageFromName(name));
    files.sort((a, b) => rank(b.$1).compareTo(rank(a.$1)));
    final (name, url) =
        files.firstOrNull ?? (_string(detail['filename']) ?? '', _downloadUri(detail['url'], _assrtDownloads));
    if (url == null) throw _invalidResponse;
    return _downloadFile(
      url,
      name,
      query,
      _assrtDownloads,
      language: _languageFromName(name) ?? language,
      format: _fileFormat(name) ?? format,
    );
  }

  Future<List<_ProviderHit>> _openSubtitles(SubtitleQuery query) async {
    final key = await _secret(SecretKind.openSubtitles, 'OPENSUBTITLES_API_KEY');
    final languages = query.languages
        .map(_language)
        .whereType<String>()
        .map((language) => language.toLowerCase())
        .toSet()
        .join(',');
    for (final title in query._titles) {
      final data = await _getJson(
        Uri.https(_openSubtitlesApi, '/api/v1/subtitles', {
          if (query.episode != null) 'episode_number': '${query.episode}',
          if (languages.isNotEmpty) 'languages': languages,
          'query': title.toLowerCase(),
          if (query.season != null) 'season_number': '${query.season}',
          if (query.year != null && query.episode == null) 'year': '${query.year}',
        }),
        headers: {'Api-Key': key},
      );
      if (data['data'] is! List) throw _invalidResponse;
      final hits = <_ProviderHit>[];
      for (final item in _rows(data['data'])) {
        final attributes = _object(item['attributes']);
        final language = _language(_string(attributes['language']));
        for (final file in _rows(attributes['files'])) {
          final id = file['file_id'];
          final name = _string(file['file_name']) ?? _string(attributes['release']);
          if (id is! int || name == null) continue;
          final format = _fileFormat(name);
          hits.add(
            _ProviderHit(
              name: name,
              language: language,
              format: format,
              download: () => _downloadOpenSubtitles(id, query, name, language, format),
            ),
          );
        }
      }
      if (hits.isNotEmpty) return hits;
    }
    return [];
  }

  Future<SubtitleDownload> _downloadOpenSubtitles(
    int id,
    SubtitleQuery query,
    String name,
    String? language,
    String? format,
  ) async {
    final key = await _secret(SecretKind.openSubtitles, 'OPENSUBTITLES_API_KEY');
    final result = await _getJson(
      Uri.https(_openSubtitlesApi, '/api/v1/download'),
      headers: {'Api-Key': key},
      body: {'file_id': id},
    );
    const domains = {'opensubtitles.com', 'opensubtitles.org'};
    final url = _downloadUri(result['link'], domains);
    if (url == null) throw _invalidResponse;
    return _downloadFile(url, _string(result['file_name']) ?? name, query, domains, language: language, format: format);
  }
}

String? _assrtLanguage(_Object codes) {
  for (final code in ['chs', 'cht', 'eng', 'jpn', 'kor']) {
    if (codes['lang$code'] == true) return _language(code);
  }
  return null;
}
