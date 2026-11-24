import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:server_emby/server_emby.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/auth_repository.dart';
import 'package:moonfin/auth/repositories/server_repository.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/auth/store/authentication_store.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/data/services/theme_music_service.dart';
import 'package:moonfin/data/offline/connectivity_aware_media_server_client.dart';
import 'package:moonfin/embyview/data/accounts.dart';
import 'package:moonfin/embyview/data/emby_media_data.dart';
import 'package:moonfin/embyview/playback/immersion.dart';
import 'package:moonfin/embyview/playback/moonfin_playback.dart';
import 'package:moonfin/playback/aether_backend.dart';

// The sample front end below compiles using this barrel alone for all models.
import 'package:moonfin/embyview/embyview.dart' as ev;
import 'package:moonfin/embyview/entry.dart';

class _Accounts implements ev.EmbyViewAccounts {
  _Accounts(this.snapshot);
  @override
  ev.AccountSnapshot snapshot;
  final controller = StreamController<ev.AccountSnapshot>.broadcast(sync: true);
  void emit(ev.AccountSnapshot value) {
    snapshot = value;
    controller.add(value);
  }

  @override
  Stream<ev.AccountSnapshot> get changes => controller.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preferences implements ev.EmbyViewPreferences {
  @override
  ev.LocalPreferences get current => const ev.LocalPreferences();
  @override
  Stream<ev.LocalPreferences> get changes => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Data implements ev.EmbyViewData {
  _Data(this.owner);
  final String owner;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playback implements ev.EmbyViewPlayback {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Immersion implements ev.ImmersionPlayback {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Subtitles implements ev.EmbyViewSubtitles {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RuntimeAuth implements AuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WrappedClient implements ConnectivityAwareMediaServerClient {
  _WrappedClient(this.onlineClient);
  @override
  final MediaServerClient onlineClient;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RuntimeAether implements AetherBackend {
  final events = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get nativeEvents => events.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RuntimeManager implements PlaybackManager {
  @override
  final state = PlayerState();
  final stopped = Completer<void>();
  final reported = Completer<void>();
  final drained = Completer<void>();
  int stops = 0;
  int drains = 0;
  @override
  Future<void> stop({bool userInitiated = true}) {
    stops++;
    return stopped.future;
  }

  @override
  Future<void> get lastStopReport => reported.future;
  @override
  Future<void> stopAndDrainReports() async {
    drains++;
    await stop(userInitiated: false);
    await reported.future;
    await drained.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RuntimeTheme implements ThemeMusicService {
  int stops = 0;
  @override
  void forceStop({
    Duration suppressionDuration = const Duration(milliseconds: 800),
  }) {
    stops++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RuntimeSessions implements SessionRepository {
  _RuntimeSessions(this.client);
  final MediaServerClient client;
  final events = StreamController<SessionState>.broadcast(sync: true);
  @override
  String? activeServerId = 'server';
  @override
  String? activeUserId = 'one';
  @override
  SessionState state = SessionState.ready;
  void emitState(SessionState value) {
    state = value;
    events.add(value);
  }

  @override
  Stream<SessionState> get stateStream => events.stream;
  @override
  Future<bool> switchCurrentSession({
    required String serverId,
    required String userId,
    String? username,
    String? password,
    bool validateToken = false,
  }) async {
    activeServerId = serverId;
    activeUserId = userId;
    client.userId = userId;
    emitState(SessionState.ready);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ev.AccountSnapshot _signedIn(String id) => ev.AccountSnapshot(
  phase: ev.AccountPhase.signedIn,
  current: ev.AccountProfile(id: id, displayName: id),
  sessionId: 'session-$id',
);

EmbyViewSessionServices _session(
  String id, {
  Future<void> Function()? dispose,
}) => EmbyViewSessionServices(
  data: _Data(id),
  playback: _Playback(),
  immersion: _Immersion(),
  dispose: dispose ?? () async {},
);

// Representative stage-three widget; no provider DTO or adapter imports needed.
class _PublicFrontend extends StatelessWidget {
  const _PublicFrontend(this.services);
  final ev.EmbyViewServices services;
  @override
  Widget build(BuildContext context) => Text(
    '${services.accounts.snapshot.current?.displayName} '
    '${services.subtitles == null ? 'subtitles unavailable' : 'subtitles ready'}',
    textDirection: TextDirection.ltr,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('only verified Mac Emby sessions enter the new route', () {
    for (final isMac in [true, false]) {
      for (final isEmby in [true, false]) {
        for (final authenticated in [true, false]) {
          final allowed = isMac && isEmby && authenticated;
          String? redirect(String path) => embyViewRouteRedirect(
            path: path,
            isMacOS: isMac,
            isEmby: isEmby,
            authenticated: authenticated,
            legacyHome: '/legacy',
            signedOut: '/login',
          );
          expect(redirect('/legacy'), allowed ? embyViewHomePath : null);
          expect(
            redirect('$embyViewHomePath/detail/1'),
            allowed
                ? null
                : authenticated
                ? '/legacy'
                : '/login',
          );
          expect(redirect('/search'), isNull);
          expect(redirect('/embyview-other'), isNull);
        }
      }
    }
  });

  test('stage one keeps the legacy home URL for its existing navigation and previews', () {
    String? redirect(String path) => embyViewRouteRedirect(
      path: path,
      isMacOS: true,
      isEmby: true,
      authenticated: true,
      legacyHome: '/home',
      signedOut: '/login',
      homeRegistered: false,
    );
    expect(redirect('/home'), isNull);
    expect(redirect(embyViewHomePath), '/home');
    expect(redirect('/search'), isNull);
  });

  testWidgets('missing stage three keeps the existing home usable', (
    tester,
  ) async {
    final registration = EmbyViewRegistration();
    final router = GoRouter(
      initialLocation: embyViewHomePath,
      routes: buildEmbyViewRoutes(
        registration: registration,
        legacyHome: (_) =>
            const Text('Legacy home', textDirection: TextDirection.ltr),
      ),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      WidgetsApp.router(color: const Color(0xff000000), routerConfig: router),
    );
    await tester.pumpAndSettle();
    expect(find.text('Legacy home'), findsOneWidget);
  });

  test(
    'switching clears old services and waits for stop before rebinding',
    () async {
      final accounts = _Accounts(_signedIn('a'));
      final preferences = _Preferences();
      final release = Completer<void>();
      final created = <String>[];
      final entry = EmbyViewEntry(
        preferences: preferences,
        accounts: accounts,
        createSession: (account) {
          final id = account.current!.id;
          created.add(id);
          return _session(id, dispose: id == 'a' ? () => release.future : null);
        },
      );
      await entry.ready;
      final oldData = entry.services.data;
      accounts.emit(const ev.AccountSnapshot(phase: ev.AccountPhase.switching));
      expect(entry.services.data, isNull);
      accounts.emit(_signedIn('b'));
      await pumpEventQueue();
      expect(created, ['a']);
      release.complete();
      await pumpEventQueue();
      expect(created, ['a', 'b']);
      expect(entry.services.data, isNot(same(oldData)));
      expect((entry.services.data as _Data).owner, 'b');
      expect(entry.services.preferences, same(preferences));
      expect(entry.services.subtitles, isNull);
      accounts.emit(const ev.AccountSnapshot(phase: ev.AccountPhase.signedOut));
      await pumpEventQueue();
      expect(entry.services.preferences, same(preferences));
      expect(entry.services.data, isNull);
      expect(entry.services.playback, isNull);
      expect(entry.services.immersion, isNull);
      expect(created, ['a', 'b']);
      await entry.close();
      entry.dispose();
      await accounts.controller.close();
    },
  );

  test(
    'late factories are disposed before a newer account is created',
    () async {
      final accounts = _Accounts(_signedIn('a'));
      final first = Completer<EmbyViewSessionServices>();
      final events = <String>[];
      final entry = EmbyViewEntry(
        preferences: _Preferences(),
        accounts: accounts,
        createSession: (account) {
          final id = account.current!.id;
          events.add('create $id');
          return id == 'a' ? first.future : _session(id);
        },
      );
      await pumpEventQueue();
      accounts.emit(_signedIn('b'));
      first.complete(
        _session(
          'a',
          dispose: () async {
            events.add('dispose a');
          },
        ),
      );
      await pumpEventQueue();
      expect(events, ['create a', 'dispose a', 'create b']);
      expect((entry.services.data as _Data).owner, 'b');
      await entry.close();
      entry.dispose();
      await accounts.controller.close();
    },
  );

  test('stage two registers independently through the public barrel', () async {
    final accounts = _Accounts(_signedIn('a'));
    final subtitles = _Subtitles();
    final registration = EmbyViewRegistration()
      ..stageTwoSubtitles = ((_) => subtitles)
      ..stageThreeHome = (context, services) => _PublicFrontend(services);
    final entry = EmbyViewEntry(
      preferences: _Preferences(),
      accounts: accounts,
      createSession: (account) => _session(account.current!.id),
      registration: registration,
    );
    await entry.ready;
    expect(entry.services.subtitles, same(subtitles));
    expect(_PublicFrontend(entry.services).services.data, isNotNull);
    accounts.emit(_signedIn('b'));
    await pumpEventQueue();
    expect(entry.services.sessionId, 'session-b');
    expect(entry.services.subtitles, same(subtitles));
    await entry.close();
    entry.dispose();
    await accounts.controller.close();
  });

  test('production composition waits for Stop and its report before switching the authenticated client', () async {
    final dependencies = GetIt.instance;
    SharedPreferences.setMockInitialValues({
      'embyview.machine.v1': '{"chooseUser":true,"preResolve115":false,"autoPlayNext":false,"readAheadBytes":1048576}',
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('moonfin/appletv_theme_music_events'),
      (_) async => null,
    );
    final store = AuthenticationStore();
    await store.init();
    final server = Server(
      id: 'server',
      name: 'Emby',
      address: 'https://emby.invalid',
      version: '4.10',
      serverType: ServerType.emby,
      dateAdded: DateTime(2026),
    );
    await store.putServer(server);
    for (final id in ['one', 'two']) {
      await store.putUser(
        PrivateUser(
          id: id,
          name: id,
          serverId: server.id,
          accessToken: 'test-token',
          lastUsed: DateTime(2026),
        ),
      );
    }
    final clients = MediaServerClientFactory(
      deviceInfo: const DeviceInfo(
        id: 'test',
        name: 'test',
        appName: 'EmbyView',
        appVersion: '1',
      ),
    );
    final client =
        EmbyMediaServerClient(
            baseUrl: server.address,
            deviceInfo: clients.deviceInfo,
            interceptors: [
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  final user = options.uri.path.contains('/two/')
                      ? 'two'
                      : 'one';
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: {
                        'Items': [
                          {
                            'Id': 'movie-$user',
                            'Name': 'Movies',
                            'CollectionType': 'movies',
                          },
                          {
                            'Id': 'series-$user',
                            'Name': 'Series',
                            'CollectionType': 'tvshows',
                          },
                        ],
                      },
                    ),
                  );
                },
              ),
            ],
          )
          ..userId = 'one'
          ..accessToken = 'test-token';
    final sessions = _RuntimeSessions(client);
    final manager = _RuntimeManager();
    final backend = _RuntimeAether();
    final theme = _RuntimeTheme();
    final servers = ServerRepository(store, clients);
    await servers.loadStoredServers();
    dependencies.registerSingleton<AuthenticationStore>(store);
    dependencies.registerSingleton<SessionRepository>(sessions);
    dependencies.registerSingleton<AuthRepository>(_RuntimeAuth());
    dependencies.registerSingleton<ServerRepository>(servers);
    dependencies.registerSingleton<MediaServerClientFactory>(clients);
    dependencies.registerSingleton<MediaServerClient>(_WrappedClient(client));
    dependencies.registerSingleton<PlaybackManager>(manager);
    dependencies.registerSingleton<AetherBackend>(backend);
    dependencies.registerSingleton<ThemeMusicService>(theme);
    final entry = await ensureMoonfinEmbyViewEntry();
    expect(entry.failure, isNull);
    expect(installedEmbyViewEntry, same(entry));
    expect(entry.services.data, isA<EmbyMediaData>());
    expect(entry.services.immersion, isA<MacImmersionPlayback>());
    expect(entry.services.accounts, isA<MoonfinEmbyViewAccounts>());
    expect(entry.services.accounts.snapshot.phase, ev.AccountPhase.signedIn);
    final playback = entry.services.playback as MoonfinPlaybackAdapter;
    expect(playback.prefetch115, isFalse);
    expect(playback.autoNext, isFalse);
    expect(playback.sessionCacheByteBudget, 1048576);
    final preferences = entry.services.preferences;
    await preferences.reorderZones(['series-one']);
    expect(preferences.current.zones.map((z) => z.id), [
      'series-one',
      'movie-one',
    ]);
    await preferences.update(
      const ev.LocalPreferences(
        preResolve115: false,
        autoPlayNext: false,
        readAheadBytes: 1048576,
      ),
    );
    await preferences.saveZone(
      const ev.ZonePreference(
        id: 'custom',
        name: 'Custom',
        iconKey: 'film',
        colorSlot: 0,
        rule: ev.ZoneRule.technology(ev.TechFilter.uhd4k),
      ),
    );
    expect(preferences.current.zones.map((z) => z.id), [
      'movie-one',
      'series-one',
      'custom',
    ]);
    final oldData = entry.services.data!;
    final switching = entry.services.accounts.switchTo('server/two');
    await pumpEventQueue();
    expect(entry.services.data, isNull);
    expect(manager.stops, 1);
    expect(manager.drains, 1);
    expect(client.userId, 'one');
    manager.stopped.complete();
    await pumpEventQueue();
    expect(client.userId, 'one');
    manager.reported.complete();
    await pumpEventQueue();
    expect(client.userId, 'one');
    manager.drained.complete();
    await switching;
    await pumpEventQueue();
    expect(client.userId, 'two');
    expect(entry.services.data, isNot(same(oldData)));
    await preferences.resetZones();
    expect(preferences.current.zones.map((z) => z.id), [
      'movie-two',
      'series-two',
    ]);
    final legacyData = entry.services.data!;
    final previousThemeStops = theme.stops;
    sessions.emitState(SessionState.switching);
    // The state event invalidates synchronously, before deferred drain completes.
    expect(entry.services.data, isNull);
    expect(theme.stops, greaterThan(previousThemeStops));
    await expectLater(
      legacyData.home(seriesSort: ev.ShelfSort.added),
      throwsA(isA<ev.EmbyViewFailure>()),
    );
    sessions.emitState(SessionState.ready);
    await pumpEventQueue();
    expect(entry.services.data, isNotNull);
    await expectLater(
      oldData.home(seriesSort: ev.ShelfSort.added),
      throwsA(isA<ev.EmbyViewFailure>()),
    );
    await dependencies.reset();
    expect(installedEmbyViewEntry, isNull);
    expect(backend.events.hasListener, isFalse);
    await sessions.events.close();
    await backend.events.close();
    manager.state.dispose();
    clients.disposeAll();
    client.dispose();
    messenger.setMockMethodCallHandler(
      const MethodChannel('moonfin/appletv_theme_music_events'),
      null,
    );
  });
}
