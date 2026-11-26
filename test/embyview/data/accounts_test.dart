import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/auth_repository.dart';
import 'package:moonfin/auth/repositories/server_repository.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/auth/store/authentication_store.dart';
import 'package:moonfin/auth/store/credential_store.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/embyview/contracts/accounts.dart';
import 'package:moonfin/embyview/contracts/common.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/data/accounts.dart';
import 'package:moonfin/embyview/prefs/machine_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient extends Fake implements MediaServerClient {
  _FakeClient(this.baseUrl);

  @override
  String baseUrl;

  final List<String> apiCalls = [];

  @override
  UsersApi get usersApi {
    apiCalls.add('usersApi');
    throw StateError('Server user API must never be called for local removal');
  }
}

class _Store extends Fake
    implements AuthenticationStore, ServerRepository, MediaServerClientFactory {
  _Store({Server? initialServer}) {
    final s = initialServer ??
        Server(
          id: 'server',
          name: '家里的 Emby',
          address: 'http://nas.local:8096',
          version: '4.10.2',
          serverType: ServerType.emby,
          dateAdded: DateTime(2026),
        );
    serversById[s.id] = s;
    usersByServer[s.id] = [
      for (final id in ['old', 'new'])
        PrivateUser(
          id: id,
          name: id,
          serverId: s.id,
          accessToken: 'token-$id',
          lastUsed: DateTime(2026),
        ),
    ];
    clientsByServer[s.id] = _FakeClient(s.address);
  }

  final Map<String, Server> serversById = {};
  final Map<String, List<PrivateUser>> usersByServer = {};
  final Map<String, _FakeClient> clientsByServer = {};
  final List<String> removedUsers = [];
  final List<String> deletedServers = [];
  final List<String> updatedAddresses = [];

  @override
  Future<void> loadStoredServers() async {}

  @override
  List<Server> getServers() => serversById.values.toList();

  @override
  Server? getServer(String id) => serversById[id];

  @override
  Future<void> putServer(Server server) async {
    serversById[server.id] = server;
  }

  @override
  Future<void> updateServer(Server server) async {
    serversById[server.id] = server;
    updatedAddresses.add(server.address);
  }

  @override
  Future<void> deleteServer(String serverId) async {
    deletedServers.add(serverId);
    serversById.remove(serverId);
    usersByServer.remove(serverId);
    clientsByServer.remove(serverId);
  }

  @override
  Future<void> removeServer(String serverId) async {
    serversById.remove(serverId);
    usersByServer.remove(serverId);
  }

  @override
  List<PrivateUser> getUsers(String id) =>
      List<PrivateUser>.from(usersByServer[id] ?? const []);

  @override
  PrivateUser? getUser(String serverId, String userId) =>
      (usersByServer[serverId] ?? const [])
          .where((u) => u.id == userId)
          .firstOrNull;

  @override
  Future<void> removeUser(String serverId, String userId) async {
    removedUsers.add('$serverId/$userId');
    usersByServer[serverId]?.removeWhere((u) => u.id == userId);
  }

  @override
  MediaServerClient? getClientIfExists(String serverId) =>
      clientsByServer[serverId];

  @override
  void removeClient(String serverId) {
    clientsByServer.remove(serverId);
  }
}

class _Credentials extends Fake implements CredentialStore {
  final List<String> deletedTokens = [];

  @override
  Future<void> deleteToken(String serverId) async {
    deletedTokens.add(serverId);
  }
}

