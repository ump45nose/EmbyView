// dart format width=120
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/data/emby_media_data.dart';
import 'package:moonfin/embyview/data/media_mapper.dart';
import 'package:moonfin/embyview/prefs/machine_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:server_emby/server_emby.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef Json = Map<String, dynamic>;

MediaCard _card(
  String id, {
  MediaKind kind = MediaKind.movie,
  String title = 'Film',
  int? year = 2010,
  double? score = 8.5,
  Duration? duration = const Duration(minutes: 120),
  bool? played,
}) => MediaCard(
  id: id,
  kind: kind,
  title: title,
  year: year,
  score: score,
  duration: duration,
  played: played,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#13 collection pure rules', () {
    test('stripCollectionTitleSuffix strips Chinese and ASCII suffixes', () {
      expect(stripCollectionTitleSuffix('蝙蝠侠：黑暗骑士（系列）'), '蝙蝠侠：黑暗骑士');
      expect(stripCollectionTitleSuffix('007(系列)  '), '007');
      expect(stripCollectionTitleSuffix('指环王'), '指环王');
    });

    test('selectCollectionNextTarget follows all 4 selection rules', () {
      final m1 = _card('m1', title: '侠影之谜', year: 2005);
      final m2 = _card('m2', title: '黑暗骑士', year: 2008);
      final m3 = _card('m3', title: '黑暗骑士崛起', year: 2012);

      // 1. None watched -> 从头看第 1 部
      final fresh = selectCollectionNextTarget([
        CollectionItem(card: m1),
        CollectionItem(card: m2),
        CollectionItem(card: m3),
      ])!;
      expect(fresh.index, 0);
      expect(fresh.kind, CollectionNextActionKind.startFromFirst);
      expect(fresh.buttonLabel, '从头看第 1 部');

      // 2. Halfway through #2 -> 继续第 2 部 (takes priority over earlier unwatched)
      final inProgress = selectCollectionNextTarget([
        CollectionItem(card: m1),
        CollectionItem(
          card: m2,
          resume: ResumeCard(
            card: m2,
            target: const PlayTarget(itemId: 'm2', startAt: Duration(minutes: 45)),
            position: const Duration(minutes: 45),
            duration: const Duration(minutes: 152),
          ),
        ),
        CollectionItem(card: m3),
      ])!;
      expect(inProgress.index, 1);
      expect(inProgress.kind, CollectionNextActionKind.resume);
      expect(inProgress.buttonLabel, '继续第 2 部');

      // 3. #1 watched (>85% or played), #2 unwatched -> 接着看第 2 部
      final nextUp = selectCollectionNextTarget([
        CollectionItem(card: m1, played: true),
        CollectionItem(card: m2),
        CollectionItem(card: m3),
      ])!;
      expect(nextUp.index, 1);
      expect(nextUp.kind, CollectionNextActionKind.continueNext);
      expect(nextUp.buttonLabel, '接着看第 2 部');

      // 4. #2 watched, #1 unwatched -> 补看第 1 部
      final catchUp = selectCollectionNextTarget([
        CollectionItem(card: m1),
        CollectionItem(card: m2, played: true),
        CollectionItem(card: m3),
      ])!;
      expect(catchUp.index, 0);
      expect(catchUp.kind, CollectionNextActionKind.catchUp);
      expect(catchUp.buttonLabel, '补看第 1 部');

      // 5. >85% progress counts as done, so next is 接着看
      final almostDone = selectCollectionNextTarget([
        CollectionItem(
          card: m1,
          resume: ResumeCard(
            card: m1,
            target: const PlayTarget(itemId: 'm1', startAt: Duration(minutes: 110)),
            position: const Duration(minutes: 110),
            duration: const Duration(minutes: 120),
          ),
        ),
        CollectionItem(card: m2),
      ])!;
      expect(almostDone.index, 1);
      expect(almostDone.kind, CollectionNextActionKind.continueNext);
      expect(almostDone.buttonLabel, '接着看第 2 部');

      // 6. All watched -> 从头看第 1 部
      final allDone = selectCollectionNextTarget([
        CollectionItem(card: m1, played: true),
        CollectionItem(card: m2, played: true),
      ])!;
      expect(allDone.index, 0);
      expect(allDone.kind, CollectionNextActionKind.startFromFirst);
    });
  });

  group('#12 person pure rules', () {
    test('formatPersonBirthDate converts Emby UTC midnight to local timezone and computes age', () {
      // 1974-11-10T16:00:00Z == 1974-11-11 00:00+08:00 (Beijing)
      final utc = DateTime.utc(1974, 11, 10, 16, 0, 0);
      final nowAfter = DateTime.utc(2026, 11, 27, 9, 0, 0);
      expect(
        formatPersonBirthDate(utc, now: nowAfter, localOffset: const Duration(hours: 8)),
        '1974 年 11 月 11 日出生 · 52 岁',
      );
      // Before birthday in 2026 -> 51 岁
      final nowBefore = DateTime.utc(2026, 11, 10, 15, 0, 0);
      expect(
        formatPersonBirthDate(utc, now: nowBefore, localOffset: const Duration(hours: 8)),
        '1974 年 11 月 11 日出生 · 51 岁',
      );
      // In UTC-5, 1974-11-10T16:00Z is 1974-11-10 11:00 -> Nov 10
      expect(
        formatPersonBirthDate(utc, now: nowAfter, localOffset: const Duration(hours: -5)),
        '1974 年 11 月 10 日出生 · 52 岁',
      );
    });

    test('personWorkFilterKinds, personIdentityLabel, and formatPersonWorkSubtitle', () {
      final works = [
        PersonWork(
          card: _card('w1', title: '盗梦空间', year: 2010),
          role: PersonWorkRole.director,
          roles: const {PersonWorkRole.director, PersonWorkRole.producer, PersonWorkRole.writer},
        ),
        PersonWork(
          card: _card('w2', title: '配音动画', year: 2022),
          role: PersonWorkRole.actor,
          roles: const {PersonWorkRole.actor},
          character: 'Hero (voice)',
        ),
        PersonWork(
          card: _card('w3', title: '客串', year: 2019),
          role: PersonWorkRole.actor,
          roles: const {PersonWorkRole.actor},
          character: 'Cameo (uncredited)',
        ),
      ];
      expect(personWorkFilterKinds(works), [
        PersonWorkRole.actor,
        PersonWorkRole.director,
        PersonWorkRole.writer,
        PersonWorkRole.producer,
      ]);
      expect(
        personIdentityLabel(PersonDetail(id: 'p1', name: 'Test', works: works)),
        '演员 · 导演 · 编剧 · 制片人',
      );
      expect(formatPersonWorkSubtitle(works[1]), '饰 Hero（配音） · 2022');
      expect(formatPersonWorkSubtitle(works[2]), '饰 Cameo · 2019');
      expect(formatPersonWorkSubtitle(works[0]), '导演 · 2010');
      expect(formatPersonWorkSubtitle(works[0], activeFilter: PersonWorkRole.producer), '制片人 · 2010');
    });
  });

  group('#4 version selection rules and preferences', () {
    const vUhd = MediaVersion(
      id: 'uhd',
      name: 'UHD 原盘 Remux',
      resolution: '4K',
      width: 3840,
      height: 2160,
      videoRange: '杜比视界',
      videoCodec: 'HEVC 10bit',
      audioLabel: 'TrueHD 全景声 7.1',
      sizeBytes: 65712999629, // ~61.2 GB
      bitrateBps: 74000000,
      origin: MediaOrigin.direct115,
    );
    const vNas = MediaVersion(
      id: 'nas',
      name: 'H.265 压制',
      resolution: '1080p',
      width: 1920,
      height: 1080,
      videoCodec: 'HEVC',
      audioLabel: 'DTS 5.1',
      sizeBytes: 6120328397, // ~5.7 GB
      bitrateBps: 5100000,
      origin: MediaOrigin.nasLocal,
    );
    const vCn = MediaVersion(
      id: 'cn',
      name: '国语配音版',
      resolution: '1080p',
      width: 1920,
      height: 1080,
      videoCodec: 'H.264',
      audioLabel: 'AAC 2.0',
      sizeBytes: 10522669875, // ~9.8 GB
      bitrateBps: 8400000,
      origin: MediaOrigin.direct115,
    );

    test('selectDefaultMediaVersion respects memory, bestQuality, smallestSize, and lastSimilar', () {
      const list = [vNas, vCn, vUhd];
      expect(vUhd.isHighBitrate, isTrue);
      expect(vNas.isHighBitrate, isFalse);

      // bestQuality picks 4K DV even when not first in list
      expect(
        selectDefaultMediaVersion(list, ruleName: DefaultVersionRule.bestQuality.name)?.id,
        'uhd',
      );
      // smallestSize picks NAS 5.7 GB
      expect(
        selectDefaultMediaVersion(list, ruleName: DefaultVersionRule.smallestSize.name)?.id,
        'nas',
      );
      // lastSimilar with 1080p NAS SDR taste picks NAS
      expect(
        selectDefaultMediaVersion(
          list,
          ruleName: DefaultVersionRule.lastSimilar.name,
          lastTaste: VersionTasteProfile.fromVersion(vNas),
        )?.id,
        'nas',
      );
      // Remembered per-item id always overrides default rule
      expect(
        selectDefaultMediaVersion(
          list,
          ruleName: DefaultVersionRule.bestQuality.name,
          rememberedId: 'cn',
        )?.id,
        'cn',
      );
    });

    test('MachinePreferences persists defaultVersionRule and warnHighBitrateOnExternalNetwork', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await SharedPreferences.getInstance();
      final prefs = await MachinePreferences.open(store: store);
      expect(prefs.current.defaultVersionRule, DefaultVersionRule.bestQuality);
      expect(prefs.current.warnHighBitrateOnExternalNetwork, isTrue);

      await prefs.update(
        prefs.current.copyWith(
          defaultVersionRule: DefaultVersionRule.smallestSize,
          warnHighBitrateOnExternalNetwork: false,
        ),
      );
      await prefs.close();

      final reopened = await MachinePreferences.open(store: store);
      expect(reopened.current.defaultVersionRule, DefaultVersionRule.smallestSize);
      expect(reopened.current.warnHighBitrateOnExternalNetwork, isFalse);
      await reopened.close();
    });
  });

  group('EmbyMediaData facade integration for #13, #12, #4', () {
    EmbyMediaServerClient createClient(
      String userId,
      Map<String, dynamic> Function(RequestOptions) responder,
    ) {
      return EmbyMediaServerClient(
          baseUrl: 'http://example.test/emby',
          deviceInfo: const DeviceInfo(id: 'test', name: 'test', appName: 'test', appVersion: '1'),
          interceptors: [
            InterceptorsWrapper(
              onRequest: (o, h) {
                h.resolve(Response(requestOptions: o, data: jsonDecode(jsonEncode(responder(o)))));
              },
            ),
          ],
        )
        ..userId = userId
        ..accessToken = 'token-$userId';
    }

    test('collection(), detail() membership, person(), and per-user version memory', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await SharedPreferences.getInstance();

      final boxset = {
        'Id': '45707',
        'Name': '蝙蝠侠：黑暗骑士（系列）',
        'Type': 'BoxSet',
        'Overview': '三部曲简介',
        'BackdropImageTags': ['b_box'],
      };
      final films = [
        {
          'Id': '22875',
          'Name': '黑暗骑士崛起',
          'SortName': 'Dark Knight Rises',
          'Type': 'Movie',
          'ProductionYear': 2012,
          'CommunityRating': 8.4,
          'RunTimeTicks': 99000000000,
          'UserData': {'Played': false},
          'People': [
            {'Id': '27673', 'Name': 'Christopher Nolan', 'Type': 'Director'},
            {'Id': '27673', 'Name': 'Christopher Nolan', 'Type': 'Producer'},
          ],
        },
        {
          'Id': '22873',
          'Name': '蝙蝠侠：侠影之谜',
          'SortName': 'Batman Begins',
          'Type': 'Movie',
          'ProductionYear': 2005,
          'CommunityRating': 8.2,
          'RunTimeTicks': 84000000000,
          'UserData': {'Played': true},
          'People': [
            {'Id': '27673', 'Name': 'Christopher Nolan', 'Type': 'Director'},
          ],
        },
        {
          'Id': '22258',
          'Name': '黑暗骑士',
          'SortName': 'Dark Knight',
          'Type': 'Movie',
          'ProductionYear': 2008,
          'CommunityRating': 9.0,
          'RunTimeTicks': 91200000000,
          'UserData': {'Played': false, 'PlaybackPositionTicks': 27000000000},
          'Collections': [
            {'Id': '45707', 'Name': '蝙蝠侠：黑暗骑士（系列）'},
          ],
          'MediaSources': [
            {
              'Id': 'src_4k',
              'Name': '黑暗骑士 - UHD 原盘 Remux',
              'Path': '/mnt/media/115/dark_knight.strm',
              'Container': 'strm',
              'Size': 65712999629,
              'Bitrate': 74000000,
              'MediaStreams': [
                {'Type': 'Video', 'Width': 3840, 'Height': 2160, 'Codec': 'hevc', 'BitDepth': 10, 'VideoRangeType': 'DOVI'},
                {'Type': 'Audio', 'Codec': 'truehd', 'Channels': 8, 'Title': 'TrueHD Atmos', 'IsDefault': true},
                {'Type': 'Subtitle', 'Language': 'chi', 'IsExternal': false},
              ],
            },
            {
              'Id': 'src_nas',
              'Name': 'H.265 压制',
              'Path': '/mnt/media/movies/dk.mkv',
              'Container': 'mkv',
              'Size': 6120328397,
              'Bitrate': 5100000,
              'MediaStreams': [
                {'Type': 'Video', 'Width': 1920, 'Height': 1080, 'Codec': 'hevc'},
                {'Type': 'Audio', 'Codec': 'dts', 'Channels': 6, 'IsDefault': true},
              ],
            },
          ],
          'People': [
            {'Id': '27673', 'Name': 'Christopher Nolan', 'Type': 'Director'},
            {'Id': '23157', 'Name': '莱昂纳多·迪卡普里奥', 'Type': 'Actor', 'Role': 'Cobb'},
          ],
        },
      ];

      Map<String, dynamic> respond(RequestOptions o) {
        if (o.path.endsWith('/Items/45707')) return boxset;
        if (o.path.endsWith('/Items/22258')) return films[2];
        if (o.path.endsWith('/Items/27673')) {
          return {
            'Id': '27673',
            'Name': 'Christopher Nolan',
            'Overview': '英国导演',
            'PremiereDate': '1970-07-29T16:00:00.0000000Z',
            'ProductionLocations': ['Westminster, London, England'],
            'ImageTags': {'Primary': 'p_nolan'},
          };
        }
        if (o.path.endsWith('/Items')) {
          if (o.queryParameters['ParentId'] == '45707') {
            return {'Items': films, 'TotalRecordCount': films.length};
          }
          if (o.queryParameters['PersonIds'] == '27673') {
            return {'Items': films, 'TotalRecordCount': films.length};
          }
        }
        return {'Items': const [], 'TotalRecordCount': 0};
      }

      final clientA = createClient('u1', respond);
      final dataA = EmbyMediaData(client: clientA, serverId: 'srv-1', indexStorage: storage);

      // #13 collection() sorts by ProductionYear ascending: 2005, 2008, 2012
      final col = await dataA.collection('45707');
      expect(col.displayName, '蝙蝠侠：黑暗骑士');
      expect(col.rawName, '蝙蝠侠：黑暗骑士（系列）');
      expect(col.items.map((e) => e.card.id).toList(), ['22873', '22258', '22875']);
      expect(col.items[0].isDone, isTrue);
      expect(col.items[1].isInProgress, isTrue);
      expect(selectCollectionNextTarget(col.items)?.buttonLabel, '继续第 2 部');

      // #13 detail() returns membership position 2 / 3 AND #4 versions
      final det = await dataA.detail('22258');
      expect(det.collection?.id, '45707');
      expect(det.collection?.displayName, '蝙蝠侠：黑暗骑士');
      expect(det.collection?.position, 2);
      expect(det.collection?.total, 3);
      expect(det.versions.length, 2);
      expect(det.versions[0].id, 'src_4k');
      expect(det.versions[0].name, 'UHD 原盘 Remux');
      expect(det.versions[0].resolution, '4K');
      expect(det.versions[0].videoRange, '杜比视界');
      expect(det.versions[0].videoCodec, 'HEVC 10bit');
      expect(det.versions[0].audioLabel, 'TrueHD 全景声 7.1');
      expect(det.versions[0].origin, MediaOrigin.direct115);
      expect(det.versions[1].id, 'src_nas');
      expect(det.versions[1].origin, MediaOrigin.nasLocal);

      // #4 rememberMediaVersion persists per server+user+item
      await dataA.rememberMediaVersion('22258', det.versions[1]);
      final detReloaded = await dataA.detail('22258');
      expect(detReloaded.rememberedVersionId, 'src_nas');
      expect(detReloaded.lastVersionTaste?.origin, MediaOrigin.nasLocal);

      // Isolated for another user on the same server
      final clientB = createClient('u2', respond);
      final dataB = EmbyMediaData(client: clientB, serverId: 'srv-1', indexStorage: storage);
      final detB = await dataB.detail('22258');
      expect(detB.rememberedVersionId, isNull);

      // #12 person() returns metadata + deduplicated multi-role works
      final nolan = await dataA.person('27673');
      expect(nolan.name, 'Christopher Nolan');
      expect(nolan.birthPlace, 'Westminster, London, England');
      expect(nolan.birthDateUtc, DateTime.utc(1970, 7, 29, 16, 0, 0));
      expect(nolan.works.length, 3);
      final risesWork = nolan.works.firstWhere((w) => w.card.id == '22875');
      expect(risesWork.hasRole(PersonWorkRole.director), isTrue);
      expect(risesWork.hasRole(PersonWorkRole.producer), isTrue);

      dataA.dispose();
      dataB.dispose();
      clientA.dispose();
      clientB.dispose();
    });
  });
}
