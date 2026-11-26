import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';
import 'package:uuid/uuid.dart';

import '../../auth/models/login_state.dart';
import '../../auth/models/server.dart';
import '../../auth/models/user.dart';
import '../../auth/repositories/auth_repository.dart';
import '../../auth/repositories/server_repository.dart';
import '../../auth/repositories/session_repository.dart';
import '../../auth/store/authentication_store.dart';
import '../../auth/store/credential_store.dart';
import '../../data/services/connectivity_service.dart';
import '../../data/services/media_server_client_factory.dart';
import '../contracts/accounts.dart';
import '../contracts/common.dart';
import '../contracts/preferences.dart';
import 'diagnostics_exporter.dart';

/// Result of probing a single Emby server address.
class AddressProbeResult {
  const AddressProbeResult({
    required this.reachable,
    this.latencyMs,
    this.serverVersion,
  });

  final bool reachable;
  final int? latencyMs;
  final String? serverVersion;
}

typedef ServerAddressProbe = Future<AddressProbeResult> Function(
  Uri address,
  Duration timeout,
);

/// Keeps Moonfin's stored identities and authentication, with an awaited
/// boundary before any client or token can change, plus multi-address failover.
class MoonfinEmbyViewAccounts implements EmbyViewAccounts {
  MoonfinEmbyViewAccounts({
    required this.store,
    required this.sessions,
    required this.auth,
    required this.servers,
    required this.clients,
    required this.beforeSessionChange,
    required this.chooseUserOnStartup,
    this.preferences,
    this.credentials,
    this.autoSwitchServerAddress,
    ServerAddressProbe? probeAddress,
  }) : _probeAddress = probeAddress ?? _defaultProbeAddress {
    _lastServerId = sessions.activeServerId ?? _firstEmbyServer()?.id;
    _snapshot = _readCurrent();
    _connectivity?.addListener(_connectionChanged);
  }

  final AuthenticationStore store;
  final SessionRepository sessions;
  final AuthRepository auth;
  final ServerRepository servers;
  final MediaServerClientFactory clients;
  final EmbyViewPreferences? preferences;
  final CredentialStore? credentials;

  /// Release the old EmbyView scope, including Stop reporting and previews.
  final Future<void> Function() beforeSessionChange;
  final bool Function() chooseUserOnStartup;
  final bool Function()? autoSwitchServerAddress;
  final ServerAddressProbe _probeAddress;
  final _connectivity = GetIt.instance.isRegistered<ConnectivityService>()
      ? GetIt.instance<ConnectivityService>()
      : null;

  final _changes = StreamController<AccountSnapshot>.broadcast(sync: true);
  late final StreamController<ConnectionNoticeEvent> _connectionNotices =
      StreamController<ConnectionNoticeEvent>.broadcast(
        sync: true,
        onListen: _flushPendingColdStartNotice,
      );
  ConnectionNoticeEvent? _pendingColdStartNotice;
  final Map<String, List<ServerAddressEntry>> _localAddressesByServer = {};

  Future<void> _pending = Future.value();
  Future<Uri?>? _inFlightProbe;
  late AccountSnapshot _snapshot;
  String? _lastServerId;
  ConnectionState? _connectionOverride;
  int? _latencyMs;
  int _triedAddressCount = 0;

  @override
  AccountSnapshot get snapshot => _snapshot;

  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

  @override
  Stream<ConnectionNoticeEvent> get connectionNotices =>
      _connectionNotices.stream;

  bool get _autoSwitchEnabled =>
      autoSwitchServerAddress?.call() ??
      preferences?.current.autoSwitchServerAddress ??
      true;

  String _profileId(PrivateUser user) =>
      '${Uri.encodeComponent(user.serverId)}/${Uri.encodeComponent(user.id)}';

  List<PrivateUser> get _users => [
    for (final server in store.getServers())
      if (server.serverType == ServerType.emby) ...store.getUsers(server.id),
  ];

  Server? _firstEmbyServer() {
    for (final server in store.getServers()) {
      if (server.serverType == ServerType.emby) return server;
    }
    return null;
  }

  Server? _resolveServer({String? preferredServerId}) {
    final activeId = sessions.activeServerId;
    if (activeId != null && activeId.isNotEmpty) {
      final server = store.getServer(activeId);
      if (server != null && server.serverType == ServerType.emby) {
        _lastServerId = server.id;
        return server;
      }
    }
    final preferred = preferredServerId ?? _lastServerId;
    if (preferred != null && preferred.isNotEmpty) {
      final server = store.getServer(preferred);
      if (server != null && server.serverType == ServerType.emby) {
        return server;
      }
    }
    return _firstEmbyServer();
  }

