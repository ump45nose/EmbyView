import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../../auth/models/login_state.dart';
import '../../../auth/models/server.dart';
import '../../../auth/models/server_addition_state.dart';
import '../../../auth/repositories/auth_repository.dart';
import '../../../auth/repositories/server_repository.dart';
import '../../../auth/repositories/server_user_repository.dart';
import '../../../auth/repositories/session_repository.dart';
import '../../../auth/services/server_discovery_service.dart';
import '../../../auth/store/authentication_preferences.dart';
import '../../../auth/store/credential_store.dart';
import '../../../data/services/media_server_client_factory.dart';
import '../../../preference/user_preferences.dart';
import '../../embyview.dart';
import 'ev_login_models.dart';

/// Real Moonfin-backed implementation of [EvLoginBackend] reusing existing
/// LAN discovery, self-signed certificate trust, and Emby auth repositories.
class MoonfinEvLoginBackend implements EvLoginBackend {
  MoonfinEvLoginBackend({
    ServerRepository? servers,
    ServerUserRepository? serverUsers,
    AuthRepository? auth,
    SessionRepository? sessions,
    MediaServerClientFactory? clients,
    AuthenticationPreferences? authPrefs,
    CredentialStore? credentials,
    UserPreferences? userPrefs,
    ServerDiscoveryService? discovery,
  }) : _servers = servers ?? GetIt.instance<ServerRepository>(),
       _serverUsers = serverUsers ?? GetIt.instance<ServerUserRepository>(),
       _auth = auth ?? GetIt.instance<AuthRepository>(),
       _sessions = sessions ?? GetIt.instance<SessionRepository>(),
       _clients = clients ?? GetIt.instance<MediaServerClientFactory>(),
       _authPrefs = authPrefs ?? GetIt.instance<AuthenticationPreferences>(),
       _credentials =
           credentials ??
           (GetIt.instance.isRegistered<CredentialStore>()
               ? GetIt.instance<CredentialStore>()
               : null),
       _userPrefs =
           userPrefs ??
           (GetIt.instance.isRegistered<UserPreferences>()
               ? GetIt.instance<UserPreferences>()
               : null),
       _discovery = discovery ?? ServerDiscoveryService();

  final ServerRepository _servers;
  final ServerUserRepository _serverUsers;
  final AuthRepository _auth;
  final SessionRepository _sessions;
  final MediaServerClientFactory _clients;
  final AuthenticationPreferences _authPrefs;
  final CredentialStore? _credentials;
  final UserPreferences? _userPrefs;
  final ServerDiscoveryService _discovery;

