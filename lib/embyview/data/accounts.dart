import 'dart:async';

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
import '../../data/services/media_server_client_factory.dart';
import '../../data/services/connectivity_service.dart';
import '../contracts/accounts.dart';
import '../contracts/common.dart';

/// Keeps Moonfin's stored identities and authentication, with an awaited
/// boundary before any client or token can change.
class MoonfinEmbyViewAccounts implements EmbyViewAccounts {
  MoonfinEmbyViewAccounts({
    required this.store,
    required this.sessions,
    required this.auth,
    required this.servers,
    required this.clients,
    required this.beforeSessionChange,
    required this.chooseUserOnStartup,
  }) {
    _snapshot = _readCurrent();
    _connectivity?.addListener(_connectionChanged);
  }

  final AuthenticationStore store;
  final SessionRepository sessions;
  final AuthRepository auth;
  final ServerRepository servers;
  final MediaServerClientFactory clients;

  /// Release the old EmbyView scope, including Stop reporting and previews.
  final Future<void> Function() beforeSessionChange;
  final bool Function() chooseUserOnStartup;
  final _connectivity = GetIt.instance.isRegistered<ConnectivityService>()
      ? GetIt.instance<ConnectivityService>()
      : null;
  final _changes = StreamController<AccountSnapshot>.broadcast(sync: true);
  Future<void> _pending = Future.value();
  late AccountSnapshot _snapshot;
  @override
  AccountSnapshot get snapshot => _snapshot;
  @override
  Stream<AccountSnapshot> get changes => _changes.stream;

  String _profileId(PrivateUser user) =>
      '${Uri.encodeComponent(user.serverId)}/${Uri.encodeComponent(user.id)}';
  List<PrivateUser> get _users => [
    for (final server in store.getServers())
      if (server.serverType == ServerType.emby) ...store.getUsers(server.id),
  ];
  AccountProfile _profile(PrivateUser user) => AccountProfile(
    id: _profileId(user),
    displayName: user.name,
    serverId: user.serverId,
  );
  AccountSnapshot _readCurrent({
    AccountPhase? phase,
    EmbyViewFailure? failure,
    String? sessionId,
  }) {
    final server = store.getServer(sessions.activeServerId ?? '');
    final user = server?.serverType == ServerType.emby
        ? store.getUser(server!.id, sessions.activeUserId ?? '')
        : null;
    return AccountSnapshot(
      phase:
          phase ??
          (user != null
              ? AccountPhase.signedIn
              : _users.isEmpty
              ? AccountPhase.signedOut
              : AccountPhase.choosing),
      current: user == null ? null : _profile(user),
      profiles: List.unmodifiable(_users.map(_profile)),
      serverAddress: server?.displayAddress ?? server?.address,
      serverVersion: server?.version,
      connection: user == null || _connectivity == null
          ? ConnectionState.unknown
          : _connectivity.canReachServer
          ? ConnectionState.connected
          : ConnectionState.disconnected,
      sessionId:
          user == null || (phase != null && phase != AccountPhase.signedIn)
          ? null
          : sessionId ?? const Uuid().v4(),
      failure: failure,
    );
  }

  void _connectionChanged() {
    if (_snapshot.phase == AccountPhase.signedIn) {
      final account = _readCurrent(
        failure: _snapshot.failure,
        sessionId: _snapshot.sessionId,
      );
      if (account.current?.id == _snapshot.current?.id) _publish(account);
    }
  }

  void _publish(AccountSnapshot value) {
    _snapshot = value;
    _changes.add(value);
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.catchError((_) {});
    return result;
  }

  Future<void> _transition(
    AccountPhase phase,
    Future<void> Function() operation,
  ) async {
    final old = store.getUser(
      sessions.activeServerId ?? '',
      sessions.activeUserId ?? '',
    );
    _publish(_readCurrent(phase: phase));
    var released = false;
    try {
      await beforeSessionChange();
      released = true;
      await operation();
      _publish(_readCurrent());
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
          AccountSnapshot(
            phase: _users.isEmpty
                ? AccountPhase.signedOut
                : AccountPhase.choosing,
            profiles: List.unmodifiable(_users.map(_profile)),
            failure: failure,
            connection: ConnectionState.disconnected,
          ),
        );
      }
      throw failure;
    }
  }

  @override
  Future<void> restore() => _serialize(() async {
    await servers.loadStoredServers();
    if (sessions.activeUserId != null ||
        chooseUserOnStartup() ||
        _users.isEmpty) {
      _publish(_readCurrent());
      return;
    }
    await _transition(AccountPhase.restoring, () async {
      if (!await sessions.restoreSession()) {
        throw const EmbyViewFailure('请选择用户重新登录。', code: 'restore_failed');
      }
    });
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
      await _activate(await _authenticate(saved, username, password), password);
    }),
  );

  @override
  Future<void> switchTo(String profileId, {String? password}) => _serialize(
    () => _transition(AccountPhase.switching, () async {
      var user = _users.where((u) => _profileId(u) == profileId).firstOrNull;
      if (user == null) throw const EmbyViewFailure('该用户已不在本机，请重新登录。');
      if (password != null) {
        user = await _authenticate(
          store.getServer(user.serverId)!,
          user.name,
          password,
        );
      }
      await _activate(user, password);
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
  }

  @override
  Future<void> signOut() => _serialize(
    () => _transition(
      AccountPhase.switching,
      () => sessions.destroyCurrentSession(),
    ),
  );

  Future<void> close() async {
    _connectivity?.removeListener(_connectionChanged);
    await _pending;
    await _changes.close();
  }
}
