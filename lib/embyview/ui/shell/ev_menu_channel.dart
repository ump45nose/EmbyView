import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';

/// Canonical macOS system menu and global shortcut action identifiers.
abstract final class EvMenuAction {
  static const about = 'about';
  static const settings = 'settings';
  static const signOut = 'signOut';
  static const search = 'search';
  static const goHome = 'goHome';
  static const goZone1 = 'goZone1';
  static const goZone2 = 'goZone2';
  static const goZone3 = 'goZone3';
  static const goZone4 = 'goZone4';
  static const goZone5 = 'goZone5';
  static const commandPalette = 'commandPalette';
  static const back = 'back';

  static const playPause = 'playPause';
  static const seekBack10 = 'seekBack10';
  static const seekForward10 = 'seekForward10';
  static const nextEpisode = 'nextEpisode';
  static const subtitlePanel = 'subtitlePanel';
  static const aiSubtitle = 'aiSubtitle';
  static const toggleAnime4k = 'toggleAnime4k';
  static const toggleFullscreen = 'toggleFullscreen';

  static const shortcuts = 'shortcuts';
  static const exportDiagnostics = 'exportDiagnostics';

  static const List<String> zoneActions = [
    goZone1,
    goZone2,
    goZone3,
    goZone4,
    goZone5,
  ];

  static const List<String> playbackActions = [
    playPause,
    seekBack10,
    seekForward10,
    nextEpisode,
    subtitlePanel,
    aiSubtitle,
    toggleAnime4k,
    toggleFullscreen,
  ];

  static int? zoneIndexFor(String action) {
    final idx = zoneActions.indexOf(action);
    return idx >= 0 ? idx : null;
  }

  static bool isPlaybackAction(String action) =>
      playbackActions.contains(action);
}

/// Origin of a dispatched menu / shortcut action, used for cross-source deduplication.
enum EvMenuActionSource { menu, keyboard, programmatic }

/// Active player control hooks invoked by the macOS "播放" menu bar actions.
@immutable
class EvPlayerMenuDelegate {
  const EvPlayerMenuDelegate({
    required this.togglePlayPause,
    required this.seekBack10,
    required this.seekForward10,
    required this.nextEpisode,
    required this.toggleSubtitlePanel,
    required this.triggerAiSubtitle,
    required this.toggleAnime4k,
    required this.toggleFullscreen,
    this.closePlayer,
    this.isFailed,
  });

  final VoidCallback togglePlayPause;
  final VoidCallback seekBack10;
  final VoidCallback seekForward10;
  final VoidCallback nextEpisode;
  final VoidCallback toggleSubtitlePanel;
  final VoidCallback triggerAiSubtitle;
  final VoidCallback toggleAnime4k;
  final VoidCallback toggleFullscreen;
  final VoidCallback? closePlayer;
  final bool Function()? isFailed;

  bool dispatch(String action) {
    if (isFailed?.call() == true && action != EvMenuAction.toggleFullscreen) {
      return false;
    }
    switch (action) {
      case EvMenuAction.playPause:
        togglePlayPause();
        return true;
      case EvMenuAction.seekBack10:
        seekBack10();
        return true;
      case EvMenuAction.seekForward10:
        seekForward10();
        return true;
      case EvMenuAction.nextEpisode:
        nextEpisode();
        return true;
      case EvMenuAction.subtitlePanel:
        toggleSubtitlePanel();
        return true;
      case EvMenuAction.aiSubtitle:
        triggerAiSubtitle();
        return true;
      case EvMenuAction.toggleAnime4k:
        toggleAnime4k();
        return true;
      case EvMenuAction.toggleFullscreen:
        toggleFullscreen();
        return true;
      default:
        return false;
    }
  }
}

typedef EvMenuActionHandler = bool Function(
  String action,
  EvMenuActionSource source,
);

/// Bridges macOS native menu bar (`embyview/menu`) and app-level shortcut
/// dispatch to the currently active EmbyView shell, with cross-source
/// deduplication so native menu key equivalents and Flutter key handlers
/// never fire twice for the same keypress.
class EvMenuChannel {
  EvMenuChannel._();

  static final EvMenuChannel instance = EvMenuChannel._();
  static const String channelName = 'embyview/menu';
  static const MethodChannel _channel = MethodChannel(channelName);
  static const Duration defaultDedupeWindow = Duration(milliseconds: 180);

  bool _attached = false;
  EvMenuActionHandler? _handler;
  Object? _handlerToken;
  DateTime Function() _clock = DateTime.now;
  String? _lastAction;
  EvMenuActionSource? _lastSource;
  DateTime? _lastAt;

