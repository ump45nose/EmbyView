import 'package:flutter/foundation.dart';

/// Build-time version and commit metadata injected via `--dart-define`:
/// - `EMBYVIEW_VERSION` (e.g. `3.1.1`)
/// - `EMBYVIEW_COMMIT` (e.g. `615880f`)
@immutable
class EvBuildInfo {
  const EvBuildInfo({
    String? version,
    String? commit,
    this.upstreamBase = defaultUpstreamBase,
    this.license = defaultLicense,
    this.sourceRepoUrl = defaultSourceRepoUrl,
  }) : _rawVersion = version ?? _envVersion,
       _rawCommit = commit ?? _envCommit;

  /// Current build metadata resolved from compile-time environment defines.
  static const EvBuildInfo current = EvBuildInfo();

  static const String defaultVersion = '3.1.1';
  static const String defaultUpstreamBase = 'Moonfin 3.1.1';
  static const String defaultLicense = 'GPL-3.0';
  static const String defaultSourceRepoUrl = 'https://github.com/ump45nose/EmbyView';

  static const String _envVersion = String.fromEnvironment('EMBYVIEW_VERSION');
  static const String _envCommit = String.fromEnvironment('EMBYVIEW_COMMIT');

  final String _rawVersion;
  final String _rawCommit;

  /// Upstream project and version this client is based on.
  final String upstreamBase;

  /// Open-source license identifier.
  final String license;

  /// Public source repository URL.
  final String sourceRepoUrl;

  /// Effective semantic version string (falls back to [defaultVersion] when unset).
  String get version {
    final trimmed = _rawVersion.trim();
    return trimmed.isNotEmpty ? trimmed : defaultVersion;
  }

  /// Normalized short commit SHA, or empty string when not injected.
  String get commit {
    final trimmed = _rawCommit.trim();
    if (trimmed.isEmpty) return '';
    if (_hexCommitRe.hasMatch(trimmed) && trimmed.length > 7) {
      return trimmed.substring(0, 7);
    }
    return trimmed;
  }

  /// Display string for the About page (e.g. `版本 3.1.1（615880f）`).
  String get formattedVersion {
    final c = commit;
    return c.isNotEmpty ? '版本 $version（$c）' : '版本 $version';
  }

  static final RegExp _hexCommitRe = RegExp(r'^[0-9a-fA-F]+$');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EvBuildInfo &&
          version == other.version &&
          commit == other.commit &&
          upstreamBase == other.upstreamBase &&
          license == other.license &&
          sourceRepoUrl == other.sourceRepoUrl;

  @override
  int get hashCode => Object.hash(version, commit, upstreamBase, license, sourceRepoUrl);
}
