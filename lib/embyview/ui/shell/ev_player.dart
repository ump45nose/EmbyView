import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/shell/ev_scope.dart';
import 'package:moonfin/embyview/ui/stage/immersion.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// External player page builder registered by stage five on [EvPlayer.pageBuilder].
/// Returning `null` falls back to the built-in minimal player page with Back/Esc exit.
typedef EvPlayerPageBuilder = Widget? Function(
  BuildContext context, PlaybackSession session, {Rect? origin, CardArtwork? art}
);

/// Single playback entry point used by browse, detail, and search pages.
abstract final class EvPlayer {
  static EvPlayerPageBuilder? pageBuilder;
  static bool _isOpening = false;
  static bool get isOpening => _isOpening;

  /// Opens [target], pauses [Immersion], pushes the player route, and guarantees
  /// closing the [PlaybackSession] and resuming immersion when returning or failing.
  static Future<void> open(
    BuildContext context, PlayTarget target, {
    Rect? origin, CardArtwork? art,
    EmbyViewPlayback? playback, Immersion? immersion, EvPlayerPageBuilder? builder,
  }) async {
    if (_isOpening) return;
    final scope = EvScope.maybeOf(context);
    final resolvedPlayback = playback ?? scope?.services.playback;
    final resolvedImmersion = immersion ?? scope?.immersion;
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (resolvedPlayback == null || navigator == null) return;

    _isOpening = true;
    PlaybackSession? session;
    var entered = false;
    try {
      resolvedImmersion?.enterPlayer();
      entered = resolvedImmersion != null;
      session = resolvedPlayback.open(target);
      final active = session;
      final customBuilder = builder ?? pageBuilder;
      await navigator.push<void>(PageRouteBuilder<void>(
        opaque: true, barrierColor: const Color(0xFF000000),
        transitionDuration: EvDurations.normal, reverseTransitionDuration: EvDurations.normal,
        pageBuilder: (ctx, _, _) =>
            customBuilder?.call(ctx, active, origin: origin, art: art) ??
            _defaultPage(ctx, active, origin: origin, art: art),
        transitionsBuilder: (_, anim, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: EvCurves.soft), child: child,
        ),
      ));
    } finally {
      try { await session?.close(); } catch (_) {}
      if (entered) resolvedImmersion?.exitPlayer();
      _isOpening = false;
    }
  }

  static Widget _defaultPage(BuildContext context, PlaybackSession session, {Rect? origin, CardArtwork? art}) {
    final scale = EvScale.of(context);
    final theme = EvTheme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          key: const Key('ev_minimal_player_page'), color: const Color(0xFF000000),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: session.videoSurface()),
              Positioned(
                left: scale.rem(5.75), top: scale.rem(0.875),
                child: EvOnImage(
                  child: Semantics(
                    button: true, label: '返回',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        key: const Key('ev_player_close'), behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).maybePop(),
                        child: EvGlass(
                          borderRadius: BorderRadius.circular(999),
                          child: SizedBox(
                            width: scale.rem(2.5), height: scale.rem(2.5),
                            child: Center(
                              child: EvIcon(EvIcons.left, size: scale.rem(1.125),
                                  color: theme.isPaper ? const Color(0xFFFAF9F5) : const Color(0xFFF5F5F7)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
