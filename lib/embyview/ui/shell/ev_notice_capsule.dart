import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Display mode for [EvNoticeCapsule].
enum EvNoticeKind { offline, switched }

/// Immutable state driving [EvNoticeCapsule], aligned with `notice()` in
/// `.spec/mockups/proto.js` L1584-1599.
@immutable
class EvNoticeState {
  const EvNoticeState.offline({
    this.serverName,
    this.initialCountdownSeconds = 8,
    this.retryIntervalSeconds = 10,
    this.triedAddressCount = 0,
    this.autoTick = true,
  }) : kind = EvNoticeKind.offline,
       message = null,
       autoDismissAfter = null;

  const EvNoticeState.switched({
    String? message,
    this.serverName,
    this.autoDismissAfter = const Duration(seconds: 8),
  }) : kind = EvNoticeKind.switched,
       message = message ?? defaultSwitchedMessage,
       initialCountdownSeconds = 0,
       retryIntervalSeconds = 0,
       triedAddressCount = 0,
       autoTick = false;

  static const String defaultServerName = '家里的 Emby';
  static const String defaultSwitchedMessage = '内网连不上，已换到 Tailscale 地址';

  factory EvNoticeState.fromConnectionEvent(ConnectionNoticeEvent event) {
    switch (event.kind) {
      case ConnectionNoticeKind.offline:
        return EvNoticeState.offline(
          serverName: event.serverName,
          triedAddressCount: event.triedAddressCount,
        );
      case ConnectionNoticeKind.switched:
        final from = event.fromLabel?.trim() ?? '';
        final to = event.toLabel?.trim() ?? '';
        final String msg;
        if (from.isNotEmpty && to.isNotEmpty) {
          msg = '$from连不上，已换到 $to 地址';
        } else if (to.isNotEmpty) {
          msg = '已换到 $to 地址';
        } else {
          msg = defaultSwitchedMessage;
        }
        return EvNoticeState.switched(
          message: msg,
          serverName: event.serverName,
        );
      case ConnectionNoticeKind.recovered:
        return EvNoticeState.switched(
          message: '已重新连接服务器',
          serverName: event.serverName,
          autoDismissAfter: const Duration(seconds: 4),
        );
    }
  }

  final EvNoticeKind kind;
  final String? serverName;
  final String? message;
  final int initialCountdownSeconds;
  final int retryIntervalSeconds;
  final int triedAddressCount;
  final bool autoTick;
  final Duration? autoDismissAfter;

  String get displayServerName {
    final trimmed = serverName?.trim() ?? '';
    return trimmed.isNotEmpty ? trimmed : defaultServerName;
  }

  String get displaySwitchedMessage {
    final trimmed = message?.trim() ?? '';
    return trimmed.isNotEmpty ? trimmed : defaultSwitchedMessage;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EvNoticeState &&
          other.kind == kind &&
          other.serverName == serverName &&
          other.message == message &&
          other.initialCountdownSeconds == initialCountdownSeconds &&
          other.retryIntervalSeconds == retryIntervalSeconds &&
          other.triedAddressCount == triedAddressCount &&
          other.autoTick == autoTick &&
          other.autoDismissAfter == autoDismissAfter);

  @override
  int get hashCode => Object.hash(
    kind,
    serverName,
    message,
    initialCountdownSeconds,
    retryIntervalSeconds,
    triedAddressCount,
    autoTick,
    autoDismissAfter,
  );
}

/// Centered frosted-glass notice pill positioned directly beneath [EvTopBar]
/// (`top: 5.25rem`, never overlapping the top bar), mirroring `.notice.glass`
/// in `.spec/mockups/proto.css` L1304-1315.
class EvNoticeCapsule extends StatefulWidget {
  const EvNoticeCapsule({
    super.key,
    required this.notice,
    this.onRetry,
    this.onOpenServerSettings,
    this.onDismiss,
  });

  final EvNoticeState notice;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenServerSettings;
  final VoidCallback? onDismiss;

  @override
  State<EvNoticeCapsule> createState() => _EvNoticeCapsuleState();
}

