part of 'subtitle_sources.dart';

const _fileLimit = 8 * 1024 * 1024;

String? _format(String? value) {
  final lower = value?.toLowerCase();
  if (lower == null) return null;
  if (lower.contains('subrip')) return 'srt';
  if (lower.contains('substation')) {
    return lower.contains('advanced') ? 'ass' : 'ssa';
  }
  if (lower == 'webvtt') return 'vtt';
  return const {'srt', 'ass', 'ssa', 'vtt', 'ttml'}.contains(lower) ? lower : null;
}

String? _fileFormat(String name) => _format(path.posix.extension(name).replaceFirst('.', ''));

bool _isSubtitleFile(String name) =>
    _fileFormat(name) != null || const {'.zip', '.rar', '.7z'}.contains(path.posix.extension(name).toLowerCase());

Uri? _downloadUri(Object? value, Set<String> domains) {
  final raw = _string(value);
  final uri = raw == null ? null : Uri.tryParse(raw);
  if (uri == null || !_isProviderHost(uri, domains)) return null;
  return uri.scheme == 'http' && !uri.hasPort ? uri.replace(scheme: 'https') : uri;
}

bool _isProviderHost(Uri uri, Set<String> domains) =>
    domains.any((domain) => uri.host == domain || uri.host.endsWith('.$domain'));

extension on SubtitleSearchScope {
  _ProviderHit _fileHit(
    Uri url,
    String name,
    SubtitleQuery query,
    Set<String> domains, {
    String? language,
    String? format,
    String? releaseGroup,
    String? match,
  }) => _ProviderHit(
    name: name,
    match: match,
    language: language,
    format: format ?? _fileFormat(name),
    releaseGroup: releaseGroup,
    download: () => _downloadFile(url, name, query, domains, language: language, format: format),
  );

  Future<SubtitleDownload> _downloadFile(
    Uri url,
    String name,
    SubtitleQuery query,
    Set<String> domains, {
    String? language,
    String? format,
  }) async {
    final uri = _downloadUri(url.toString(), domains);
    if (uri == null) throw _invalidResponse;
    final response = await _request(uri, downloadDomains: domains);
    var bytes = response.bodyBytes;
    final signature = String.fromCharCodes(bytes.take(6));
    if (signature.startsWith('PK\x03\x04')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      final members = {
        for (final file in archive)
          if (file.isFile && !file.isSymbolicLink && file.size <= _fileLimit) file.name: file,
      };
      name = _archiveMember(query, members.keys);
      bytes = members[name]!.content;
    } else if (signature == '7z\xbc\xaf\x27\x1c' || signature == 'Rar!\x1a\x07') {
      final listing = await _readArchive(bytes, ['-tf', '-']);
      name = _archiveMember(query, utf8.decode(listing).split('\n'));
      final literal = name.replaceAllMapped(RegExp(r'[\\*?\[]'), (match) => '\\${match[0]}');
      bytes = await _readArchive(bytes, ['-xOf', '-', '--', literal]);
    }
    final inferred = _sniffFormat(bytes);
    final header = response.headers['content-type']?.toLowerCase() ?? '';
    if (bytes.isEmpty || (inferred == null && (header.contains('html') || header.contains('json')))) {
      throw const EmbyViewFailure('字幕来源未返回字幕文件', retryable: true);
    }
    final resolvedFormat = _fileFormat(name) ?? inferred ?? format;
    if (resolvedFormat == null) {
      throw const EmbyViewFailure('字幕格式无法识别');
    }
    return SubtitleDownload(bytes: bytes, language: _languageFromName(name) ?? language, format: resolvedFormat);
  }
}

String _archiveMember(SubtitleQuery query, Iterable<String> entries) {
  final members = entries.where((name) => _fileFormat(name) != null && _matchesEpisode(query, name)).toList();
  if (members.isEmpty) {
    throw const EmbyViewFailure('字幕压缩包中没有与当前影片匹配的文本字幕');
  }
  int rank(String name) => _rank(query, name, _languageFromName(name));
  members.sort((a, b) => rank(b).compareTo(rank(a)));
  return members.first;
}

String? _sniffFormat(Uint8List bytes) {
  final prefix = utf8.decode(bytes.take(1024).toList(), allowMalformed: true).replaceFirst('\uFEFF', '').trimLeft();
  if (prefix.startsWith('WEBVTT')) return 'vtt';
  if (prefix.startsWith('[Script Info]')) return 'ass';
  if (prefix.contains('-->')) return 'srt';
  if (RegExp(r'<tt(?:\s|>)').hasMatch(prefix)) return 'ttml';
  return null;
}

// macOS libarchive can read RAR and 7z from stdin and emit a selected member
// to stdout. No archive filenames are used as local filesystem paths.
Future<Uint8List> _readArchive(Uint8List bytes, List<String> args) async {
  if (!Platform.isMacOS) throw const EmbyViewFailure('此设备不支持该字幕压缩格式');
  final process = await Process.start('/usr/bin/tar', args);
  try {
    final drain = process.stderr.drain<void>();
    final output = _collect(process.stdout, _fileLimit);
    process.stdin.add(bytes);
    final input = process.stdin.close();
    final [_, _, data, status] = await Future.wait<Object?>([
      input,
      drain,
      output,
      process.exitCode,
    ], eagerError: true).timeout(_requestTimeout);
    if (status != 0) throw const EmbyViewFailure('字幕压缩包无法打开');
    return data as Uint8List;
  } finally {
    process.kill();
  }
}
