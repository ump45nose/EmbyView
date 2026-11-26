import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// A single shortcut row shared between the quick-reference overlay (`shortcuts`)
/// and Settings -> Shortcuts (`settings:shortcuts`).
@immutable
class EvShortcutEntry {
  const EvShortcutEntry({required this.keys, required this.label});

  /// Space-separated tokens matching `KEYS` / `kcap()` in `.spec/mockups/proto.js`.
  /// Tokens `'或'` and `'…'` render as muted connector text; all others render as keycaps.
  final String keys;
  final String label;
}

/// A column / group of related shortcuts.
@immutable
class EvShortcutGroup {
  const EvShortcutGroup({required this.title, required this.items});

  final String title;
  final List<EvShortcutEntry> items;
}

/// Shared shortcut catalog ported directly from `KEYS` in `.spec/mockups/proto.js` L1570-1575.
const List<EvShortcutGroup> evShortcutGroups = [
  EvShortcutGroup(
    title: '浏览',
    items: [
      EvShortcutEntry(keys: '← → ↑ ↓', label: '移动焦点'),
      EvShortcutEntry(keys: '回车', label: '打开'),
      EvShortcutEntry(keys: '空格', label: '一瞥：预览选中的片子'),
      EvShortcutEntry(keys: 'Esc', label: '返回上一页、关掉弹层'),
      EvShortcutEntry(keys: '⌘ F', label: '搜索'),
      EvShortcutEntry(keys: '⌘ K', label: '命令面板'),
      EvShortcutEntry(keys: '⌘ 1 … ⌘ 6', label: '首页和各分区'),
      EvShortcutEntry(keys: '⌘ [', label: '后退'),
    ],
  ),
  EvShortcutGroup(
    title: '播放',
    items: [
      EvShortcutEntry(keys: '空格', label: '播放 / 暂停'),
      EvShortcutEntry(keys: '← →', label: '后退 / 前进 10 秒'),
      EvShortcutEntry(keys: '↑ ↓', label: '音量'),
      EvShortcutEntry(keys: 'M', label: '静音'),
      EvShortcutEntry(keys: 'F', label: '全屏'),
    ],
  ),
  EvShortcutGroup(
    title: '窗口',
    items: [
      EvShortcutEntry(keys: '⌘ ,', label: '设置'),
      EvShortcutEntry(keys: '? 或 ⌘ /', label: '快捷键速查'),
      EvShortcutEntry(keys: '⌘ M', label: '最小化'),
      EvShortcutEntry(keys: '⌘ Q', label: '退出 EmbyView'),
    ],
  ),
];

/// Renders a single keycap (`kbd`) mirroring `.spec/mockups/proto.css` L1283-1284.
class EvKeycap extends StatelessWidget {
  const EvKeycap(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final bg = t.isPaper ? const Color(0xFFFFFFFF) : t.fill2;
    final borderColor = t.isPaper ? const Color(0xFFDEDBCF) : t.line;
    final bottomEdge = t.isPaper ? const Color(0xFFE8E6DC) : t.fill3;
    final radius = BorderRadius.circular(s.rem(0.4375));

    return Container(
      constraints: BoxConstraints(
        minWidth: s.rem(1.875),
        minHeight: s.rem(1.875),
      ),
      height: s.rem(1.875),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: Border.all(color: borderColor, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 2,
            child: ColoredBox(color: bottomEdge),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: s.rem(0.5)),
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: t.bodyStyle(
                s.font(0.875),
                fontWeight: FontWeight.w600,
                color: t.ink,
                height: 1.0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders a sequence of keycaps and connector words (`.kc`) matching `kcap()` in `proto.js`.
class EvKeycapSequence extends StatelessWidget {
  const EvKeycapSequence(this.spec, {super.key});

  final String spec;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final tokens = spec.split(' ').where((tok) => tok.isNotEmpty).toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tokens.length; i++) ...[
          if (i > 0) SizedBox(width: s.rem(0.3125)),
          if (tokens[i] == '或' || tokens[i] == '…')
            Padding(
              padding: EdgeInsets.symmetric(horizontal: s.rem(0.125)),
              child: Text(
                tokens[i],
                maxLines: 1,
                softWrap: false,
                style: t.bodyStyle(s.font(0.875), color: t.ink3),
              ),
            )
          else
            EvKeycap(tokens[i]),
        ],
      ],
    );
  }
}

/// Full-screen centered keyboard shortcut quick-reference card (`shortcuts`)
/// matching `.keys`, `.kcard`, `.khead`, `.kcols`, and `.krow` in `proto.css`.
class EvShortcutsOverlay extends StatefulWidget {
  const EvShortcutsOverlay({
    super.key,
    required this.onClose,
    this.groups = evShortcutGroups,
  });