  List<ServerAddressEntry> _addressesForServer(Server? server) {
    if (server == null) return const [];
    final fromPrefs = preferences?.current.serverAddresses[server.id];
    if (fromPrefs != null && fromPrefs.isNotEmpty) {
      return List.unmodifiable(fromPrefs);
    }
    final fromLocal = _localAddressesByServer[server.id];
    if (fromLocal != null && fromLocal.isNotEmpty) {
      return List.unmodifiable(fromLocal);
    }
    final raw = server.address.trim();
    if (raw.isEmpty) return const [];
    final migrated = ServerAddressEntry(
      id: 'primary',
      url: raw,
      label: inferServerAddressLabel(raw),
      subtitle: inferServerAddressSubtitle(raw),
    );
    return List.unmodifiable([migrated]);
  }

  ServerAddressEntry? _activeEntryForServer(
    Server? server,
    List<ServerAddressEntry> addresses,
  ) {
    if (server == null || addresses.isEmpty) return null;
    final currentKey = _urlKey(server.address);
    for (final entry in addresses) {
      if (_urlKey(entry.url) == currentKey) return entry;
    }
    return addresses.first;
  }

  String _urlKey(String raw) =>
      parseEmbyServerAddress(raw)?.toString().toLowerCase() ??
      raw.trim().replaceFirst(RegExp(r'/+$'), '').toLowerCase();

  String _addressLabel(ServerAddressEntry entry) =>
      entry.label.trim().isNotEmpty
          ? entry.label.trim()
          : inferServerAddressLabel(entry.url);

  AccountProfile _profile(PrivateUser user) => AccountProfile(
    id: _profileId(user),
    displayName: user.name,
    serverId: user.serverId,
    lastUsedAt: user.lastUsed,
  );

  AccountSnapshot _readCurrent({
    AccountPhase? phase,
    EmbyViewFailure? failure,
    String? sessionId,
    String? preferredServerId,
    bool allowFallbackServer = true,
  }) {
    final activeServer = store.getServer(sessions.activeServerId ?? '');
    final user = activeServer?.serverType == ServerType.emby
        ? store.getUser(activeServer!.id, sessions.activeUserId ?? '')
        : null;
    final server = activeServer?.serverType == ServerType.emby
        ? activeServer
        : (allowFallbackServer
              ? _resolveServer(preferredServerId: preferredServerId)
              : null);
    final addresses = _addressesForServer(server);
    final activeAddress = _activeEntryForServer(server, addresses);
    final connection = _connectionOverride ??
        (user == null || _connectivity == null
            ? ConnectionState.unknown
            : _connectivity.canReachServer
            ? ConnectionState.connected
            : ConnectionState.disconnected);

    return AccountSnapshot(
      phase:
          phase ??
          (user != null
              ? AccountPhase.signedIn
              : _users.isEmpty && server == null
              ? AccountPhase.signedOut
              : _users.isEmpty
              ? AccountPhase.signedOut
              : AccountPhase.choosing),
      current: user == null ? null : _profile(user),
      profiles: List.unmodifiable(_users.map(_profile)),
      serverName: server?.name.isNotEmpty == true ? server!.name : null,
      serverAddress:
          activeAddress?.url ?? server?.displayAddress ?? server?.address,
      activeAddress: activeAddress,
      addresses: addresses,
      serverVersion: server?.version.isNotEmpty == true ? server!.version : null,
      latencyMs: _latencyMs,
      triedAddressCount: _triedAddressCount,
      connection: connection,
      sessionId:
          user == null || (phase != null && phase != AccountPhase.signedIn)
          ? null
          : sessionId ?? const Uuid().v4(),
      failure: failure,
    );
  }

  void _connectionChanged() {
    if (_snapshot.phase != AccountPhase.signedIn) return;
    final reachable = _connectivity?.canReachServer ?? true;
    if (!reachable) {
      _connectionOverride = null;
      EvDiagnosticsLog.instance.record(
        'connection',
        'connectivity_lost',
        level: 'WARN',
        details: {'autoSwitch': _autoSwitchEnabled},
      );
      final account = _readCurrent(
        failure: _snapshot.failure,
        sessionId: _snapshot.sessionId,
      );
      if (account.current?.id == _snapshot.current?.id) _publish(account);
      if (_autoSwitchEnabled && account.addresses.length > 1) {
        unawaited(probeAndFailover());
      }
      return;
    }
    _connectionOverride = ConnectionState.connected;
    EvDiagnosticsLog.instance.record('connection', 'connectivity_restored');
    final account = _readCurrent(
      failure: _snapshot.failure,
      sessionId: _snapshot.sessionId,
    );
    if (account.current?.id == _snapshot.current?.id) _publish(account);
  }