class _Sessions extends Fake implements SessionRepository {
  final calls = <String>[];
  String? failUser;
  int destroyCalls = 0;

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
    activeServerId = serverId;
    activeUserId = userId;
    return userId != failUser;
  }

  @override
  Future<void> destroyCurrentSession({bool tokenKnownInvalid = false}) async {
    destroyCalls++;
    activeServerId = null;
    activeUserId = null;
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

  test('auto-migrates single address and persists ordered addresses + autoSwitch preference', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await MachinePreferences.open();
    expect(prefs.current.autoSwitchServerAddress, isTrue);

    final store = _Store();
    final sessions = _Sessions();
    final accounts = MoonfinEmbyViewAccounts(
      store: store,
      sessions: sessions,
      auth: _Auth(),
      servers: store,
      clients: store,
      preferences: prefs,
      chooseUserOnStartup: () => false,
      beforeSessionChange: () async {},
    );

    // Migrated from single server.address
    expect(accounts.snapshot.serverName, '家里的 Emby');
    expect(accounts.snapshot.addresses, hasLength(1));
    expect(accounts.snapshot.addresses.first.url, 'http://nas.local:8096');
    expect(accounts.snapshot.addresses.first.label, '内网');
    expect(accounts.snapshot.activeAddress?.url, 'http://nas.local:8096');

    // Add second address, update, reorder, activate, validate errors
    await accounts.addServerAddress(
      const ServerAddressEntry(
        id: 'ts',
        url: 'https://nas.tail-example.ts.net',
        label: 'Tailscale',
        subtitle: '出门时自动换到这里',
      ),
    );
    expect(accounts.snapshot.addresses.map((e) => e.id), ['primary', 'ts']);

    await expectLater(
      accounts.addServerAddress(const ServerAddressEntry(id: 'bad', url: 'not a url :::')),
      throwsA(isA<EmbyViewFailure>()),
    );

    await accounts.updateServerAddress(
      const ServerAddressEntry(
        id: 'ts',
        url: 'https://nas.tail-new.ts.net',
        label: 'Tailscale',
        subtitle: '外网专线',
      ),
    );
    expect(accounts.snapshot.addresses[1].url, 'https://nas.tail-new.ts.net');

    await accounts.reorderServerAddresses(['ts', 'primary']);
    expect(accounts.snapshot.addresses.map((e) => e.id), ['ts', 'primary']);

    await accounts.activateServerAddress('ts');
    expect(accounts.snapshot.activeAddress?.id, 'ts');
    expect(store.serversById['server']?.address, 'https://nas.tail-new.ts.net');
    expect(store.clientsByServer['server']?.baseUrl, 'https://nas.tail-new.ts.net');

    await accounts.removeServerAddress('primary');
    expect(accounts.snapshot.addresses, hasLength(1));
    await expectLater(
      accounts.removeServerAddress('ts'),
      throwsA(isA<EmbyViewFailure>()),
    );

    // Reopen MachinePreferences to verify persistence
    await accounts.close();
    await prefs.close();
    final reopened = await MachinePreferences.open();
    expect(reopened.current.autoSwitchServerAddress, isTrue);
    expect(reopened.current.serverAddresses['server']?.single.url, 'https://nas.tail-new.ts.net');
    await reopened.close();
  });

  test('failover on timeout, connection refused, and DNS failure remembers active address and emits switched event', () async {
    for (final failureKind in ['timeout', 'refused', 'dns']) {
      SharedPreferences.setMockInitialValues({});
      final prefs = await MachinePreferences.open();
      final store = _Store();
      final sessions = _Sessions();
      final probed = <String>[];
      final notices = <ConnectionNoticeEvent>[];

      final accounts = MoonfinEmbyViewAccounts(
        store: store,
        sessions: sessions,
        auth: _Auth(),
        servers: store,
        clients: store,
        preferences: prefs,
        chooseUserOnStartup: () => false,
        beforeSessionChange: () async {},
        probeAddress: (uri, timeout) async {
          probed.add(uri.toString());
          if (uri.host == 'nas.local') {
            if (failureKind == 'timeout') {
              throw TimeoutException('connect timeout', timeout);
            }
            if (failureKind == 'refused') {
              throw const SocketException('Connection refused', osError: OSError('Connection refused', 61));
            }
            throw const SocketException('Failed host lookup: nas.local');
          }
          return const AddressProbeResult(reachable: true, latencyMs: 28, serverVersion: '4.10.2');
        },
      );
      final sub = accounts.connectionNotices.listen(notices.add);

      await accounts.setServerAddresses(const [
        ServerAddressEntry(id: 'lan', url: 'http://nas.local:8096', label: '内网', subtitle: '在家时用'),
        ServerAddressEntry(id: 'ts', url: 'https://nas.tail-example.ts.net', label: 'Tailscale', subtitle: '出门时自动换到这里'),
      ]);

      final active = await accounts.probeAndFailover(timeout: const Duration(milliseconds: 200));
      expect(active?.toString(), 'https://nas.tail-example.ts.net', reason: 'failed for $failureKind');
      expect(probed, ['http://nas.local:8096', 'https://nas.tail-example.ts.net']);
      expect(store.serversById['server']?.address, 'https://nas.tail-example.ts.net');
      expect(store.clientsByServer['server']?.baseUrl, 'https://nas.tail-example.ts.net');
      expect(accounts.snapshot.activeAddress?.id, 'ts');
      expect(accounts.snapshot.connection, ConnectionState.connected);
      expect(accounts.snapshot.latencyMs, 28);
      expect(notices, hasLength(1));
      expect(notices.single.kind, ConnectionNoticeKind.switched);
      expect(notices.single.fromLabel, '内网');
      expect(notices.single.toLabel, 'Tailscale');
      expect(notices.single.activeAddress, 'https://nas.tail-example.ts.net');

      await sub.cancel();
      await accounts.close();
      await prefs.close();
    }
  });

  test('all addresses failing emits offline with triedAddressCount and retryConnection emits recovered', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await MachinePreferences.open();
    final store = _Store();
    final sessions = _Sessions();
    var allDown = true;
    final notices = <ConnectionNoticeEvent>[];

    final accounts = MoonfinEmbyViewAccounts(
      store: store,
      sessions: sessions,
      auth: _Auth(),
      servers: store,
      clients: store,
      preferences: prefs,
      chooseUserOnStartup: () => false,
      beforeSessionChange: () async {},
      probeAddress: (uri, _) async => allDown
          ? const AddressProbeResult(reachable: false)
          : const AddressProbeResult(reachable: true, latencyMs: 12),
    );
    final sub = accounts.connectionNotices.listen(notices.add);

    await accounts.setServerAddresses(const [
      ServerAddressEntry(id: 'lan', url: 'http://nas.local:8096', label: '内网'),
      ServerAddressEntry(id: 'ts', url: 'https://nas.tail-example.ts.net', label: 'Tailscale'),
    ]);

    final uri = await accounts.probeAndFailover();
    expect(uri, isNull);
    expect(accounts.snapshot.connection, ConnectionState.disconnected);
    expect(accounts.snapshot.triedAddressCount, 2);
    expect(notices, hasLength(1));
    expect(notices.last.kind, ConnectionNoticeKind.offline);
    expect(notices.last.serverName, '家里的 Emby');
    expect(notices.last.triedAddressCount, 2);

    allDown = false;
    await accounts.retryConnection();
    expect(accounts.snapshot.connection, ConnectionState.connected);
    expect(accounts.snapshot.latencyMs, 12);
    expect(notices, hasLength(2));
    expect(notices.last.kind, ConnectionNoticeKind.recovered);

    await sub.cancel();
    await accounts.close();
    await prefs.close();
  });

  test('autoSwitchServerAddress = false does not switch to secondary address', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await MachinePreferences.open();
    await prefs.update(const LocalPreferences(autoSwitchServerAddress: false));

    final store = _Store();
    final sessions = _Sessions();
    final probed = <String>[];
    final notices = <ConnectionNoticeEvent>[];

    final accounts = MoonfinEmbyViewAccounts(
      store: store,
      sessions: sessions,
      auth: _Auth(),
      servers: store,
      clients: store,
      preferences: prefs,
      chooseUserOnStartup: () => false,
      beforeSessionChange: () async {},
      probeAddress: (uri, _) async {
        probed.add(uri.toString());
        return AddressProbeResult(reachable: uri.host != 'nas.local', latencyMs: 18);
      },
    );
    final sub = accounts.connectionNotices.listen(notices.add);

    await accounts.setServerAddresses(const [
      ServerAddressEntry(id: 'lan', url: 'http://nas.local:8096', label: '内网'),
      ServerAddressEntry(id: 'ts', url: 'https://nas.tail-example.ts.net', label: 'Tailscale'),
    ]);

    final uri = await accounts.probeAndFailover();
    expect(uri, isNull);
    expect(probed, ['http://nas.local:8096']);
    expect(store.serversById['server']?.address, 'http://nas.local:8096');
    expect(notices.single.kind, ConnectionNoticeKind.offline);
    expect(notices.single.triedAddressCount, 1);

    await sub.cancel();
    await accounts.close();
    await prefs.close();
  });

  test('signOut keeps server and addresses and enters choosing phase', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await MachinePreferences.open();
    final store = _Store();
    final sessions = _Sessions();
    final accounts = MoonfinEmbyViewAccounts(
      store: store,
      sessions: sessions,
      auth: _Auth(),
      servers: store,
      clients: store,
      preferences: prefs,
      chooseUserOnStartup: () => false,
      beforeSessionChange: () async {},
    );

    await accounts.setServerAddresses(const [
      ServerAddressEntry(id: 'lan', url: 'http://nas.local:8096', label: '内网'),
      ServerAddressEntry(id: 'ts', url: 'https://nas.tail-example.ts.net', label: 'Tailscale'),
    ]);

    await accounts.signOut();
    expect(sessions.destroyCalls, 1);
    expect(accounts.snapshot.phase, AccountPhase.choosing);
    expect(accounts.snapshot.current, isNull);
    expect(accounts.snapshot.serverName, '家里的 Emby');
    expect(accounts.snapshot.addresses, hasLength(2));
    expect(store.serversById.containsKey('server'), isTrue);

    await accounts.close();
    await prefs.close();
  });

  test('removeLocalAccount and removeCurrentServer only delete local records and tokens without server user API calls', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await MachinePreferences.open();
    final store = _Store();
    final client = store.clientsByServer['server']!;
    final creds = _Credentials();
    final sessions = _Sessions();
    final accounts = MoonfinEmbyViewAccounts(
      store: store,
      sessions: sessions,
      auth: _Auth(),
      servers: store,
      clients: store,
      preferences: prefs,
      credentials: creds,
      chooseUserOnStartup: () => false,
      beforeSessionChange: () async {},
    );

    await accounts.setServerAddresses(const [
      ServerAddressEntry(id: 'lan', url: 'http://nas.local:8096', label: '内网'),
      ServerAddressEntry(id: 'ts', url: 'https://nas.tail-example.ts.net', label: 'Tailscale'),
    ]);

    // Remove non-current account: stays signed in, only removes local record
    await accounts.removeLocalAccount('server/new');
    expect(store.removedUsers, ['server/new']);
    expect(accounts.snapshot.phase, AccountPhase.signedIn);
    expect(accounts.snapshot.profiles.map((p) => p.id), ['server/old']);
    expect(client.apiCalls, isEmpty);

    // Remove current account: signs out first, removes local user & token, keeps server
    await accounts.removeLocalAccount('server/old');
    expect(sessions.destroyCalls, 1);
    expect(store.removedUsers, ['server/new', 'server/old']);
    expect(creds.deletedTokens, ['server']);
    expect(accounts.snapshot.phase, AccountPhase.choosing);
    expect(accounts.snapshot.profiles, isEmpty);
    expect(store.serversById.containsKey('server'), isTrue);
    expect(client.apiCalls, isEmpty);

    // Remove current server: deletes server, local addresses, and goes to signedOut
    await accounts.removeCurrentServer();
    expect(store.deletedServers, ['server']);
    expect(store.serversById, isEmpty);
    expect(prefs.current.serverAddresses, isEmpty);
    expect(accounts.snapshot.phase, AccountPhase.signedOut);
    expect(accounts.snapshot.addresses, isEmpty);
    expect(client.apiCalls, isEmpty);

    await accounts.close();
    await prefs.close();
  });

  test('cold-start restore fails over from unreachable primary address to secondary address and emits switched notice', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await MachinePreferences.open();
    await prefs.update(
      prefs.current.copyWith(
        autoSwitchServerAddress: true,
        serverAddresses: const {
          'server': [
            ServerAddressEntry(id: 'lan', url: 'http://nas.local:8096', label: '内网'),
            ServerAddressEntry(id: 'ts', url: 'https://nas.tail-cold.ts.net', label: 'Tailscale'),
          ],
        },
      ),
    );
    final store = _Store();
    final sessions = _Sessions()..activeUserId = null;
    final notices = <ConnectionNoticeEvent>[];
    final probed = <String>[];

    final accounts = MoonfinEmbyViewAccounts(
      store: store,
      sessions: sessions,
      auth: _Auth(),
      servers: store,
      clients: store,
      preferences: prefs,
      chooseUserOnStartup: () => false,
      beforeSessionChange: () async {},
      probeAddress: (uri, _) async {
        probed.add(uri.toString());
        if (uri.host == 'nas.local') {
          return const AddressProbeResult(reachable: false);
        }
        return const AddressProbeResult(reachable: true, latencyMs: 24, serverVersion: '4.10.2');
      },
    );
    final sub = accounts.connectionNotices.listen(notices.add);

    await accounts.restore();
    expect(probed, ['http://nas.local:8096', 'https://nas.tail-cold.ts.net']);
    expect(sessions.calls, ['restore']);
    expect(store.serversById['server']?.address, 'https://nas.tail-cold.ts.net');
    expect(store.clientsByServer['server']?.baseUrl, 'https://nas.tail-cold.ts.net');
    expect(accounts.snapshot.phase, AccountPhase.signedIn);
    expect(accounts.snapshot.activeAddress?.id, 'ts');
    expect(notices, hasLength(1));
    expect(notices.single.kind, ConnectionNoticeKind.switched);
    expect(notices.single.fromLabel, '内网');
    expect(notices.single.toLabel, 'Tailscale');

    await sub.cancel();
    await accounts.close();
    await prefs.close();
  });

  test('adding backup HTTPS address syncs Server.candidateAddresses for untrusted cert trust and keeps CredentialStore token while another user remains', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await MachinePreferences.open();
    final store = _Store();
    final realServers = ServerRepository(store, store);
    await realServers.loadStoredServers();
    final prevAllow = gAllowSelfSignedCertificates;
    gAllowSelfSignedCertificates = true;
    addTearDown(() {
      gAllowSelfSignedCertificates = prevAllow;
      realServers.dispose();
    });

    final creds = _Credentials();
    final sessions = _Sessions();
    final accounts = MoonfinEmbyViewAccounts(
      store: store,
      sessions: sessions,
      auth: _Auth(),
      servers: realServers,
      clients: store,
      preferences: prefs,
      credentials: creds,
      chooseUserOnStartup: () => false,
      beforeSessionChange: () async {},
    );

    expect(acceptsUntrustedCertificate('backup.home.lan'), isFalse);
    await accounts.addServerAddress(
      const ServerAddressEntry(
        id: 'https-backup',
        url: 'https://backup.home.lan:8920',
        label: '备用 HTTPS',
      ),
    );
    expect(
      store.serversById['server']?.candidateAddresses,
      ['http://nas.local:8096', 'https://backup.home.lan:8920'],
    );
    expect(acceptsUntrustedCertificate('backup.home.lan'), isTrue);

    // Removing current user while 'new' still exists on the same server must NOT delete server token.
    await accounts.removeLocalAccount('server/old');
    expect(creds.deletedTokens, isEmpty);
    expect(store.getUsers('server').map((u) => u.id), ['new']);

    // Removing the last remaining user deletes the server-level token.
    await accounts.removeLocalAccount('server/new');
    expect(creds.deletedTokens, ['server']);

    await accounts.close();
    await prefs.close();
  });
}
