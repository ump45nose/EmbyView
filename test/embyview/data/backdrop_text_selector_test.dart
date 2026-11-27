// dart format width=120
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/data/emby_media_data.dart';
import 'package:server_core/server_core.dart';
import 'package:server_emby/server_emby.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _Json = Map<String, dynamic>;

EmbyMediaServerClient _makeClient({
  required List<_Json> items,
  String baseUrl = 'http://example.test/emby',
  String userId = 'u1',
  String token = 'test-token',
}) {
  return EmbyMediaServerClient(
      baseUrl: baseUrl,
      deviceInfo: const DeviceInfo(id: 'test', name: 'test', appName: 'test', appVersion: '1'),
      interceptors: [
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final path = options.path;
            dynamic payload = {'Items': [], 'TotalRecordCount': 0};
            if (path.endsWith('/Views')) {
              payload = {
                'Items': [
                  {'Id': 'movies', 'Name': '电影', 'CollectionType': 'movies'},
                ],
              };
            } else if (path.endsWith('/Items')) {
              final ids = options.queryParameters['Ids']?.toString().split(',').toSet();
              final rows = ids == null ? items : items.where((e) => ids.contains(e['Id'].toString())).toList();
              payload = {
                'Items': rows,
                'TotalRecordCount': rows.length,
              };
            } else if (path.contains('/Items/')) {
              final id = path.split('/').last;
              final found = items.where((e) => e['Id'].toString() == id).firstOrNull;
              if (found != null) payload = found;
            }
            handler.resolve(Response(requestOptions: options, data: jsonDecode(jsonEncode(payload))));
          },
        ),
      ],
    )
    ..userId = userId
    ..accessToken = token;
}