  void _publish(AccountSnapshot value) {
    _snapshot = value;
    if (!_changes.isClosed) _changes.add(value);
  }

  void _emitNotice(ConnectionNoticeEvent event, {bool replayIfUnobserved = false}) {
    if (_connectionNotices.isClosed) return;
    if (_connectionNotices.hasListener) {
      _pendingColdStartNotice = null;
      _connectionNotices.add(event);
    } else if (replayIfUnobserved) {
      _pendingColdStartNotice = event;
    }
  }

  void _flushPendingColdStartNotice() {
    final pending = _pendingColdStartNotice;
    if (pending == null || _connectionNotices.isClosed) return;
    _pendingColdStartNotice = null;
    scheduleMicrotask(() {
      if (!_connectionNotices.isClosed && _connectionNotices.hasListener) {
        _connectionNotices.add(pending);
      }
    });
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.catchError((_) {});
    return result;
  }

  Future<void> _syncServerCandidateAddresses(
    String serverId,
    List<ServerAddressEntry> entries,
  ) async {
    final server = servers.getServer(serverId) ?? store.getServer(serverId);
    if (server == null) return;
    final urls = List<String>.unmodifiable(
      entries.map((e) => e.url).where((u) => u.isNotEmpty),
    );
    if (listEquals(server.candidateAddresses, urls)) return;
    final updated = server.copyWith(candidateAddresses: urls);
    await servers.updateServer(updated);
    if (!listEquals(store.getServer(serverId)?.candidateAddresses, urls)) {
      await store.putServer(updated);
    }
  }

  Future<void> _syncAllStoredCandidateAddresses() async {
    final configured = preferences?.current.serverAddresses;
    if (configured == null || configured.isEmpty) return;
    for (final entry in configured.entries) {
      if (entry.value.isNotEmpty) {
        await _syncServerCandidateAddresses(entry.key, entry.value);
      }
    }
  }

  Future<void> _persistAddresses(
    String serverId,
    List<ServerAddressEntry> entries,
  ) async {
    final immutable = List<ServerAddressEntry>.unmodifiable(entries);
    if (immutable.isEmpty) {
      _localAddressesByServer.remove(serverId);
    } else {
      _localAddressesByServer[serverId] = immutable;
    }
    final prefs = preferences;
    if (prefs != null) {
      final map = Map<String, List<ServerAddressEntry>>.from(
        prefs.current.serverAddresses,
      );
      if (immutable.isEmpty) {
        map.remove(serverId);
      } else {
        map[serverId] = immutable;
      }
      await prefs.update(
        prefs.current.copyWith(serverAddresses: Map.unmodifiable(map)),
      );
    }
    if (immutable.isNotEmpty) {
      await _syncServerCandidateAddresses(serverId, immutable);
    }
  }

  Future<void> _applyServerActiveAddress(
    Server server,
    String nextUrl, {
    String? serverVersion,
  }) async {
    final updated = server.copyWith(
      address: nextUrl,
      clearDisplayAddress: true,
      version: serverVersion != null && serverVersion.isNotEmpty
          ? serverVersion
          : server.version,
      dateLastAccessed: DateTime.now(),
    );
    await servers.updateServer(updated);
    if (store.getServer(server.id)?.address != updated.address) {
      await store.putServer(updated);
    }
    final client = clients.getClientIfExists(server.id);
    if (client != null) {
      client.baseUrl = nextUrl;
    }
  }

