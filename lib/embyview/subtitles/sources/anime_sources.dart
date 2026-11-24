part of 'subtitle_sources.dart';

extension on SubtitleSearchScope {
  Future<List<_ProviderHit>> _anime(SubtitleQuery query) async {
    final available = (await Future.wait([
      _available(_github(query, 'Kitauji-Sub/Subtitles', 'main', '北宇治')),
      _available(_github(query, 'SweetSub/SweetSub', 'master', 'SweetSub')),
      _available(_jimaku(query)),
      _available(_kitsunekko(query)),
      _available(_acgRip(query)),
    ])).whereType<List<_ProviderHit>>();
    if (available.isEmpty) {
      throw const EmbyViewFailure('动画字幕组来源暂时不可用', retryable: true);
    }
    return available.expand((hits) => hits).toList();
  }

  Future<List<_ProviderHit>> _github(SubtitleQuery query, String repo, String branch, String group) async {
    final paths = await _githubPaths(repo, branch);
    return [
      for (final name in paths)
        if (_matchesTitle(query, name) && _matchesEpisode(query, name))
          _fileHit(
            Uri(
              scheme: 'https',
              host: 'raw.githubusercontent.com',
              pathSegments: [...repo.split('/'), branch, ...name.split('/')],
            ),
            path.posix.basename(name),
            query,
            {'raw.githubusercontent.com'},
            releaseGroup: group,
            match: name,
            language: _languageFromName(name) ?? 'zh',
          ),
    ];
  }

  Future<List<String>> _githubPaths(String repo, String branch) async {
    final cached = _sources._repositoryIndexes[repo];
    if (cached != null && DateTime.now().difference(cached.$1) < const Duration(minutes: 30)) {
      return cached.$2;
    }
    List<String> paths;
    try {
      final response = await _getJson(
        Uri.https('api.github.com', '/repos/$repo/git/trees/$branch', {'recursive': '1'}),
      );
      if (response['truncated'] == true || response['tree'] is! List) {
        throw _invalidResponse;
      }
      paths = _rows(response['tree'])
          .where((entry) => entry['type'] == 'blob')
          .map((entry) => _string(entry['path']))
          .whereType<String>()
          .toList();
    } on Exception {
      // GitHub's public file finder returns indexed paths for a commit ID.
      const headers = {'X-Requested-With': 'XMLHttpRequest'};
      final tree = await _getJson(Uri.https('github.com', '/$repo/tree/$branch'), headers: headers);
      final route = _object(_object(tree['payload'])['codeViewTreeRoute']);
      final oid = _string(_object(route['refInfo'])['currentOid']);
      if (oid == null || !RegExp(r'^[a-f0-9]{40}$').hasMatch(oid)) {
        throw _invalidResponse;
      }
      final index = await _getJson(Uri.https('github.com', '/$repo/tree-list/$oid'), headers: headers);
      final files = index['paths'];
      if (files is! List) throw _invalidResponse;
      paths = files.whereType<String>().toList();
    }
    paths = paths.where(_isSubtitleFile).toList();
    _sources._repositoryIndexes[repo] = (DateTime.now(), paths);
    return paths;
  }

  Future<List<_ProviderHit>> _jimaku(SubtitleQuery query) async {
    final index = Uri.https('jimaku.cc', '/', {'query': query._titles.first});
    final html = await _html(index);
    final entries = <Uri>{};
    final entryPattern = RegExp(
      r'<div\s+class="entry"\s+data-extra="([^"]+)"[^>]*>\s*'
      r'<a\s+href="(/entry/\d+)"',
      caseSensitive: false,
    );
    for (final match in entryPattern.allMatches(html)) {
      final data = _object(jsonDecode(_htmlText(match.group(1)!)));
      final names = [
        for (final key in ['name', 'english_name', 'japanese_name'])
          if (data[key] is String) data[key] as String,
      ];
      if (names.any((name) => _matchesTitle(query, name) && _matchesEpisode(query, name))) {
        entries.add(index.resolve(match.group(2)!));
      }
    }
    return _animeListings(entries, query, 'Jimaku', (uri) => uri.path.contains('/download/'));
  }

