import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/auth/repositories/auth_repository.dart';
import 'package:moonfin/auth/repositories/server_repository.dart';
import 'package:moonfin/auth/store/authentication_store.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/embyview/contracts/accounts.dart';
import 'package:moonfin/embyview/data/accounts.dart';
import 'package:server_core/server_core.dart';

class _Store extends Fake
    implements AuthenticationStore, ServerRepository, MediaServerClientFactory {
  @override
  Future<void> loadStoredServers() async {}
  final server = Server(
    id: 'server',
    name: 'NAS',
    address: 'https://emby.test',
    version: '4.10',
    serverType: ServerType.emby,
    dateAdded: DateTime(2026),
  );
  final users = [
    for (final id in ['old', 'new'])
      PrivateUser(
        id: id,
        name: id,
        serverId: 'server',
        accessToken: 'token-$id',
        lastUsed: DateTime(2026),
      ),
  ];
  @override
  List<Server> getServers() => [server];
  @override
  Server? getServer(String id) => server;
  @override
  List<PrivateUser> getUsers(String id) => users;
  @override
  PrivateUser? getUser(String serverId, String userId) =>
      users.where((u) => u.id == userId).firstOrNull;
}

class _Sessions extends Fake implements SessionRepository {
  final calls = <String>[];
  String? failUser;
  @override
  String? activeServerId = 'server';
  @override
  String? activeUserId = 'old';
  @override
  Future<bool> restoreSession() async {
    calls.add('restore');
    activeServerId = 'server';
    activeUserId = 'old';
    return true;
  }

  @override
  Future<bool> switchCurrentSession({
    required String serverId,
    required String userId,
    String? username,
    String? password,
    bool validateToken = false,
  }) async {
    calls.add(userId);
    activeUserId = userId;
    return userId != failUser;
  }
}

class _Auth extends Fake implements AuthRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('startup choices, awaited switching and recovery preserve account ownership', () async {
    final sessions = _Sessions()..activeUserId = null;
    final store = _Store();
    var chooseUser = true;
    Completer<void>? stopped;
    final accounts = MoonfinEmbyViewAccounts(
      store: store,
      sessions: sessions,
      auth: _Auth(),
      servers: store,
      clients: store,
      chooseUserOnStartup: () => chooseUser,
      beforeSessionChange: () => stopped?.future ?? Future.value(),
    );
    await accounts.restore();
    expect(accounts.snapshot.phase, AccountPhase.choosing);
    expect(sessions.calls, isEmpty);
    chooseUser = false;
    await accounts.restore();
    expect(sessions.calls, ['restore']);
    expect(accounts.snapshot.phase, AccountPhase.signedIn);
    sessions.calls.clear();
    stopped = Completer<void>();
    final change = accounts.switchTo('server/new');
    await Future<void>.delayed(Duration.zero);
    expect(sessions.calls, isEmpty);
    stopped.complete();
    await change;
    expect(sessions.calls, ['new']);
    expect(accounts.snapshot.current?.displayName, 'new');
    final oldSession = accounts.snapshot.sessionId;
    sessions.failUser = 'old';
    await expectLater(accounts.switchTo('server/old'), throwsA(anything));
    expect(accounts.snapshot.phase, AccountPhase.signedIn);
    expect(accounts.snapshot.current?.displayName, 'new');
    expect(accounts.snapshot.sessionId, isNot(oldSession));
    await accounts.close();
  });
}
