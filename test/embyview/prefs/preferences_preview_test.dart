import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/contracts/internal/authorized_resources.dart';
import 'package:moonfin/embyview/contracts/media.dart';
import 'package:moonfin/embyview/contracts/playback.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/prefs/machine_preferences.dart';
import 'package:moonfin/embyview/playback/immersion.dart';
import 'package:shared_preferences/shared_preferences.dart';

ZonePreference _zone(String id) => ZonePreference(
  id: id,
  name: id,
  iconKey: 'film',
  colorSlot: 0,
  rule: ZoneRule.genre(id),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('embyview/media_folder');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'authorized': false},
    );
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('translation addresses normalize default ports and reject incomplete or credential-bearing URLs', () {
    expect(parseTranslationBaseUrl(' HTTPS://API.OPENAI.COM:443/v1/// '), Uri.parse(defaultTranslationBaseUrl));
    for (final value in ['api.example', 'file:///tmp', 'http://', 'https://a:b@api.example/v1', 'https://api.example/v1?q=1',
      'https://api.example/#key', 'https://api.example:9999999999999999999999/v1', 'https://api.example/a b']) {
      expect(parseTranslationBaseUrl(value), isNull, reason: value);
    }
  });

  test('translation keys follow the saved origin, including the existing official key', () async {
    FlutterSecureStorage.setMockInitialValues({'embyview.secret.openAi': 'legacy-official'});
    final prefs = await MachinePreferences.open();
    final official = parseTranslationBaseUrl(defaultTranslationBaseUrl)!;
    final gateway = parseTranslationBaseUrl('https://gateway.example:8443/v1/')!;
    final alternate = parseTranslationBaseUrl('https://gateway.example:9443/v1')!;
    expect(await prefs.readTranslationKey(official), 'legacy-official');
    await prefs.update(LocalPreferences(translationBaseUrl: gateway.toString()));
    expect(await prefs.configuredSecrets(), isNot(contains(SecretKind.openAi)));
    expect(await prefs.readTranslationKey(gateway), isNull);
    await prefs.setSecret(SecretKind.openAi, 'gateway-test');
    expect(await prefs.readTranslationKey(gateway.replace(path: '/compatible/v1')), 'gateway-test');
    expect(await prefs.readTranslationKey(alternate), isNull);
    expect(await prefs.readTranslationKey(gateway.replace(scheme: 'http')), isNull);
    await prefs.update(const LocalPreferences());
    expect(await prefs.configuredSecrets(), contains(SecretKind.openAi));
    expect(await prefs.readTranslationKey(official), 'legacy-official');
    await prefs.close();
    final restored = await MachinePreferences.open();
    expect(await restored.readTranslationKey(gateway), 'gateway-test');
    await restored.close();
  });

  test('old preferences take the standard translation defaults and keep unrelated choices', () async {
    SharedPreferences.setMockInitialValues({'embyview.machine.v1': '{"theme":"paper","translationProvider":"gemini"}'});
    final prefs = await MachinePreferences.open();
    expect(prefs.current.theme, ThemeMode.paper);
    expect(prefs.current.translationBaseUrl, 'https://api.openai.com/v1');
    expect(prefs.current.translationModel, 'gpt-5.4-mini');
    expect(prefs.current.audioLanguages, isEmpty);
    expect(prefs.current.subtitleLanguages, ['zh', 'ja', 'en']);
    expect(prefs.current.subtitleAutoMode, SubtitleAutoMode.always);
    await prefs.close();
  });

  test('audio and subtitle preferences persist and migrate legacy autoChinese cleanly', () async {
    // Legacy autoChinese: false migrates to SubtitleAutoMode.off.
    SharedPreferences.setMockInitialValues({
      'embyview.machine.v1': '{"autoChinese":false,"subtitleLanguages":["zh-TW","jpn","eng","zh-hant"]}',
    });
    var prefs = await MachinePreferences.open();
    expect(prefs.current.audioLanguages, isEmpty);
    expect(prefs.current.subtitleAutoMode, SubtitleAutoMode.off);
    expect(prefs.current.subtitleLanguages, ['zh-hant', 'ja', 'en']);
    await prefs.close();

    // Legacy autoChinese: true migrates to SubtitleAutoMode.always.
    SharedPreferences.setMockInitialValues({'embyview.machine.v1': '{"autoChinese":true}'});
    prefs = await MachinePreferences.open();
    expect(prefs.current.subtitleAutoMode, SubtitleAutoMode.always);
    await prefs.close();

    // Explicit subtitleAutoMode wins over legacy autoChinese and survives round-trip.
    SharedPreferences.setMockInitialValues({
      'embyview.machine.v1': '{"autoChinese":false,"subtitleAutoMode":"foreignOnly","audioLanguages":["jpn","zh-CN","yue","ja"]}',
    });
    prefs = await MachinePreferences.open();
    expect(prefs.current.subtitleAutoMode, SubtitleAutoMode.foreignOnly);
    expect(prefs.current.audioLanguages, ['ja', 'zh', 'yue']);

    await prefs.update(
      prefs.current.copyWith(
        audioLanguages: const ['yue', 'zh'],
        subtitleLanguages: const ['zh', 'zh-hant', 'en'],
        subtitleAutoMode: SubtitleAutoMode.foreignOnly,
      ),
    );
    await prefs.close();

    final restored = await MachinePreferences.open();
    expect(restored.current.audioLanguages, ['yue', 'zh']);
    expect(restored.current.subtitleLanguages, ['zh', 'zh-hant', 'en']);
    expect(restored.current.subtitleAutoMode, SubtitleAutoMode.foreignOnly);
    await restored.close();

    // Corrupt language / enum fields fall back to defaults without losing unrelated choices.
    SharedPreferences.setMockInitialValues({
      'embyview.machine.v1': '{"theme":"paper","audioLanguages":"bad","subtitleLanguages":123,"subtitleAutoMode":"bogus"}',
    });
    final repaired = await MachinePreferences.open();
    expect(repaired.current.theme, ThemeMode.paper);
    expect(repaired.current.audioLanguages, isEmpty);
    expect(repaired.current.subtitleLanguages, ['zh', 'ja', 'en']);
    expect(repaired.current.subtitleAutoMode, SubtitleAutoMode.always);
    await repaired.close();
  });

  test('machine choices and zone order survive reopening', () async {
    final builtin = _zone('movies');
    final custom = _zone('genre');
    final prefs = await MachinePreferences.open(defaultZones: [builtin]);
    await prefs.update(
      LocalPreferences(
        theme: ThemeMode.paper,
        translationBaseUrl: 'https://gateway.example/custom/v1',
        translationModel: 'custom-model',
        chooseUserOnStartup: false,
        zones: [builtin],
      ),
    );
    await prefs.saveZone(custom);
    await prefs.reorderZones(['genre', 'movies']);
    final restored = await MachinePreferences.open(defaultZones: [builtin]);
    expect(restored.current.theme, ThemeMode.paper);
    expect(restored.current.chooseUserOnStartup, false);
    expect(restored.current.translationBaseUrl, 'https://gateway.example/custom/v1');
    expect(restored.current.translationModel, 'custom-model');
    expect(restored.current.zones.map((z) => z.id), ['genre', 'movies']);
    await prefs.close();
    await restored.close();
  });

  test(
    'first zone edits and reset use the visible libraries atomically',
    () async {
      final defaults = [_zone('movies'), _zone('series')];
      for (final saveFirst in [true, false]) {
        SharedPreferences.setMockInitialValues({});
        final prefs = await MachinePreferences.open(
          loadDefaultZones: () async => defaults,
        );
        final published = <LocalPreferences>[];
        final subscription = prefs.changes.listen(published.add);
        if (saveFirst) {
          await prefs.saveZone(_zone('custom'));
          expect(prefs.current.zones.map((z) => z.id), [
            'movies',
            'series',
            'custom',
          ]);
        } else {
          await prefs.reorderZones(['series']);
          expect(prefs.current.zones.map((z) => z.id), ['series', 'movies']);
        }
        expect(published.length, 1);
        await prefs.resetZones();
        expect(prefs.current.zones.map((z) => z.id), ['movies', 'series']);
        final restored = await MachinePreferences.open();
        expect(restored.current.zones.map((z) => z.id), ['movies', 'series']);
        await subscription.cancel();
        await prefs.close();
        await restored.close();
      }
    },
  );

  test(
    'failed default-library reads never commit an empty zone list',
    () async {
      final store = await SharedPreferences.getInstance();
      final prefs = await MachinePreferences.open(
        store: store,
        loadDefaultZones: () async => throw StateError('unreachable'),
      );
      final before = prefs.current;
      final published = <LocalPreferences>[];
      final subscription = prefs.changes.listen(published.add);
      for (final operation in [
        () => prefs.saveZone(_zone('custom')),
        () => prefs.reorderZones(['movies']),
        prefs.resetZones,
      ]) {
        await expectLater(operation(), throwsA(anything));
        expect(identical(prefs.current, before), true);
        expect(store.getKeys(), isEmpty);
      }
      expect(published, isEmpty);
      await subscription.cancel();
      await prefs.close();
    },
  );

  test('folder authorization keeps OS state and cancellation preserves the bookmark', () async {
    var state = <String, Object>{
      'authorized': true,
      'state': 'authorized',
      'path': '/Volumes/media',
      'embyRoot': '/mnt/media',
    };
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'authorize'
          ? {'authorized': false, 'cancelled': true}
          : state,
    );
    final prefs = await MachinePreferences.open();
    expect(prefs.current.mediaFolder.localRoot, '/Volumes/media');
    expect(await prefs.authorizeMediaFolder(embyRoot: '/mnt/media'), false);
    expect(prefs.current.mediaFolder.state, MediaFolderState.authorized);
    for (final status in [
      MediaFolderState.denied,
      MediaFolderState.unmounted,
    ]) {
      state = {
        'authorized': false,
        'state': status.name,
        'embyRoot': '/mnt/media',
        'path': '/Volumes/unavailable',
      };
      expect((await prefs.mediaFolderStatus()).state, status);
      expect(prefs.current.mediaFolder.localRoot, null);
    }
    await prefs.close();
  });

  test('authorized muted video and theme coexist, track actual time, and stop before handoff', () async {
    const preview = MethodChannel('moonfin/appletv_preview');
    const previewEvents = MethodChannel('moonfin/appletv_preview_events');
    const theme = MethodChannel('moonfin/appletv_theme_music');
    final calls = <(String, MethodCall)>[];
    for (final source in ['preview', 'preview_events', 'theme_music']) {
      messenger.setMockMethodCallHandler(
        MethodChannel('moonfin/appletv_$source'),
        (call) async {
          calls.add((source, call));
          return source == 'preview' && call.method == 'open'
              ? {'textureId': 12}
              : null;
        },
      );
    }
    final preferences = await MachinePreferences.open();
    final events = StreamController<Map>.broadcast(sync: true);
    final main = StreamController<bool>.broadcast(sync: true);
    final immersion = MacImmersionPlayback(
      preferences: preferences,
      themeEvents: events.stream,
      mainPlaybackChanges: main.stream,
    );
    final ref = AuthorizedPreviewRef(
      id: 'media',
      name: 'media',
      uri: Uri.parse('https://emby.test/preview'),
      headers: {'X-Emby-Token': 'test'},
    );
    await immersion.showMutedVideo(ref);
    await immersion.playTheme(ref);
    final videoOpen = calls
        .firstWhere((c) => c.$1 == 'preview' && c.$2.method == 'open')
        .$2;
    expect(videoOpen.arguments['volume'], 0);
    expect(videoOpen.arguments['headers'], {'X-Emby-Token': 'test'});
    final themeOpen = calls
        .firstWhere((c) => c.$1 == 'theme_music' && c.$2.method == 'open')
        .$2;
    expect(themeOpen.arguments['headers'], {'X-Emby-Token': 'test'});
    final token = themeOpen.arguments['token'];
    expect(immersion.snapshot.video, PreviewState.ready);
    expect(immersion.snapshot.theme, PreviewState.loading);
    events.add({
      'token': token,
      'state': 'ready',
      'positionMs': 2700,
      'durationMs': 90000,
      'muted': false,
    });
    expect(immersion.snapshot.theme, PreviewState.ready);
    expect(
      immersion.snapshot.themePosition,
      const Duration(milliseconds: 2700),
    );
    expect(immersion.snapshot.themeDuration, const Duration(seconds: 90));
    main.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(immersion.snapshot.video, PreviewState.idle);
    expect(immersion.snapshot.theme, PreviewState.idle);
    expect(
      calls.any((c) => c.$1 == 'preview' && c.$2.method == 'dispose'),
      true,
    );
    expect(
      calls.any((c) => c.$1 == 'theme_music' && c.$2.method == 'stop'),
      true,
    );
    await immersion.close();
    await preferences.close();
    await events.close();
    await main.close();
    for (final c in [preview, previewEvents, theme]) {
      messenger.setMockMethodCallHandler(c, null);
    }
  });
}