  Future<List<_ProviderHit>> _kitsunekko(SubtitleQuery query) => _website(
    Uri.https('kitsunekko.net', '/dirlist.php', {'dir': 'subtitles/japanese'}),
    query,
    'Kitsunekko',
    (url) => url.path == '/dirlist.php' && (url.queryParameters['dir'] ?? '').startsWith('subtitles/japanese/'),
    (url) => url.path.startsWith('/subtitles/japanese/'),
    language: 'ja',
  );

  Future<List<_ProviderHit>> _acgRip(SubtitleQuery query) => _website(
    Uri.https('bbs.acgrip.com', '/search.php', {
      'mod': 'forum',
      'searchid': '0',
      'searchsubmit': 'yes',
      'srchtxt': query._titles.first,
    }),
    query,
    'ACG.RIP',
    (url) => url.path == '/forum.php' && url.queryParameters['mod'] == 'viewthread',
    (url) => url.queryParameters['mod'] == 'attachment',
  );

  Future<List<_ProviderHit>> _website(
    Uri index,
    SubtitleQuery query,
    String group,
    bool Function(Uri) acceptsEntry,
    bool Function(Uri) acceptsFile, {
    String? language,
  }) async => _animeListings(
    {
      for (final (url, name) in _links(index, await _html(index)))
        if (url.host == index.host && acceptsEntry(url) && _matchesTitle(query, name) && _matchesEpisode(query, name))
          url,
    },
    query,
    group,
    acceptsFile,
    language: language,
  );

  Future<List<_ProviderHit>> _animeListings(
    Set<Uri> entries,
    SubtitleQuery query,
    String group,
    bool Function(Uri) acceptsFile, {
    String? language,
  }) async {
    final pages = entries
        .take(4)
        .map(
          (entry) async => [
            for (final (url, name) in _links(entry, await _html(entry)))
              if (url.host == entry.host && acceptsFile(url) && _isSubtitleFile(name) && _matchesEpisode(query, name))
                _fileHit(
                  url,
                  name,
                  query,
                  {entry.host},
                  language: _languageFromName(name) ?? language,
                  releaseGroup: group,
                ),
          ],
        );
    final available = (await Future.wait(pages.map(_available))).whereType<List<_ProviderHit>>();
    if (entries.isNotEmpty && available.isEmpty) throw _invalidResponse;
    return available.expand((page) => page).toList();
  }

  Future<String> _html(Uri url) async => utf8.decode((await _request(url)).bodyBytes, allowMalformed: true);
}

Future<List<_ProviderHit>?> _available(Future<List<_ProviderHit>> run) async {
  try {
    return await run;
  } catch (_) {
    return null;
  }
}

bool _matchesTitle(SubtitleQuery query, String filename) {
  final name = _normalizeTitle(filename);
  return query._titles.any((title) {
    final normalized = _normalizeTitle(title);
    return normalized.isNotEmpty && name.contains(normalized);
  });
}

bool _matchesEpisode(SubtitleQuery query, String name) {
  final season = _seasonOf(name);
  final episode = _episodeOf(name);
  return (season == null || query.season == null || season == query.season) &&
      (episode == null || query.episode == null || episode == query.episode);
}

final _anchor = RegExp(
  r'''<a\b[^>]*\bhref\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a\s*>''',
  caseSensitive: false,
  dotAll: true,
);

Iterable<(Uri, String)> _links(Uri base, String html) sync* {
  for (final match in _anchor.allMatches(html)) {
    final href = Uri.tryParse(_htmlText(match.group(2)!));
    if (href == null) continue;
    final label = _htmlText(match.group(3)!.replaceAll(RegExp(r'<[^>]*>'), ''));
    if (label.isNotEmpty) yield (base.resolveUri(href), label.trim());
  }
}

String _htmlText(String value) =>
    value.replaceAllMapped(RegExp(r'&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);', caseSensitive: false), (match) {
      final entity = match.group(1)!.toLowerCase();
      if (entity.startsWith('#')) {
        final hex = entity.startsWith('#x');
        final number = int.tryParse(entity.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
        return number == null || number > 0x10ffff ? match[0]! : String.fromCharCode(number);
      }
      return const {'amp': '&', 'quot': '"', 'apos': "'", 'lt': '<', 'gt': '>', 'nbsp': ' '}[entity]!;
    });
