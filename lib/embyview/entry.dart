/// Composition and staged registration. UI imports only embyview.dart.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:server_emby/server_emby.dart';

import '../auth/repositories/auth_repository.dart';
import '../auth/repositories/server_repository.dart';
import '../auth/repositories/session_repository.dart';
import '../auth/store/authentication_store.dart';
import '../data/offline/connectivity_aware_media_server_client.dart';
import '../data/services/media_server_client_factory.dart';
import '../data/services/theme_music_service.dart';
import '../playback/aether_backend.dart';
import 'data/accounts.dart';
import 'data/emby_media_data.dart';
import 'embyview.dart';
import 'playback/immersion.dart';
import 'playback/moonfin_playback.dart';
import 'playback/native_playback.dart';
import 'prefs/machine_preferences.dart';

typedef EmbyViewSessionFactory = FutureOr<EmbyViewSessionServices> Function(
  AccountSnapshot account,
);
typedef EmbyViewSubtitlesFactory = EmbyViewSubtitles Function(
  EmbyViewServices services,
);
typedef EmbyViewHomeBuilder = Widget Function(
  BuildContext context,
  EmbyViewServices services,
);
typedef EmbyViewPlayerBuilder = Widget Function(
  BuildContext context,
  PlaybackSession session, {
  Rect? origin,
  CardArtwork? art,
});

/// Internal factories retain credentials; this object contains public services only.
class EmbyViewSessionServices {
  const EmbyViewSessionServices({
    required this.data,
    required this.playback,
    required this.immersion,
    required this.dispose,
    this.invalidate,
  });

  final EmbyViewData data;
  final EmbyViewPlayback playback;
  final ImmersionPlayback immersion;

  /// Revoke browsing and start stopping previews in the account event itself.
  final void Function()? invalidate;

  /// Cancel requests and await playback Stop reporting before completing.
  final Future<void> Function() dispose;
}

/// Each later stage owns one registration section, without modifying app_router.
class EmbyViewRegistration {
  // Stage two: subtitle capability. Leave null until the implementation exists.
  EmbyViewSubtitlesFactory? stageTwoSubtitles;

  // Stage three: shell, home, zones and walls.
  EmbyViewHomeBuilder? stageThreeHome;
  final List<RouteBase> stageThreeRoutes = [];

  // Stage four: detail, search, users, settings and command surfaces.
  final List<RouteBase> stageFourRoutes = [];

  // Stage five: controls around a session created by EvPlayer.open.
  EmbyViewPlayerBuilder? stageFivePlayer;
  final List<RouteBase> stageFiveRoutes = [];

  List<RouteBase> get routes => [
    ...stageThreeRoutes,
    ...stageFourRoutes,
    ...stageFiveRoutes,
  ];
}

final embyViewRegistration = EmbyViewRegistration();
final _installedEntry = ValueNotifier<EmbyViewEntry?>(null);
Future<EmbyViewEntry>? _productionInitialization;

EmbyViewEntry? get installedEmbyViewEntry => _installedEntry.value;

/// The application composition root installs this before first signed-in routing.
void installEmbyViewEntry(EmbyViewEntry? entry) {
  _installedEntry.value = entry;
  if (entry == null) _productionInitialization = null;
}

/// Called by the verified Mac/Emby route after Moonfin has authenticated.
/// Playback module registration precedes login, so the shared Aether backend
/// already exists; this does not create another engine or restore another login.
Future<EmbyViewEntry> ensureMoonfinEmbyViewEntry() async {
  final installed = installedEmbyViewEntry;
  if (installed != null) {
    await installed.ready;
    return installed;
  }
  return _productionInitialization ??= _createMoonfinEntry().catchError((
    Object error,
  ) {
    _productionInitialization = null;
    throw error;
  });
}

