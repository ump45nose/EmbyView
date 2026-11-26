import 'package:flutter/foundation.dart';
import 'package:moonfin/embyview/embyview.dart';

/// All five steps of the unified EmbyView login screen, mirroring `vLogin` in
/// `.spec/mockups/proto.js`.
enum EvLoginStep { server, cert, fail, users, pass }

/// An Emby server discovered on the local network.
@immutable
class EvDiscoveredServer {
  const EvDiscoveredServer({
    required this.id,
    required this.name,
    required this.address,
    this.version,
    this.latencyMs,
  });

  final String id;
  final String name;
  final String address;
  final String? version;
  final int? latencyMs;

  String get displayAddress => formatServerAddressForDisplay(address);

  String get subtitle {
    final ver = version?.trim();
    if (ver != null && ver.isNotEmpty) {
      return 'Emby $ver · $displayAddress';
    }
    return displayAddress;
  }
}

/// Connected Emby server summary shown on the user-selection step.
@immutable
class EvConnectedServer {
  const EvConnectedServer({
    required this.id,
    required this.name,
    required this.address,
    this.version,
  });

  final String id;
  final String name;
  final String address;
  final String? version;

  String get displayAddress => formatServerAddressForDisplay(address);
}

/// User entry presented in the "Who's watching?" step of [EvLoginPage].
@immutable
class EvLoginUser {
  const EvLoginUser({
    required this.id,
    required this.name,
    this.hasPassword = true,
    this.hasStoredToken = false,
    this.avatar,
    this.serverId,
  });

  final String id;
  final String name;
  final bool hasPassword;
  final bool hasStoredToken;
  final ArtworkRef? avatar;
  final String? serverId;

  AccountProfile toProfile() => AccountProfile(
    id: id,
    displayName: name,
    avatar: avatar,
    serverId: serverId,
    hasPassword: hasPassword,
  );
}

/// Self-signed TLS certificate challenge displayed in `login:cert`.
@immutable
class EvCertChallenge {
  const EvCertChallenge({
    required this.address,
    required this.host,
    required this.fingerprint,
  });

  final String address;
  final String host;

  /// Colon-separated SHA-256 fingerprint (without or with `SHA-256` prefix).
  final String fingerprint;

  String get formattedFingerprint {
    final trimmed = fingerprint.trim();
    if (trimmed.isEmpty) return 'SHA-256　（服务器未返回证书指纹）';
    if (trimmed.toUpperCase().startsWith('SHA-256')) return trimmed;
    return 'SHA-256　$trimmed';
  }
}

/// Connection failure details displayed in `login:fail`.
@immutable
class EvConnectFailure {
  const EvConnectFailure({
    required this.address,
    required this.reason,
  });

  final String address;
  final String reason;
}

/// Outcome of attempting to connect to an Emby server address.
sealed class EvServerConnectResult {
  const EvServerConnectResult();
}

final class EvServerConnectSuccess extends EvServerConnectResult {
  const EvServerConnectSuccess({
    required this.server,
    required this.users,
  });

  final EvConnectedServer server;
  final List<EvLoginUser> users;
}

final class EvServerConnectUntrustedCert extends EvServerConnectResult {
  const EvServerConnectUntrustedCert(this.challenge);

  final EvCertChallenge challenge;
}

final class EvServerConnectFailure extends EvServerConnectResult {
  const EvServerConnectFailure(this.failure);

  final EvConnectFailure failure;
}

/// Injectable backend driving [EvLoginPage] discovery, TLS trust, and sign-in.
abstract interface class EvLoginBackend {
  /// Emits progressively updated lists of LAN-discovered Emby servers.
  Stream<List<EvDiscoveredServer>> discoverServers();

  /// Loads a previously saved Emby server (optional [serverId]), if any.
  Future<EvConnectedServer?> loadSavedServer({String? serverId});

  /// Loads public + stored users for [server].
  Future<List<EvLoginUser>> loadUsers(EvConnectedServer server);

  /// Connects to [rawAddress] and returns either the server + users,
  /// a self-signed certificate challenge, or a failure with actionable copy.
  Future<EvServerConnectResult> connectServer(String rawAddress);

  /// Persists trust for [challenge]'s self-signed certificate and retries.
  Future<EvServerConnectResult> trustCertificateAndConnect(
    EvCertChallenge challenge,
  );

  /// Authenticates a listed [user] on [server].
  Future<void> signInWithUser({
    required EvConnectedServer server,
    required EvLoginUser user,
    String? password,
    bool rememberPassword = true,
  });

  /// Authenticates a manually entered [username] and [password] on [server].
  Future<void> signInManually({
    required EvConnectedServer server,
    required String username,
    required String password,
    bool rememberPassword = true,
  });
}

/// Canonical demo fixtures matching `.spec/mockups/proto.js` (`vLogin`).
abstract final class EvLoginDemoData {
  static const List<EvDiscoveredServer> discoveredServers = [
    EvDiscoveredServer(
      id: 'home',
      name: '家里的 Emby',
      address: 'http://nas.local:8096',
      version: '4.10.2',
      latencyMs: 12,
    ),
    EvDiscoveredServer(
      id: 'studio',
      name: '工作室',
      address: 'http://192.168.1.40:8096',
      version: '4.9.1',
      latencyMs: 31,
    ),
  ];