  @override
  Stream<List<EvDiscoveredServer>> discoverServers() {
    final controller = StreamController<List<EvDiscoveredServer>>();
    final byId = <String, EvDiscoveredServer>{};
    var pendingProbes = 0;
    var streamDone = false;

    void maybeClose() {
      if (streamDone && pendingProbes == 0 && !controller.isClosed) {
        controller.close();
      }
    }

    void emitSorted() {
      if (controller.isClosed) return;
      final list = byId.values.toList()
        ..sort((a, b) => (a.latencyMs ?? 99999).compareTo(b.latencyMs ?? 99999));
      controller.add(List<EvDiscoveredServer>.unmodifiable(list));
    }

    final sub = _discovery.discoverLocalServers().listen(
      (found) {
        // UDP port 7359 responds for both Jellyfin and Emby; probe public info
        // to confirm ServerType.emby and gather version + latency.
        if (found.serverType == ServerType.plex ||
            found.serverType == ServerType.silo) {
          return;
        }
        pendingProbes++;
        unawaited(() async {
          try {
            final probed = await _probeDiscoveredEmby(found);
            if (probed != null) {
              byId[probed.id] = probed;
              emitSorted();
            }
          } finally {
            pendingProbes--;
            maybeClose();
          }
        }());
      },
      onError: (_) {
        streamDone = true;
        maybeClose();
      },
      onDone: () {
        streamDone = true;
        maybeClose();
      },
    );

    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  Future<EvDiscoveredServer?> _probeDiscoveredEmby(
    DiscoveredServer found,
  ) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        followRedirects: false,
        validateStatus: (s) => s != null && s < 400,
      ),
    );
    configureServerDio(dio);
    final sw = Stopwatch()..start();
    try {
      final res = await probeServerPublicInfo(dio, found.address);
      sw.stop();
      if (res == null || res.serverType != ServerType.emby) return null;
      return EvDiscoveredServer(
        id: found.id,
        name: (res.info['ServerName'] as String?)?.trim().isNotEmpty == true
            ? (res.info['ServerName'] as String).trim()
            : found.name,
        address: res.resolvedBaseUrl.isNotEmpty
            ? res.resolvedBaseUrl
            : found.address,
        version: (res.info['Version'] as String?)?.trim(),
        latencyMs: sw.elapsedMilliseconds,
      );
    } catch (_) {
      if (found.serverType == ServerType.emby) {
        return EvDiscoveredServer(
          id: found.id,
          name: found.name,
          address: found.address,
        );
      }
      return null;
    } finally {
      dio.close();
    }
  }

  @override
  Future<EvConnectedServer?> loadSavedServer({String? serverId}) async {
    await _servers.loadStoredServers();
    Server? server;
    if (serverId != null && serverId.isNotEmpty) {
      final match = _servers.getServer(serverId);
      if (match != null && match.serverType == ServerType.emby) {
        server = match;
      }
    }
    if (server == null && _authPrefs.savedLastServerId.isNotEmpty) {
      final match = _servers.getServer(_authPrefs.savedLastServerId);
      if (match != null && match.serverType == ServerType.emby) {
        server = match;
      }
    }
    server ??= _servers.servers
        .where((s) => s.serverType == ServerType.emby)
        .firstOrNull;
    if (server == null) return null;
    return _toConnectedServer(server);
  }

  @override
  Future<List<EvLoginUser>> loadUsers(EvConnectedServer server) async {
    await _servers.loadStoredServers();
    final storedServer = _servers.getServer(server.id);
    if (storedServer == null) return const [];

    final storedUsers = _serverUsers.getStoredServerUsers(storedServer.id);
    final publicUsers = await _serverUsers.getPublicServerUsers(storedServer);

    final merged = <String, EvLoginUser>{};
    for (final u in publicUsers) {
      merged[u.id] = EvLoginUser(
        id: u.id,
        name: u.name,
        hasPassword: u.hasPassword,
        avatar: _avatarFor(storedServer.address, u.id, u.imageTag),
        serverId: storedServer.id,
      );
    }
    for (final u in storedUsers) {
      final existing = merged[u.id];
      merged[u.id] = EvLoginUser(
        id: u.id,
        name: u.name,
        hasPassword: existing?.hasPassword ?? true,
        avatar:
            existing?.avatar ?? _avatarFor(storedServer.address, u.id, u.imageTag),
        serverId: storedServer.id,
      );
    }
    return List<EvLoginUser>.unmodifiable(merged.values);
  }

  @override
  Future<EvServerConnectResult> connectServer(String rawAddress) async {
    final trimmed = rawAddress.trim();
    if (trimmed.isEmpty) {
      return const EvServerConnectFailure(
        EvConnectFailure(
          address: '',
          reason: '请先输入 Emby 服务器地址（默认端口 8096，HTTPS 是 8920）。',
        ),
      );
    }

    final saved = await _servers.addServer(trimmed);
    if (saved != null) {
      if (saved.serverType != ServerType.emby) {
        return EvServerConnectFailure(
          EvConnectFailure(
            address: formatServerAddressForDisplay(trimmed),
            reason:
                '这台服务器不是 Emby。EmbyView 仅支持 Emby 服务器（默认端口 8096，HTTPS 是 8920）。',
          ),
        );
      }
      final connected = _toConnectedServer(saved);
      final users = await loadUsers(connected);
      return EvServerConnectSuccess(server: connected, users: users);
    }

    final fail = _servers.lastFailure;
    if (fail?.untrustedCandidate != null) {
      final candidate = fail!.untrustedCandidate!;
      final uri = Uri.tryParse(candidate);
      final fingerprint = await _fetchCertificateSha256(candidate);
      return EvServerConnectUntrustedCert(
        EvCertChallenge(
          address: candidate,
          host: uri?.host ?? formatServerAddressForDisplay(candidate),
          fingerprint: fingerprint,
        ),
      );
    }

    return EvServerConnectFailure(
      EvConnectFailure(
        address: formatServerAddressForDisplay(trimmed),
        reason: _formatFailureReason(fail),
      ),
    );
  }

  @override
  Future<EvServerConnectResult> trustCertificateAndConnect(
    EvCertChallenge challenge,
  ) async {
    gAllowSelfSignedCertificates = true;
    await _userPrefs?.set(UserPreferences.allowSelfSignedCerts, true);
    return connectServer(challenge.address);
  }

  @override
  Future<void> signInWithUser({
    required EvConnectedServer server,
    required EvLoginUser user,
    String? password,
    bool rememberPassword = true,
  }) async {
    final storedServer = _servers.getServer(server.id);
    if (storedServer == null) {
      throw const EmbyViewFailure('服务器配置已失效，请重新连接。');
    }

    if (password == null && !user.hasPassword) {
      await _authenticateAndActivate(
        storedServer,
        username: user.name,
        password: '',
        rememberPassword: rememberPassword,
      );
      return;
    }

    await _authenticateAndActivate(
      storedServer,
      username: user.name,
      password: password ?? '',
      rememberPassword: rememberPassword,
    );
  }

  @override
  Future<void> signInManually({
    required EvConnectedServer server,
    required String username,
    required String password,
    bool rememberPassword = true,
  }) async {
    final storedServer = _servers.getServer(server.id);
    if (storedServer == null) {
      throw const EmbyViewFailure('服务器配置已失效，请重新连接。');
    }
    await _authenticateAndActivate(
      storedServer,
      username: username,
      password: password,
      rememberPassword: rememberPassword,
    );
  }

  Future<void> _authenticateAndActivate(
    Server server, {
    required String username,
    required String password,
    required bool rememberPassword,
  }) async {
    final client = _clients.getClient(
      serverId: server.id,
      serverType: server.serverType,
      baseUrl: server.address,
    );
    final state = await _auth.authenticate(
      client: client,
      serverId: server.id,
      username: username,
      password: password,
    );
    if (state is! Authenticated) {
      final msg = switch (state) {
        RequireSignIn() => '用户名或密码不正确，请重试。',
        SignInForbidden() => '该账号当前被限制登录，请联系管理员。',
        ServerUnavailable() => '无法连接到服务器，请检查网络或服务器状态。',
        UntrustedCertificate() => '服务器证书不受信任，请先信任自签名证书。',
        ApiClientError(:final error) => '登录失败：$error',
        _ => '登录失败，请检查用户名、密码和服务器权限。',
      };
      throw EmbyViewFailure(msg, code: 'sign_in_failed');
    }

    final switched = await _sessions.switchCurrentSession(
      serverId: server.id,
      userId: state.userId,
      username: username,
      password: rememberPassword ? password : null,
      validateToken: false,
    );
    if (!switched) {
      throw const EmbyViewFailure('已验证账号，但启动会话失败，请重试。', retryable: true);
    }
    if (!rememberPassword) {
      final otherStoredUsers = _serverUsers
          .getStoredServerUsers(server.id)
          .where((u) => u.id != state.userId);
      if (otherStoredUsers.isEmpty) {
        await _credentials?.deleteToken(server.id);
      }
    }
  }

  EvConnectedServer _toConnectedServer(Server server) => EvConnectedServer(
    id: server.id,
    name: server.name.isNotEmpty
        ? server.name
        : formatServerAddressForDisplay(server.address),
    address: server.address,
    version: server.version.isNotEmpty ? server.version : null,
  );

  ArtworkRef? _avatarFor(String baseUrl, String userId, String? imageTag) {
    if (imageTag == null || imageTag.isEmpty) return null;
    final cleanBase = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final url = '$cleanBase/Users/$userId/Images/Primary?tag=$imageTag';
    return _LoginAvatarRef(id: 'user_$userId', url: url);
  }

  static Future<String> _fetchCertificateSha256(String address) async {
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty) return '无法获取证书指纹';
    final port = uri.hasPort ? uri.port : 443;
    X509Certificate? captured;
    try {
      final socket = await SecureSocket.connect(
        uri.host,
        port,
        timeout: const Duration(seconds: 4),
        onBadCertificate: (cert) {
          captured = cert;
          return false;
        },
      );
      await socket.close();
    } catch (_) {
      // Expected: handshake aborts when onBadCertificate returns false.
    }
    final der = captured?.der;
    if (der == null || der.isEmpty) return '（未能读取证书 SHA-256 指纹）';
    final digest = sha256.convert(der);
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  static String _formatFailureReason(ServerUnableToConnect? fail) {
    final errType = (fail?.lastErrorType ?? '').toLowerCase();
    final msg = (fail?.lastErrorMessage ?? '').toLowerCase();
    if (errType.contains('timeout') || msg.contains('timed out')) {
      return '5 秒没有回应。确认 NAS 已开机、地址和端口没写错（Emby 默认 8096，HTTPS 是 8920）。';
    }
    if (msg.contains('failed host lookup') || msg.contains('nodename')) {
      return '找不到这个主机名。请检查地址拼写或网络连接（Emby 默认 8096，HTTPS 是 8920）。';
    }
    if (msg.contains('refused') ||
        msg.contains('errno = 61') ||
        msg.contains('errno = 111')) {
      return '服务器拒绝连接。请确认 Emby 服务已运行，且端口没写错（Emby 默认 8096，HTTPS 是 8920）。';
    }
    return '无法连接服务器。请确认 NAS 已开机、地址和端口没写错（Emby 默认 8096，HTTPS 是 8920）。';
  }
}

class _LoginAvatarRef implements ArtworkRef {
  _LoginAvatarRef({required this.id, required String url})
    : cacheKey = url,
      image = NetworkImage(url);

  @override
  final String id;
  @override
  final String cacheKey;
  @override
  final ImageProvider<Object> image;
  @override
  double? get aspectRatio => 1.0;
  @override
  int? get width => null;
  @override
  int? get height => null;
}