Future<EmbyViewEntry> _createMoonfinEntry() async {
  final dependencies = GetIt.instance;
  final sessions = dependencies<SessionRepository>();
  late final EmbyViewEntry entry;
  final preferences = await MachinePreferences.open(
    loadDefaultZones: () async {
      final data = entry.services.data;
      if (data is! EmbyMediaData) {
        throw const EmbyViewFailure('当前用户的片库尚未就绪，请稍后重试。', retryable: true);
      }
      return data.defaultZonePreferences();
    },
  );
  final accounts = MoonfinEmbyViewAccounts(
    store: dependencies<AuthenticationStore>(),
    sessions: sessions,
    auth: dependencies<AuthRepository>(),
    servers: dependencies<ServerRepository>(),
    clients: dependencies<MediaServerClientFactory>(),
    beforeSessionChange: () => entry.releaseCurrentSession(),
    chooseUserOnStartup: () => preferences.current.chooseUserOnStartup,
  );
  entry = EmbyViewEntry(
    preferences: preferences,
    accounts: accounts,
    createSession: (account) {
      final active = dependencies<MediaServerClient>();
      final client = active is ConnectivityAwareMediaServerClient
          ? active.onlineClient
          : active;
      final profileId =
          '${Uri.encodeComponent(sessions.activeServerId ?? '')}/${Uri.encodeComponent(sessions.activeUserId ?? '')}';
      if (client is! EmbyMediaServerClient ||
          client.userId != sessions.activeUserId ||
          client.accessToken?.isNotEmpty != true ||
          account.current?.id != profileId) {
        throw const EmbyViewFailure('Emby 用户已变更，请重新打开。', retryable: true);
      }
      final manager = dependencies<PlaybackManager>();
      final native = EmbyViewNativePlayback(dependencies<AetherBackend>());
      final data = EmbyMediaData(
        client: client,
        zonePreferences: () => preferences.current.zones,
      );
      final immersion = MacImmersionPlayback(
        preferences: preferences,
        legacyThemeMusic: dependencies.isRegistered<ThemeMusicService>()
            ? dependencies<ThemeMusicService>()
            : null,
        mainPlaybackChanges: manager.state.playingStream,
      );
      final settings = preferences.current;
      final playback = MoonfinPlaybackAdapter(
        manager: manager,
        client: client,
        native: native,
        data: data,
        beforeOpen: immersion.stop,
        prefetch115: settings.preResolve115,
        autoNext: settings.autoPlayNext,
        sessionCacheByteBudget: settings.readAheadBytes,
        anime4kForAnime: settings.anime4kForAnime,
        anime4kForOther: settings.anime4kForOther,
        anime4kDefaults: () => (
          anime: preferences.current.anime4kForAnime,
          other: preferences.current.anime4kForOther,
        ),
        isAnimeItem: data.isAnimePlaybackItem,
      );
      Future<void>? stoppingImmersion;
      return EmbyViewSessionServices(
        data: data,
        playback: playback,
        immersion: immersion,
        invalidate: () {
          data.dispose();
          stoppingImmersion ??= immersion.stop();
          // Observe errors immediately; dispose still awaits the original result.
          unawaited(stoppingImmersion!.catchError((_) {}));
        },
        dispose: () async {
          try {
            await playback.dispose();
            // The stage-one fallback page still opens the shared legacy player.
            await manager.stopAndDrainReports();
          } finally {
            try {
              await stoppingImmersion;
              await immersion.close();
            } finally {
              data.dispose();
              await native.dispose();
            }
          }
        },
      );
    },
  );
  // Legacy pages still change Moonfin sessions directly during stage one.
  // Their async state stream cannot make that producer await our drain. Revoke
  // data and start stopping previews as soon as its state event is delivered.
  final sessionChanges = sessions.stateStream.listen((state) {
    final phase = accounts.snapshot.phase;
    if (phase == AccountPhase.switching ||
        phase == AccountPhase.signingIn ||
        phase == AccountPhase.restoring) {
      return;
    }
    final current = accounts.snapshot.current;
    final expected =
        '${Uri.encodeComponent(sessions.activeServerId ?? '')}/${Uri.encodeComponent(sessions.activeUserId ?? '')}';
    if (state != SessionState.ready ||
        current?.id != expected ||
        entry.services.sessionId == null) {
      unawaited(
        entry
            .releaseCurrentSession()
            .then((_) async {
              if (sessions.state == SessionState.ready) {
                await accounts.restore();
              }
            })
            .catchError((_) {}),
      );
    }
  });
  dependencies.registerSingleton<EmbyViewEntry>(
    entry,
    dispose: (value) async {
      await sessionChanges.cancel();
      await value.close();
      await accounts.close();
      await preferences.close();
      if (identical(installedEmbyViewEntry, value)) installEmbyViewEntry(null);
      value.dispose();
    },
  );
  installEmbyViewEntry(entry);
  await entry.ready;
  return entry;
}

/// Replaces all user services at the account boundary; device services survive.
class EmbyViewEntry extends ChangeNotifier {
  EmbyViewEntry({
    required EmbyViewPreferences preferences,
    required EmbyViewAccounts accounts,
    required this.createSession,
    EmbyViewRegistration? registration,
  }) : _preferences = preferences,
       _accounts = accounts,
       registration = registration ?? embyViewRegistration {
    _services = EmbyViewServices(preferences: preferences, accounts: accounts);
    _subscription = accounts.changes.listen((account) {
      unawaited(_bind(account));
    });
    ready = _bind(accounts.snapshot);
  }

  final EmbyViewPreferences _preferences;
  final EmbyViewAccounts _accounts;
  final EmbyViewSessionFactory createSession;
  final EmbyViewRegistration registration;
  late final StreamSubscription<AccountSnapshot> _subscription;
  late final Future<void> ready;
  late EmbyViewServices _services;
  EmbyViewSessionServices? _session;
  EmbyViewFailure? _failure;
  Future<void> _release = Future.value();
  String? _bindingKey;
  int _revision = 0;
  bool _closed = false;
  Future<void>? _closeFuture;

  EmbyViewServices get services => _services;
  EmbyViewFailure? get failure => _failure;

