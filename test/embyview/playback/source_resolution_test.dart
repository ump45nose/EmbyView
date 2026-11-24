import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/playback/source_resolution.dart';

void main() {
  test('cold, hit, exact five minute expiry and explicit invalidation', () async {
    var now = DateTime.utc(2026);
    var calls = 0;
    final cache = PlaybackRedirectCache(
      now: () => now,
      request: (uri, headers) async {
        calls++;
        return RedirectReply(302, Uri.parse('https://cdn.test/file?attempt=$calls'));
      },
    );
    const key = PlaybackSourceKey(
      server: 'https://emby.test',
      user: 'a',
      item: 'movie',
      mediaSource: 'source',
      userAgent: 'same-ua',
    );
    final source = Uri.parse('https://redirect.test/file');
    final first = await cache.resolve(key, source);
    expect(first.cacheHit, isFalse);
    expect((await cache.resolve(key, source)).cacheHit, isTrue);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 5));
    expect((await cache.resolve(key, source)).cacheHit, isFalse);
    expect(calls, 2);
    cache.invalidate(key);
    await cache.resolve(key, source);
    expect(calls, 3);
    cache.close();
  });

  test('keys isolate server, user, source and UA; concurrent reads merge', () async {
    var calls = 0;
    final gate = Completer<RedirectReply>();
    final cache = PlaybackRedirectCache(
      request: (uri, headers) {
        calls++;
        return gate.future;
      },
    );
    PlaybackSourceKey key({
      String server = 'server',
      String user = 'a',
      String source = 's',
      String ua = 'ua',
    }) => PlaybackSourceKey(server: server, user: user, item: 'movie', mediaSource: source, userAgent: ua);
    final uri = Uri.parse('https://redirect.test/file');
    final requests = [
      cache.resolve(key(), uri),
      cache.resolve(key(), uri),
      cache.resolve(key(user: 'b'), uri),
      cache.resolve(key(server: 'other'), uri),
      cache.resolve(key(source: 'other'), uri),
      cache.resolve(key(ua: 'other'), uri),
    ];
    gate.complete(RedirectReply(302, Uri.parse('https://cdn.test/file')));
    await Future.wait(requests);
    expect(calls, 5);
    cache.close();
  });

  test('same UA, a single request, and no Emby credentials cross origin', () async {
    final seen = <(Uri, Map<String, String>)>[];
    final cache = PlaybackRedirectCache(
      request: (uri, headers) async {
        seen.add((uri, headers));
        return RedirectReply(302, Uri.parse('https://cdn.test/f?api_key=secret&sign=signed'));
      },
    );
    const key = PlaybackSourceKey(
      server: 'https://emby.test',
      user: 'a',
      item: 'movie',
      mediaSource: 's',
      userAgent: 'same-ua',
    );
    final result = await cache.resolve(
      key,
      Uri.parse('https://redirect.test/f?api_key=secret&pick=x'),
      headers: {'Authorization': 'secret', 'X-Emby-Token': 'secret', 'Cookie': 'secret'},
    );
    expect(seen, hasLength(1));
    expect(seen.single.$1.queryParameters, {'pick': 'x'});
    expect(seen.single.$2, {'User-Agent': 'same-ua'});
    expect(result.headers, {'User-Agent': 'same-ua'});
    expect(result.uri.queryParameters, {'sign': 'signed'});
    cache.close();
  });

  test('invalidated or closed in-flight resolution cannot repopulate cache', () async {
    var calls = 0;
    final gates = <Completer<RedirectReply>>[];
    final cache = PlaybackRedirectCache(
      request: (uri, headers) {
        calls++;
        final gate = Completer<RedirectReply>();
        gates.add(gate);
        return gate.future;
      },
    );
    const key = PlaybackSourceKey(server: 'server', user: 'a', item: 'i', mediaSource: 's', userAgent: 'ua');
    final uri = Uri.parse('https://redirect.test/f');
    final old = cache.resolve(key, uri);
    cache.invalidate(key);
    final fresh = cache.resolve(key, uri);
    gates[1].complete(RedirectReply(302, Uri.parse('https://cdn.test/new')));
    await fresh;
    gates[0].complete(RedirectReply(302, Uri.parse('https://cdn.test/old')));
    await old;
    expect((await cache.resolve(key, uri)).uri.path, '/new');
    expect(calls, 2);
    cache.close();
    cache.close();
    await expectLater(cache.resolve(key, uri), throwsStateError);
  });

  test('HTTP transport does not follow 302 or forward authentication', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) {
      requests++;
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/destination');
      request.response.close();
    });
    final cache = PlaybackRedirectCache();
    const key = PlaybackSourceKey(
      server: 'https://emby.test',
      user: 'a',
      item: 'i',
      mediaSource: 's',
      userAgent: 'same-ua',
    );
    final result = await cache.resolve(key, Uri.parse('http://127.0.0.1:${server.port}/source'));
    expect(result.uri.path, '/destination');
    expect(requests, 1);
    cache.close();
    await server.close(force: true);
  });
}