  static const EvConnectedServer server = EvConnectedServer(
    id: 'home',
    name: '家里的 Emby',
    address: 'http://nas.local:8096',
    version: '4.10.2',
  );

  static const List<EvLoginUser> users = [
    EvLoginUser(id: 'sfw', name: 'sfw', hasPassword: true, serverId: 'home'),
    EvLoginUser(id: 'family', name: '家人', hasPassword: true, serverId: 'home'),
    EvLoginUser(id: 'guest', name: '访客', hasPassword: false, serverId: 'home'),
  ];

  static const EvCertChallenge certChallenge = EvCertChallenge(
    address: 'https://192.168.1.20:8920',
    host: '192.168.1.20',
    fingerprint: '4F:2A:9C:07:…:D3:7B:E1',
  );

  static const EvConnectFailure connectFailure = EvConnectFailure(
    address: '192.168.1.20:8096',
    reason: '5 秒没有回应。确认 NAS 已开机、地址和端口没写错（Emby 默认 8096，HTTPS 是 8920）。',
  );
}

/// Zero-network stub backend for unit tests and the Stage 7 demo launcher.
class EvDemoLoginBackend implements EvLoginBackend {
  EvDemoLoginBackend({
    this.discovered = EvLoginDemoData.discoveredServers,
    this.defaultServer = EvLoginDemoData.server,
    this.users = EvLoginDemoData.users,
  });

  final List<EvDiscoveredServer> discovered;
  final EvConnectedServer defaultServer;
  final List<EvLoginUser> users;
  final Set<String> _trustedAddresses = {};

  String? lastSignedInUser;
  String? lastSignedInPassword;
  bool? lastRememberPassword;

  @override
  Stream<List<EvDiscoveredServer>> discoverServers() =>
      Stream<List<EvDiscoveredServer>>.value(discovered);

  @override
  Future<EvConnectedServer?> loadSavedServer({String? serverId}) async =>
      defaultServer;

  @override
  Future<List<EvLoginUser>> loadUsers(EvConnectedServer server) async => users;

  @override
  Future<EvServerConnectResult> connectServer(String rawAddress) async {
    final trimmed = rawAddress.trim();
    if (trimmed.isEmpty) {
      return const EvServerConnectFailure(EvLoginDemoData.connectFailure);
    }
    for (final s in discovered) {
      if (trimmed == s.address || trimmed == s.displayAddress) {
        return EvServerConnectSuccess(
          server: EvConnectedServer(
            id: s.id,
            name: s.name,
            address: s.address,
            version: s.version,
          ),
          users: users,
        );
      }
    }
    if (trimmed.startsWith('https://') && !_trustedAddresses.contains(trimmed)) {
      final host = Uri.tryParse(trimmed)?.host ?? trimmed;
      return EvServerConnectUntrustedCert(
        EvCertChallenge(
          address: trimmed,
          host: host,
          fingerprint: EvLoginDemoData.certChallenge.fingerprint,
        ),
      );
    }
    if (trimmed.contains('192.168.1.20:8096') || trimmed.contains('fail')) {
      return EvServerConnectFailure(
        EvConnectFailure(
          address: formatServerAddressForDisplay(trimmed),
          reason: EvLoginDemoData.connectFailure.reason,
        ),
      );
    }
    final uri = parseEmbyServerAddress(trimmed);
    if (uri == null) {
      return EvServerConnectFailure(
        EvConnectFailure(
          address: trimmed,
          reason: '地址格式不正确。请填写如 192.168.1.20:8096 或 https://emby.example.com（Emby 默认 8096，HTTPS 是 8920）。',
        ),
      );
    }
    return EvServerConnectSuccess(
      server: EvConnectedServer(
        id: uri.host,
        name: defaultServer.name,
        address: uri.toString(),
        version: defaultServer.version,
      ),
      users: users,
    );
  }

  @override
  Future<EvServerConnectResult> trustCertificateAndConnect(
    EvCertChallenge challenge,
  ) async {
    _trustedAddresses.add(challenge.address);
    return EvServerConnectSuccess(
      server: EvConnectedServer(
        id: challenge.host,
        name: defaultServer.name,
        address: challenge.address,
        version: defaultServer.version,
      ),
      users: users,
    );
  }

  @override
  Future<void> signInWithUser({
    required EvConnectedServer server,
    required EvLoginUser user,
    String? password,
    bool rememberPassword = true,
  }) async {
    lastSignedInUser = user.name;
    lastSignedInPassword = password;
    lastRememberPassword = rememberPassword;
  }

  @override
  Future<void> signInManually({
    required EvConnectedServer server,
    required String username,
    required String password,
    bool rememberPassword = true,
  }) async {
    lastSignedInUser = username;
    lastSignedInPassword = password;
    lastRememberPassword = rememberPassword;
  }
}
