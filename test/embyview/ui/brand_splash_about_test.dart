import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/data/build_info.dart';
import 'package:moonfin/embyview/data/diagnostics_exporter.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/subtitles/ai/local_subtitle_asr.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_sections.dart';
import 'package:moonfin/embyview/ui/splash/ev_icons_showcase.dart';
import 'package:moonfin/embyview/ui/splash/ev_splash_page.dart';

Widget _wrap(ThemeMode mode, Widget child, {bool disableAnimations = false}) {
  return MediaQuery(
    data: MediaQueryData(
      size: const Size(1440, 900),
      disableAnimations: disableAnimations,
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: EvThemeScope(
        themeMode: mode,
        child: child,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 7.1 EvAppIcon, 10 new icons, EvBrandBackground & EvIconsShowcase', () {
    testWidgets('10 supplement dual-theme icons resolve by key and render in both themes', (
      tester,
    ) async {
      const expectedKeys = [
        'server',
        'folder',
        'download',
        'lock',
        'logout',
        'keyboard',
        'nowifi',
        'hourglass',
        'shield',
        'refresh',
      ];
      for (final key in expectedKeys) {
        final icon = EvIcons.byKey(key);
        expect(icon.key, key, reason: 'Missing EvIcons entry for $key');
        expect(EvIcons.all, contains(icon));
      }
      expect(EvIcons.byKey('no_wifi').key, 'nowifi');

      for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
        await tester.pumpWidget(
          _wrap(
            mode,
            Wrap(
              spacing: 8,
              children: [
                for (final key in expectedKeys)
                  EvIcon(EvIcons.byKey(key), key: Key('ic_$key'), size: 24),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        for (final key in expectedKeys) {
          final paint = tester.widget<CustomPaint>(
            find.descendant(
              of: find.byKey(Key('ic_$key')),
              matching: find.byType(CustomPaint),
            ),
          );
          final painter = paint.painter! as EvIconPainter;
          expect(painter.isPaper, mode == ThemeMode.paper);
        }
      }
    });

    testWidgets('EvAppIcon renders light and dark variants at all preview sizes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ThemeMode.cinema,
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              EvAppIcon(key: Key('app_light_128'), size: 128, dark: false),
              EvAppIcon(key: Key('app_dark_64'), size: 64, dark: true),
              EvAppIcon(key: Key('app_light_32'), size: 32, dark: false, showShadow: false),
              EvAppIcon(key: Key('app_dark_16'), size: 16, dark: true, showShadow: false),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final lightPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('app_light_128')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((lightPaint.painter! as EvAppIconPainter).dark, isFalse);

      final darkPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('app_dark_64')),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((darkPaint.painter! as EvAppIconPainter).dark, isTrue);
    });

    testWidgets('EvBrandBackground renders normal and calm modes in both themes', (
      tester,
    ) async {
      for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
        for (final calm in [false, true]) {
          await tester.pumpWidget(
            _wrap(
              mode,
              EvBrandBackground(
                calm: calm,
                child: const Center(child: Text('EmbyView')),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.takeException(), isNull);
          expect(find.text('EmbyView'), findsOneWidget);
          expect(find.byType(EvIcon), calm ? findsNothing : findsNWidgets(10));
        }
      }
    });

    testWidgets('EvIconsShowcase renders light/dark cards, sizes, and docks in both themes', (
      tester,
    ) async {
      for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
        await tester.pumpWidget(_wrap(mode, const EvIconsShowcase()));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('应用图标'), findsOneWidget);
        expect(find.text('默认外观'), findsOneWidget);
        expect(find.text('深色外观'), findsOneWidget);
        expect(find.text('Dock 里的样子'), findsOneWidget);
        expect(find.text('128'), findsNWidgets(2));
        expect(find.text('64'), findsNWidgets(2));
        expect(find.text('32'), findsNWidgets(2));
        expect(find.text('16'), findsNWidgets(2));
        expect(find.byKey(const Key('ev_icons_dock_dark')), findsOneWidget);
        expect(find.byKey(const Key('ev_icons_dock_light')), findsOneWidget);
      }
    });
  });

  group('Stage 7.1 EvSplashPage', () {
    testWidgets('renders in cinema and paper themes with default and custom status copy', (
      tester,
    ) async {
      for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
        await tester.pumpWidget(_wrap(mode, const EvSplashPage()));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('ev_splash_icon')), findsOneWidget);
        expect(find.text('EmbyView'), findsOneWidget);
        expect(find.text('正在连接家里的 Emby…'), findsOneWidget);
        expect(find.byKey(const Key('ev_splash_progress')), findsOneWidget);
        // Must use code-drawn EvAppIcon rather than legacy logo_and_text.png.
        expect(find.byType(Image), findsNothing);
      }

      await tester.pumpWidget(
        _wrap(ThemeMode.paper, const EvSplashPage(serverName: '工作室'), disableAnimations: true),
      );
      await tester.pump();
      expect(find.text('正在连接工作室…'), findsOneWidget);

      await tester.pumpWidget(
        _wrap(ThemeMode.cinema, const EvSplashPage(statusText: '正在准备片库…'), disableAnimations: true),
      );
      await tester.pump();
      expect(find.text('正在准备片库…'), findsOneWidget);
    });
  });

  group('Stage 7.1 settings:about (EvAboutSettingsPane)', () {
    const asrChannel = MethodChannel('embyview/asr');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(asrChannel, null));

    testWidgets('renders real version, ASR state, log size, export & source actions in both themes', (
      tester,
    ) async {
      messenger.setMockMethodCallHandler(asrChannel, (call) async {
        if (call.method == 'modelStatus') {
          return {
            'state': AsrModelState.ready.name,
            'receivedBytes': 574000000,
            'totalBytes': 574000000,
          };
        }
        return null;
      });

      final exporter = EvDiagnosticsExporter(
        logDirectoriesLoader: () async => const [],
        recentInMemoryEntriesLoader: () => [
          (time: DateTime.now(), line: 'x' * 2500),
        ],
      );

      var exported = false;
      Uri? openedUri;

      for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
        exported = false;
        openedUri = null;
        await tester.pumpWidget(
          _wrap(
            mode,
            SingleChildScrollView(
              child: EvAboutSettingsPane(
                buildInfo: const EvBuildInfo(version: '1.0.0', commit: '615880f'),
                diagnosticsExporter: exporter,
                onExportDiagnostics: () async {
                  exported = true;
                  return const EvDiagnosticsExportResult(
                    path: '/tmp/EmbyView-diagnostics.log',
                    byteCount: 2560,
                    fileCount: 1,
                    entryCount: 1,
                  );
                },
                onOpenSourceUrl: (uri) async => openedUri = uri,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ev_about_app_icon')), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(find.text('EmbyView'), findsOneWidget);
        expect(find.text('版本 1.0.0（615880f）'), findsOneWidget);
        expect(find.text('基于 Moonfin 3.1.1'), findsOneWidget);
        expect(find.text('GPL-3.0'), findsOneWidget);
        expect(find.text('AetherEngine · Anime4K'), findsOneWidget);
        expect(find.text('就绪'), findsOneWidget);
        expect(find.text('whisper large-v3-turbo · 574 MB'), findsOneWidget);
        expect(find.text('已下载'), findsOneWidget);
        expect(find.text('2.4 KB'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_about_export_logs')));
        await tester.pumpAndSettle();
        expect(exported, isTrue);
        expect(find.byKey(const Key('ev_about_export_feedback')), findsOneWidget);

        await tester.tap(find.byKey(const Key('ev_about_source_code')));
        await tester.pumpAndSettle();
        expect(openedUri, Uri.parse('https://github.com/ump45nose/EmbyView'));
      }
    });

    testWidgets('reflects notDownloaded and failed ASR states accurately', (tester) async {
      messenger.setMockMethodCallHandler(asrChannel, (call) async {
        if (call.method == 'modelStatus') {
          return {
            'state': AsrModelState.notDownloaded.name,
            'receivedBytes': 0,
            'totalBytes': 574000000,
          };
        }
        return null;
      });

      final exporter = EvDiagnosticsExporter(
        logDirectoriesLoader: () async => const [],
        recentInMemoryEntriesLoader: () => const [],
      );

      await tester.pumpWidget(
        _wrap(
          ThemeMode.paper,
          SingleChildScrollView(
            child: EvAboutSettingsPane(diagnosticsExporter: exporter),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未下载'), findsOneWidget);
      expect(find.text('0 B'), findsOneWidget);

      messenger.setMockMethodCallHandler(asrChannel, (call) async {
        if (call.method == 'modelStatus') {
          return {
            'state': AsrModelState.failed.name,
            'receivedBytes': 1000,
            'totalBytes': 574000000,
            'error': 'network reset',
          };
        }
        return null;
      });

      await tester.pumpWidget(
        _wrap(
          ThemeMode.cinema,
          SingleChildScrollView(
            child: EvAboutSettingsPane(
              key: const ValueKey('failed_about'),
              diagnosticsExporter: exporter,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('下载失败'), findsOneWidget);
    });

    testWidgets('displays real non-zero log size after EvDiagnosticsLog records events', (tester) async {
      messenger.setMockMethodCallHandler(asrChannel, (call) async {
        if (call.method == 'modelStatus') {
          return {
            'state': AsrModelState.ready.name,
            'receivedBytes': 574000000,
            'totalBytes': 574000000,
          };
        }
        return null;
      });

      late Directory tempDir;
      late EvDiagnosticsLog log;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('ev_about_log_test_');
        log = EvDiagnosticsLog(directoryLoader: () async => tempDir);
        log.record('app', 'shell_init', details: {'version': '1.0.0'});
        log.record('connection', 'failover_switched', details: {'from': '内网', 'to': 'Tailscale'});
        log.record('playback', 'open', details: {'itemId': '22749'});
        log.record('subtitle', 'load_nas', details: {'itemId': '22749', 'nasTracks': 2});
        await log.flush();
      });
      addTearDown(() async {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final exporter = EvDiagnosticsExporter(
        diagnosticsLog: log,
        recentInMemoryEntriesLoader: () => const [],
      );

      await tester.pumpWidget(
        _wrap(
          ThemeMode.cinema,
          SingleChildScrollView(
            child: EvAboutSettingsPane(diagnosticsExporter: exporter),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        final current = tester.widget<Text>(find.byKey(const Key('ev_about_log_size'))).data;
        if (current != null && current != '计算中…') break;
      }

      final sizeWidget = tester.widget<Text>(find.byKey(const Key('ev_about_log_size')));
      expect(sizeWidget.data, isNotNull);
      expect(sizeWidget.data, isNot('0 B'));
      expect(sizeWidget.data, isNot('计算中…'));
    });
  });
}
