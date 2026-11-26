import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Startup splash screen ported from `vSplash` in `.spec/mockups/proto.js` and
/// `.splash` / `.sbar` in `.spec/mockups/proto.css`.
///
/// Renders [EvBrandBackground], centered [EvAppIcon], `EmbyView` wordmark,
/// animated thin indeterminate progress bar, and connection status copy in both
/// cinema and paper themes.
class EvSplashPage extends StatefulWidget {
  const EvSplashPage({
    super.key,
    this.statusText,
    this.serverName,
    this.darkIcon = false,
  });

  /// Explicit status message. Overrides [serverName] when provided.
  final String? statusText;

  /// Server name shown in `正在连接<serverName>…`. Defaults to `家里的 Emby` when
  /// both [statusText] and [serverName] are null.
  final String? serverName;

  /// Whether to render the dark appearance variant of [EvAppIcon].
  final bool darkIcon;

  @override
  State<EvSplashPage> createState() => _EvSplashPageState();
}

class _EvSplashPageState extends State<EvSplashPage>
    with TickerProviderStateMixin {
  late final AnimationController _enterCtrl;
  AnimationController? _barCtrl;

  String get _effectiveStatus {
    final explicit = widget.statusText?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (widget.serverName == null) return '正在连接家里的 Emby…';
    final server = widget.serverName!.trim();
    return server.isEmpty ? '正在连接 Emby…' : '正在连接$server…';
  }

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  void _syncAnimations(bool disableAnimations) {
    if (disableAnimations) {
      _enterCtrl.value = 1.0;
      _barCtrl?.dispose();
      _barCtrl = null;
    } else {
      if (_enterCtrl.status == AnimationStatus.dismissed) {
        _enterCtrl.forward();
      }
      _barCtrl ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      )..repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimations(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _barCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);

    final iconAnim = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.0, 0.82, curve: EvCurves.spring),
    );
    final wordmarkAnim = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.14, 0.86, curve: EvCurves.out),
    );
    final footerAnim = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.27, 1.0, curve: EvCurves.out),
    );

    final barWidth = s.rem(10.0);

    return EvBrandBackground(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: iconAnim,
              builder: (_, child) => Opacity(
                opacity: iconAnim.value.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.8 + 0.2 * iconAnim.value,
                  child: child,
                ),
              ),
              child: EvAppIcon(
                key: const Key('ev_splash_icon'),
                size: s.rem(9.0),
                dark: widget.darkIcon,
              ),
            ),
            SizedBox(height: s.rem(1.0)),
            _RiseTransition(
              animation: wordmarkAnim,
              offsetY: s.rem(0.75),
              child: Text(
                'EmbyView',
                key: const Key('ev_splash_wordmark'),
                style: t.displayStyle(s.font(2.375)),
              ),
            ),
            SizedBox(height: s.rem(2.0)),
            _RiseTransition(
              animation: footerAnim,
              offsetY: s.rem(0.75),
              child: Container(
                key: const Key('ev_splash_progress'),
                width: barWidth,
                height: 3,
                decoration: BoxDecoration(
                  color: t.fill2,
                  borderRadius: BorderRadius.circular(2),
                ),
                clipBehavior: Clip.hardEdge,
                child: _barCtrl == null
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: barWidth * 0.4,
                          height: 3,
                          decoration: BoxDecoration(
                            color: t.ink,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      )
                    : AnimatedBuilder(
                        animation: _barCtrl!,
                        builder: (_, _) {
                          final v = EvCurves.soft.transform(_barCtrl!.value);
                          final segW = barWidth * 0.4;
                          final dx = (-1.0 + 3.5 * v) * segW;
                          return Transform.translate(
                            offset: Offset(dx, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: segW,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: t.ink,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            SizedBox(height: s.rem(1.0)),
            _RiseTransition(
              animation: footerAnim,
              offsetY: s.rem(0.75),
              child: Text(
                _effectiveStatus,
                key: const Key('ev_splash_status'),
                style: t.bodyStyle(s.font(0.9375), color: t.ink3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RiseTransition extends StatelessWidget {
  const _RiseTransition({
    required this.animation,
    required this.offsetY,
    required this.child,
  });

  final Animation<double> animation;
  final double offsetY;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (_, c) {
        final v = animation.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, offsetY * (1.0 - v)),
            child: c,
          ),
        );
      },
    );
  }
}