  void _ensureAttached() {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// Registers the active menu action receiver. Returns an opaque token used
  /// by [unregisterHandler] so stale shells cannot clear a newer binding.
  Object registerHandler(EvMenuActionHandler handler) {
    _ensureAttached();
    final token = Object();
    _handlerToken = token;
    _handler = handler;
    return token;
  }

  void unregisterHandler(Object token) {
    if (identical(_handlerToken, token)) {
      _handlerToken = null;
      _handler = null;
    }
  }

  bool get hasHandler => _handler != null;

  @visibleForTesting
  void configureClockForTesting(DateTime Function()? clock) {
    _clock = clock ?? DateTime.now;
    _lastAction = null;
    _lastSource = null;
    _lastAt = null;
  }

  bool _shouldDedupe(String action, EvMenuActionSource source) {
    if (source == EvMenuActionSource.programmatic) return false;
    final lastAt = _lastAt;
    if (lastAt == null || _lastAction != action || _lastSource == null) {
      return false;
    }
    if (_lastSource == source || _lastSource == EvMenuActionSource.programmatic) {
      return false;
    }
    return _clock().difference(lastAt) < defaultDedupeWindow;
  }

  /// Dispatches [action] to the currently registered shell handler.
  /// Returns `true` if handled or intentionally deduplicated.
  bool dispatchAction(
    String action, {
    EvMenuActionSource source = EvMenuActionSource.programmatic,
  }) {
    if (_shouldDedupe(action, source)) {
      return true;
    }
    if (source != EvMenuActionSource.programmatic) {
      _lastAction = action;
      _lastSource = source;
      _lastAt = _clock();
    }
    final handler = _handler;
    if (handler == null) return false;
    return handler(action, source);
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method != 'menuAction') return null;
    final args = call.arguments;
    final action = args is Map ? args['action']?.toString() : args?.toString();
    if (action == null || action.isEmpty) return false;
    return dispatchAction(action, source: EvMenuActionSource.menu);
  }

  /// Updates the native "前往" zone menu item titles (⌘2–⌘6) to reflect the
  /// active user's configured zones. Safe no-op outside macOS or in unit tests.
  Future<void> syncZones(List<ZoneTile> zones) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
    _ensureAttached();
    try {
      await _channel.invokeMethod<void>('updateZones', <String, Object>{
        'names': [for (final z in zones.take(5)) z.name],
      });
    } catch (_) {}
  }
}

/// Returns `true` when the primary focus is inside an [EditableText] field.
bool evIsTextInputFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Maps a hardware [KeyDownEvent] to an [EvMenuAction] identifier for EmbyView
/// browsing screens. Explicitly ignores `F1` (macOS brightness key) and suppresses
/// bare `?` while a text input is focused.
String? evResolveShellMenuAction(
  KeyEvent event, {
  required bool isEditingText,
  HardwareKeyboard? keyboard,
}) {
  if (event is! KeyDownEvent) return null;
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.f1) return null;

  final hw = keyboard ?? HardwareKeyboard.instance;
  final primary = hw.isMetaPressed || hw.isControlPressed;
  final alt = hw.isAltPressed;
  final shift = hw.isShiftPressed;

  if (key == LogicalKeyboardKey.escape) {
    return EvMenuAction.back;
  }

  if (primary && !alt) {
    if (key == LogicalKeyboardKey.comma) return EvMenuAction.settings;
    if (key == LogicalKeyboardKey.keyF) return EvMenuAction.search;
    if (key == LogicalKeyboardKey.bracketLeft) return EvMenuAction.back;
    if (key == LogicalKeyboardKey.slash || key == LogicalKeyboardKey.question) {
      return EvMenuAction.shortcuts;
    }
    if (!shift) {
      if (key == LogicalKeyboardKey.digit1) return EvMenuAction.goHome;
      if (key == LogicalKeyboardKey.digit2) return EvMenuAction.goZone1;
      if (key == LogicalKeyboardKey.digit3) return EvMenuAction.goZone2;
      if (key == LogicalKeyboardKey.digit4) return EvMenuAction.goZone3;
      if (key == LogicalKeyboardKey.digit5) return EvMenuAction.goZone4;
      if (key == LogicalKeyboardKey.digit6) return EvMenuAction.goZone5;
    }
  }

  if (!primary && !alt && !isEditingText) {
    final isQuestion = key == LogicalKeyboardKey.question ||
        event.character == '?' ||
        (key == LogicalKeyboardKey.slash && shift);
    if (isQuestion) {
      return EvMenuAction.shortcuts;
    }
  }

  return null;
}
