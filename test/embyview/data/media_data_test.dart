// dart format width=120
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/data/emby_media_data.dart';
import 'package:moonfin/embyview/data/title_index.dart';
import 'package:moonfin/embyview/data/media_mapper.dart' show embyAudioTechnicalLabel, embySubtitleQualifiers;
import 'package:server_core/server_core.dart';
import 'package:server_emby/server_emby.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef Json = Map<String, dynamic>;
WallQuery query({
  WallSort sort = WallSort.title,
  String zone = 'movies',
  TechFilter? tech,
  WatchFilter watched = WatchFilter.all,
  YearRange? years,
  HomeFeature? feature,
}) => (
  scope: feature == null ? WallScope.zone(zone) : WallScope.feature(feature),
  sort: sort,
  watched: watched,
  genreId: null,
  years: years,
  technology: tech,
);
Json movie(String id, String name, {bool played = false, bool favorite = false, double ratio = .67}) => {
  'Id': id,
  'Name': name,
  'Type': 'Movie',
  'ProductionYear': 2024,
  'CommunityRating': 8,
  'OriginalTitle': id == 'b' ? 'Inception' : null,
  'RunTimeTicks': 54000000000,
  'PrimaryImageAspectRatio': ratio,
  'ImageTags': {'Primary': 'p$id'},
  'BackdropImageTags': ['b$id'],
  'Genres': ['科幻'],
  'GenreItems': [
    {'Id': 'g1', 'Name': '科幻'},
  ],
  'UserData': {'Played': played, 'IsFavorite': favorite},
};
String latin(String s) => s.replaceAll('盗梦空间', 'dao meng kong jian');

class Fixture {
  final requests = <RequestOptions>[];
  final preferences = <ZonePreference>[];
  final items = [
    movie('b', '盗梦空间'),
    movie('a', 'Alpha', played: true),
    movie('z', 'Zebra', ratio: 1.5),
    movie('n', '123'),
  ];
  final changed = <Json>[];
  Future<dynamic> Function(RequestOptions)? hook;
  bool deny = false;
  int? Function(RequestOptions)? rejectStatus;
  late final client =
      EmbyMediaServerClient(
          baseUrl: 'http://example.test/emby',
          deviceInfo: const DeviceInfo(id: 'test', name: 'test', appName: 'test', appVersion: '1'),
          interceptors: [
            InterceptorsWrapper(
              onRequest: (o, h) async {
                requests.add(o);
                final status = deny ? 401 : rejectStatus?.call(o);
                if (status != null) {
                  h.reject(
                    DioException(
                      requestOptions: o,
                      response: Response(requestOptions: o, statusCode: status),
                    ),
                  );
                  return;
                }
                final value = await hook?.call(o);
                if (value != null) {
                  h.resolve(Response(requestOptions: o, data: jsonDecode(jsonEncode(value))));
                  return;
                }
                final p = o.queryParameters;
                dynamic data = switch (o.path) {
                  '/Genres' => {
                    'Items': [
                      {'Id': 'g1', 'Name': '科幻'},
                    ],
                  },
                  '/ExtendedVideoTypes' => ['DolbyVision', 'Hdr10'],
                  '/AudioLayouts' => ['5.1'],
                  _ => {'Items': [], 'TotalRecordCount': 0},
                };
                if (o.path.endsWith('/Views')) {
                  data = {
                    'Items': [
                      {'Id': 'movies', 'Name': '电影', 'CollectionType': 'movies'},
                    ],
                  };
                } else if (o.path.endsWith('/Items')) {
                  var rows = (p['MinDateLastSaved'] == null ? items : changed).toList();
                  if (p['Ids'] != null) {
                    rows = rows
                        .where((e) => p['Ids'].toString().split(',').contains(e['Id']))
                        .toList()
                        .reversed
                        .toList();
                  }
                  if (p['IsPlayed'] != null) {
                    rows = rows.where((e) => (e['UserData'] as Map)['Played'] == p['IsPlayed']).toList();
                  }
                  if (p['IsFavorite'] != null) {
                    rows = rows.where((e) => (e['UserData'] as Map)['IsFavorite'] == p['IsFavorite']).toList();
                  }
                  if (p['Is4K'] == true || p['ExtendedVideoTypes'] == 'DolbyVision') {
                    rows = rows.where((e) => e['Id'] == 'b').toList();
                  }
                  if (p['GenreIds'] != null) {
                    rows = rows.where((e) => (e['GenreItems'] as List).any((g) => g['Id'] == p['GenreIds'])).toList();
                  }
                  if (p['Years'] != null) {
                    rows = rows
                        .where((e) => p['Years'].toString().split(',').contains('${e['ProductionYear']}'))
                        .toList();
                  }
                  data = {
                    'Items': rows.skip(p['StartIndex'] as int? ?? 0).take(p['Limit'] as int? ?? rows.length).toList(),
                    'TotalRecordCount': rows.length,
                  };
                }
                h.resolve(Response(requestOptions: o, data: jsonDecode(jsonEncode(data))));
              },
            ),
          ],
        )
        ..userId = 'u1'
        ..accessToken = 'fixture-token';
  late final data = EmbyMediaData(client: client, zonePreferences: () => preferences, transliterate: latin);
  void dispose() {
    data.dispose();
    client.dispose();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('episode 20806 inherits series identity, including when only the series has a Logo', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    final episode = {
      'Id': '20806', 'Type': 'Episode', 'Name': '第 2 集',
      'SeriesId': '20800', 'SeasonId': '20804', 'ParentIndexNumber': 1, 'IndexNumber': 2,
      'ImageTags': {'Logo': 'episode-only'},
    };
    final series = {
      'Id': '20800', 'Type': 'Series', 'Name': '北斗神拳 拳王军杂兵们的挽歌', 'ImageTags': {'Logo': 'series-logo'},
    };
    f.hook = (o) async => o.path.endsWith('/Items/20806') ? episode : o.path.endsWith('/Items/20800') ? series : null;
    final card = (await f.data.detail('20806')).card;
    expect(card.seriesName, series['Name']);
    expect(card.seasonNumber, 1);
    expect(card.episodeNumber, 2);
    expect(card.title, '第 2 集');
    expect(card.art.logo?.id, '20800:Logo:0');
    series.remove('ImageTags');
    expect((await f.data.detail('20806')).card.art.logo, isNull);
  });

