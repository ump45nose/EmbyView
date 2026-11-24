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

class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.displayName,
    this.avatar,
    this.serverId,
  });

  final String id;
  final String displayName;
  final ArtworkRef? avatar;
  final String? serverId;
}

class AccountSnapshot {
  const AccountSnapshot({
    required this.phase,
    this.current,
    this.profiles = const [],
    this.serverAddress,
    this.serverVersion,
    this.connection = ConnectionState.unknown,
    this.sessionId,
    this.failure,
  });

  final AccountPhase phase;
  final AccountProfile? current;
  final List<AccountProfile> profiles;
  final String? serverAddress;
  final String? serverVersion;
  final ConnectionState connection;

  /// Opaque authorization identity; changes after a new login or user switch.
  final String? sessionId;
  final EmbyViewFailure? failure;
}

abstract interface class EmbyViewAccounts {
  AccountSnapshot get snapshot;
  Stream<AccountSnapshot> get changes;
  Future<void> restore();
  Future<void> signIn(Uri server, String username, String password);
  Future<void> switchTo(String profileId, {String? password});
  Future<void> signOut();
}