_Json _movie(String id, String name, List<String> backdropTags, {double rating = 8.5}) => {
  'Id': id,
  'Name': name,
  'Type': 'Movie',
  'ProductionYear': 2025,
  'CommunityRating': rating,
  'ImageTags': {'Primary': 'p_$id', 'Logo': 'l_$id'},
  'BackdropImageTags': backdropTags,
  'UserData': {'Played': false, 'IsFavorite': false},
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('picks first clean backdrop when index 0 has text and short-circuits remaining tags', () async {
    final items = [_movie('m1', 'WithTextFirst', ['tag_text', 'tag_clean', 'tag_unchecked'])];
    final client = _makeClient(items: items);
    final seenRequests = <(Uri, Map<String, String>)>[];
    final data = EmbyMediaData(
      client: client,
      backdropTextDetector: (uri, headers) async {
        seenRequests.add((uri, headers));
        return uri.queryParameters['tag'] == 'tag_text';
      },
    );
    addTearDown(() {
      data.dispose();
      client.dispose();
    });

    final detail = await data.detail('m1');
    expect(detail.card.art.backdrops.map((b) => b.id).toList(), ['m1:Backdrop:1', 'm1:Backdrop:2', 'm1:Backdrop:0']);
    expect(detail.card.art.stage.layers.first.source.id, 'm1:Backdrop:1');
    expect(detail.card.art.landscape.layers.first.source.id, 'm1:Backdrop:1');
    // Only tag_text and tag_clean were inspected; tag_unchecked was skipped once a clean backdrop was found.
    expect(seenRequests.map((r) => r.$1.queryParameters['tag']).toList(), ['tag_text', 'tag_clean']);
    // Detection requests use maxWidth <= 512 and pass token only via header.
    for (final (uri, headers) in seenRequests) {
      expect(uri.queryParameters['maxWidth'], '512');
      expect(uri.toString(), isNot(contains('test-token')));
      expect(headers['X-Emby-Token'], 'test-token');
    }
  });

  test('keeps index 0 when first backdrop has no text without inspecting later backdrops', () async {
    final items = [_movie('m2', 'CleanFirst', ['clean_0', 'text_1', 'clean_2'])];
    final client = _makeClient(items: items);
    final detectedTags = <String>[];
    final data = EmbyMediaData(
      client: client,
      backdropTextDetector: (uri, _) async {
        final tag = uri.queryParameters['tag']!;
        detectedTags.add(tag);
        return tag == 'text_1';
      },
    );
    addTearDown(() {
      data.dispose();
      client.dispose();
    });

    final detail = await data.detail('m2');
    expect(detail.card.art.backdrops.map((b) => b.id).toList(), ['m2:Backdrop:0', 'm2:Backdrop:1', 'm2:Backdrop:2']);
    expect(detail.card.art.stage.layers.first.source.id, 'm2:Backdrop:0');
    expect(detectedTags, ['clean_0']);
  });

  test('keeps original first backdrop when all backdrops have text', () async {
    final items = [_movie('m3', 'AllText', ['t0', 't1', 't2'])];
    final client = _makeClient(items: items);
    final detectedTags = <String>[];
    final data = EmbyMediaData(
      client: client,
      backdropTextDetector: (uri, _) async {
        detectedTags.add(uri.queryParameters['tag']!);
        return true;
      },
    );
    addTearDown(() {
      data.dispose();
      client.dispose();
    });

    final detail = await data.detail('m3');
    expect(detail.card.art.backdrops.map((b) => b.id).toList(), ['m3:Backdrop:0', 'm3:Backdrop:1', 'm3:Backdrop:2']);
    expect(detail.card.art.stage.layers.first.source.id, 'm3:Backdrop:0');
    expect(detectedTags, ['t0', 't1', 't2']);
  });

  test('skips detection completely when an item only has a single backdrop', () async {
    final items = [_movie('m4', 'SingleBackdrop', ['only_one'])];
    final client = _makeClient(items: items);
    var calls = 0;
    final data = EmbyMediaData(
      client: client,
      backdropTextDetector: (_, _) async {
        calls++;
        return true;
      },
    );
    addTearDown(() {
      data.dispose();
      client.dispose();
    });

    final detail = await data.detail('m4');
    expect(detail.card.art.backdrops.map((b) => b.id).toList(), ['m4:Backdrop:0']);
    expect(detail.card.art.stage.layers.first.source.id, 'm4:Backdrop:0');
    expect(calls, 0);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('persists tag verdicts locally so repeated loads and restarts hit cache with zero detections', () async {
    final items = [_movie('m5', 'CachedMovie', ['bad_0', 'good_1'])];
    final client = _makeClient(items: items);
    var firstSessionCalls = 0;
    final first = EmbyMediaData(
      client: client,
      serverId: 'srv-1',
      backdropTextDetector: (uri, _) async {
        firstSessionCalls++;
        return uri.queryParameters['tag'] == 'bad_0';
      },
    );

    // First call detects bad_0 (text) and good_1 (clean).
    final firstDetail = await first.detail('m5');
    expect(firstDetail.card.art.stage.layers.first.source.id, 'm5:Backdrop:1');
    expect(firstSessionCalls, 2);

    // Second call in the same session hits in-memory cache (0 new calls).
    final secondDetail = await first.detail('m5');
    expect(secondDetail.card.art.stage.layers.first.source.id, 'm5:Backdrop:1');
    expect(firstSessionCalls, 2);
    first.dispose();

    // Fresh EmbyMediaData instance (simulated restart) restores persisted cache with 0 detector calls.
    var restartedCalls = 0;
    final restored = EmbyMediaData(
      client: client,
      serverId: 'srv-1',
      backdropTextDetector: (_, _) async {
        restartedCalls++;
        throw StateError('persisted backdrop verdicts must be reused without re-detecting');
      },
    );
    addTearDown(() {
      restored.dispose();
      client.dispose();
    });

    final restoredDetail = await restored.detail('m5');
    expect(restoredDetail.card.art.stage.layers.first.source.id, 'm5:Backdrop:1');
    expect(restoredDetail.card.art.backdrops.first.id, 'm5:Backdrop:1');
    expect(restartedCalls, 0);
  });

  test('resolves clean backdrops up front for home hero, zone stage, and zone tiles without flicker', () async {
    final items = [
      _movie('h1', 'HeroTextFirst', ['h1_text', 'h1_clean'], rating: 9.5),
      _movie('h2', 'HeroCleanFirst', ['h2_clean', 'h2_text'], rating: 9.0),
    ];
    final client = _makeClient(items: items);
    final calls = <String>[];
    final data = EmbyMediaData(
      client: client,
      serverId: 'srv-home',
      backdropTextDetector: (uri, _) async {
        final tag = uri.queryParameters['tag']!;
        calls.add(tag);
        return tag.endsWith('_text');
      },
    );
    addTearDown(() {
      data.dispose();
      client.dispose();
    });

    final home = await data.home(seriesSort: ShelfSort.score);
    expect(home.zones.single.art?.id, 'h1:Backdrop:1');
    expect(home.recommendations.first.card.art.stage.layers.first.source.id, 'h1:Backdrop:1');
    expect(home.recommendations[1].card.art.stage.layers.first.source.id, 'h2:Backdrop:0');

    final countAfterHome = calls.length;
    final zone = await data.zone('movies');
    expect(zone.zone.art?.id, 'h1:Backdrop:1');
    expect(zone.recommendations.first.card.art.stage.layers.first.source.id, 'h1:Backdrop:1');
    expect(calls.length, countAfterHome);
  });

  test('treats detector failure as unknown without poisoning cache or demoting index 0', () async {
    final items = [_movie('m6', 'TransientFailure', ['t0', 't1'])];
    final client = _makeClient(items: items);
    var fail = true;
    final data = EmbyMediaData(
      client: client,
      backdropTextDetector: (uri, _) async {
        if (fail) return null;
        return uri.queryParameters['tag'] == 't0';
      },
    );
    addTearDown(() {
      data.dispose();
      client.dispose();
    });

    final failedDetail = await data.detail('m6');
    expect(failedDetail.card.art.stage.layers.first.source.id, 'm6:Backdrop:0');

    fail = false;
    final recoveredDetail = await data.detail('m6');
    expect(recoveredDetail.card.art.stage.layers.first.source.id, 'm6:Backdrop:1');
  });
}