  Future<void> _transition(
    AccountPhase phase,
    Future<void> Function() operation, {
    AccountPhase? postPhase,
    String? preferredServerId,
    bool allowFallbackServer = true,
  }) async {
    final old = store.getUser(
      sessions.activeServerId ?? '',
      sessions.activeUserId ?? '',
    );
    _publish(
      _readCurrent(
        phase: phase,
        preferredServerId: preferredServerId,
        allowFallbackServer: allowFallbackServer,
      ),
    );
    var released = false;
    try {
      await beforeSessionChange();
      released = true;
      await operation();
      _publish(
        _readCurrent(
          phase: postPhase,
          preferredServerId: preferredServerId,
          allowFallbackServer: allowFallbackServer,
        ),
      );
    } catch (error) {
      final failure = error is EmbyViewFailure
          ? error
          : const EmbyViewFailure('无法切换用户，请检查连接后重试。', retryable: true);
      var recovered = !released;
      if (released &&
          old != null &&
          store.getUser(old.serverId, old.id) != null) {
        try {
          await _activate(old);
          recovered = true;
        } catch (_) {
          recovered = false;
        }
      }
      if (recovered) {
        // A fresh identity rebuilds the disposed services even for the same user.
        _publish(_readCurrent(failure: failure));
      } else {
        _publish(
          _readCurrent(
            phase: _users.isEmpty
                ? AccountPhase.signedOut
                : AccountPhase.choosing,
            failure: failure,
            preferredServerId: preferredServerId,
          ),
        );
      }
      throw failure;
    }
  }

  Future<ConnectionNoticeEvent?> _failoverOnRestoreIfNeeded({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_autoSwitchEnabled) return null;
    final server = _resolveServer();
    if (server == null) return null;
    final addresses = _addressesForServer(server);
    if (addresses.length < 2) return null;
    final currentEntry = _activeEntryForServer(server, addresses)!;
    final candidates = <ServerAddressEntry>[
      currentEntry,
      ...addresses.where((e) => e.id != currentEntry.id),
    ];
    var tried = 0;
    for (final candidate in candidates) {
      final uri = parseEmbyServerAddress(candidate.url);
      tried++;
      if (uri == null) continue;
      AddressProbeResult result;
      try {
        result = await _probeAddress(uri, timeout);
      } catch (_) {
        result = const AddressProbeResult(reachable: false);
      }
      if (!result.reachable) continue;
      final switched = _urlKey(candidate.url) != _urlKey(currentEntry.url);
      if (switched) {
        await _applyServerActiveAddress(
          server,
          uri.toString(),
          serverVersion: result.serverVersion,
        );
      }
      _connectionOverride = ConnectionState.connected;
      _latencyMs = result.latencyMs;
      _triedAddressCount = tried;
      if (!switched) {
        EvDiagnosticsLog.instance.record(
          'connection',
          'restore_probe_ok',
          details: {'label': _addressLabel(candidate), 'latencyMs': result.latencyMs},
        );
        return null;
      }
      EvDiagnosticsLog.instance.record(
        'connection',
        'restore_failover_switched',
        details: {
          'from': _addressLabel(currentEntry),
          'to': _addressLabel(candidate),
          'tried': tried,
          'latencyMs': result.latencyMs,
        },
      );
      return ConnectionNoticeEvent.switched(
        serverName: server.name,
        fromLabel: _addressLabel(currentEntry),
        toLabel: _addressLabel(candidate),
        activeAddress: uri.toString(),
        triedAddressCount: tried,
      );
    }
    _connectionOverride = ConnectionState.disconnected;
    _latencyMs = null;
    _triedAddressCount = tried;
    EvDiagnosticsLog.instance.record(
      'connection',
      'restore_probe_disconnected',
      level: 'WARN',
      details: {'tried': tried},
    );
    return null;
  }

  @override
  Future<void> restore() => _serialize(() async {
    await servers.loadStoredServers();
    _lastServerId ??= _firstEmbyServer()?.id;
    await _syncAllStoredCandidateAddresses();
    if (sessions.activeUserId != null) {
      final switched = await _failoverOnRestoreIfNeeded();
      final snap = _readCurrent();
      _publish(snap);
      EvDiagnosticsLog.instance.record(
        'connection',
        'restore',
        details: {
          'phase': snap.phase.name,
          'addresses': snap.addresses.length,
          'switched': switched != null,
        },
      );
      if (switched != null) {
        _emitNotice(switched, replayIfUnobserved: true);
      }
      return;
    }
    if (chooseUserOnStartup() || _users.isEmpty) {
      final snap = _readCurrent();
      _publish(snap);
      EvDiagnosticsLog.instance.record(
        'connection',
        'restore',
        details: {'phase': snap.phase.name, 'profiles': snap.profiles.length},
      );
      return;
    }
    ConnectionNoticeEvent? switched;
    await _transition(AccountPhase.restoring, () async {
      switched = await _failoverOnRestoreIfNeeded();
      if (!await sessions.restoreSession()) {
        EvDiagnosticsLog.instance.record(
          'connection',
          'restore_failed',
          level: 'WARN',
        );
        throw const EmbyViewFailure('请选择用户重新登录。', code: 'restore_failed');
      }
    });
    EvDiagnosticsLog.instance.record(
      'connection',
      'restore_ok',
      details: {'switched': switched != null},
    );
    if (switched != null) {
      _emitNotice(switched!, replayIfUnobserved: true);
    }
  });

