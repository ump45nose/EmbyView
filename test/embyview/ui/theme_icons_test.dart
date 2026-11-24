import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/prefs/machine_preferences.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const folderChannel = MethodChannel('embyview/media_folder');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(
      folderChannel,
      (_) async => {'authorized': false},
    );
  });

  tearDown(() => messenger.setMockMethodCallHandler(folderChannel, null));

  group('C3.1 theme switching, auto day/night, and persistence', () {
    testWidgets('updates theme & EvIcon painting live and persists across reopen', (
      tester,
    ) async {
      final prefs = await MachinePreferences.open();
      var now = DateTime(2026, 11, 24, 10, 0);

      EvTheme? observedTheme;
      Widget buildHarness(EmbyViewPreferences p) => MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: EvThemeScope(
            preferences: p,
            clock: () => now,
            child: Builder(
              builder: (context) {
                observedTheme = EvTheme.of(context);
                return const Row(
                  children: [
                    EvIcon(EvIcons.navHome, key: Key('home_icon')),
                    EvIcon(EvIcons.play, key: Key('play_icon')),
                  ],
                );
              },
            ),
          ),
        ),
      );

      EvIconPainter painterFor(Key key) {
        final paint = tester.widget<CustomPaint>(
          find.descendant(of: find.byKey(key), matching: find.byType(CustomPaint)),
        );
        return paint.painter! as EvIconPainter;
      }

      await tester.pumpWidget(buildHarness(prefs));

      // Default cinema theme
      expect(observedTheme!.isPaper, isFalse);
      expect(observedTheme!.bg, EvTheme.cinema.bg);
      expect(observedTheme!.displayName, '影院');
      expect(painterFor(const Key('home_icon')).isPaper, isFalse);
      expect(painterFor(const Key('home_icon')).fillOpacity, closeTo(0.2, 1e-6));
      expect(painterFor(const Key('play_icon')).isSolid, isTrue);

      // Switch to paper via EmbyViewPreferences.update -> immediate update
      await prefs.update(const LocalPreferences(theme: ThemeMode.paper));
      await tester.pump();
      expect(observedTheme!.isPaper, isTrue);
      expect(observedTheme!.bg, EvTheme.paper.bg);
      expect(observedTheme!.displayName, '纸面');
      expect(painterFor(const Key('home_icon')).isPaper, isTrue);
      expect(painterFor(const Key('home_icon')).fillOpacity, closeTo(1.0, 1e-6));
      expect(painterFor(const Key('home_icon')).accentColor, EvTheme.paper.brand);
      expect(painterFor(const Key('play_icon')).isSolid, isTrue);

      // Switch to automatic at 10:00 -> paper
      await prefs.update(const LocalPreferences(theme: ThemeMode.automatic));
      await tester.pump();
      expect(observedTheme!.isPaper, isTrue);
      expect(painterFor(const Key('home_icon')).isPaper, isTrue);

      // Re-evaluate automatic at 22:00 -> cinema
      now = DateTime(2026, 11, 24, 22, 0);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: EvThemeScope(
              preferences: prefs,
              clock: () => now,
              child: Builder(
                builder: (context) {
                  observedTheme = EvTheme.of(context);
                  return const EvIcon(EvIcons.navHome, key: Key('home_icon'));
                },
              ),
            ),
          ),
        ),
      );
      expect(observedTheme!.isPaper, isFalse);
      expect(observedTheme!.bg, EvTheme.cinema.bg);
      expect(painterFor(const Key('home_icon')).isPaper, isFalse);

      // Persist paper, close and reopen preferences, rebuild fresh EvThemeScope
      await prefs.update(const LocalPreferences(theme: ThemeMode.paper));
      await prefs.close();

      final reopened = await MachinePreferences.open();
      expect(reopened.current.theme, ThemeMode.paper);
      await tester.pumpWidget(buildHarness(reopened));
      expect(observedTheme!.isPaper, isTrue);
      expect(observedTheme!.bg, EvTheme.paper.bg);
      expect(painterFor(const Key('home_icon')).isPaper, isTrue);

      await reopened.close();
    });

    testWidgets('automatic mode switches automatically across 19:00 boundary', (
      tester,
    ) async {
      var now = DateTime(2026, 11, 24, 18, 59, 59);
      EvTheme? observed;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: EvThemeScope(
            themeMode: ThemeMode.automatic,
            clock: () => now,
            child: Builder(
              builder: (context) {
                observed = EvTheme.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(observed!.isPaper, isTrue);

      now = DateTime(2026, 11, 24, 19, 0, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(observed!.isPaper, isFalse);
    });

    test('resolveIsPaper and resolveBrightness respect 07:00 and 19:00 bounds', () {
      expect(
        EvThemeScope.resolveIsPaper(ThemeMode.automatic, DateTime(2026, 1, 1, 6, 59)),
        isFalse,
      );
      expect(
        EvThemeScope.resolveIsPaper(ThemeMode.automatic, DateTime(2026, 1, 1, 7, 0)),
        isTrue,
      );
      expect(
        EvThemeScope.resolveIsPaper(ThemeMode.automatic, DateTime(2026, 1, 1, 18, 59)),
        isTrue,
      );
      expect(
        EvThemeScope.resolveIsPaper(ThemeMode.automatic, DateTime(2026, 1, 1, 19, 0)),
        isFalse,
      );
      expect(
        EvThemeScope.resolveBrightness(ThemeMode.paper, DateTime(2026, 1, 1, 23, 0)),
        Brightness.light,
      );
      expect(
        EvThemeScope.resolveBrightness(ThemeMode.cinema, DateTime(2026, 1, 1, 12, 0)),
        Brightness.dark,
      );
    });
  });

  group('C3.2 EvScale, EvOnImage, primitives, and full EvIcons rendering', () {
    test('EvScale matches proto.js formula at 1440x900 and 2560x1440', () {
      final s1440 = EvScale.fromSize(const Size(1440, 900));
      expect(s1440.remSize, 16.0);
      expect(s1440.factor, 1.0);
      expect(s1440.gutter, 72.0);
      expect(s1440.peek, 136.0);
      expect(s1440.vh(1), 9.0);
      expect(s1440.vh(100), 900.0);
      expect(s1440.vw(1), 14.4);
      expect(s1440.vw(100), 1440.0);
      expect(s1440.minFontSize, 13.0);
      expect(s1440.rem(2), 32.0);
      expect(s1440.px(24), 24.0);

      final s2560 = EvScale.fromSize(const Size(2560, 1440));
      expect(s2560.remSize, 20.0);
      expect(s2560.factor, 1.25);
      expect(s2560.gutter, 90.0);
      expect(s2560.peek, 170.0);
      expect(s2560.vh(1), 14.4);
      expect(s2560.vh(100), 1440.0);
      expect(s2560.vw(1), 25.6);
      expect(s2560.vw(100), 2560.0);
      expect(s2560.minFontSize, 16.25);
      expect(s2560.rem(2), 40.0);
      expect(s2560.px(24), 30.0);
    });

    test('EvTheme zone colors and EvCurves match proto.css', () {
      expect(EvTheme.cinema.zoneColors.length, 7);
      expect(EvTheme.paper.zoneColors.length, 7);
      expect(EvTheme.cinema.zoneColorByKey('anime'), const Color(0xFFFF8060));
      expect(EvTheme.paper.zoneColorByKey('anime'), const Color(0xFFD97757));
      expect(EvTheme.cinema.zoneColor(7), EvTheme.cinema.zoneColor(0));
      expect(EvCurves.out, const Cubic(0.16, 1.0, 0.3, 1.0));
      expect(EvCurves.spring, const Cubic(0.3, 1.35, 0.55, 1.0));
      expect(EvCurves.soft, const Cubic(0.4, 0.0, 0.2, 1.0));
    });

    testWidgets('EvOnImage switches paper subtree to light ink and dark glass', (
      tester,
    ) async {
      EvTheme? outerTheme;
      EvTheme? innerTheme;
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(1440, 900)),
            child: EvThemeScope(
              themeMode: ThemeMode.paper,
              child: Builder(
                builder: (context) {
                  outerTheme = EvTheme.of(context);
                  return EvOnImage(
                    child: Builder(
                      builder: (innerCtx) {
                        innerTheme = EvTheme.of(innerCtx);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            EvGlass(
                              padding: const EdgeInsets.all(8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const EvScoreBadge(score: 8.8),
                                  const EvQualityBadge(
                                    label: 'Dolby Vision',
                                    kind: EvQualityBadgeKind.dolbyVision,
                                  ),
                                  const EvQualityBadge(
                                    label: '115 直连',
                                    kind: EvQualityBadgeKind.source,
                                  ),
                                  const EvQualityBadge(label: '4K'),
                                ],
                              ),
                            ),
                            EvButton.primary(
                              icon: EvIcons.play,
                              label: '继续第 9 集',
                              secondaryLabel: '· 剩 9 分钟',
                              progress: 0.62,
                              onPressed: () => tapped = true,
                            ),
                            EvButton.ghost(
                              small: true,
                              round: true,
                              icon: EvIcons.plus,
                              onPressed: () {},
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(outerTheme!.isPaper, isTrue);
      expect(outerTheme!.onImage, isFalse);
      expect(outerTheme!.ink, const Color(0xFF141413));
      expect(outerTheme!.glass, const Color.fromRGBO(255, 255, 255, 0.84));

      expect(innerTheme!.isPaper, isTrue);
      expect(innerTheme!.onImage, isTrue);
      expect(innerTheme!.ink, const Color(0xFFF5F5F7));
      expect(innerTheme!.ink2, const Color.fromRGBO(245, 245, 247, 0.84));
      expect(innerTheme!.glass, const Color.fromRGBO(20, 20, 19, 0.40));
      expect(innerTheme!.glassSolid, const Color.fromRGBO(20, 20, 19, 0.86));
      expect(innerTheme!.glassBorder, const Color.fromRGBO(255, 255, 255, 0.16));
      expect(innerTheme!.blurSigma, 24);
      expect(innerTheme!.indBg, const Color(0xFFFAF9F5));
      expect(innerTheme!.indFg, const Color(0xFF141413));

      await tester.tap(find.text('继续第 9 集'));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('all EvIcons render cleanly in both cinema and paper modes', (
      tester,
    ) async {
      expect(EvIcons.zoneIcons.length, 20);
      for (final icon in EvIcons.all) {
        expect(EvIcons.byKey(icon.key).key, icon.key);
      }

      for (final mode in [ThemeMode.cinema, ThemeMode.paper]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: EvThemeScope(
              themeMode: mode,
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final icon in EvIcons.all)
                      EvIcon(icon, size: icon.viewBox),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('EvIcons contract aliases, evFormatCount, and EvButton keyboard activation work', (tester) async {
      expect(EvIcons.byKey('series').key, EvIcons.navTv.key);
      expect(EvIcons.byKey('tvshows').key, EvIcons.navTv.key);
      expect(EvIcons.byKey('movies').key, EvIcons.navMovie.key);
      expect(EvIcons.byKey('boxsets').key, EvIcons.navBox.key);
      expect(EvIcons.byKey('collections').key, EvIcons.navBox.key);
      expect(EvIcons.byKey('documentaries').key, EvIcons.navDoc.key);
      expect(evFormatCount(0), '0');
      expect(evFormatCount(1234567), '1,234,567');

      var hits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: EvThemeScope(
            themeMode: ThemeMode.cinema,
            child: Center(
              child: EvButton.primary(label: '播放', onPressed: () => hits++),
            ),
          ),
        ),
      );
      Focus.of(tester.element(find.text('播放'))).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(hits, 2);
    });
  });
}
