import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/shell/ev_scope.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

const _kCinemaGradients = [
  [Color(0xFF7C8CFF), Color(0xFFC86BFF)],
  [Color(0xFFFFB26B), Color(0xFFFF6B8B)],
  [Color(0xFF58D6B0), Color(0xFF3C9CFF)],
];
const _kPaperFills = [Color(0xFFD97757), Color(0xFF6A9BCC), Color(0xFFBCD1CA)];

int _slotFor(AccountProfile? p, int? explicit) {
  if (explicit != null) return explicit.abs() % 3;
  final id = p?.id ?? '';
  if (id.isEmpty || id == 'sfw') return 0;
  var h = 0;
  for (final c in id.codeUnits) { h = (h * 31 + c) & 0x7fffffff; }
  return h % 3;
}

/// Circular avatar button (`.avatar`): paper theme uses `EvIcons.faceFor`;
/// cinema theme uses user photo or gradient initial circle.
class EvAvatarButton extends StatefulWidget {
  const EvAvatarButton({
    super.key, this.profile, this.size, this.colorIndex,
    this.menuOpen = false, this.focusNode, this.onTap,
  });
  final AccountProfile? profile;
  final double? size;
  final int? colorIndex;
  final bool menuOpen;
  final FocusNode? focusNode;
  final VoidCallback? onTap;

  @override
  State<EvAvatarButton> createState() => _EvAvatarButtonState();
}

class _EvAvatarButtonState extends State<EvAvatarButton> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final d = widget.size ?? scale.rem(2.5), slot = _slotFor(widget.profile, widget.colorIndex);
    final isPaper = theme.isPaper;
    final name = widget.profile?.displayName.trim() ?? '';
    final init = name.isEmpty ? 'U' : name.characters.first.toUpperCase();

    Widget initialText() => Text(init, style: theme.bodyStyle(d * 0.42, fontWeight: FontWeight.w600, color: const Color(0xFFFFFFFF)));
    final Widget content = isPaper
        ? EvIcon(EvIcons.faceFor(widget.profile?.id ?? 'sfw'), size: d * 0.92, color: const Color(0xFF141413), forcePaper: true)
        : widget.profile?.avatar != null
        ? Image(image: widget.profile!.avatar!.image, fit: BoxFit.cover, width: d, height: d, errorBuilder: (_, _, _) => initialText())
        : initialText();

    final circle = Container(
      width: d, height: d, clipBehavior: Clip.antiAlias, alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isPaper ? _kPaperFills[slot] : null,
        gradient: isPaper ? null : LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _kCinemaGradients[slot]),
        border: Border.all(color: isPaper ? const Color(0xFF141413) : const Color.fromRGBO(255, 255, 255, 0.25), width: isPaper ? 1.5 : 1.0),
        boxShadow: isPaper ? null : const [BoxShadow(offset: Offset(0, 4), blurRadius: 16, color: Color.fromRGBO(0, 0, 0, 0.25))],
      ),
      child: content,
    );

    if (widget.onTap == null) return circle;
    return Semantics(
      button: true, focused: _focused, label: '用户',
      child: Focus(
        focusNode: widget.focusNode, onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) { if (!evIsActivateKey(e)) return KeyEventResult.ignored; widget.onTap!(); return KeyEventResult.handled; },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: widget.onTap,
            child: AnimatedScale(scale: (_hovered || _focused || widget.menuOpen) ? 1.08 : 1.0,
                duration: EvDurations.normal, curve: EvCurves.spring, child: circle),
          ),
        ),
      ),
    );
  }
}

/// Frosted glass account popover menu mirroring `#usermenu.menu.glass`.
class EvAvatarMenu extends StatelessWidget {
  const EvAvatarMenu({
    super.key,
    required this.accounts,
    this.onSelectProfile,
    this.onSwitchUsers,
    this.onManageZones,
    this.onOpenSettings,
    this.onSignOut,
    this.onDismiss,
  });
  final EmbyViewAccounts accounts;
  final ValueChanged<AccountProfile>? onSelectProfile;
  final VoidCallback? onSwitchUsers, onManageZones, onOpenSettings, onSignOut, onDismiss;