  test('subtitle variant labels follow the original track metadata', () {
    expect(embySubtitleQualifiers({'DisplayTitle': 'Turkish (SUBRIP)'}), isEmpty);
    expect(embySubtitleQualifiers({'Title': 'Full', 'DisplayTitle': 'Turkish (SUBRIP)'}), ['全字幕']);
    expect(embySubtitleQualifiers({'IsForced': true}), ['强制']);
    expect(embySubtitleQualifiers({'Title': 'non-forced', 'IsHearingImpaired': true}), ['SDH']);
    expect(embySubtitleQualifiers({'Title': '非强制', 'IsDefault': true}), ['默认']);
  });

  test('audio pill uses codec and channel metadata independently', () {
    const title = 'Japanese EAC3 stereo (默认)';
    expect(embyAudioTechnicalLabel({'DisplayTitle': title, 'Codec': 'eac3', 'ChannelLayout': 'stereo', 'Channels': 2}), 'EAC3 2.0');
    expect(embyAudioTechnicalLabel({'Codec': 'aac', 'Channels': 2}), 'AAC 2.0');
    expect(embyAudioTechnicalLabel({'Codec': 'dts', 'ChannelLayout': '5.1(side)', 'Channels': 6}), 'DTS 5.1');
    expect(embyAudioTechnicalLabel({'Codec': 'ac3', 'DisplayTitle': title}), 'AC3');
    expect(embyAudioTechnicalLabel({'ChannelLayout': 'mono'}), '1.0');
    expect(embyAudioTechnicalLabel({'Channels': 6}), '6 声道');
    expect(embyAudioTechnicalLabel({'DisplayTitle': title}), isNull);
    expect(embyAudioTechnicalLabel(null), isNull);
  });