class _EvNoticeCapsuleState extends State<EvNoticeCapsule>
    with TickerProviderStateMixin {
  late final AnimationController _enter;
  late final CurvedAnimation _fade, _slide;
  late final AnimationController _pulse;
  Timer? _tickTimer;
  Timer? _dismissTimer;
  late int _countdown;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..forward();
    _fade = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.0, 0.64, curve: EvCurves.soft),
    );
    _slide = CurvedAnimation(parent: _enter, curve: EvCurves.spring);
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _configureForNotice();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _enter.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(EvNoticeCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notice != widget.notice) {
      _configureForNotice();
    }
  }

  void _configureForNotice() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _dismissTimer?.cancel();
    _dismissTimer = null;

    final notice = widget.notice;
    if (notice.kind == EvNoticeKind.offline) {
      _countdown = notice.initialCountdownSeconds > 0
          ? notice.initialCountdownSeconds
          : 8;
      if (!_pulse.isAnimating) {
        _pulse.repeat();
      }
      if (notice.autoTick) {
        _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          if (_countdown > 1) {
            setState(() => _countdown--);
          } else {
            final resetTo = notice.retryIntervalSeconds > 0
                ? notice.retryIntervalSeconds
                : 10;
            setState(() => _countdown = resetTo);
            widget.onRetry?.call();
          }
        });
      }
    } else {
      _countdown = 0;
      if (_pulse.isAnimating) _pulse.stop();
      final dismissAfter = notice.autoDismissAfter;
      if (dismissAfter != null) {
        _dismissTimer = Timer(dismissAfter, () {
          if (mounted) widget.onDismiss?.call();
        });
      }
    }
  }

  void _handleRetryTap() {
    final resetTo = widget.notice.retryIntervalSeconds > 0
        ? widget.notice.retryIntervalSeconds
        : 10;
    setState(() => _countdown = resetTo);
    widget.onRetry?.call();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _dismissTimer?.cancel();
    _fade.dispose();
    _slide.dispose();
    _enter.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final notice = widget.notice;
    final isSwitched = notice.kind == EvNoticeKind.switched;

    final dotColor = isSwitched
        ? (t.isPaper ? const Color(0xFF5F8A4E) : const Color(0xFF34C759))
        : (t.isPaper ? const Color(0xFFD97757) : const Color(0xFFFFB547));

    final dotSize = s.rem(0.5);
    final Widget dot = isSwitched
        ? Container(
            key: const Key('ev_notice_dot_ok'),
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          )
        : AnimatedBuilder(
            animation: _pulse,
            builder: (_, _) {
              final progress = _pulse.value;
              final spread = progress < 0.7 ? (progress / 0.7) * s.rem(0.5) : s.rem(0.5);
              final alpha = progress < 0.7 ? 0.55 * (1.0 - progress / 0.7) : 0.0;
              return Container(
                key: const Key('ev_notice_dot_offline'),
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: alpha > 0
                      ? [
                          BoxShadow(
                            color: dotColor.withValues(alpha: alpha),
                            spreadRadius: spread,
                            blurRadius: 0,
                          ),
                        ]
                      : null,
                ),
              );
            },
          );

    final padding = EdgeInsets.fromLTRB(
      s.rem(1.125),
      s.rem(0.375),
      isSwitched ? s.rem(1.25) : s.rem(0.375),
      s.rem(0.375),
    );

    final pill = EvGlass(
      key: Key(isSwitched ? 'ev_notice_switched' : 'ev_notice_offline'),
      borderRadius: BorderRadius.circular(999),
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          SizedBox(width: s.rem(0.75)),
          if (isSwitched)
            Text(
              notice.displaySwitchedMessage,
              key: const Key('ev_notice_message'),
              maxLines: 1,
              softWrap: false,
              style: t.bodyStyle(
                s.font(0.9375),
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            )
          else ...[
            Text(
              '连不上${notice.displayServerName}',
              key: const Key('ev_notice_title'),
              maxLines: 1,
              softWrap: false,
              style: t.bodyStyle(
                s.font(0.9375),
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            SizedBox(width: s.rem(0.375)),
            Text(
              '· $_countdown 秒后重试',
              key: const Key('ev_notice_countdown'),
              maxLines: 1,
              softWrap: false,
              style: t
                  .bodyStyle(s.font(0.9375), color: t.ink3)
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            SizedBox(width: s.rem(0.75)),
            _NoticePillButton(
              key: const Key('ev_notice_retry'),
              label: '立即重试',
              primary: true,
              onPressed: _handleRetryTap,
            ),
            SizedBox(width: s.rem(0.5)),
            _NoticePillButton(
              key: const Key('ev_notice_server_settings'),
              label: '服务器设置',
              primary: false,
              onPressed: widget.onOpenServerSettings,
            ),
          ],
        ],
      ),
    );

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: s.rem(5.25)),
        child: FadeTransition(
          opacity: _fade,
          child: AnimatedBuilder(
            animation: _slide,
            builder: (_, child) => Transform.translate(
              offset: Offset(0, -s.rem(0.75) * (1.0 - _slide.value)),
              child: child,
            ),
            child: Semantics(
              liveRegion: true,
              child: pill,
            ),
          ),
        ),
      ),
    );
  }
}

class _NoticePillButton extends StatefulWidget {
  const _NoticePillButton({
    super.key,
    required this.label,
    required this.primary,
    this.onPressed,
  });

  final String label;
  final bool primary;
  final VoidCallback? onPressed;

  @override
  State<_NoticePillButton> createState() => _NoticePillButtonState();
}

class _NoticePillButtonState extends State<_NoticePillButton> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final hi = _hovered || _focused;
    final radius = BorderRadius.circular(t.isPaper ? s.rem(0.625) : 999.0);
    final Color bg;
    final Color fg;
    Color? border;
    if (widget.primary) {
      fg = t.priFg;
      bg = hi && t.isPaper ? const Color(0xFF9F4829) : t.priBg;
    } else if (t.isPaper) {
      fg = t.ink;
      bg = hi ? const Color(0xFFF0EEE6) : const Color(0xFFFFFFFF);
      border = const Color(0xFFD1CFC5);
    } else {
      fg = t.ink;
      bg = hi ? t.fill3 : t.glass;
      border = t.glassBorder;
    }
    return Semantics(
      button: true,
      enabled: widget.onPressed != null,
      label: widget.label,
      child: Focus(
        canRequestFocus: widget.onPressed != null,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (widget.onPressed == null || !evIsActivateKey(e)) {
            return KeyEventResult.ignored;
          }
          widget.onPressed!();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: widget.onPressed != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: EvDurations.fast,
              curve: EvCurves.soft,
              height: s.rem(2.125),
              padding: EdgeInsets.symmetric(horizontal: s.rem(0.875)),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: radius,
                border: border != null
                    ? Border.all(color: border, width: 1)
                    : null,
              ),
              child: Text(
                widget.label,
                maxLines: 1,
                softWrap: false,
                style: t.bodyStyle(
                  s.font(0.875),
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
