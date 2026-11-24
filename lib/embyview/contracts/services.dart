import 'accounts.dart';
import 'media.dart';
import 'playback.dart';
import 'preferences.dart';
import 'subtitles.dart';

/// A single account binding. Read a new value after accounts.changes emits.
class EmbyViewServices {
  const EmbyViewServices({
    required this.preferences,
    required this.accounts,
    this.sessionId,
    this.data,
    this.playback,
    this.immersion,
    this.subtitles,
  });

  final EmbyViewPreferences preferences;
  final EmbyViewAccounts accounts;
  final String? sessionId;
  final EmbyViewData? data;
  final EmbyViewPlayback? playback;
  final ImmersionPlayback? immersion;

  /// Null until stage two registers this capability, or while signed out.
  final EmbyViewSubtitles? subtitles;

  bool get signedIn => sessionId != null && data != null;
}
