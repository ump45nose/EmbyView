import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/contracts/subtitles.dart';
import 'package:moonfin/embyview/subtitles/sources/subtitle_sources.dart';

const query = SubtitleQuery(title: '芙莉莲', originalTitle: 'Frieren', season: 1, episode: 2, languages: ['zh-CN', 'ja']);
final srt = latin1.encode('1\n00:00:00,010 --> 00:00:01,000\ncafé\n');
final ass = utf8.encode('[Script Info]\nTitle: 字幕\n');
final unavailable = http.Response('private provider response', 503);
const xunlei = 'api-shoulei-ssl.xunlei.com';

http.Response json(Object? data) => html(jsonEncode(data));
http.Response file(List<int> bytes) => http.Response.bytes(bytes, 200);
http.Response html(String body) => file(utf8.encode(body));

http.Response xunleiResults() => json({
  'code': 0,
  'data': [
    for (final number in ['01', '02'])
      {
        'name': '芙莉莲.S01E$number.srt',
        'ext': 'srt',
        'languages': ['简体'],
        'url': 'https://subtitle.v.geilijiasu.com/$number.srt',
      },
  ],
});

http.Response assrtResults(List<Object> subtitles) => json({
  'status': 0,
  'sub': {'subs': subtitles},
});

void main() {
  test('four concurrent searches download each provider’s original text bytes', () async {
    final reached = <String>{};
    final ready = Completer<void>();
    final sources = SubtitleSources(
      readSecret: (kind) async => kind == SecretKind.assrt ? 'test-assrt' : 'test-open',
      client: MockClient((request) async {
        final uri = request.url;
        if (reached.add(uri.host) &&
            !ready.isCompleted &&
            reached.containsAll({xunlei, 'api.assrt.net', 'api.opensubtitles.com', 'api.github.com'})) {
          ready.complete();
        }
        await ready.future;
        switch (uri.host) {
          case xunlei:
            expect(uri.queryParameters['name'], '芙莉莲 S01E02');
            return xunleiResults();
          case 'api.assrt.net':
            expect(request.headers['Authorization'], 'Bearer test-assrt');
            expect(uri.queryParameters.containsKey('token'), false);
            if (uri.path.endsWith('/search')) {
              expect(uri.queryParameters['q'], '芙莉莲 S01E02');
              return assrtResults([
                {'id': 123, 'native_name': '芙莉莲 第2集'},
              ]);
            }
            expect(uri.queryParameters['id'], '123');
            return assrtResults([
              {
                'filelist': [
                  {'f': 'S01E01.chs.ass', 'url': 'https://file.assrt.net/01.ass'},
                  {'f': 'S01E02.chs.ass', 'url': 'https://file.assrt.net/02.ass'},
                ],
              },
            ]);
          case 'api.opensubtitles.com':
            expect(request.headers['Api-Key'], 'test-open');
            if (uri.path.endsWith('/subtitles')) {
              expect(uri.queryParameters, {
                'episode_number': '2',
                'languages': 'zh-cn,ja',
                'query': '芙莉莲',
                'season_number': '1',
              });
              return json({
                'data': [
                  {
                    'id': '999',
                    'attributes': {
                      'language': 'zh-cn',
                      'files': [
                        {'file_id': 321, 'file_name': 'Frieren.S01E02'},
                      ],
                    },
                  },
                ],
              });
            }
            expect(request.method, 'POST');
            expect(jsonDecode(request.body), {'file_id': 321});
            return json({'link': 'https://www.opensubtitles.com/download/opaque', 'file_name': 'Frieren.S01E02.srt'});
          case 'api.github.com':
            return json({
              'tree': [
                {'type': 'blob', 'path': '芙莉莲/Frieren.S01E02.cht.ass'},
              ],
            });
          default:
            expect(request.headers['Authorization'], isNull);
            expect(request.headers['Api-Key'], isNull);
            return switch (uri.host) {
              'subtitle.v.geilijiasu.com' || 'www.opensubtitles.com' => file(srt),
              'file.assrt.net' when uri.path == '/02.ass' => file(ass),
              'raw.githubusercontent.com' => file(ass),
              _ => unavailable,
            };
        }
      }),
    );
    addTearDown(sources.close);
    final scope = sources.openScope();
    final groups = await scope.search(query).timeout(const Duration(seconds: 3));
    expect(groups.map((group) => group.source), SubtitleSource.values);
    expect(groups.first.candidates.first.name, '芙莉莲.S01E02.srt');
    final downloads = await Future.wait([for (final group in groups) scope.download(group.candidates.first)]);
    expect(downloads.map((result) => result.bytes), [srt, ass, srt, ass]);
    expect(downloads.map((result) => result.format), ['srt', 'ass', 'srt', 'ass']);
    expect(downloads.map((result) => result.language), ['zh-CN', 'zh-CN', 'zh-CN', 'zh-TW']);
    expect(groups[2].candidates.single.id, matches(r'^[A-Za-z0-9_-]{24}$'));
  });

  test('failures stay in their source and handles expire with the scope', () async {
    final pending = Completer<http.Response>();
    final sources = SubtitleSources(
      readSecret: (_) async => null,
      client: MockClient(
        (request) async => switch (request.url.host) {
          xunlei => xunleiResults(),
          'subtitle.v.geilijiasu.com' => pending.future,
          _ => unavailable,
        },
      ),
    );
    addTearDown(sources.close);
    final first = sources.openScope();
    final groups = await first.search(query);
    expect(groups[1].failure?.reason, contains('ASSRT_TOKEN'));
    expect(groups[2].failure?.reason, contains('OPENSUBTITLES_API_KEY'));
    expect(groups[3].failure?.retryable, true);
    expect(groups[3].failure?.reason, isNot(contains('private provider response')));

    final expired = isA<EmbyViewFailure>().having((failure) => failure.code, 'code', 'expired_candidate');
    final old = groups.first.candidates.first;
    final second = sources.openScope();
    await second.search(query);
    await expectLater(second.download(old), throwsA(expired));
    final current = (await first.search(query)).first.candidates.first;
    await expectLater(first.download(old), throwsA(expired));
    final rejected = expectLater(first.download(current), throwsA(expired));
    first.close();
    await rejected;
    pending.complete(file(srt));
  });

  test('anime repositories recover from throttling and web sources supply downloads', () async {
    final archive = ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile.string('Frieren.S01E01.chs.srt', 'wrong episode'))
        ..addFile(ArchiveFile.bytes('Frieren.S01E02.chs.srt', srt)),
    );
    final sources = SubtitleSources(
      readSecret: (_) async => null,
      client: MockClient((request) async {
        final uri = request.url;
        return switch (uri.host) {
          'api.github.com' => http.Response('', 403),
          'github.com' when uri.path.contains('/tree/') => json({
            'payload': {
              'codeViewTreeRoute': {
                'refInfo': {'currentOid': 'a' * 40},
              },
            },
          }),
          'github.com' when uri.path.endsWith('/tree-list/${'a' * 40}') => json({
            'paths': ['芙莉莲/S01E02.chs.ass'],
          }),
          'jimaku.cc' when uri.path == '/' => html(
            '<div class="entry" data-extra="{&#34;name&#34;:&#34;Frieren&#34;}">'
            '<a href="/entry/729">Frieren</a></div>',
          ),
          'jimaku.cc' when uri.path == '/entry/729' => html(
            '<a href="/entry/729/download/02.srt">Frieren - 02.srt</a>',
          ),
          'kitsunekko.net' when uri.queryParameters['dir'] == 'subtitles/japanese' => html(
            '<a href="/dirlist.php?dir=subtitles%2Fjapanese%2FFrieren">Frieren</a>',
          ),
          'kitsunekko.net' when uri.path == '/dirlist.php' => html(
            """<a href="/subtitles/japanese/Journey's S01E02.srt">S01E02.srt</a>""",
          ),
          'kitsunekko.net' when uri.pathSegments.last == "Journey's S01E02.srt" => file(srt),
          'bbs.acgrip.com' when uri.path == '/search.php' => html(
            '<a href="forum.php?mod=viewthread&amp;tid=7">芙莉莲</a>',
          ),
          'bbs.acgrip.com' when uri.queryParameters['mod'] == 'viewthread' => html(
            '<a href="forum.php?mod=attachment&amp;aid=88">芙莉莲.zip</a>',
          ),
          'bbs.acgrip.com' => file(archive),
          _ => unavailable,
        };
      }),
    );
    addTearDown(sources.close);
    final scope = sources.openScope();
    final group = (await scope.search(query)).last;
    expect(group.failure, isNull);
    expect(group.candidates.map((candidate) => candidate.releaseGroup).toSet(), {
      '北宇治',
      'SweetSub',
      'Jimaku',
      'Kitsunekko',
      'ACG.RIP',
    });
    final forum = group.candidates.singleWhere((candidate) => candidate.releaseGroup == 'ACG.RIP');
    final kitsunekko = group.candidates.singleWhere((candidate) => candidate.releaseGroup == 'Kitsunekko');
    final result = await scope.download(forum);
    expect(result.bytes, srt);
    expect(result.format, 'srt');
    expect(result.language, 'zh-CN');
    expect((await scope.download(kitsunekko)).bytes, srt);
  });

  test('ASSRT falls back across empty object subs and short-keyword status 101, and surfaces auth/rate errors', () async {
    final seenQueries = <String>[];
    final sources = SubtitleSources(
      readSecret: (kind) async => kind == SecretKind.assrt ? 'test-assrt' : null,
      client: MockClient((request) async {
        final uri = request.url;
        if (uri.host != 'api.assrt.net') return unavailable;
        final q = uri.queryParameters['q'] ?? '';
        seenQueries.add(q);
        if (q == 'Up 2009') {
          return json({'status': 0, 'sub': {'action': 'search', 'result': 'succeed', 'subs': <String, Object>{}}});
        }
        if (q == 'Up') {
          return json({'status': 101, 'sub': {'action': 'search', 'result': 'failed', 'subs': <String, Object>{}}, 'errmsg': 'length of keyword must be longer than 3'});
        }
        if (q == '飞屋环游记') {
          return assrtResults([
            {'id': 456, 'native_name': '飞屋环游记 简中.srt', 'subtype': 'Subrip(srt)'},
          ]);
        }
        if (q == 'bad-token') {
          return json({'status': 20001, 'errmsg': 'invalid token'});
        }
        if (q == 'rate-limit') {
          return json({'status': 30001, 'errmsg': 'rate limit'});
        }
        return json({'status': 20900, 'errmsg': 'subtitle not found'});
      }),
    );
    addTearDown(sources.close);
    final scope = sources.openScope();

    final fallback = (await scope.search(
      const SubtitleQuery(title: 'Up', originalTitle: '飞屋环游记', year: 2009),
      enabledSources: {SubtitleSource.assrt},
    )).singleWhere((g) => g.source == SubtitleSource.assrt);
    expect(seenQueries, ['Up 2009', 'Up', '飞屋环游记']);
    expect(fallback.failure, isNull);
    expect(fallback.candidates.single.name, '飞屋环游记 简中.srt');

    final authErr = (await scope.search(
      const SubtitleQuery(title: 'bad-token'),
      enabledSources: {SubtitleSource.assrt},
    )).singleWhere((g) => g.source == SubtitleSource.assrt);
    expect(authErr.failure?.code, 'invalid_credentials');
    expect(authErr.failure?.reason, contains('ASSRT_TOKEN'));

    final rateErr = (await scope.search(
      const SubtitleQuery(title: 'rate-limit'),
      enabledSources: {SubtitleSource.assrt},
    )).singleWhere((g) => g.source == SubtitleSource.assrt);
    expect(rateErr.failure?.code, 'rate_limited');
    expect(rateErr.failure?.retryable, isTrue);

    final notFound = (await scope.search(
      const SubtitleQuery(title: 'missing-film'),
      enabledSources: {SubtitleSource.assrt},
    )).singleWhere((g) => g.source == SubtitleSource.assrt);
    expect(notFound.failure, isNull);
    expect(notFound.candidates, isEmpty);
  });
}
