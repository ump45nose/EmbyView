import 'dart:async';
import 'dart:io';

/// Matches the real 115 probe; shared by redirect, engine, and audio readers.
const embyViewPlaybackUserAgent = 'Mozilla/5.0';

/// The identity excludes URLs and tokens so diagnostics never disclose them.
class PlaybackSourceKey {
  const PlaybackSourceKey({
    required this.server,
    required this.user,
    required this.item,
    required this.mediaSource,
    required this.userAgent,
  });
  final String server;
  final String user;
  final String item;
  final String mediaSource;
  final String userAgent;
  @override
  bool operator ==(Object other) =>
      other is PlaybackSourceKey &&
      server == other.server &&
      user == other.user &&
      item == other.item &&
      mediaSource == other.mediaSource &&
      userAgent == other.userAgent;
  @override
  int get hashCode => Object.hash(server, user, item, mediaSource, userAgent);
}

class RedirectReply {
  const RedirectReply(this.status, [this.location]);
  final int status;
  final Uri? location;
}

typedef RedirectRequest = Future<RedirectReply> Function(Uri uri, Map<String, String> headers);

class ResolvedPlaybackAddress {
  const ResolvedPlaybackAddress({
    required this.uri,
    required this.headers,
    required this.cacheHit,
    required this.elapsed,
  });
  final Uri uri;
  final Map<String, String> headers;
  final bool cacheHit;
  final Duration elapsed;
}

class _CachedAddress {
  const _CachedAddress(this.uri, this.headers, this.expires, this.original);
  final Uri uri;
  final Uri original;
  final Map<String, String> headers;
  final DateTime expires;
}

/// One bounded request reads Location, without fetching the redirected video.
/// The same UA is passed to the engine and subtitle audio readers.
class PlaybackRedirectCache {
  PlaybackRedirectCache({
    DateTime Function()? now,
    this.request,
    this.timeout = const Duration(seconds: 12),
    this.capacity = 64,
  }) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final RedirectRequest? request;
  final Duration timeout;
  final int capacity;
  final _cache = <PlaybackSourceKey, _CachedAddress>{};
  final _pending = <PlaybackSourceKey, Future<ResolvedPlaybackAddress>>{};
  final _epochs = <PlaybackSourceKey, int>{};
  final _client = HttpClient();
  bool _closed = false;

  static bool sameOrigin(Uri a, Uri b) => a.scheme == b.scheme && a.host == b.host && a.port == b.port;
  static const _credentialParameters = {'api_key', 'x-emby-token', 'x-emby-authorization', 'access_token'};
  static Uri authorizedUri(Uri value, Uri server) {
    if (sameOrigin(value, server)) return value;
    final query = Map<String, dynamic>.from(value.queryParametersAll)
      ..removeWhere((key, _) => _credentialParameters.contains(key.toLowerCase()));
    return value.replace(
      userInfo: '',
      queryParameters: query.isEmpty ? null : query,
      query: query.isEmpty ? '' : null,
    );
  }

  static Map<String, String> authorizedHeaders(
    Uri value,
    Uri server,
    Map<String, String> headers,
    String userAgent,
  ) => Map.unmodifiable({
    if (sameOrigin(value, server))
      for (final entry in headers.entries)
        if (entry.key.toLowerCase() != 'user-agent') entry.key: entry.value,
    'User-Agent': userAgent,
  });

