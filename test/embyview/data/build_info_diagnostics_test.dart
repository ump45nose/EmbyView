import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/data/build_info.dart';
import 'package:moonfin/embyview/data/diagnostics_exporter.dart';
import 'package:path/path.dart' as p;

void main() {
  group('EvBuildInfo', () {
    test('falls back to default version when environment defines are empty', () {
      const info = EvBuildInfo(version: '', commit: '');
      expect(info.version, EvBuildInfo.defaultVersion);
      expect(info.version, '1.0.0');
      expect(info.version, isNot('1.0'));
      expect(info.commit, isEmpty);
      expect(info.formattedVersion, '版本 ${EvBuildInfo.defaultVersion}');
      expect(info.upstreamBase, 'Moonfin 3.1.1');
      expect(info.license, 'GPL-3.0');
      expect(info.sourceRepoUrl, 'https://github.com/ump45nose/EmbyView');
    });

    test('formats injected version and shortens full commit SHA to 7 chars', () {
      const shortInfo = EvBuildInfo(version: '1.0.0', commit: '615880f');
      expect(shortInfo.commit, '615880f');
      expect(shortInfo.formattedVersion, '版本 1.0.0（615880f）');

      const fullInfo = EvBuildInfo(
        version: '1.2.0',
        commit: '615880f4b1234567890abcdef1234567890abcde',
      );
      expect(fullInfo.commit, '615880f');
      expect(fullInfo.formattedVersion, '版本 1.2.0（615880f）');
    });
  });

  group('EvDiagnosticsExporter.sanitizeDiagnosticText', () {
    test('strips passwords, API keys, Bearer/Emby tokens, and query secrets', () {
      const raw = '''
POST https://alice:superSecret99@emby.private.home:8920/emby/Users/AuthenticateByName?api_key=embyKey123&token=tok_abc987&X-Emby-Token=headerTok&IncludeItemTypes=Movie
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig12345
X-Emby-Authorization: MediaBrowser Client="EmbyView", Token="mbSecretToken001"
X-Emby-Token: rawEmbyToken42
X-MediaBrowser-Token: rawMbToken99
X-Api-Key: sk-proj-AbCdEf1234567890XyZ
{"password": "myPlainPassword!", "apiKey": "sk-ant-9876543210abcd", "refresh_token": "rt_secret_val"}
pwd=inlinePass123 access_token=at_secret_999
''';
      final clean = EvDiagnosticsExporter.sanitizeDiagnosticText(raw);

      for (final secret in const [
        'superSecret99',
        'emby.private.home',
        'embyKey123',
        'tok_abc987',
        'headerTok',
        'eyJhbGciOiJIUzI1NiJ9',
        'sig12345',
        'mbSecretToken001',
        'rawEmbyToken42',
        'rawMbToken99',
        'sk-proj-AbCdEf1234567890XyZ',
        'myPlainPassword!',
        'sk-ant-9876543210abcd',
        'rt_secret_val',
        'inlinePass123',
        'at_secret_999',
      ]) {
        expect(clean, isNot(contains(secret)), reason: 'Secret leaked: $secret\n$clean');
      }

      // Keeps safe diagnostic context
      expect(clean, contains('/emby/Users/AuthenticateByName'));
      expect(clean, contains('IncludeItemTypes=Movie'));
      expect(clean, contains('https://[REDACTED_HOST]'));
      expect(clean, contains('[REDACTED]'));
    });

    test('strips IPv4, IPv6, .local, .ts.net hostnames, and preserves version numbers', () {
      const raw = '''
2026-11-26T12:00:00Z INFO EmbyView 1.0.0 (AetherEngine · Anime4K)
Connecting to nas.local:8096 and my-nas.tail1234.ts.net:8920
Fallback endpoint 192.168.1.20:8096 or 100.64.0.12 or [fe80::1]:8096 or 2001:db8::42
Failed host lookup: 'media.myfamily.org'
server=emby.example.net:8920
User path /Users/yuwk/Library/Logs/embyview.log vs Emby API /Users/0123456789abcdef0123456789abcdef/Items
HTTP 403 · whisper large-v3-turbo · 574 MB
''';
      final clean = EvDiagnosticsExporter.sanitizeDiagnosticText(raw);

      for (final leaked in const [
        'nas.local',
        'my-nas.tail1234.ts.net',
        '192.168.1.20',
        '100.64.0.12',
        'fe80::1',
        '2001:db8::42',
        'media.myfamily.org',
        'emby.example.net',
        '/Users/yuwk/',
      ]) {
        expect(clean, isNot(contains(leaked)), reason: 'Host/IP leaked: $leaked\n$clean');
      }

      expect(clean, contains('EmbyView 1.0.0'));
      expect(clean, contains('AetherEngine'));
      expect(clean, contains('HTTP 403'));
      expect(clean, contains('whisper large-v3-turbo'));
      expect(clean, contains('/Users/0123456789abcdef0123456789abcdef/Items'));
    });

    test('formats byte sizes cleanly', () {
      expect(EvDiagnosticsExporter.formatByteSize(0), '0 B');
      expect(EvDiagnosticsExporter.formatByteSize(512), '512 B');
      expect(EvDiagnosticsExporter.formatByteSize(2048), '2.0 KB');
      expect(EvDiagnosticsExporter.formatByteSize(2516582), '2.4 MB');
    });

    test('redacts prefixed credential keys, unquoted X-Emby-Authorization, AIza keys, cookies, bare domain:port, and private TLDs', () {
      const raw = '''
{"translationApiKey": "trKeySecret123", "gateway_api_key": "gwKeySecret456", "emby_token": "etok789", "streamToken": "stTok999"}
x-goog-api-key: AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz12345
Cookie: session_id=cookieVal1; auth=cookieVal2
Set-Cookie: sid=setCookieSecret; Path=/; HttpOnly
X-Emby-Authorization: MediaBrowser Client="EmbyView", Device="MacBook", DeviceId="dev-secret-id", Token="embyAuthTok"
Failed connecting to emby.example.com:8920, nas.lan:8096, box.home, media.corp.internal
at EmbyMediaData.detail (package:moonfin/embyview/data/emby_media_data.dart:951)
''';
      final clean = EvDiagnosticsExporter.sanitizeDiagnosticText(raw);

      for (final leaked in const [
        'trKeySecret123',
        'gwKeySecret456',
        'etok789',
        'stTok999',
        'AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz12345',
        'cookieVal1',
        'cookieVal2',
        'setCookieSecret',
        'dev-secret-id',
        'embyAuthTok',
        'emby.example.com:8920',
        'nas.lan',
        'box.home',
        'media.corp.internal',
      ]) {
        expect(clean, isNot(contains(leaked)), reason: 'Leaked: $leaked\n$clean');
      }

      // Keeps safe stack frame file:line context.
      expect(clean, contains('emby_media_data.dart:951'));
    });
  });

  group('EvDiagnosticsExporter 7-day filtering and bundle export', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ev_diag_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('estimates and exports only last 7 days with full sanitization', () async {
      final now = DateTime.utc(2026, 11, 26, 12, 0, 0);
      final logsDir = Directory(p.join(tempDir.path, 'logs'))..createSync();

      final oldFile = File(p.join(logsDir.path, 'old.log'));
      await oldFile.writeAsString('OLD_ENTRY_SHOULD_BE_EXCLUDED 192.168.1.99\n');
      await oldFile.setLastModified(now.subtract(const Duration(days: 8)));

      final recentFile = File(p.join(logsDir.path, 'recent.log'));
      const recentBody =
          'RECENT_LOG connect https://nas.tail9.ts.net:8920/emby/Items?api_key=secretKey999\n'
          'Authorization: Bearer myBearerToken12345\n';
      await recentFile.writeAsString(recentBody);
      await recentFile.setLastModified(now.subtract(const Duration(days: 2)));

      final exporter = EvDiagnosticsExporter(
        buildInfo: const EvBuildInfo(version: '1.0.0', commit: '615880f'),
        logDirectoriesLoader: () async => [logsDir],
        now: () => now,
        recentInMemoryEntriesLoader: () => [
          (
            time: now.subtract(const Duration(days: 10)),
            line: 'STALE_MEMORY_ENTRY',
          ),
          (
            time: now.subtract(const Duration(hours: 3)),
            line: 'RECENT_MEMORY_ENTRY host=nas.local:8096 password=topsecret',
          ),
        ],
      );

      final estimated = await exporter.estimateRecentLogsBytes();
      expect(estimated, greaterThan(recentBody.length));
      expect(estimated, lessThan(recentBody.length + 200));

      final dest = p.join(tempDir.path, 'out', 'bundle.log');
      final result = await exporter.exportSanitizedBundle(destinationPath: dest);

      expect(result.path, dest);
      expect(result.fileCount, 1);
      expect(result.entryCount, 1);
      expect(result.byteCount, greaterThan(0));

      final written = await File(dest).readAsString();
      expect(written, contains('Version: 版本 1.0.0（615880f）'));
      expect(written, contains('RECENT_LOG'));
      expect(written, contains('RECENT_MEMORY_ENTRY'));
      expect(written, isNot(contains('OLD_ENTRY_SHOULD_BE_EXCLUDED')));
      expect(written, isNot(contains('STALE_MEMORY_ENTRY')));
      expect(written, isNot(contains('nas.tail9.ts.net')));
      expect(written, isNot(contains('secretKey999')));
      expect(written, isNot(contains('myBearerToken12345')));
      expect(written, isNot(contains('nas.local')));
      expect(written, isNot(contains('topsecret')));
    });

    test('EvDiagnosticsLog rolls daily files, prunes logs older than 7 days, and exports sanitized connection/playback/subtitle events', () async {
      final now = DateTime.utc(2026, 11, 26, 12, 0, 0);
      final rollingDir = Directory(p.join(tempDir.path, EvDiagnosticsLog.directoryName))..createSync();

      // Seed an expired rolling log (> 7 days old) and a recent log (3 days old).
      final expiredFile = File(p.join(rollingDir.path, 'diag-2026-11-15.log'));
      await expiredFile.writeAsString('2026-11-15T08:00:00Z INFO  [connection] EXPIRED_EVENT\n');
      await expiredFile.setLastModified(now.subtract(const Duration(days: 11)));

      final threeDaysAgoFile = File(p.join(rollingDir.path, 'diag-2026-11-23.log'));
      await threeDaysAgoFile.writeAsString('2026-11-23T09:00:00Z INFO  [app] RECENT_THREE_DAYS_AGO\n');
      await threeDaysAgoFile.setLastModified(now.subtract(const Duration(days: 3)));

      final log = EvDiagnosticsLog(
        directoryLoader: () async => rollingDir,
        now: () => now,
      );

      log.record(
        'connection',
        'failover_switched',
        details: {
          'from': '内网',
          'to': 'Tailscale',
          'url': 'https://alice:secretPass@nas.tail-example.ts.net:8920/emby?api_key=embyTok999',
        },
      );
      log.record(
        'playback',
        'rate_limited_403',
        level: 'ERROR',
        details: {'itemId': '22749', 'httpStatus': 403, 'source': '115 网盘', 'rateLimited': true},
      );
      log.record(
        'subtitle',
        'online_search',
        details: {'itemId': '22749', 'groups': 3, 'candidates': 5, 'apiKey': 'sk-ant-secret12345678'},
      );
      log.record(
        'subtitle',
        'ai_completed',
        details: {'itemId': '22749', 'cues': 420},
      );

      await log.flush();

      // Expired rolling file should be pruned automatically.
      expect(await expiredFile.exists(), isFalse);
      final todayFile = File(p.join(rollingDir.path, 'diag-2026-11-26.log'));
      expect(await todayFile.exists(), isTrue);

      // Even on-disk daily log must already be sanitized.
      final onDisk = await todayFile.readAsString();
      expect(onDisk, contains('[connection] failover_switched'));
      expect(onDisk, contains('[playback] rate_limited_403'));
      expect(onDisk, contains('[subtitle] online_search'));
      expect(onDisk, contains('[subtitle] ai_completed'));
      for (final secret in const ['secretPass', 'nas.tail-example.ts.net', 'embyTok999', 'sk-ant-secret12345678']) {
        expect(onDisk, isNot(contains(secret)));
      }

      final exporter = EvDiagnosticsExporter(
        buildInfo: const EvBuildInfo(version: '1.0.0', commit: '615880f'),
        diagnosticsLog: log,
        recentInMemoryEntriesLoader: () => const [],
        now: () => now,
      );

      final estimated = await exporter.estimateRecentLogsBytes();
      expect(estimated, greaterThan(0));

      final dest = p.join(tempDir.path, 'out', 'rolling-bundle.log');
      final result = await exporter.exportSanitizedBundle(destinationPath: dest);
      expect(result.fileCount, 2);
      expect(result.byteCount, greaterThan(0));

      final bundle = await File(dest).readAsString();
      expect(bundle, contains('RECENT_THREE_DAYS_AGO'));
      expect(bundle, contains('[connection] failover_switched'));
      expect(bundle, contains('[playback] rate_limited_403'));
      expect(bundle, contains('[subtitle] online_search'));
      expect(bundle, contains('[subtitle] ai_completed'));
      expect(bundle, isNot(contains('EXPIRED_EVENT')));
      for (final secret in const ['secretPass', 'nas.tail-example.ts.net', 'embyTok999', 'sk-ant-secret12345678']) {
        expect(bundle, isNot(contains(secret)));
      }
    });
  });
}