  @override
  Future<void> signIn(
    Uri server,
    String username,
    String password,
  ) => _serialize(
    () => _transition(AccountPhase.signingIn, () async {
      if (!['https', 'http'].contains(server.scheme) || server.host.isEmpty) {
        throw const EmbyViewFailure('请填写有效的 Emby 服务器地址。');
      }
      final saved = await servers.addServer(server.toString());
      if (saved == null || saved.serverType != ServerType.emby) {
        throw const EmbyViewFailure('无法连接 Emby 服务器，请检查地址。', retryable: true);
      }
      _lastServerId = saved.id;
      final existing = _addressesForServer(saved);
      if (existing.isEmpty) {
        await _persistAddresses(saved.id, [
          ServerAddressEntry(
            id: 'primary',
            url: saved.address,
            label: inferServerAddressLabel(saved.address),
            subtitle: inferServerAddressSubtitle(saved.address),
          ),
        ]);
      }
      await _activate(await _authenticate(saved, username, password), password);
      EvDiagnosticsLog.instance.record(
        'connection',
        'sign_in_ok',
        details: {
          'scheme': server.scheme,
          'label': inferServerAddressLabel(saved.address),
        },
      );
    }),
  );

  @override
  Future<void> switchTo(String profileId, {String? password}) => _serialize(
    () => _transition(AccountPhase.switching, () async {
      var user = _users
          .where((u) => _profileId(u) == profileId || u.id == profileId)
          .firstOrNull;
      if (user == null) throw const EmbyViewFailure('该用户已不在本机，请重新登录。');
      if (password != null) {
        user = await _authenticate(
          store.getServer(user.serverId)!,
          user.name,
          password,
        );
      }
      await _activate(user, password);
      EvDiagnosticsLog.instance.record('connection', 'switch_user_ok');
    }),
  );

  Future<PrivateUser> _authenticate(
    Server server,
    String username,
    String password,
  ) async {
    final state = await auth.authenticate(
      client: clients.getClient(
        serverId: server.id,
        serverType: server.serverType,
        baseUrl: server.address,
      ),
      serverId: server.id,
      username: username,
      password: password,
    );
    final user = state is Authenticated
        ? store.getUser(state.serverId, state.userId)
        : null;
    if (user == null) {
      EvDiagnosticsLog.instance.record(
        'connection',
        'sign_in_failed',
        level: 'WARN',
        details: {'code': 'sign_in_failed'},
      );
      throw const EmbyViewFailure(
        '登录失败，请检查用户名、密码和服务器权限。',
        code: 'sign_in_failed',
      );
    }
    return user;
  }

  Future<void> _activate(PrivateUser user, [String? password]) async {
    if (!await sessions.switchCurrentSession(
      serverId: user.serverId,
      userId: user.id,
      username: user.name,
      password: password,
      validateToken: true,
    )) {
      throw const EmbyViewFailure('无法切换用户，请重新登录。', retryable: true);
    }
    _lastServerId = user.serverId;
  }

  @override
  Future<void> signOut() => _serialize(() async {
    final serverId = sessions.activeServerId ?? _lastServerId ?? _firstEmbyServer()?.id;
    _lastServerId = serverId;
    final postPhase = serverId != null && store.getServer(serverId) != null
        ? AccountPhase.choosing
        : AccountPhase.signedOut;
    await _transition(
      AccountPhase.switching,
      () => sessions.destroyCurrentSession(),
      postPhase: postPhase,
      preferredServerId: serverId,
    );
    EvDiagnosticsLog.instance.record(
      'connection',
      'sign_out',
      details: {'postPhase': postPhase.name},
    );
  });