  Future<ResolvedPlaybackAddress> resolve(
    PlaybackSourceKey key,
    Uri original, {
    Map<String, String> headers = const {},
  }) {
    if (_closed) {
      return Future.error(StateError('Playback address resolver closed'));
    }
    final cached = _cache[key];
    if (cached != null && cached.original == original && _now().isBefore(cached.expires)) {
      return Future.value(
        ResolvedPlaybackAddress(
          uri: cached.uri,
          headers: cached.headers,
          cacheHit: true,
          elapsed: Duration.zero,
        ),
      );
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final epoch = _epochs[key] ?? 0;
    final task = _resolve(key, original, headers, epoch);
    _pending[key] = task;
    return task.whenComplete(() {
      if (identical(_pending[key], task)) _pending.remove(key);
    });
  }

  Future<ResolvedPlaybackAddress> _resolve(
    PlaybackSourceKey key,
    Uri original,
    Map<String, String> headers,
    int epoch,
  ) async {
    final watch = Stopwatch()..start();
    final server = Uri.parse(key.server);
    final input = authorizedUri(original, server);
    final inputHeaders = authorizedHeaders(input, server, headers, key.userAgent);
    final reply = await (request ?? _httpRequest)(input, inputHeaders).timeout(timeout);
    Uri address;
    if ({301, 302, 303, 307, 308}.contains(reply.status)) {
      final location = reply.location;
      if (location == null) throw const HttpException('Missing media redirect');
      address = input.resolveUri(location);
      if (address.scheme != 'https' && address.scheme != 'http') {
        throw const HttpException('Unsupported media redirect');
      }
    } else if (reply.status >= 200 && reply.status < 300) {
      address = input;
    } else {
      throw PlaybackAddressException(reply.status);
    }
    address = authorizedUri(address, server);
    final outputHeaders = authorizedHeaders(address, server, headers, key.userAgent);
    if (!_closed && epoch == (_epochs[key] ?? 0)) {
      _cache.removeWhere((_, value) => !_now().isBefore(value.expires));
      if (_cache.length >= capacity) _cache.remove(_cache.keys.first);
      _cache[key] = _CachedAddress(address, outputHeaders, _now().add(const Duration(minutes: 5)), original);
    }
    return ResolvedPlaybackAddress(
      uri: address,
      headers: outputHeaders,
      cacheHit: false,
      elapsed: watch.elapsed,
    );
  }

  Future<RedirectReply> _httpRequest(Uri uri, Map<String, String> headers) async {
    final request = await _client.getUrl(uri).timeout(timeout);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close().timeout(timeout);
    final location = response.headers.value(HttpHeaders.locationHeader);
    // Cancel the body immediately: a server may ignore Range and serve a film.
    await response.listen((_) {}).cancel();
    return RedirectReply(response.statusCode, location == null ? null : Uri.tryParse(location));
  }

  void invalidate(PlaybackSourceKey key) {
    _epochs[key] = (_epochs[key] ?? 0) + 1;
    _cache.remove(key);
    _pending.remove(key);
  }

  /// Invalidates every cached and in-flight redirect entry belonging to [item]
  /// on [server] for [user], ensuring the next open fetches a fresh URL.
  void invalidateForItem({
    required String server,
    required String user,
    required String item,
  }) {
    final keys = <PlaybackSourceKey>{
      ..._cache.keys,
      ..._pending.keys,
      ..._epochs.keys,
    };
    for (final key in keys) {
      if (key.server == server && key.user == user && key.item == item) {
        invalidate(key);
      }
    }
  }

  /// Invalidates every cached and in-flight redirect entry bound to [server]
  /// for [user] (used when switching between multiple addresses of a server).
  void invalidateForServer({
    required String server,
    required String user,
  }) {
    final keys = <PlaybackSourceKey>{
      ..._cache.keys,
      ..._pending.keys,
      ..._epochs.keys,
    };
    for (final key in keys) {
      if (key.server == server && key.user == user) {
        invalidate(key);
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    _pending.clear();
    _epochs.clear();
    _client.close(force: true);
  }
}

class PlaybackAddressException implements Exception {
  const PlaybackAddressException(this.status);
  final int status;
  @override
  String toString() => 'Media address unavailable (HTTP $status)';
}

/// Returns `true` when [host] belongs to a 115 direct-link domain.
bool is115MediaHost(String host) {
  final lower = host.toLowerCase();
  return const ['115.com', '115cdn.net', '115cdn.com']
      .any((domain) => lower == domain || lower.endsWith('.$domain'));
}

/// Extracts a typed HTTP status code from a playback/redirect error if present.
int? extractPlaybackHttpStatus(Object? error) {
  if (error == null) return null;
  if (error is PlaybackAddressException) return error.status;
  if (error is Map) {
    for (final key in const ['status', 'statusCode', 'httpStatus']) {
      final value = error[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return extractPlaybackHttpStatus(error['message'] ?? error['kind']);
  }
  final match = RegExp(r'\b([45]\d{2})\b').firstMatch(error.toString());
  return match != null ? int.tryParse(match.group(1)!) : null;
}

/// Retry eligibility uses typed status first; log strings are never retained.
bool isExpiringPlaybackAddress(Object? error) {
  if (error == null || error is TimeoutException) return true;
  if (extractPlaybackHttpStatus(error) == 403) return true;
  final text = error.toString().toLowerCase();
  return text.contains('timed out') ||
      text.contains('timeout') ||
      text.contains('time-out');
}
