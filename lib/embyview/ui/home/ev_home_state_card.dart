import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Centered full-viewport state card with calm brand background for `home:empty`
/// (account with 0 visible libraries) and `home:error` (no cached home data and
/// server unreachable), mirroring `vHomeG` in `.spec/mockups/proto.js` and
/// `.brandbg.calm` / `.hstate` / `.scard` in `.spec/mockups/proto.css`.
class EvHomeStateCard extends StatefulWidget {
  const EvHomeStateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.meta,
    required this.actions,
    this.animate = true,
  });

  factory EvHomeStateCard.empty({
    Key? key = const Key('ev_home_empty'),
    required String username,
    VoidCallback? onRecheck,
    VoidCallback? onSwitchUser,
    bool animate = true,
  }) {
    final displayUser = username.trim().isNotEmpty ? username.trim() : '当前用户';
    return EvHomeStateCard(
      key: key,
      icon: EvIcons.lock,
      title: '这个账号还看不到片库',
      description:
          '服务器上的「$displayUser」还没有开放任何片库。请管理员在 Emby 网页后台打开「用户 → $displayUser → 媒体库访问」，勾选要开放的片库，再回来点「重新检查」。',
      animate: animate,
      actions: [
        EvButton.primary(
          key: const Key('ev_home_empty_recheck'),
          small: true,
          icon: EvIcons.refresh,
          label: '重新检查',
          onPressed: onRecheck,
        ),
        EvButton.ghost(
          key: const Key('ev_home_empty_switch_user'),
          small: true,
          icon: EvIcons.users,
          label: '切换用户',
          onPressed: onSwitchUser,
        ),
      ],
    );
  }

  factory EvHomeStateCard.error({
    Key? key = const Key('ev_home_error'),
    String? serverName,
    int triedAddressCount = 1,
    int retryIntervalSeconds = 10,
    VoidCallback? onRetry,
    VoidCallback? onServerSettings,
    VoidCallback? onSwitchUser,
    bool animate = true,
  }) {
    final name = (serverName ?? '').trim().isNotEmpty ? serverName!.trim() : '家里的 Emby';
    final count = triedAddressCount > 0 ? triedAddressCount : 1;
    final interval = retryIntervalSeconds > 0 ? retryIntervalSeconds : 10;
    return EvHomeStateCard(
      key: key,
      icon: EvIcons.nowifi,
      title: '连不上$name',
      description: '内网地址和备用地址都没有回应。NAS 可能在睡眠、断网，或者 Emby 服务没在运行。',
      meta: '已试 $count 个地址 · 每 $interval 秒自动重试一次',
      animate: animate,
      actions: [
        EvButton.primary(
          key: const Key('ev_home_retry_btn'),
          small: true,
          icon: EvIcons.refresh,
          label: '立即重试',
          onPressed: onRetry,
        ),
        EvButton.ghost(
          key: const Key('ev_home_error_settings'),
          small: true,
          icon: EvIcons.server,
          label: '服务器设置',
          onPressed: onServerSettings,
        ),
        EvButton.ghost(
          key: const Key('ev_home_error_switch_user'),
          small: true,
          icon: EvIcons.users,
          label: '切换账号',
          onPressed: onSwitchUser,
        ),
      ],
    );
  }

  final EvIconData icon;
  final String title;
  final String description;
  final String? meta;
  final List<Widget> actions;
  final bool animate;

  @override
  State<EvHomeStateCard> createState() => _EvHomeStateCardState();
}

class _EvHomeStateCardState extends State<EvHomeStateCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter;
  late final CurvedAnimation _curve;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
      value: widget.animate ? 0.0 : 1.0,
    );
    _curve = CurvedAnimation(parent: _enter, curve: EvCurves.out);
    if (widget.animate) _enter.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.animate || (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _enter.value = 1.0;
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _enter.dispose();
    super.dispose();
  }

  EvIconData _paperBigIcon(EvIconData icon) => EvIconData(
    'big_${icon.key}',
    icon.spec,
    cinemaSpec: icon.cinemaSpec,
    solid: icon.solid,
    viewBox: icon.viewBox,
    cinemaStrokeWidth: icon.cinemaStrokeWidth,
    doodleStrokeWidth: 1.15,
  );

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);

    final Widget iconBox = theme.isPaper
        ? SizedBox(
            key: Key('ev_home_state_icon_${widget.icon.key}'),
            width: scale.rem(9.0),
            height: scale.rem(9.0),
            child: Center(
              child: EvIcon(
                _paperBigIcon(widget.icon),
                size: scale.rem(9.0),
                color: theme.ink,
              ),
            ),
          )
        : Container(
            key: Key('ev_home_state_icon_${widget.icon.key}'),
            width: scale.rem(7.5),
            height: scale.rem(7.5),
            decoration: BoxDecoration(
              color: theme.fill,
              borderRadius: BorderRadius.circular(scale.rem(2.0)),
              border: Border.all(color: theme.line, width: 1),
            ),
            alignment: Alignment.center,
            child: EvIcon(
              widget.icon,
              size: scale.rem(3.5),
              color: theme.ink2,
            ),
          );

    final card = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: scale.rem(38.0)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconBox,
          SizedBox(height: scale.rem(1.75)),
          Text(
            widget.title,
            key: const Key('ev_home_state_title'),
            textAlign: TextAlign.center,
            style: theme.displayStyle(scale.font(2.25), color: theme.ink),
          ),
          SizedBox(height: scale.rem(1.0)),
          Text(
            widget.description,
            key: const Key('ev_home_state_desc'),
            textAlign: TextAlign.center,
            style: theme.bodyStyle(
              scale.font(1.0625),
              color: theme.ink2,
              height: 1.65,
            ),
          ),
          if (widget.meta != null && widget.meta!.isNotEmpty) ...[
            SizedBox(height: scale.rem(0.75)),
            Text(
              widget.meta!,
              key: const Key('ev_home_state_meta'),
              textAlign: TextAlign.center,
              style: theme
                  .bodyStyle(scale.font(0.875), color: theme.ink3)
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
          if (widget.actions.isNotEmpty) ...[
            SizedBox(height: scale.rem(2.0)),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: scale.rem(0.625),
              runSpacing: scale.rem(0.625),
              children: widget.actions,
            ),
          ],
        ],
      ),
    );

    return EvBrandBackground(
      calm: true,
      child: Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            scale.gutter,
            scale.rem(6.0),
            scale.gutter,
            scale.rem(3.0),
          ),
          child: AnimatedBuilder(
            animation: _curve,
            builder: (_, child) => Opacity(
              opacity: _curve.value.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, scale.rem(1.25) * (1.0 - _curve.value)),
                child: child,
              ),
            ),
            child: card,
          ),
        ),
      ),
    );
  }
}