  final VoidCallback onClose;
  final List<EvShortcutGroup> groups;

  @override
  State<EvShortcutsOverlay> createState() => _EvShortcutsOverlayState();
}

class _EvShortcutsOverlayState extends State<EvShortcutsOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter;
  late final CurvedAnimation _fade, _spring;
  final _focusNode = FocusNode(debugLabel: 'ev_shortcuts_overlay');

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(vsync: this, duration: EvDurations.medium)
      ..forward();
    _fade = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.0, 0.65, curve: EvCurves.soft),
    );
    _spring = CurvedAnimation(parent: _enter, curve: EvCurves.spring);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) _focusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _enter.value = 1.0;
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _spring.dispose();
    _enter.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final scrimColor = t.isPaper
        ? const Color.fromRGBO(250, 249, 245, 0.45)
        : const Color.fromRGBO(0, 0, 0, 0.55);
    final cardWidth = math.max(
      280.0,
      math.min(s.rem(70.0), s.size.width - s.rem(6.0)),
    );
    final cardRadius = BorderRadius.circular(s.rem(1.75));
    final shadows = t.isPaper
        ? t.glassShadow
        : [
            BoxShadow(
              offset: Offset(0, s.rem(2.0)),
              blurRadius: s.rem(5.0),
              color: const Color.fromRGBO(0, 0, 0, 0.40),
            ),
          ];

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: FadeTransition(
        opacity: _fade,
        child: Stack(
          key: const Key('ev_shortcuts_overlay'),
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('ev_shortcuts_scrim'),
                behavior: HitTestBehavior.opaque,
                onTap: widget.onClose,
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: ColoredBox(color: scrimColor),
                ),
              ),
            ),
            Center(
              child: AnimatedBuilder(
                animation: _spring,
                builder: (_, child) => Transform.scale(
                  scale: 0.97 + 0.03 * _spring.value,
                  child: child,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: cardWidth,
                    maxHeight: math.max(240.0, s.size.height - s.rem(4.0)),
                  ),
                  child: Container(
                    key: const Key('ev_shortcuts_card'),
                    width: cardWidth,
                    decoration: BoxDecoration(
                      color: t.glassSolid,
                      borderRadius: cardRadius,
                      border: Border.all(color: t.glassBorder, width: 1),
                      boxShadow: shadows,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        if (t.glassEdge.a > 0)
                          Positioned(
                            left: 1,
                            right: 1,
                            top: 0,
                            height: 1,
                            child: IgnorePointer(
                              child: ColoredBox(color: t.glassEdge),
                            ),
                          ),
                        SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(
                            s.rem(2.25),
                            s.rem(2.0),
                            s.rem(2.25),
                            s.rem(1.75),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildHeader(t, s),
                              SizedBox(height: s.rem(1.25)),
                              _buildColumns(t, s),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(EvTheme t, EvScale s) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Text('快捷键', style: t.displayStyle(s.font(1.875))),
      Semantics(
        button: true,
        label: '关闭快捷键速查卡',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const Key('ev_shortcuts_close'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const EvKeycapSequence('Esc'),
                SizedBox(width: s.rem(0.5)),
                Text('关闭', style: t.bodyStyle(s.font(0.875), color: t.ink3)),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _buildColumns(EvTheme t, EvScale s) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < widget.groups.length; i++) ...[
        if (i > 0) SizedBox(width: s.rem(2.5)),
        Expanded(child: _buildGroupColumn(t, s, widget.groups[i])),
      ],
    ],
  );

  Widget _buildGroupColumn(EvTheme t, EvScale s, EvShortcutGroup group) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: s.rem(0.5)),
            child: Text(
              group.title,
              style: t.bodyStyle(
                s.font(0.9375),
                fontWeight: FontWeight.w600,
                color: t.ink3,
              ),
            ),
          ),
          for (var i = 0; i < group.items.length; i++)
            Container(
              constraints: BoxConstraints(minHeight: s.rem(2.875)),
              decoration: i == 0
                  ? null
                  : BoxDecoration(
                      border: Border(top: BorderSide(color: t.line, width: 1)),
                    ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      group.items[i].label,
                      style: t.bodyStyle(s.font(0.9375), color: t.ink),
                    ),
                  ),
                  SizedBox(width: s.rem(1.0)),
                  EvKeycapSequence(group.items[i].keys),
                ],
              ),
            ),
        ],
      );
}