  /// Removes only this Mac's locally stored account record and token.
  /// Never calls any Emby server user-deletion API.
  @override
  Future<void> removeLocalAccount(String profileId) => _serialize(() async {
    final user = _users
        .where((u) => _profileId(u) == profileId || u.id == profileId)
        .firstOrNull;
    if (user == null) return;
    final serverId = user.serverId;
    _lastServerId ??= serverId;
    final isCurrent =
        sessions.activeServerId == serverId && sessions.activeUserId == user.id;

    if (isCurrent) {
      await _transition(
        AccountPhase.switching,
        () async {
          await sessions.destroyCurrentSession();
          await store.removeUser(serverId, user.id);
          if (store.getUsers(serverId).isEmpty) {
            await credentials?.deleteToken(serverId);
          }
        },
        postPhase: store.getServer(serverId) != null
            ? AccountPhase.choosing
            : AccountPhase.signedOut,
        preferredServerId: serverId,
      );
      return;
    }

    await store.removeUser(serverId, user.id);
    if (store.getUsers(serverId).isEmpty) {
      await credentials?.deleteToken(serverId);
    }
    _publish(
      _readCurrent(
        phase: _snapshot.phase,
        sessionId: _snapshot.sessionId,
        preferredServerId: serverId,
      ),
    );
  });

  /// Removes only this Mac's locally stored server configuration, address list,
  /// and all associated local accounts/tokens. Never deletes server users.
  @override
  Future<void> removeCurrentServer() => _serialize(() async {
    final server = _resolveServer();
    if (server == null) {
      _lastServerId = null;
      _connectionOverride = null;
      _latencyMs = null;
      _triedAddressCount = 0;
      _publish(
        _readCurrent(
          phase: AccountPhase.signedOut,
          allowFallbackServer: false,
        ),
      );
      return;
    }

    final serverId = server.id;
    final isActiveServer = sessions.activeServerId == serverId;

    if (isActiveServer) {
      _publish(
        _readCurrent(phase: AccountPhase.switching, preferredServerId: serverId),
      );
      await beforeSessionChange();
      await sessions.destroyCurrentSession();
    }

    for (final user in [...store.getUsers(serverId)]) {
      await store.removeUser(serverId, user.id);
    }
    await credentials?.deleteToken(serverId);
    await servers.deleteServer(serverId);
    if (store.getServer(serverId) != null) {
      await store.removeServer(serverId);
    }
    await _persistAddresses(serverId, const []);

    _lastServerId = null;
    _connectionOverride = null;
    _latencyMs = null;
    _triedAddressCount = 0;
    _publish(
      _readCurrent(
        phase: AccountPhase.signedOut,
        allowFallbackServer: false,
      ),
    );
  });

  @override
  Future<Uri?> probeAndFailover({
    Duration timeout = const Duration(seconds: 5),
  }) {
    final existing = _inFlightProbe;
    if (existing != null) return existing;
    final future = _probeAndFailoverImpl(timeout: timeout);
    _inFlightProbe = future;
    future.whenComplete(() {
      if (identical(_inFlightProbe, future)) _inFlightProbe = null;
    });
    return future;
  }

  Future<Uri?> _probeAndFailoverImpl({required Duration timeout}) async {
    final server = _resolveServer();
    if (server == null) return null;
    final addresses = _addressesForServer(server);
    if (addresses.isEmpty) return null;

    final currentEntry = _activeEntryForServer(server, addresses)!;
    final candidates = <ServerAddressEntry>[
      currentEntry,
      if (_autoSwitchEnabled)
        ...addresses.where((e) => e.id != currentEntry.id),
    ];

    final wasOffline = _snapshot.connection == ConnectionState.disconnected;
    var tried = 0;

    for (final candidate in candidates) {
      final uri = parseEmbyServerAddress(candidate.url);
      tried++;
      if (uri == null) continue;
      AddressProbeResult result;
      try {
        result = await _probeAddress(uri, timeout);
      } catch (_) {
        result = const AddressProbeResult(reachable: false);
      }
      if (!result.reachable) continue;

      final switched = _urlKey(candidate.url) != _urlKey(currentEntry.url);
      if (switched) {
        await _applyServerActiveAddress(
          server,
          uri.toString(),
          serverVersion: result.serverVersion,
        );
      }
      _connectionOverride = ConnectionState.connected;
      _latencyMs = result.latencyMs;
      _triedAddressCount = tried;

      _publish(
        _readCurrent(
          phase: _snapshot.phase,
          sessionId: _snapshot.sessionId,
          preferredServerId: server.id,
        ),
      );

      if (switched) {
        EvDiagnosticsLog.instance.record(
          'connection',
          'failover_switched',
          details: {
            'from': _addressLabel(currentEntry),
            'to': _addressLabel(candidate),
            'tried': tried,
            'latencyMs': result.latencyMs,
          },
        );
        _emitNotice(
          ConnectionNoticeEvent.switched(
            serverName: server.name,
            fromLabel: _addressLabel(currentEntry),
            toLabel: _addressLabel(candidate),
            activeAddress: uri.toString(),
            triedAddressCount: tried,
          ),
        );
      } else if (wasOffline) {
        EvDiagnosticsLog.instance.record(
          'connection',
          'recovered',
          details: {
            'label': _addressLabel(candidate),
            'tried': tried,
            'latencyMs': result.latencyMs,
          },
        );
        _emitNotice(
          ConnectionNoticeEvent.recovered(
            serverName: server.name,
            toLabel: _addressLabel(candidate),
            activeAddress: uri.toString(),
          ),
        );
      } else {
        EvDiagnosticsLog.instance.record(
          'connection',
          'probe_ok',
          details: {
            'label': _addressLabel(candidate),
            'latencyMs': result.latencyMs,
          },
        );
      }
      return uri;
    }

    _connectionOverride = ConnectionState.disconnected;
    _latencyMs = null;
    _triedAddressCount = tried;
    EvDiagnosticsLog.instance.record(
      'connection',
      'disconnected',
      level: 'WARN',
      details: {'tried': tried},
    );
    _publish(
      _readCurrent(
        phase: _snapshot.phase,
        sessionId: _snapshot.sessionId,
        preferredServerId: server.id,
      ),
    );
    _emitNotice(
      ConnectionNoticeEvent.offline(
        serverName: server.name,
        triedAddressCount: tried,
      ),
    );
    return null;
  }

