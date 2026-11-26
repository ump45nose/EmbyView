import 'common.dart';
import 'media.dart';

enum AccountPhase {
  restoring,
  choosing,
  signingIn,
  switching,
  signedIn,
  signedOut,
}

enum ConnectionState { unknown, connected, disconnected }

enum ConnectionNoticeKind { switched, offline, recovered }

/// A single configured server endpoint ordered by connection preference.
class ServerAddressEntry {
  const ServerAddressEntry({
    required this.id,
    required this.url,
    this.label = '',
    this.subtitle = '',
  });

  final String id;
  final String url;
  final String label;
  final String subtitle;

  ServerAddressEntry copyWith({
    String? id,
    String? url,
    String? label,
    String? subtitle,
  }) => ServerAddressEntry(
    id: id ?? this.id,
    url: url ?? this.url,
    label: label ?? this.label,
    subtitle: subtitle ?? this.subtitle,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ServerAddressEntry &&
          other.id == id &&
          other.url == url &&
          other.label == label &&
          other.subtitle == subtitle);

  @override
  int get hashCode => Object.hash(id, url, label, subtitle);
}

/// Validates and normalizes an Emby server address string.
/// Accepts explicit `http://` / `https://` or bare `host[:port]` (defaulting to `http://`).
Uri? parseEmbyServerAddress(String raw) {
  final trimmed = raw.trim().replaceFirst(RegExp(r'/+$'), '');
  if (trimmed.isEmpty || RegExp(r'[\s\\]').hasMatch(trimmed)) return null;
  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed);
  final candidate = hasScheme ? trimmed : 'http://$trimmed';
  try {
    final uri = Uri.parse(candidate);
    if (!['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

/// Formats an Emby address for compact UI display (drops `http://`, keeps `https://`).
String formatServerAddressForDisplay(String raw) {
  final trimmed = raw.trim().replaceFirst(RegExp(r'/+$'), '');
  if (trimmed.toLowerCase().startsWith('http://')) {
    return trimmed.substring('http://'.length);
  }
  return trimmed;
}

/// Infers a short Chinese network label for an address when none is specified.
String inferServerAddressLabel(String raw) {
  final uri = parseEmbyServerAddress(raw);
  final host = (uri?.host ?? raw).toLowerCase();
  if (host.endsWith('.ts.net') || _isTailscaleCgnat(host)) {
    return 'Tailscale';
  }
  if (host == 'localhost' ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host.startsWith('127.') ||
      host.startsWith('192.168.') ||
      host.startsWith('10.') ||
      _isPrivate172(host)) {
    return '内网';
  }
  return '远程';
}

/// Infers a short subtitle for an auto-migrated server address.
String inferServerAddressSubtitle(String raw) {
  return switch (inferServerAddressLabel(raw)) {
    '内网' => '在家时用',
    'Tailscale' => '出门时自动换到这里',
    _ => '公网访问地址',
  };
}

bool _isTailscaleCgnat(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}

bool _isPrivate172(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  return a == 172 && b != null && b >= 16 && b <= 31;
}

/// Connection notice emitted when failover switches addresses, goes offline, or recovers.
class ConnectionNoticeEvent {
  const ConnectionNoticeEvent.switched({
    this.serverName,
    this.fromLabel,
    this.toLabel,
    required String this.activeAddress,
    this.triedAddressCount = 0,
  }) : kind = ConnectionNoticeKind.switched;

  const ConnectionNoticeEvent.offline({
    this.serverName,
    this.triedAddressCount = 0,
  }) : kind = ConnectionNoticeKind.offline,
       fromLabel = null,
       toLabel = null,
       activeAddress = null;

  const ConnectionNoticeEvent.recovered({
    this.serverName,
    this.toLabel,
    this.activeAddress,
  }) : kind = ConnectionNoticeKind.recovered,
       fromLabel = null,
       triedAddressCount = 0;

  final ConnectionNoticeKind kind;
  final String? serverName;
  final String? fromLabel;
  final String? toLabel;
  final String? activeAddress;
  final int triedAddressCount;
}

class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.displayName,
    this.avatar,
    this.serverId,
    this.hasPassword,
    this.visibleLibraryCount,
    this.lastUsedAt,
    this.lastUsedLabel,
  });

  final String id;
  final String displayName;
  final ArtworkRef? avatar;
  final String? serverId;
  final bool? hasPassword;
  final int? visibleLibraryCount;
  final DateTime? lastUsedAt;
  final String? lastUsedLabel;
}

class AccountSnapshot {
  const AccountSnapshot({
    required this.phase,
    this.current,
    this.profiles = const [],
    this.serverName,
    this.serverAddress,
    this.activeAddress,
    this.addresses = const [],
    this.serverVersion,
    this.latencyMs,
    this.triedAddressCount = 0,
    this.connection = ConnectionState.unknown,
    this.sessionId,
    this.failure,
  });

  final AccountPhase phase;
  final AccountProfile? current;
  final List<AccountProfile> profiles;
  final String? serverName;
  final String? serverAddress;
  final ServerAddressEntry? activeAddress;
  final List<ServerAddressEntry> addresses;
  final String? serverVersion;
  final int? latencyMs;
  final int triedAddressCount;
  final ConnectionState connection;

  /// Opaque authorization identity; changes after a new login or user switch.
  final String? sessionId;
  final EmbyViewFailure? failure;
}

abstract interface class EmbyViewAccounts {
  AccountSnapshot get snapshot;
  Stream<AccountSnapshot> get changes;
  Stream<ConnectionNoticeEvent> get connectionNotices;
  Future<void> restore();
  Future<void> signIn(Uri server, String username, String password);
  Future<void> switchTo(String profileId, {String? password});
  Future<void> signOut();
  Future<void> removeLocalAccount(String profileId);
  Future<void> removeCurrentServer();
  Future<Uri?> probeAndFailover({Duration timeout = const Duration(seconds: 5)});
  Future<void> retryConnection();
  Future<void> setServerAddresses(List<ServerAddressEntry> entries);
  Future<void> addServerAddress(ServerAddressEntry entry);
  Future<void> updateServerAddress(ServerAddressEntry entry);
  Future<void> removeServerAddress(String addressId);
  Future<void> reorderServerAddresses(List<String> addressIds);
  Future<void> activateServerAddress(String addressId);
}