  test('macOS system transliteration supplies the shared Chinese sort and initials', () {
    final key = TitleKey('盗梦空间', MacPinyin.transliterate);
    expect([key.sort, key.initials, key.letter], ['daomengkongjian', 'dmkj', 'D']);
  }, skip: !Platform.isMacOS);
  test('title and random snapshots preserve page order; deletion and session changes revoke access', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    final wall = await f.data.openWall(query());
    expect(wall.info.letterOffsets, {'A': 0, 'D': 1, 'Z': 2, '#': 3});
    final page = await wall.page(offset: 1, limit: 2);
    expect(page.items.map((e) => e.id), ['b', 'z']);
    expect(page.nextOffset, 3);
    final random = await f.data.openWall(query(sort: WallSort.random));
    expect(
      (await random.page(offset: 0, limit: 4)).items.map((e) => e.id),
      (await random.page(offset: 0, limit: 4)).items.map((e) => e.id),
    );
    expect(f.requests.any((r) => r.queryParameters['SortBy'] == 'Random'), false);
    f.items.removeWhere((e) => e['Id'] == 'b');
    await expectLater(wall.page(offset: 0, limit: 4), throwsA(isA<EmbyViewFailure>()));
    expect((await f.data.openWall(query())).info.total, 3);
    final pending = Completer<dynamic>();
    f.hook = (o) => o.path.endsWith('/Resume') ? pending.future : Future.value(null);
    final late = f.data.continueWatching();
    f.client.userId = 'u2';
    pending.complete({'Items': []});
    await expectLater(late, throwsA(isA<EmbyViewFailure>()));
    await expectLater(random.page(offset: 0, limit: 1), throwsA(isA<EmbyViewFailure>()));
  });
  test(
    'scoped persistent index restores, updates incrementally, reconciles deletion and rejects revoked auth',
    () async {
      final f = Fixture();
      addTearDown(f.dispose);
      expect((await f.data.search('dmkj')).bestMatch?.id, 'b');
      expect((await f.data.search('Inception')).bestMatch?.id, 'b');
      f.data.dispose();
      f.requests.clear();
      final restored = EmbyMediaData(
        client: f.client,
        transliterate: (s) {
          if (s == '盗梦空间') throw StateError('persisted title must not be rebuilt');
          return latin(s);
        },
      );
      addTearDown(restored.dispose);
      expect((await restored.search('dmkj')).bestMatch?.id, 'b');
      expect(f.requests.any((r) => r.queryParameters['MinDateLastSaved'] != null), true);
      expect(
        f.requests
            .where((r) => r.path.endsWith('/Items'))
            .every(
              (r) =>
                  r.queryParameters['Ids'] != null ||
                  r.queryParameters['Fields'] == 'Id,Collections' ||
                  r.queryParameters['MinDateLastSaved'] != null,
            ),
        true,
      );
      expect((await restored.searchLanding()).recentTerms, ['dmkj', 'Inception']);
      f.items.first['Name'] = 'Beta';
      f.changed.add(f.items.first);
      expect((await restored.search('Beta')).bestMatch?.id, 'b');
      f.items.removeWhere((e) => e['Id'] == 'z');
      expect((await restored.search('Zebra')).total, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().any((k) => k.contains('fixture-token')), false);
      f.deny = true;
      await expectLater(restored.search('Beta'), throwsA(isA<EmbyViewFailure>()));
      expect(prefs.getKeys().where((k) => !k.endsWith('.terms')), isEmpty);
      f.deny = false;
      f.client.userId = 'u2';
      final other = EmbyMediaData(client: f.client, transliterate: latin);
      addTearDown(other.dispose);
      expect((await other.searchLanding()).recentTerms, isEmpty);
    },
  );
  test('verified filters and custom zones keep counts, empty ranges, home and wall entry sets aligned', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    final q = query(sort: WallSort.score, tech: TechFilter.uhd4k, watched: WatchFilter.unplayed);
    final wall = await f.data.openWall(q);
    expect(wall.info.total, 1);
    await wall.page(offset: 0, limit: 20);
    final p = f.requests.last.queryParameters;
    expect(
      [p['SortBy'], p['SortOrder'], p['Is4K'], p['IsPlayed']],
      ['CommunityRating,SortName', 'Descending,Ascending', true, false],
    );
    expect((await f.data.wallFacets(q)).watched.firstWhere((e) => e.value == WatchFilter.unplayed).count, 1);
    expect((await f.data.openWall(query(sort: WallSort.year, years: YearRange(from: 3000)))).info.total, 0);
    final home = await f.data.home(seriesSort: ShelfSort.title);
    expect([home.recentMovies?.total, home.shortHighRated?.total, home.uhdDolbyVision?.total], [4, 2, 1]);
    expect(home.recentMovies?.more, isNotNull);
    final zone = await f.data.zone('movies');
    expect(zone.genreCounts.single.count, 4);
    expect(zone.collage.length, 4);
    expect(
      f.requests.singleWhere((r) => r.queryParameters.containsKey('MinDateCreated')).queryParameters['MinDateCreated'],
      endsWith('Z'),
    );
    f.preferences.addAll([
      const ZonePreference(
        id: '4k',
        name: '4K',
        iconKey: 'film',
        colorSlot: 1,
        rule: ZoneRule.technology(TechFilter.uhd4k),
      ),
      const ZonePreference(id: 'empty', name: '空', iconKey: 'film', colorSlot: 2, rule: ZoneRule.genre('absent')),
    ]);
    expect((await f.data.openWall(query(zone: '4k'))).info.total, 1);
    expect((await f.data.openWall(query(zone: 'empty'))).info.total, 0);
    expect((await f.data.customZoneFacets()).technologies.map((e) => e.value), TechFilter.values);
    expect(f.requests.where((r) => r.path == '/Genres').every((r) => r.queryParameters['UserId'] == 'u1'), true);
  });
  test('episodes use explicit watched flags and real resume membership; covers and themes fall back safely', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    final series = {
      'Id': 's',
      'Name': 'Series',
      'Type': 'Series',
      'ImageTags': {'Primary': 'sp'},
      'BackdropImageTags': ['sb'],
    };
    f.items.first['ImageTags'] = {'Primary': 'p', 'Thumb': 't', 'Logo': 'l'};
    f.hook = (o) async {
      if (o.path.endsWith('/Items/s')) return series;
      if (o.path.endsWith('/Items/b')) return f.items.first;
      if (o.path.endsWith('/Seasons')) {
        return {
          'Items': [
            {'Id': 'season', 'Name': 'Season 1', 'IndexNumber': 1},
          ],
        };
      }
      if (o.path.endsWith('/Episodes')) {
        return {
          'Items': [
            for (var i = 1; i <= 4; i++)
              {
                'Id': 'e$i',
                'Name': 'E$i',
                'Type': 'Episode',
                'ParentIndexNumber': i >= 3 ? 2 : 1,
                'SeasonName': i >= 3 ? '第 2 季' : 'Season 1',
                'IndexNumber': i,
                'SeriesId': 's',
                if (i != 4) 'ImageTags': {'Primary': 'p$i'},
                'UserData': {if (i == 1 || i == 3) 'Played': true, 'PlayedPercentage': 100},
              },
          ],
        };
      }
      if (o.path.endsWith('/Resume')) {
        return {
          'Items': [
            {'Id': 'e2', 'SeriesId': 's'},
          ],
        };
      }
      if (o.path.endsWith('/ThemeMedia')) {
        return {
          'ThemeSongsResult': {
            'Items': [
              {'Id': 'song', 'Name': 'Theme'},
            ],
          },
          'ThemeVideosResult': {
            'Items': [
              {'Id': 'blank', 'RunTimeTicks': 0},
            ],
          },
        };
      }
      return null;
    };
    final episodes = await f.data.episodes('s', 'season');
    expect([episodes.season.total, episodes.playedCount, episodes.episodes.last.played], [4, 2, null]);
    expect(episodes.season.art?.id, 's:Primary:0');
    expect(episodes.episodes.last.still.layers.single.text, '第 4 集');
    final stills = await f.data.safeEpisodeStills('s');
    expect(stills.map((e) => e.image.id), ['e1:Primary:0', 'e2:Primary:0', 'e3:Primary:0']);
    expect(stills.map((e) => e.seasonNumber), [1, 1, 2]);
    expect(stills.map((e) => e.episodeNumber), [1, 2, 3]);
    expect(stills.map((e) => e.seasonName), ['Season 1', 'Season 1', '第 2 季']);
    expect(await f.data.safeEpisodeStills('other'), isEmpty);
    final first = (await f.data.detail('b')).card;
    expect(first.art.landscape.layers.map((e) => e.source.id), ['b:Thumb:0', 'b:Backdrop:0', 'b:Backdrop:0']);
    expect(first.art.stage.layers.first.logo?.id, 'b:Logo:0');
    expect(first.art.stage.layers.last.blurred, true);
    final theme = await f.data.themeMedia('b');
    expect(theme.songs.single.id, 'song');
    expect([theme.backgroundVideo, theme.trailer], [null, null]);
    f.client.userId = 'u2';
    final other = EmbyMediaData(client: f.client);
    addTearDown(other.dispose);
    final second = (await other.detail('b')).card.art.poster.layers.first.source;
    expect(first.art.poster.layers.first.source.cacheKey, isNot(second.cacheKey));
    expect(first.art.poster.layers.first.source.image, isNot(second.image));
    expect((second.image as NetworkImage).url, isNot(contains('fixture-token')));
    expect((second.image as NetworkImage).headers?['X-Emby-Token'], 'fixture-token');
  });
  test('first collection posters reuse reverse membership, numeric IDs and the detail order without N+1', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    final members = [movie('m3', 'C'), movie('m1', 'A'), movie('m2', 'B')];
    for (final member in members) {
      member['Collections'] = [
        {'Id': 42, 'Name': 'Set'},
      ];
    }
    final set = {
      'Id': '42',
      'Name': 'Set',
      'Type': 'BoxSet',
      'ImageTags': {'Primary': 'set'},
    };
    f.items
      ..clear()
      ..addAll([
        set,
        ...members,
        {'Id': 'empty', 'Name': 'Unknown', 'Type': 'BoxSet'},
      ]);
    f.hook = (o) async {
      if (o.path.endsWith('/Items/42')) return set;
      if (o.path.endsWith('/Items') && o.queryParameters['ParentId'] == '42') {
        return {'Items': members, 'TotalRecordCount': 3};
      }
      return null;
    };
    final wall = await f.data.openWall(query(sort: WallSort.added));
    final cards = (await wall.page(offset: 0, limit: 20)).items;
    expect(cards.firstWhere((c) => c.id == '42').art.poster.stack.map((e) => e.id), ['m2:Primary:0', 'm3:Primary:0']);
    expect(cards.firstWhere((c) => c.id == 'empty').art.poster.stack, isEmpty);
    expect(
      f.requests.any((r) => r.queryParameters['ParentId'] == '42' || r.queryParameters['ParentId'] == 'empty'),
      false,
    );
    expect(f.requests.any((r) => r.queryParameters['Fields'].toString().contains('Collections')), true);
    final detail = await f.data.detail('42');
    expect(detail.playTarget, null);
    expect(detail.collectionItems.map((c) => c.id), ['m1', 'm2', 'm3']);
    expect(detail.card.art.poster.stack.map((e) => e.id), ['m2:Primary:0', 'm3:Primary:0']);
    members.last['Collections'] = []; // Membership may change without the movie's DateLastSaved.
    final refreshed = await f.data.openWall(query());
    expect(
      (await refreshed.page(
        offset: 0,
        limit: 20,
      )).items.firstWhere((c) => c.id == '42').art.poster.stack.map((e) => e.id),
      ['m3:Primary:0'],
    );
  });
  test('ID reconciliation is paged at 500 and persistent indexes isolate servers', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    f.items
      ..clear()
      ..addAll(List.generate(503, (i) => movie('$i', 'A$i')));
    final old = await f.data.openWall(query());
    expect(old.info.total, 503);
    f.items.removeAt(250);
    expect((await f.data.openWall(query())).info.total, 502);
    expect(
      f.requests.where((r) => r.path.endsWith('/Items')).every((r) => (r.queryParameters['Limit'] as int) <= 500),
      true,
    );
    await expectLater(old.page(offset: 0, limit: 1), throwsA(isA<EmbyViewFailure>()));
    final other = Fixture();
    addTearDown(other.dispose);
    other.client.baseUrl = 'http://other.test/emby';
    expect((await other.data.search('dmkj')).bestMatch?.id, 'b');
    expect(other.requests.firstWhere((r) => r.path.endsWith('/Items')).queryParameters['MinDateLastSaved'], null);
    expect((await SharedPreferences.getInstance()).getKeys().where((k) => !k.endsWith('.terms')).length, 2);
  });

  test('one resource 403 drops its cached authorization while other items and libraries remain usable', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    expect((await f.data.search('Inception')).bestMatch?.id, 'b');
    final old = await f.data.openWall(query());
    f.rejectStatus = (o) => o.path.endsWith('/Items/b') || o.queryParameters['ParentId'] == 'blocked' ? 403 : null;
    f.hook = (o) async {
      if (o.path.endsWith('/Items/a')) return f.items.firstWhere((e) => e['Id'] == 'a');
      if (o.path.endsWith('/Views')) {
        return {
          'Items': [
            {'Id': 'blocked', 'Name': '受限片库', 'CollectionType': 'movies'},
            {'Id': 'movies', 'Name': '电影', 'CollectionType': 'movies'},
          ],
        };
      }
      return null;
    };
    await expectLater(f.data.detail('b'), throwsA(isA<EmbyViewFailure>().having((e) => e.code, 'code', 'forbidden')));
    expect((await SharedPreferences.getInstance()).getKeys().where((k) => !k.endsWith('.terms')), isEmpty);
    expect((await f.data.detail('a')).card.title, 'Alpha');
    await expectLater(
      old.page(offset: 0, limit: 1),
      throwsA(isA<EmbyViewFailure>().having((e) => e.code, 'code', 'wall_changed')),
    );
    expect((await f.data.search('Inception')).total, 0);
    expect((await f.data.search('Alpha')).bestMatch?.id, 'a');
  });

  test('random walls, non-title spreads and year filters do not build the global title index', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    final data = EmbyMediaData(client: f.client, transliterate: (_) => throw StateError('unexpected title indexing'));
    addTearDown(data.dispose);
    for (final q in [
      query(sort: WallSort.random),
      query(sort: WallSort.score, feature: HomeFeature.shortHighRated),
      query(sort: WallSort.added, feature: HomeFeature.uhdDolbyVision),
      query(sort: WallSort.year, years: YearRange(from: 2020)),
    ]) {
      final listing = await data.openWall(q);
      await listing.page(offset: 0, limit: 20);
    }
    expect(
      f.requests.any(
        (r) =>
            r.queryParameters['Fields'].toString().contains('Collections') ||
            r.queryParameters.containsKey('MinDateLastSaved'),
      ),
      false,
    );
  });

  test('default zones use the same visible libraries independently of saved custom overrides', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    f.preferences.add(
      const ZonePreference(
        id: 'custom',
        name: '自定义',
        iconKey: 'film',
        colorSlot: 1,
        rule: ZoneRule.technology(TechFilter.uhd4k),
      ),
    );
    final defaults = await f.data.defaultZonePreferences();
    expect(defaults.map((p) => p.id), ['movies']);
    expect(defaults.single.custom, false);
    expect((await f.data.zones()).single.id, 'custom');
    f.preferences.clear();
    expect((await f.data.zones()).single.id, defaults.single.id);
    expect(f.requests.where((r) => r.path.endsWith('/Views')).length, 1);
  });

  test('setFavorite and setPlayed send standard Emby POST/DELETE routes and invalidate/sync cache', () async {
    final f = Fixture();
    addTearDown(f.dispose);
    f.hook = (o) async {
      final favMatch = RegExp(r'^/Users/([^/]+)/FavoriteItems/([^/]+)$').firstMatch(o.path);
      if (favMatch != null) {
        final item = f.items.firstWhere((e) => e['Id'] == favMatch.group(2));
        (item['UserData'] as Map)['IsFavorite'] = o.method == 'POST';
        return item['UserData'];
      }
      final playedMatch = RegExp(r'^/Users/([^/]+)/PlayedItems/([^/]+)$').firstMatch(o.path);
      if (playedMatch != null) {
        final item = f.items.firstWhere((e) => e['Id'] == playedMatch.group(2));
        (item['UserData'] as Map)['Played'] = o.method == 'POST';
        return item['UserData'];
      }
      return null;
    };

    // Seed catalog index and open an initial wall snapshot.
    expect((await f.data.search('Inception')).bestMatch?.id, 'b');
    final staleWall = await f.data.openWall(query(watched: WatchFilter.favorite));
    expect(staleWall.info.total, 0);

    await f.data.setFavorite('b', true);
    expect(f.requests.last.method, 'POST');
    expect(f.requests.last.path, '/Users/u1/FavoriteItems/b');

    // Open wall snapshot is invalidated after write; fresh wall sees the updated favorite filter.
    await expectLater(
      staleWall.page(offset: 0, limit: 1),
      throwsA(isA<EmbyViewFailure>().having((e) => e.code, 'code', 'wall_changed')),
    );
    final favWall = await f.data.openWall(query(watched: WatchFilter.favorite));
    expect(favWall.info.total, 1);
    final favCards = (await favWall.page(offset: 0, limit: 10)).items;
    expect(favCards.single.id, 'b');
    expect(favCards.single.favorite, isTrue);

    await f.data.setFavorite('b', false);
    expect(f.requests.last.method, 'DELETE');
    expect(f.requests.last.path, '/Users/u1/FavoriteItems/b');
    expect((await f.data.openWall(query(watched: WatchFilter.favorite))).info.total, 0);

    await f.data.setPlayed('b', true);
    expect(f.requests.last.method, 'POST');
    expect(f.requests.last.path, '/Users/u1/PlayedItems/b');
    final playedWall = await f.data.openWall(query(watched: WatchFilter.played));
    expect(playedWall.info.total, 2);
    expect((await playedWall.page(offset: 0, limit: 10)).items.firstWhere((c) => c.id == 'b').played, isTrue);

    await f.data.setPlayed('b', false);
    expect(f.requests.last.method, 'DELETE');
    expect(f.requests.last.path, '/Users/u1/PlayedItems/b');
    expect((await f.data.openWall(query(watched: WatchFilter.played))).info.total, 1);

    // Persisted index UserData reflects the latest state.
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = prefs.getKeys().singleWhere((k) => !k.endsWith('.terms'));
    final saved = jsonDecode(prefs.getString(cacheKey)!) as Map<String, dynamic>;
    final savedB = (saved['rows'] as List).cast<Map>().firstWhere((r) => (r['raw'] as Map)['Id'] == 'b');
    expect(((savedB['raw'] as Map)['UserData'] as Map)['IsFavorite'], isFalse);
    expect(((savedB['raw'] as Map)['UserData'] as Map)['Played'], isFalse);
  });

  test('setFavorite and setPlayed reject invalidated sessions and map HTTP/network errors', () async {
    final f = Fixture();
    addTearDown(f.dispose);

    f.rejectStatus = (o) => o.path.contains('/FavoriteItems/') ? 500 : null;
    await expectLater(
      f.data.setFavorite('b', true),
      throwsA(
        isA<EmbyViewFailure>().having((e) => e.code, 'code', 'server').having((e) => e.retryable, 'retryable', true),
      ),
    );

    f.rejectStatus = (o) => o.path.contains('/PlayedItems/') ? 403 : null;
    await expectLater(
      f.data.setPlayed('b', true),
      throwsA(isA<EmbyViewFailure>().having((e) => e.code, 'code', 'forbidden')),
    );

    // 401 revokes session and disposes EmbyMediaData.
    f.rejectStatus = null;
    f.deny = true;
    await expectLater(
      f.data.setFavorite('b', true),
      throwsA(isA<EmbyViewFailure>().having((e) => e.code, 'code', 'unauthorized')),
    );
    // Subsequent call after 401 disposal is rejected immediately without HTTP request.
    f.deny = false;
    final countBefore = f.requests.length;
    await expectLater(
      f.data.setPlayed('b', true),
      throwsA(isA<EmbyViewFailure>().having((e) => e.code, 'code', 'session_changed')),
    );
    expect(f.requests.length, countBefore);

    // Session switch on a fresh instance rejects before sending HTTP request.
    final f2 = Fixture();
    addTearDown(f2.dispose);
    final boundData = f2.data;
    f2.client.userId = 'u2';
    await expectLater(
      boundData.setFavorite('b', true),
      throwsA(isA<EmbyViewFailure>().having((e) => e.code, 'code', 'session_changed')),
    );
    await expectLater(
      boundData.setPlayed('b', false),
      throwsA(isA<EmbyViewFailure>().having((e) => e.code, 'code', 'session_changed')),
    );
    expect(f2.requests, isEmpty);
  });
}