  @override
  Future<void> retryConnection() async {
    await probeAndFailover();
  }

  @override
  Future<void> setServerAddresses(List<ServerAddressEntry> entries) =>
      _serialize(() async {
        final server = _resolveServer();
        if (server == null) {
          throw const EmbyViewFailure('尚未配置 Emby 服务器。');
        }
        if (entries.isEmpty) {
          throw const EmbyViewFailure('至少保留一条服务器地址。');
        }
        final normalized = <ServerAddressEntry>[];
        final seenUrls = <String>{};
        for (final entry in entries) {
          final uri = parseEmbyServerAddress(entry.url);
          if (uri == null) {
            throw const EmbyViewFailure(
              '请填写有效的服务器地址（如 http://nas.local:8096 或 https://emby.example.com）。',
            );
          }
          final url = uri.toString();
          if (!seenUrls.add(_urlKey(url))) {
            throw const EmbyViewFailure('该服务器地址已存在。');
          }
          normalized.add(
            ServerAddressEntry(
              id: entry.id.trim().isEmpty ? const Uuid().v4() : entry.id.trim(),
              url: url,
              label: entry.label.trim().isEmpty
                  ? inferServerAddressLabel(url)
                  : entry.label.trim(),
              subtitle: entry.subtitle.trim(),
            ),
          );
        }
        await _persistAddresses(server.id, normalized);
        final currentKey = _urlKey(server.address);
        if (normalized.every((e) => _urlKey(e.url) != currentKey)) {
          await _applyServerActiveAddress(server, normalized.first.url);
        }
        _publish(
          _readCurrent(
            phase: _snapshot.phase,
            sessionId: _snapshot.sessionId,
            preferredServerId: server.id,
          ),
        );
      });

  @override
  Future<void> addServerAddress(ServerAddressEntry entry) =>
      _serialize(() async {
        final server = _resolveServer();
        if (server == null) {
          throw const EmbyViewFailure('尚未配置 Emby 服务器。');
        }
        final uri = parseEmbyServerAddress(entry.url);
        if (uri == null) {
          throw const EmbyViewFailure(
            '请填写有效的服务器地址（如 http://nas.local:8096 或 https://emby.example.com）。',
          );
        }
        final url = uri.toString();
        final current = _addressesForServer(server);
        if (current.any((e) => _urlKey(e.url) == _urlKey(url))) {
          throw const EmbyViewFailure('该服务器地址已存在。');
        }
        final created = ServerAddressEntry(
          id: entry.id.trim().isEmpty ? const Uuid().v4() : entry.id.trim(),
          url: url,
          label: entry.label.trim().isEmpty
              ? inferServerAddressLabel(url)
              : entry.label.trim(),
          subtitle: entry.subtitle.trim().isEmpty
              ? inferServerAddressSubtitle(url)
              : entry.subtitle.trim(),
        );
        await _persistAddresses(server.id, [...current, created]);
        _publish(
          _readCurrent(
            phase: _snapshot.phase,
            sessionId: _snapshot.sessionId,
            preferredServerId: server.id,
          ),
        );
      });