  Widget _divider(EvTheme theme, EvScale scale) => Padding(
    padding: EdgeInsets.symmetric(horizontal: scale.rem(0.5), vertical: scale.rem(0.375)),
    child: SizedBox(height: 1, child: ColoredBox(color: theme.line)),
  );

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final signOutCallback = onSignOut ?? EvScope.maybeOf(context)?.shell.onSignedOutToUserPicker;
    return StreamBuilder<AccountSnapshot>(
      stream: accounts.changes,
      initialData: accounts.snapshot,
      builder: (context, snap) {
        final state = snap.data ?? accounts.snapshot, current = state.current;
        final profiles = <AccountProfile>[
          ...state.profiles,
          if (current != null && state.profiles.every((p) => p.id != current.id)) current,
        ];
        final serverTitle = (state.serverName?.trim().isNotEmpty ?? false)
            ? state.serverName!.trim()
            : 'Emby 服务器';
        final rawAddr = state.activeAddress?.url ?? state.serverAddress ?? '';
        final displayAddr = formatServerAddressForDisplay(rawAddr);
        final connLabel = switch (state.connection) {
          ConnectionState.connected => '已连接',
          ConnectionState.disconnected => '已断开',
          ConnectionState.unknown => displayAddr.isEmpty ? '未连接' : '已连接',
        };
        final serverSub = displayAddr.isNotEmpty ? '$displayAddr · $connLabel' : connLabel;

        return SizedBox(
          width: scale.rem(15.5),
          child: EvGlass(
            key: const Key('ev_avatar_menu'),
            borderRadius: BorderRadius.circular(scale.rem(1.0)),
            padding: EdgeInsets.all(scale.rem(0.375)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  key: const Key('ev_avatar_menu_server_header'),
                  padding: EdgeInsets.fromLTRB(
                    scale.rem(0.75),
                    scale.rem(0.625),
                    scale.rem(0.75),
                    scale.rem(0.5),
                  ),
                  child: Row(
                    children: [
                      EvIcon(EvIcons.server, size: scale.rem(1.125), color: theme.ink3),
                      SizedBox(width: scale.rem(0.75)),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              serverTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.bodyStyle(
                                scale.font(0.9375),
                                fontWeight: FontWeight.w600,
                                color: theme.ink,
                              ),
                            ),
                            SizedBox(height: scale.rem(0.125)),
                            Text(
                              serverSub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.bodyStyle(scale.font(0.8125), color: theme.ink3),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _divider(theme, scale),
                if (profiles.isNotEmpty) ...[
                  for (var i = 0; i < profiles.length; i++)
                    _EvMenuItem(
                      key: Key('ev_avatar_menu_profile_${profiles[i].id}'),
                      leading: EvAvatarButton(profile: profiles[i], size: scale.rem(1.75), colorIndex: i),
                      label: profiles[i].displayName,
                      trailing: current?.id == profiles[i].id
                          ? EvIcon(EvIcons.check, size: scale.rem(1.0), color: theme.ink)
                          : null,
                      onTap: () {
                        final target = profiles[i];
                        onDismiss?.call();
                        if (onSelectProfile != null) {
                          onSelectProfile!(target);
                        } else if (current?.id != target.id) {
                          unawaited(accounts.switchTo(target.id));
                        }
                      },
                    ),
                  _divider(theme, scale),
                ],
                _EvMenuItem(
                  key: const Key('ev_avatar_menu_users'),
                  leading: EvIcon(EvIcons.users, size: scale.rem(1.125), color: theme.ink),
                  label: '切换用户…',
                  onTap: () {
                    onDismiss?.call();
                    onSwitchUsers?.call();
                  },
                ),
                if (onManageZones != null)
                  _EvMenuItem(
                    key: const Key('ev_avatar_menu_zones'),
                    leading: EvIcon(EvIcons.zones, size: scale.rem(1.125), color: theme.ink),
                    label: '分区',
                    onTap: () {
                      onDismiss?.call();
                      onManageZones?.call();
                    },
                  ),
                _EvMenuItem(
                  key: const Key('ev_avatar_menu_settings'),
                  leading: EvIcon(EvIcons.gear, size: scale.rem(1.125), color: theme.ink),
                  label: '设置',
                  shortcut: '⌘ ,',
                  onTap: () {
                    onDismiss?.call();
                    onOpenSettings?.call();
                  },
                ),
                _divider(theme, scale),
                _EvMenuItem(
                  key: const Key('ev_avatar_menu_logout'),
                  leading: EvIcon(EvIcons.logout, size: scale.rem(1.125), color: theme.ink),
                  label: '退出登录',
                  onTap: () {
                    onDismiss?.call();
                    unawaited(() async {
                      try {
                        await accounts.signOut();
                      } finally {
                        signOutCallback?.call();
                      }
                    }());
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EvMenuItem extends StatefulWidget {
  const _EvMenuItem({super.key, required this.leading, required this.label, this.shortcut, this.trailing, required this.onTap});
  final Widget leading;
  final String label;
  final String? shortcut;
  final Widget? trailing;
  final VoidCallback onTap;
  @override
  State<_EvMenuItem> createState() => _EvMenuItemState();
}

class _EvMenuItemState extends State<_EvMenuItem> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    return Semantics(
      button: true, label: widget.label,
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) { if (!evIsActivateKey(e)) return KeyEventResult.ignored; widget.onTap(); return KeyEventResult.handled; },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150), curve: EvCurves.soft,
              padding: EdgeInsets.symmetric(horizontal: scale.rem(0.75), vertical: scale.rem(0.6875)),
              decoration: BoxDecoration(
                color: (_hovered || _focused) ? theme.fill2 : const Color(0x00000000),
                borderRadius: BorderRadius.circular(scale.rem(0.625)),
              ),
              child: Row(
                children: [
                  widget.leading, SizedBox(width: scale.rem(0.75)),
                  Expanded(child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w500, color: theme.ink))),
                  if (widget.shortcut != null) Text(widget.shortcut!, style: theme.bodyStyle(scale.font(0.8125), color: theme.ink3)),
                  if (widget.trailing != null) widget.trailing!,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