  /// Accounts await this before the underlying authenticated client can change.
  /// Device preferences and accounts remain available while user services vanish.
  Future<void> releaseCurrentSession() {
    if (_closed) return _closeFuture ?? Future.value();
    _session?.invalidate?.call();
    ++_revision;
    _bindingKey = null;
    _services = EmbyViewServices(
      preferences: _preferences,
      accounts: _accounts,
    );
    notifyListeners();
    final released = _release.then((_) async {
      final old = _session;
      if (old != null) await old.dispose();
      _session = null;
    });
    _release = released.catchError((Object error) {
      _failure = error is EmbyViewFailure
          ? error
          : const EmbyViewFailure('无法结束旧用户的播放，请重试。', retryable: true);
      if (!_closed) notifyListeners();
    });
    return released;
  }

  Future<void> _bind(AccountSnapshot account) {
    if (_closed) return Future.value();
    final signedIn =
        account.phase == AccountPhase.signedIn &&
        account.current != null &&
        account.sessionId != null;
    final key = signedIn ? account.sessionId : null;
    if (key != null && key == _bindingKey) return _release;
    final revision = ++_revision;
    _bindingKey = key;
    _session?.invalidate?.call();
    _failure = null;
    _services = EmbyViewServices(
      preferences: _preferences,
      accounts: _accounts,
    );
    notifyListeners();
    // Serialize creation as well as teardown. A late factory must finish and
    // release its resources before a new account can own the playback manager.
    _release = _release.then((_) async {
      try {
        final old = _session;
        if (old != null) await old.dispose();
        _session = null;
        if (!signedIn || _closed || revision != _revision) return;
        final created = await createSession(account);
        if (_closed || revision != _revision) {
          await created.dispose();
          return;
        }
        final base = EmbyViewServices(
          preferences: _preferences,
          accounts: _accounts,
          sessionId: key,
          data: created.data,
          playback: created.playback,
          immersion: created.immersion,
        );
        try {
          final subtitles = registration.stageTwoSubtitles?.call(base);
          _session = created;
          _services = EmbyViewServices(
            preferences: _preferences,
            accounts: _accounts,
            sessionId: key,
            data: created.data,
            playback: created.playback,
            immersion: created.immersion,
            subtitles: subtitles,
          );
        } catch (_) {
          await created.dispose();
          rethrow;
        }
      } catch (error) {
        if (_closed || revision != _revision) return;
        _bindingKey = null;
        _failure = error is EmbyViewFailure
            ? error
            : const EmbyViewFailure(
                'Unable to open this account.',
                retryable: true,
              );
      }
      if (!_closed && revision == _revision) notifyListeners();
    });
    return _release;
  }

  /// Await this at application shutdown, before disposing account adapters.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    ++_revision;
    _session?.invalidate?.call();
    await _subscription.cancel();
    _bindingKey = null;
    _services = EmbyViewServices(
      preferences: _preferences,
      accounts: _accounts,
    );
    await _release;
    final old = _session;
    _session = null;
    if (old != null) await old.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

const embyViewHomePath = '/embyview';

bool isEmbyViewPath(String path) =>
    path == embyViewHomePath || path.startsWith('$embyViewHomePath/');

/// The caller supplies verified platform, server and authentication state.
String? embyViewRouteRedirect({
  required String path,
  required bool isMacOS,
  required bool isEmby,
  required bool authenticated,
  required String legacyHome,
  required String signedOut,
  bool homeRegistered = true,
}) {
  final allowed = isMacOS && isEmby && authenticated;
  if (isEmbyViewPath(path) && !allowed) {
    return authenticated ? legacyHome : signedOut;
  }
  if (path == embyViewHomePath && allowed && !homeRegistered) return legacyHome;
  if (path == legacyHome && allowed && homeRegistered) return embyViewHomePath;
  return null;
}

List<RouteBase> buildEmbyViewRoutes({
  required WidgetBuilder legacyHome,
  EmbyViewRegistration? registration,
}) {
  final routes = registration ?? embyViewRegistration;
  return [
    GoRoute(
      path: embyViewHomePath,
      builder: (context, state) =>
          _EmbyViewHome(legacyHome: legacyHome, registration: routes),
      routes: routes.routes,
    ),
  ];
}

class _EmbyViewHome extends StatelessWidget {
  const _EmbyViewHome({required this.legacyHome, required this.registration});

  final WidgetBuilder legacyHome;
  final EmbyViewRegistration registration;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EmbyViewEntry?>(
      valueListenable: _installedEntry,
      builder: (context, entry, _) {
        if (entry == null) return legacyHome(context);
        return ListenableBuilder(
          listenable: entry,
          builder: (context, _) {
            final services = entry.services;
            final home = registration.stageThreeHome;
            if (home == null || !services.signedIn) return legacyHome(context);
            return KeyedSubtree(
              key: ValueKey(services.sessionId),
              child: home(context, services),
            );
          },
        );
      },
    );
  }
}

/// Stage three calls this while stage five has not registered a player yet.
Widget buildEmbyViewPlayer(
  BuildContext context,
  PlaybackSession session, {
  Rect? origin,
  CardArtwork? art,
  EmbyViewRegistration? registration,
}) {
  final builder = (registration ?? embyViewRegistration).stageFivePlayer;
  return builder?.call(context, session, origin: origin, art: art) ??
      session.videoSurface();
}