  @override
  Future<void> updateServerAddress(ServerAddressEntry entry) =>
      _serialize(() async {
        final server = _resolveServer();
        if (server == null) {
          throw const EmbyViewFailure('尚未配置 Emby 服务器。');
        }
        final uri = parseEmbyServerAddress(entry.url);
        if (uri == null) {
          throw const EmbyViewFailure(
            '请填写有效的服务器地址（如 http://nas.local:8096 或 https://emby.example.com）。',
          );
        }
        final url = uri.toString();
        final current = [..._addressesForServer(server)];
        final idx = current.indexWhere((e) => e.id == entry.id);
        if (idx < 0) {
          throw const EmbyViewFailure('未找到要修改的服务器地址。');
        }
        if (current.any((e) => e.id != entry.id && _urlKey(e.url) == _urlKey(url))) {
          throw const EmbyViewFailure('该服务器地址已存在。');
        }
        final wasActive = _urlKey(current[idx].url) == _urlKey(server.address);
        current[idx] = ServerAddressEntry(
          id: entry.id,
          url: url,
          label: entry.label.trim().isEmpty
              ? inferServerAddressLabel(url)
              : entry.label.trim(),
          subtitle: entry.subtitle.trim(),
        );
        await _persistAddresses(server.id, current);
        if (wasActive) {
          await _applyServerActiveAddress(server, url);
        }
        _publish(
          _readCurrent(
            phase: _snapshot.phase,
            sessionId: _snapshot.sessionId,
            preferredServerId: server.id,
          ),
        );
      });

  @override
  Future<void> removeServerAddress(String addressId) => _serialize(() async {
    final server = _resolveServer();
    if (server == null) {
      throw const EmbyViewFailure('尚未配置 Emby 服务器。');
    }
    final current = [..._addressesForServer(server)];
    final idx = current.indexWhere((e) => e.id == addressId);
    if (idx < 0) return;
    if (current.length <= 1) {
      throw const EmbyViewFailure('至少保留一条服务器地址。');
    }
    final removed = current.removeAt(idx);
    await _persistAddresses(server.id, current);
    if (_urlKey(removed.url) == _urlKey(server.address)) {
      await _applyServerActiveAddress(server, current.first.url);
    }
    _publish(
      _readCurrent(
        phase: _snapshot.phase,
        sessionId: _snapshot.sessionId,
        preferredServerId: server.id,
      ),
    );
  });

  @override
  Future<void> reorderServerAddresses(List<String> addressIds) =>
      _serialize(() async {
        final server = _resolveServer();
        if (server == null) return;
        final current = _addressesForServer(server);
        if (current.isEmpty) return;
        final remaining = {for (final a in current) a.id: a};
        final ordered = <ServerAddressEntry>[];
        for (final id in addressIds) {
          final found = remaining.remove(id);
          if (found != null) ordered.add(found);
        }
        ordered.addAll(remaining.values);
        await _persistAddresses(server.id, ordered);
        _publish(
          _readCurrent(
            phase: _snapshot.phase,
            sessionId: _snapshot.sessionId,
            preferredServerId: server.id,
          ),
        );
      });

  @override
  Future<void> activateServerAddress(String addressId) => _serialize(() async {
    final server = _resolveServer();
    if (server == null) return;
    final current = _addressesForServer(server);
    final target = current.where((e) => e.id == addressId).firstOrNull;
    if (target == null) return;
    final uri = parseEmbyServerAddress(target.url);
    final nextUrl = uri?.toString() ?? target.url;
    await _applyServerActiveAddress(server, nextUrl);
    _publish(
      _readCurrent(
        phase: _snapshot.phase,
        sessionId: _snapshot.sessionId,
        preferredServerId: server.id,
      ),
    );
  });

  static Future<AddressProbeResult> _defaultProbeAddress(
    Uri address,
    Duration timeout,
  ) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    configureServerDio(dio);
    final sw = Stopwatch()..start();
    try {
      final result = await probeServerPublicInfo(dio, address.toString());
      sw.stop();
      if (result == null) return const AddressProbeResult(reachable: false);
      return AddressProbeResult(
        reachable: true,
        latencyMs: sw.elapsedMilliseconds,
        serverVersion: result.info['Version'] as String?,
      );
    } catch (_) {
      return const AddressProbeResult(reachable: false);
    } finally {
      dio.close();
    }
  }

  Future<void> close() async {
    _connectivity?.removeListener(_connectionChanged);
    _pendingColdStartNotice = null;
    await _pending;
    await _changes.close();
    await _connectionNotices.close();
  }
}
