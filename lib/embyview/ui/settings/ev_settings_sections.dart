import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/subtitles/ai/subtitle_ai.dart' show AsrModelState, AsrModelStatus, LocalSubtitleAsr, isSubtitleTranslationMetered;
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_widgets.dart';

T _nearest<T extends num>(T value, List<T> presets) {
  var best = presets.first;
  var minDiff = (value - best).abs();
  for (final p in presets.skip(1)) {
    final d = (value - p).abs();
    if (d < minDiff) { best = p; minDiff = d; }
  }
  return best;
}

EvSettingsRow _toggleRow(String key, String title, String? sub, bool value, ValueChanged<bool> onChanged) => EvSettingsRow(
  title: title, subtitle: sub,
  trailing: EvToggle(key: Key(key), semanticLabel: title, value: value, onChanged: onChanged),
);

/// 1. Account & server pane (`account`).
class EvAccountSettingsPane extends StatelessWidget {
  const EvAccountSettingsPane({
    super.key, required this.snapshot, required this.prefs, required this.visibleZoneCount,
    required this.onSwitchProfile, required this.onOpenUsers, required this.onUpdatePrefs,
  });
  final AccountSnapshot snapshot;
  final LocalPreferences prefs;
  final int visibleZoneCount;
  final ValueChanged<String> onSwitchProfile;
  final VoidCallback? onOpenUsers;
  final ValueChanged<LocalPreferences> onUpdatePrefs;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), cur = snapshot.current, d = s.rem(3.5);
    final profiles = [...snapshot.profiles, if (cur != null && snapshot.profiles.every((p) => p.id != cur.id)) cur];
    final addr = snapshot.serverAddress?.trim().replaceFirst(RegExp(r'^https?://'), '');
    final ver = snapshot.serverVersion?.trim();
    final serverDesc = (addr == null || addr.isEmpty) ? (ver?.isNotEmpty == true ? 'Emby $ver' : '未配置服务器') : (ver?.isNotEmpty == true ? '$addr · Emby $ver' : addr);
    final (connLabel, connTone) = switch (snapshot.connection) {
      ConnectionState.connected => ('已连接', EvStatusTone.ok),
      ConnectionState.disconnected => ('已断开', EvStatusTone.error),
      ConnectionState.unknown => ('未检测', EvStatusTone.warn),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '用户与服务器'),
      EvSettingsGroup(title: '切换用户', children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: s.rem(1.125), vertical: s.rem(1.0)),
          child: Wrap(spacing: s.rem(1.0), runSpacing: s.rem(1.0), children: [
            for (var i = 0; i < profiles.length; i++)
              EvInteractive(
                key: Key('ev_settings_profile_${profiles[i].id}'), selected: cur?.id == profiles[i].id, label: profiles[i].displayName,
                onTap: () => onSwitchProfile(profiles[i].id),
                builder: (_, hovered, focused) {
                  final sel = cur?.id == profiles[i].id;
                  return SizedBox(width: s.rem(5.5), child: Column(mainAxisSize: MainAxisSize.min, children: [
                    AnimatedScale(
                      scale: (hovered || focused) ? 1.06 : 1.0, duration: EvDurations.normal, curve: EvCurves.spring,
                      child: Container(padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: sel ? t.ink : evTransparent, width: 2)),
                        child: Container(padding: const EdgeInsets.all(2), decoration: BoxDecoration(shape: BoxShape.circle, color: sel ? t.bg : evTransparent),
                          child: EvAvatarButton(profile: profiles[i], size: d, colorIndex: i))),
                    ),
                    SizedBox(height: s.rem(0.5)),
                    Text(profiles[i].displayName, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: t.bodyStyle(s.font(0.875), fontWeight: sel ? FontWeight.w600 : FontWeight.w400, color: sel ? t.ink : t.ink2)),
                  ]));
                },
              ),
            EvInteractive(
              key: const Key('ev_settings_profiles_manage'), label: '添加 / 管理', enabled: onOpenUsers != null, onTap: onOpenUsers,
              builder: (_, hovered, _) => Opacity(opacity: onOpenUsers != null ? 1.0 : 0.45, child: SizedBox(width: s.rem(5.5), child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(padding: const EdgeInsets.all(4), child: AnimatedScale(
                  scale: hovered ? 1.06 : 1.0, duration: EvDurations.normal, curve: EvCurves.spring,
                  child: Container(width: d, height: d, alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: t.fill3, width: 2)),
                    child: EvIcon(EvIcons.plus, size: s.rem(1.5), color: t.ink3)),
                )),
                SizedBox(height: s.rem(0.5)),
                Text('添加 / 管理', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.875), color: t.ink2)),
              ]))),
            ),
          ]),
        ),
      ]),
      EvSettingsGroup(title: '服务器', children: [
        EvSettingsRow(title: 'Emby 服务器', subtitle: serverDesc, trailing: EvStatusIndicator(key: const Key('ev_settings_connection_status'), label: connLabel, tone: connTone)),
        EvSettingsRow(title: '当前用户', subtitle: cur == null ? '尚未登录' : '${cur.displayName} · 可见 $visibleZoneCount 个分区',
          trailing: EvButton.ghost(key: const Key('ev_settings_switch_users_btn'), small: true, label: '切换…', onPressed: onOpenUsers)),
        _toggleRow('ev_toggle_choose_user', '打开时询问“谁在看”', '多人共用这台 Mac 时开启', prefs.chooseUserOnStartup,
          (v) => onUpdatePrefs(evCopyPreferences(prefs, chooseUserOnStartup: v))),
      ]),
    ]);
  }
}

/// 2. Appearance pane (`look`).
class EvLookSettingsPane extends StatelessWidget {
  const EvLookSettingsPane({super.key, required this.prefs, required this.onUpdatePrefs});
  final LocalPreferences prefs;
  final ValueChanged<LocalPreferences> onUpdatePrefs;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    const cards = [
      (ThemeMode.cinema, '影院', '深色舞台、毛玻璃、整幅剧照铺满'),
      (ThemeMode.paper, '纸面', '暖白纸面、衬线标题、简笔画图标'),
      (ThemeMode.automatic, '昼夜自动', '早 7 点到晚 7 点用纸面，其余时间用影院'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '外观'),
      EvSettingsGroup(title: '主题', children: [
        Padding(padding: EdgeInsets.symmetric(horizontal: s.rem(1.125), vertical: s.rem(1.0)),
          child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < cards.length; i++) ...[if (i > 0) SizedBox(width: s.rem(1.0)), Expanded(child: _themeCard(t, s, cards[i].$1, cards[i].$2, cards[i].$3))],
          ]))),
      ]),
      EvSettingsGroup(title: '顶栏导航', children: [
        EvSettingsRow(title: '导航样式', subtitle: '图标：平时只显示图标，当前页展开名称，悬停显示提示',
          trailing: EvSegmentedControl<NavigationStyle>(value: prefs.navigation, onChanged: (v) => onUpdatePrefs(evCopyPreferences(prefs, navigation: v)),
            options: const [
              EvSegmentOption(key: Key('ev_nav_style_icon'), value: NavigationStyle.icon, label: '图标'),
              EvSegmentOption(key: Key('ev_nav_style_iconAndText'), value: NavigationStyle.iconAndText, label: '图标 + 文字'),
              EvSegmentOption(key: Key('ev_nav_style_text'), value: NavigationStyle.text, label: '文字'),
            ])),
      ]),
      EvSettingsGroup(title: '首页', children: [
        EvSettingsRow(title: '番剧、剧集两排的顺序', subtitle: '默认最近添加，新番和新剧一入库就排在最前',
          trailing: EvSegmentedControl<ShelfSort>(value: prefs.seriesSort, onChanged: (v) => onUpdatePrefs(evCopyPreferences(prefs, seriesSort: v)),
            options: const [
              EvSegmentOption(key: Key('ev_shelf_sort_added'), value: ShelfSort.added, label: '最近添加'),
              EvSegmentOption(key: Key('ev_shelf_sort_score'), value: ShelfSort.score, label: '评分最高'),
              EvSegmentOption(key: Key('ev_shelf_sort_title'), value: ShelfSort.title, label: '按标题'),
            ])),
      ]),
    ]);
  }

  Widget _themeCard(EvTheme t, EvScale s, ThemeMode mode, String title, String sub) {
    final sel = prefs.theme == mode;
    return EvInteractive(
      key: Key('ev_theme_card_${mode.name}'), selected: sel, label: title,
      onTap: () => onUpdatePrefs(evCopyPreferences(prefs, theme: mode)),
      builder: (_, hovered, focused) => AnimatedSlide(
        offset: hovered ? const Offset(0, -0.015) : Offset.zero, duration: EvDurations.normal, curve: EvCurves.spring,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(s.rem(0.875)),
            border: Border.all(color: sel ? t.ink : (focused ? t.focusColor : t.line), width: sel ? 2.0 : 1.0),
            boxShadow: sel ? [BoxShadow(color: t.bg, spreadRadius: 1)] : null),
          child: ClipRRect(borderRadius: BorderRadius.circular(s.rem(0.8)), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: s.rem(6.0), child: _swatch(s, mode)),
            Padding(padding: EdgeInsets.fromLTRB(s.rem(0.75), s.rem(0.625), s.rem(0.75), 0),
              child: Text(title, style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: t.ink))),
            Padding(padding: EdgeInsets.fromLTRB(s.rem(0.75), s.rem(0.125), s.rem(0.75), s.rem(0.75)),
              child: Text(sub, style: t.bodyStyle(s.font(0.8125), color: t.ink3, height: 1.4))),
          ])),
        ),
      ),
    );
  }

  Widget _swatch(EvScale s, ThemeMode mode) => switch (mode) {
    ThemeMode.cinema => DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF0B0B0D),
        gradient: RadialGradient(center: Alignment(0.8, -1.0), radius: 1.1, colors: [Color(0xFF3A4A63), Color(0xFF0B0B0D)])),
      child: _bars(s, const Color.fromRGBO(255, 255, 255, 0.72), const Color.fromRGBO(255, 255, 255, 0.72))),
    ThemeMode.paper => DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFFFAF9F5), border: Border(bottom: BorderSide(color: Color(0xFFE8E6DC)))),
      child: Stack(fit: StackFit.expand, children: [
        _bars(s, const Color(0xFF141413), const Color(0xFFB5532F)),
        Positioned(right: s.rem(0.75), bottom: s.rem(0.5),
          child: EvIcon(EvIcons.navAnime, size: s.rem(3.0), color: const Color(0xFF141413), accentColor: const Color(0xFFD97757), forcePaper: true)),
      ])),
    ThemeMode.automatic => Stack(fit: StackFit.expand, children: [
      const Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: ColoredBox(color: Color(0xFFFAF9F5))), Expanded(child: ColoredBox(color: Color(0xFF0B0B0D)))]),
      Center(child: EvIcon(EvIcons.clock, size: s.rem(2.75), color: const Color(0xFFB5532F), accentColor: const Color(0xFFD97757), forcePaper: true)),
    ]),
  };

  Widget _bars(EvScale s, Color bar, Color pill) => Padding(
    padding: EdgeInsets.fromLTRB(s.rem(0.75), s.rem(2.4), s.rem(0.75), s.rem(0.75)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FractionallySizedBox(widthFactor: 0.52, child: Container(height: s.rem(0.55), decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(2)))),
      SizedBox(height: s.rem(0.45)),
      FractionallySizedBox(widthFactor: 0.58, child: Container(height: s.rem(0.32), decoration: BoxDecoration(color: bar.withValues(alpha: bar.a * 0.4), borderRadius: BorderRadius.circular(2)))),
      SizedBox(height: s.rem(0.42)),
      FractionallySizedBox(widthFactor: 0.28, child: Container(height: s.rem(0.68), decoration: BoxDecoration(color: pill, borderRadius: BorderRadius.circular(999)))),
    ]),
  );
}

/// 3. Zones management pane (`zones`).
class EvZonesSettingsPane extends StatelessWidget {
  const EvZonesSettingsPane({
    super.key, required this.zones, required this.tilesById, required this.facets,
    required this.onMoveZone, required this.onEditZone, required this.onAddZone, required this.onResetZones,
  });
  final List<ZonePreference> zones;
  final Map<String, ZoneTile> tilesById;
  final ZoneFacets? facets;
  final void Function(int index, int delta) onMoveZone;
  final ValueChanged<ZonePreference> onEditZone;
  final VoidCallback onAddZone, onResetZones;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '分区'),
      EvSettingsGroup(title: '顶栏和首页「片库」里的入口，按这里的顺序排列', children: [
        if (zones.isEmpty) const EvSettingsRow(title: '暂无分区', subtitle: '点击下方「添加分区」新建，或恢复默认片库分区'),
        for (var i = 0; i < zones.length; i++) () {
          final z = zones[i], c = t.zoneColor(z.colorSlot), tile = tilesById[z.id], desc = evZoneRuleDescription(z, facets: facets);
          return EvSettingsRow(
            key: Key('ev_zone_row_${z.id}'),
            leading: Container(width: s.rem(2.5), height: s.rem(2.5), padding: EdgeInsets.all(s.rem(0.5)),
              decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(s.rem(0.75))),
              child: EvIcon(EvIcons.byKey(z.iconKey), size: s.rem(1.5), color: c, accentColor: c)),
            title: z.name, subtitle: tile != null ? '$desc · ${evFormatCount(tile.total)} ${tile.unit}' : desc,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              EvButton.ghost(key: Key('ev_zone_move_up_${z.id}'), small: true, round: true, tooltip: '上移',
                onPressed: i > 0 ? () => onMoveZone(i, -1) : null, child: EvChevronIcon(up: true, size: s.rem(1.0), color: t.ink)),
              SizedBox(width: s.rem(0.375)),
              EvButton.ghost(key: Key('ev_zone_move_down_${z.id}'), small: true, round: true, tooltip: '下移',
                onPressed: i < zones.length - 1 ? () => onMoveZone(i, 1) : null, child: EvChevronIcon(up: false, size: s.rem(1.0), color: t.ink)),
              SizedBox(width: s.rem(0.5)),
              EvButton.ghost(key: Key('ev_zone_edit_${z.id}'), small: true, icon: EvIcons.edit, label: '编辑', onPressed: () => onEditZone(z)),
            ]),
          );
        }(),
        EvInteractive(
          key: const Key('ev_zone_add'), label: '添加分区', onTap: onAddZone,
          builder: (_, hovered, _) => AnimatedContainer(
            duration: EvDurations.fast, curve: EvCurves.soft, constraints: BoxConstraints(minHeight: s.rem(3.5)),
            padding: EdgeInsets.symmetric(horizontal: s.rem(1.125), vertical: s.rem(0.75)), color: hovered ? t.fill2 : evTransparent,
            child: Row(children: [
              EvIcon(EvIcons.plus, size: s.rem(1.25), color: hovered ? t.ink : t.ink2),
              SizedBox(width: s.rem(0.75)),
              Text('添加分区', style: t.bodyStyle(s.font(1.0), fontWeight: FontWeight.w500, color: hovered ? t.ink : t.ink2)),
              SizedBox(width: s.rem(1.0)),
              Expanded(child: Text('按类型或画质 / 音轨筛出一组片子，自己起名、选图标和颜色',
                textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.875), color: t.ink3))),
            ]),
          ),
        ),
      ]),
      EvSettingsGroup(children: [
        EvSettingsRow(title: '恢复默认分区', subtitle: '回到服务器默认的片库入口顺序',
          trailing: EvButton.ghost(key: const Key('ev_zone_reset'), small: true, label: '恢复', onPressed: onResetZones)),
      ]),
    ]);
  }
}

/// 4. Playback pane (`play`).
class EvPlaySettingsPane extends StatelessWidget {
  const EvPlaySettingsPane({super.key, required this.prefs, required this.onUpdatePrefs});
  final LocalPreferences prefs;
  final ValueChanged<LocalPreferences> onUpdatePrefs;
  static const _mb64 = 64 * 1024 * 1024, _mb256 = 256 * 1024 * 1024, _gb1 = 1024 * 1024 * 1024;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '播放'),
      EvSettingsGroup(title: '起播', children: [
        _toggleRow('ev_toggle_preresolve115', '115 起播预解析', '提前用播放器同一 UA 取得跳转后的地址，目标 2 秒内出画面',
          prefs.preResolve115, (v) => onUpdatePrefs(evCopyPreferences(prefs, preResolve115: v))),
        EvSettingsRow(title: '预读缓存', subtitle: '拖动进度条后更快续上',
          trailing: EvSegmentedControl<int>(value: _nearest(prefs.readAheadBytes, const [_mb64, _mb256, _gb1]),
            onChanged: (v) => onUpdatePrefs(evCopyPreferences(prefs, readAheadBytes: v)),
            options: const [
              EvSegmentOption(key: Key('ev_readahead_64mb'), value: _mb64, label: '64 MB'),
              EvSegmentOption(key: Key('ev_readahead_256mb'), value: _mb256, label: '256 MB'),
              EvSegmentOption(key: Key('ev_readahead_1gb'), value: _gb1, label: '1 GB'),
            ])),
        EvSettingsRow(title: '本地文件', subtitle: 'Emby 静态流，不转码', trailing: evValueText(t, s, '直接播放')),
      ]),
      EvSettingsGroup(title: '进度', children: [
        EvSettingsRow(title: '回传 Emby', subtitle: '播放进度与已看状态自动同步到所有设备', trailing: evValueText(t, s, '自动同步')),
        EvSettingsRow(title: '看完判定', subtitle: '播放到片尾字幕前标为已看', trailing: evValueText(t, s, '90%')),
        _toggleRow('ev_toggle_autoplay_next', '片尾自动下一集', '片尾时正片缩到角落，5 秒后播放下一集',
          prefs.autoPlayNext, (v) => onUpdatePrefs(evCopyPreferences(prefs, autoPlayNext: v))),
      ]),
    ]);
  }
}

/// 5. Immersion pane (`immerse`).
class EvImmerseSettingsPane extends StatelessWidget {
  const EvImmerseSettingsPane({super.key, required this.prefs, required this.onUpdatePrefs});
  final LocalPreferences prefs;
  final ValueChanged<LocalPreferences> onUpdatePrefs;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), trailer = prefs.detailTrailerDelay;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '沉浸'),
      EvSettingsGroup(title: '浏览', children: [
        _toggleRow('ev_toggle_bg_video', '停留后播放背景视频', '卡片选中停留后，背景淡入这部片的静音视频；没有视频时剧照慢速推拉',
          prefs.backgroundVideo, (v) => onUpdatePrefs(evCopyPreferences(prefs, backgroundVideo: v))),
        EvSettingsRow(title: '停留时长',
          trailing: EvSegmentedControl<int>(value: _nearest(prefs.backgroundVideoDelay.inMilliseconds, const [1000, 1700, 2000]),
            onChanged: (ms) => onUpdatePrefs(evCopyPreferences(prefs, backgroundVideoDelay: Duration(milliseconds: ms))),
            options: const [
              EvSegmentOption(key: Key('ev_bg_delay_1000'), value: 1000, label: '1 秒'),
              EvSegmentOption(key: Key('ev_bg_delay_1700'), value: 1700, label: '1.7 秒'),
              EvSegmentOption(key: Key('ev_bg_delay_2000'), value: 2000, label: '2 秒'),
            ])),
        _toggleRow('ev_toggle_quicklook', '空格一瞥', '选中卡片按空格，弹出片段、画质与字幕情况',
          prefs.quickLook, (v) => onUpdatePrefs(evCopyPreferences(prefs, quickLook: v))),
      ]),
      EvSettingsGroup(title: '详情页', children: [
        EvSettingsRow(title: '停留后转入预告', subtitle: '详情页停留这么久，剧照换成静音预告片；没有预告的剧集改为播放一段正片',
          trailing: EvSegmentedControl<int>(value: (trailer == null || trailer <= Duration.zero) ? 0 : _nearest(trailer.inSeconds, const [8, 12, 20]),
            onChanged: (sec) => onUpdatePrefs(evCopyPreferences(prefs, detailTrailerDelay: sec == 0 ? null : Duration(seconds: sec))),
            options: const [
              EvSegmentOption(key: Key('ev_trailer_delay_0'), value: 0, label: '关闭'),
              EvSegmentOption(key: Key('ev_trailer_delay_8'), value: 8, label: '8 秒'),
              EvSegmentOption(key: Key('ev_trailer_delay_12'), value: 12, label: '12 秒'),
              EvSegmentOption(key: Key('ev_trailer_delay_20'), value: 20, label: '20 秒'),
            ])),
        _toggleRow('ev_toggle_theme_music', '主题曲', '进入详情页淡入主题曲，离开淡出',
          prefs.themeMusic, (v) => onUpdatePrefs(evCopyPreferences(prefs, themeMusic: v))),
        EvSettingsRow(title: '主题曲音量',
          trailing: EvSegmentedControl<double>(value: _nearest(prefs.themeVolume, const [0.2, 0.35, 0.6]),
            onChanged: (v) => onUpdatePrefs(evCopyPreferences(prefs, themeVolume: v)),
            options: const [
              EvSegmentOption(key: Key('ev_theme_vol_low'), value: 0.2, label: '低'),
              EvSegmentOption(key: Key('ev_theme_vol_mid'), value: 0.35, label: '中'),
              EvSegmentOption(key: Key('ev_theme_vol_high'), value: 0.6, label: '高'),
            ])),
        _toggleRow('ev_toggle_hide_overview', '未看剧集隐藏简介', '防剧透：停留在集卡上才展开',
          prefs.hideUnwatchedOverview, (v) => onUpdatePrefs(evCopyPreferences(prefs, hideUnwatchedOverview: v))),
      ]),
    ]);
  }
}

/// 6. Subtitles & NAS folder mapping pane (`subs`).
class EvSubtitlesSettingsPane extends StatefulWidget {
  const EvSubtitlesSettingsPane({
    super.key, required this.prefs, required this.onUpdatePrefs, required this.onAuthorizeFolder, required this.onRecheckFolder,
  });
  final LocalPreferences prefs;
  final ValueChanged<LocalPreferences> onUpdatePrefs;
  final Future<void> Function(String embyRoot) onAuthorizeFolder;
  final Future<void> Function() onRecheckFolder;
  @override State<EvSubtitlesSettingsPane> createState() => _EvSubtitlesSettingsPaneState();
}

class _EvSubtitlesSettingsPaneState extends State<EvSubtitlesSettingsPane> {
  late final _rootCtrl = TextEditingController(text: widget.prefs.mediaFolder.embyRoot);
  bool _busy = false;
  @override void didUpdateWidget(EvSubtitlesSettingsPane old) {
    super.didUpdateWidget(old);
    final next = widget.prefs.mediaFolder.embyRoot;
    if (old.prefs.mediaFolder.embyRoot != next && _rootCtrl.text != next) _rootCtrl.text = next;
  }
  @override void dispose() { _rootCtrl.dispose(); super.dispose(); }
  Future<void> _runBusy(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await fn(); } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), prefs = widget.prefs, folder = prefs.mediaFolder;
    final (fLabel, fTone) = switch (folder.state) {
      MediaFolderState.authorized => folder.writable == false ? ('已挂载 · 只读', EvStatusTone.warn)
          : folder.writable == true ? ('已挂载 · 可写', EvStatusTone.ok) : ('已授权', EvStatusTone.ok),
      MediaFolderState.unmounted => ('未挂载', EvStatusTone.warn),
      MediaFolderState.denied => ('拒绝访问', EvStatusTone.error),
      MediaFolderState.invalid => ('授权失效', EvStatusTone.error),
      MediaFolderState.unconfigured => ('未配置', EvStatusTone.warn),
    };
    const sources = [
      (SubtitleSource.xunlei, '迅雷字幕', '无需密钥'), (SubtitleSource.assrt, '射手网 assrt', '需要 ASSRT_TOKEN'),
      (SubtitleSource.openSubtitles, 'OpenSubtitles', '需要 API Key'),
      (SubtitleSource.anime, '动画字幕组', '北宇治、SweetSub、Jimaku、Kitsunekko、ACG.RIP'),
    ];
    final langs = prefs.subtitleLanguages.isEmpty ? '简体中文 → 繁体中文 → 英文' : prefs.subtitleLanguages.map((c) => switch (c.toLowerCase()) {
      'zh' || 'zh-cn' || 'zh-hans' || 'chi' || 'zho' => '简体中文', 'zh-tw' || 'zh-hk' || 'zh-hant' => '繁体中文', 'ja' || 'jpn' => '日语', 'en' || 'eng' => '英文', _ => c,
    }).join(' → ');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '字幕'),
      EvSettingsGroup(title: '偏好', children: [
        EvSettingsRow(title: '首选语言', trailing: evValueText(t, s, langs)),
        _toggleRow('ev_toggle_auto_zh_sub', '自动选择', '有中文字幕时自动打开',
          prefs.autoSelectChineseSubtitle, (v) => widget.onUpdatePrefs(evCopyPreferences(prefs, autoSelectChineseSubtitle: v))),
      ]),
      EvSettingsGroup(title: '在线检索来源', children: [
        for (final (src, title, sub) in sources)
          _toggleRow('ev_toggle_sub_${src.name}', title, sub, prefs.subtitleSources.contains(src), (v) {
            final next = {...prefs.subtitleSources};
            v ? next.add(src) : next.remove(src);
            widget.onUpdatePrefs(evCopyPreferences(prefs, subtitleSources: Set.unmodifiable(next)));
          }),
      ]),
      EvSettingsGroup(title: '保存位置', children: [
        EvSettingsRow(
          title: '写到 NAS 片子同目录',
          subtitle: '${folder.localRoot?.isNotEmpty == true ? folder.localRoot! : '尚未授权本机目录'} · 文件名按 Emby 规则（片名.zh.ass），写完通知 Emby 重新识别',
          bottom: folder.reason?.isNotEmpty == true ? Padding(padding: EdgeInsets.only(top: s.rem(0.375)),
            child: Text(folder.reason!, style: t.bodyStyle(s.font(0.8125), color: fTone == EvStatusTone.error ? evDangerColor : const Color(0xFFE3A03C)))) : null,
          trailing: EvStatusIndicator(key: const Key('ev_subs_folder_status'), label: fLabel, tone: fTone),
        ),
        EvSettingsRow(
          title: 'Emby 媒体根路径映射', subtitle: '将 Emby 返回的媒体根路径（默认 /mnt/media）映射到本机已挂载目录',
          bottom: Padding(padding: EdgeInsets.only(top: s.rem(0.625)), child: Row(children: [
            Expanded(child: EvSettingsTextField(key: const Key('ev_subs_emby_root_input'), controller: _rootCtrl, placeholder: '/mnt/media')),
            SizedBox(width: s.rem(0.625)),
            EvButton.primary(key: const Key('ev_subs_authorize_folder'), small: true, label: '授权目录',
              onPressed: _busy ? null : () => _runBusy(() => widget.onAuthorizeFolder(_rootCtrl.text.trim().isEmpty ? '/mnt/media' : _rootCtrl.text.trim()))),
            SizedBox(width: s.rem(0.5)),
            EvButton.ghost(key: const Key('ev_subs_recheck_folder'), small: true, label: '重新检测', onPressed: _busy ? null : () => _runBusy(widget.onRecheckFolder)),
          ])),
        ),
      ]),
    ]);
  }
}

/// 7. AI subtitles pane (`ai`).
class EvAiSettingsPane extends StatefulWidget {
  const EvAiSettingsPane({
    super.key, required this.prefs, required this.subtitlesAvailable, required this.usage,
    required this.loadingUsage, required this.jobs, required this.onUpdatePrefs, required this.onCancelJob,
    required this.configuredSecrets, required this.loadingSecrets, required this.onSaveSecret,
  });
  final LocalPreferences prefs;
  final bool subtitlesAvailable, loadingUsage, loadingSecrets;
  final Set<SecretKind> configuredSecrets;
  final Future<void> Function(SecretKind, String?) onSaveSecret;
  final AiUsage? usage;
  final List<SeasonJob> jobs;
  final ValueChanged<LocalPreferences> onUpdatePrefs;
  final Future<void> Function(String jobId) onCancelJob;
  @override State<EvAiSettingsPane> createState() => _EvAiSettingsPaneState();
}

class _EvAiSettingsPaneState extends State<EvAiSettingsPane> {
  static const _presets = [10000000, 30000000, 50000000, 100000000];
  late final _budgetCtrl = TextEditingController(text: _fmt(widget.prefs.monthlyBudgetMicros));
  late final _address = TextEditingController(text: widget.prefs.translationBaseUrl);
  late final _model = TextEditingController(text: widget.prefs.translationModel);
  String? _budgetError, _addressError, _modelError;
  String _fmt(int m) => m % 1000000 == 0 ? '${m ~/ 1000000}' : (m / 1000000.0).toStringAsFixed(2);

  @override void didUpdateWidget(EvAiSettingsPane old) {
    super.didUpdateWidget(old);
    if (old.prefs.translationBaseUrl != widget.prefs.translationBaseUrl) _address.text = widget.prefs.translationBaseUrl;
    if (old.prefs.translationModel != widget.prefs.translationModel) _model.text = widget.prefs.translationModel;
    if (old.prefs.monthlyBudgetMicros != widget.prefs.monthlyBudgetMicros) _budgetCtrl.text = _fmt(widget.prefs.monthlyBudgetMicros);
  }
  @override void dispose() {
    _address.dispose();
    _model.dispose();
    _budgetCtrl.dispose();
    super.dispose();
  }

  void _applyTranslation() {
    final address = _address.text.trim(), model = _model.text.trim();
    final uri = Uri.tryParse(address);
    final valid = uri != null && (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty && uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment;
    setState(() {
      _addressError = valid ? null : '请输入有效的翻译服务地址';
      _modelError = model.isEmpty ? '请输入翻译模型名称' : null;
    });
    if (valid && model.isNotEmpty) {
      widget.onUpdatePrefs(evCopyPreferences(widget.prefs, translationBaseUrl: address, translationModel: model));
    }
  }

  void _applyBudget() {
    final v = double.tryParse(_budgetCtrl.text.trim().replaceFirst(RegExp(r'^\$'), ''));
    if (v == null || v < 0 || v > 1000000) { setState(() => _budgetError = '请输入有效的美元金额'); return; }
    setState(() => _budgetError = null);
    widget.onUpdatePrefs(evCopyPreferences(widget.prefs, monthlyBudgetMicros: (v * 1000000).round()));
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), prefs = widget.prefs;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, 'AI 字幕'),
      EvSettingsGroup(title: '本机听写', children: [
        const _AsrModelRow(),
        EvSettingsRow(title: '校正时间轴', subtitle: '本机音频对白匹配，计算偏移与漂移，不额外调用接口', trailing: evValueText(t, s, '本机自动')),
      ]),
      _SecretGroup(title: '翻译服务', items: const [_translationKey],
        configuredSecrets: widget.configuredSecrets, loadingSecrets: widget.loadingSecrets, onSaveSecret: widget.onSaveSecret,
        prefix: [
          EvSettingsRow(title: '接口地址', subtitle: _addressError ?? '兼容 OpenAI 的服务地址',
            subtitleColor: _addressError == null ? null : evDangerColor,
            trailing: SizedBox(width: s.rem(22), child: EvSettingsTextField(
              key: const Key('ev_ai_translation_address'), controller: _address, keyboardType: TextInputType.url,
              onSubmitted: (_) => _applyTranslation()))),
          EvSettingsRow(title: '翻译模型', subtitle: _modelError, subtitleColor: evDangerColor,
            trailing: SizedBox(width: s.rem(22), child: Row(children: [
              Expanded(child: EvSettingsTextField(key: const Key('ev_ai_translation_model'), controller: _model,
                onSubmitted: (_) => _applyTranslation())),
              SizedBox(width: s.rem(0.5)),
              ListenableBuilder(listenable: Listenable.merge([_address, _model]), builder: (_, _) {
                final changed = _address.text != prefs.translationBaseUrl || _model.text != prefs.translationModel;
                return EvButton.ghost(key: const Key('ev_ai_translation_save'), small: true,
                  label: '保存配置', onPressed: changed ? _applyTranslation : null);
              }),
            ]))),
        ]),
      EvSettingsGroup(title: '每月预算', children: [
        EvSettingsRow(title: '预算上限', subtitle: '本月累计达到预算后不再开新任务，进行中的集做完为止',
          trailing: EvSegmentedControl<int>(
            value: _presets.contains(prefs.monthlyBudgetMicros) ? prefs.monthlyBudgetMicros : null,
            options: [for (final p in _presets) EvSegmentOption(key: Key('ev_ai_budget_${p ~/ 1000000}'), value: p, label: evFormatMicros(p, trimZeroCents: true))],
            onChanged: (v) { setState(() => _budgetError = null); widget.onUpdatePrefs(evCopyPreferences(prefs, monthlyBudgetMicros: v)); },
          )),
        EvSettingsRow(title: '自定义金额（美元）', subtitle: _budgetError, subtitleColor: _budgetError != null ? evDangerColor : null,
          trailing: SizedBox(width: s.rem(13.0), child: Row(children: [
            Expanded(child: EvSettingsTextField(key: const Key('ev_ai_budget_input'), controller: _budgetCtrl,
              placeholder: '30', keyboardType: const TextInputType.numberWithOptions(decimal: true), onSubmitted: (_) => _applyBudget())),
            SizedBox(width: s.rem(0.5)),
            EvButton.ghost(key: const Key('ev_ai_budget_apply'), small: true, label: '应用', onPressed: _applyBudget),
          ]))),
      ]),
      EvSettingsGroup(title: '本月用量', children: [_usageRow()]),
      EvSettingsGroup(title: '批量队列', children: _jobRows(s)),
    ]);
  }

  Widget _usageRow() {
    if (!widget.subtitlesAvailable) {
      return const EvSettingsRow(key: Key('ev_ai_subtitles_disabled'), title: 'AI 字幕服务未启用', subtitle: '当前会话尚未接入字幕服务，登录后可查看本月用量与批量任务');
    }
    if (widget.loadingUsage && widget.usage == null) return const EvSettingsRow(title: '正在读取本月用量…');
    final u = widget.usage, budget = u?.budgetMicros ?? widget.prefs.monthlyBudgetMicros, used = u?.usedMicros;
    final ratio = (used != null && budget > 0) ? used / budget : 0.0;
    final (stLabel, stTone) = switch (u?.state ?? AiUsageState.unavailable) {
      AiUsageState.available => ('已同步', EvStatusTone.ok),
      AiUsageState.localOnly => ('仅本机记录', EvStatusTone.warn),
      AiUsageState.unavailable => ('暂不可用', EvStatusTone.warn),
    };
    final parts = [
      if (u != null && u.month.isNotEmpty) u.month, '本月生成 ${u?.completedEpisodes ?? 0} 集',
      if (u?.averageEpisodeMicros != null) '平均每集 ${evFormatMicros(u!.averageEpisodeMicros!)}',
      if (!isSubtitleTranslationMetered(widget.prefs)) '当前翻译服务未计费',
      if ((u?.unmeteredCalls ?? 0) > 0) '${u!.unmeteredCalls} 次翻译未计费',
      if (u?.reason?.isNotEmpty == true) u!.reason!,
    ];
    return EvSettingsRow(
      key: const Key('ev_ai_usage_row'), title: '${used != null ? evFormatMicros(used) : '—'} / ${evFormatMicros(budget, trimZeroCents: true)}',
      subtitle: parts.join(' · '), bottom: EvMeterBar(progress: ratio, exceeded: ratio >= 1.0),
      trailing: EvStatusIndicator(label: stLabel, tone: stTone),
    );
  }

  List<Widget> _jobRows(EvScale s) {
    if (!widget.subtitlesAvailable) return const [EvSettingsRow(title: '未启用批量队列', subtitle: '接入字幕服务后，整季生成任务会显示在这里')];
    if (widget.jobs.isEmpty) return const [EvSettingsRow(key: Key('ev_ai_jobs_empty'), title: '当前没有批量任务', subtitle: '在剧集详情页点击「AI 中字」可整季排队生成')];
    return [for (final job in widget.jobs) () {
      final active = job.episodes.where((e) => e.state == EpisodeJobState.reading || e.state == EpisodeJobState.transcribing || e.state == EpisodeJobState.translating).firstOrNull;
      final status = active != null
          ? '${switch (active.state) { EpisodeJobState.reading => '正在读取', EpisodeJobState.transcribing => '正在听写', EpisodeJobState.translating => '正在翻译', _ => '正在处理' }}${active.episodeNumber != null ? '第 ${active.episodeNumber} 集' : active.name}'
          : job.failure?.reason ?? (job.episodes.any((e) => e.state == EpisodeJobState.queued) ? '排队中' : '已完成');
      return EvSettingsRow(
        key: Key('ev_ai_job_${job.id}'), title: job.seasonName, subtitle: '已完成 ${job.completedCount} / ${job.total} 集 · $status',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (active != null) ...[const EvPulseDot(), SizedBox(width: s.rem(0.75))],
          EvButton.ghost(key: Key('ev_ai_cancel_job_${job.id}'), small: true, label: '取消', onPressed: () => unawaited(widget.onCancelJob(job.id))),
        ]),
      );
    }()];
  }
}

class _AsrModelRow extends StatefulWidget {
  const _AsrModelRow();
  @override State<_AsrModelRow> createState() => _AsrModelRowState();
}

class _AsrModelRowState extends State<_AsrModelRow> {
  static const _asr = LocalSubtitleAsr();
  AsrModelStatus? _status;
  Timer? _timer;
  bool _busy = false;
  int _revision = 0;
  String? _error;

  @override void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh([Future<void> Function()? action]) async {
    final revision = ++_revision;
    _timer?.cancel();
    if (action != null) setState(() => _busy = true);
    try {
      await action?.call();
      final status = await _asr.modelStatus();
      if (!mounted || revision != _revision) return;
      setState(() { _status = status; _busy = false; _error = null; });
      if (status.state == AsrModelState.downloading) {
        _timer = Timer(const Duration(milliseconds: 500), _refresh);
      }
    } catch (error) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _error = error is EmbyViewFailure ? error.reason : '无法读取模型状态，请重试。';
        _status = null;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = EvScale.of(context);
    final status = _status, state = status?.state;
    final received = status?.receivedBytes ?? 0, total = status?.totalBytes ?? 0;
    final progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
    const mib = 1024 * 1024;
    final size = total > 0 ? '${(total / mib).round()} MiB' : '约 547 MiB';
    final downloading = state == AsrModelState.downloading;
    final paused = state == AsrModelState.notDownloaded && received > 0;
    final label = switch (state) {
      AsrModelState.downloading => '下载中 ${(progress * 100).round()}%',
      AsrModelState.ready => '已就绪',
      AsrModelState.failed => '下载失败',
      AsrModelState.notDownloaded => paused ? '已暂停' : '未下载',
      null => _error == null ? '读取中' : '暂不可用',
    };
    final (actionLabel, action) = switch (state) {
      AsrModelState.downloading => ('取消下载', _asr.cancelDownload),
      AsrModelState.ready => ('删除模型', _asr.deleteModel),
      AsrModelState.failed => ('重新下载', _asr.downloadModel),
      AsrModelState.notDownloaded => (paused ? '继续下载' : '下载模型', _asr.downloadModel),
      null => ('重试', null),
    };
    final detail = _error ?? status?.error;
    return EvSettingsRow(
      title: 'Whisper large-v3-turbo',
      subtitle: ['Q5_0', downloading || paused ? '${(received / mib).floor()} / $size' : size,
        '本机听写免费', ?detail].join(' · '),
      bottom: downloading ? EvMeterBar(progress: progress) : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        EvStatusIndicator(label: label, tone: state == AsrModelState.ready ? EvStatusTone.ok
          : detail != null ? EvStatusTone.error : EvStatusTone.warn),
        if (state != null || _error != null) ...[
          SizedBox(width: s.rem(0.75)),
          EvButton.ghost(small: true, label: actionLabel, onPressed: _busy ? null : () => _refresh(action)),
        ],
        if (paused || (state == AsrModelState.failed && received > 0)) ...[
          SizedBox(width: s.rem(0.375)),
          EvButton.ghost(small: true, label: '删除模型', onPressed: _busy ? null : () => _refresh(_asr.deleteModel)),
        ],
      ]),
    );
  }
}

/// 8. Video enhancement pane (`video`).
class EvVideoSettingsPane extends StatelessWidget {
  const EvVideoSettingsPane({super.key, required this.prefs, required this.onUpdatePrefs});
  final LocalPreferences prefs;
  final ValueChanged<LocalPreferences> onUpdatePrefs;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '画面增强'),
      EvSettingsGroup(title: 'Anime4K', children: [
        _toggleRow('ev_toggle_anime4k_anime', '番剧库自动开启', '仅 Mac；1080p 放大到 4K 输出',
          prefs.anime4kForAnime, (v) => onUpdatePrefs(evCopyPreferences(prefs, anime4kForAnime: v))),
        EvSettingsRow(title: '档位', subtitle: 'M1 Pro 实测轻量档每帧 9 ms，更高档位会掉帧',
          trailing: EvSegmentedControl<String>(value: 'lite', onChanged: (_) {}, options: const [
            EvSegmentOption(value: 'lite', label: '轻量'),
            EvSegmentOption(value: 'std', label: '标准', enabled: false),
            EvSegmentOption(value: 'high', label: '高', enabled: false),
          ])),
        _toggleRow('ev_toggle_anime4k_other', '其他片库', '真人影像不建议开启',
          prefs.anime4kForOther, (v) => onUpdatePrefs(evCopyPreferences(prefs, anime4kForOther: v))),
      ]),
    ]);
  }
}

/// 9. Keychain secrets pane (`keys`).
class EvKeysSettingsPane extends StatelessWidget {
  const EvKeysSettingsPane({super.key, required this.configuredSecrets, required this.loadingSecrets, required this.onSaveSecret});
  final Set<SecretKind> configuredSecrets;
  final bool loadingSecrets;
  final Future<void> Function(SecretKind kind, String? value) onSaveSecret;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    evPaneTitle(EvTheme.of(context), EvScale.of(context), '密钥'),
    _SecretGroup(title: '存在本机钥匙串', configuredSecrets: configuredSecrets, loadingSecrets: loadingSecrets, onSaveSecret: onSaveSecret,
      items: const [_translationKey, (SecretKind.assrt, '射手网 assrt', '字幕检索'), (SecretKind.openSubtitles, 'OpenSubtitles', '字幕检索')]),
  ]);
}

const _translationKey = (SecretKind.openAi, '翻译密钥', '仅存本机钥匙串');

class _SecretGroup extends StatefulWidget {
  const _SecretGroup({required this.title, this.prefix = const [], required this.items,
    required this.configuredSecrets, required this.loadingSecrets, required this.onSaveSecret});
  final String title;
  final List<Widget> prefix;
  final List<(SecretKind, String, String)> items;
  final Set<SecretKind> configuredSecrets;
  final bool loadingSecrets;
  final Future<void> Function(SecretKind kind, String? value) onSaveSecret;
  @override State<_SecretGroup> createState() => _SecretGroupState();
}

class _SecretGroupState extends State<_SecretGroup> {
  SecretKind? _editing;
  final _ctrl = TextEditingController();
  bool _saving = false;
  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _commit(SecretKind kind, String? value) async {
    if (_saving || (value != null && value.isEmpty)) return;
    setState(() => _saving = true);
    try { await widget.onSaveSecret(kind, value); if (mounted) { _ctrl.clear(); setState(() => _editing = null); } }
    finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return EvSettingsGroup(title: widget.title, children: [
        ...widget.prefix,
        for (final (kind, title, sub) in widget.items) () {
          final ok = widget.configuredSecrets.contains(kind);
          return EvSettingsRow(
            key: Key('ev_secret_row_${kind.name}'), title: title, subtitle: sub,
            bottom: _editing == kind ? Padding(padding: EdgeInsets.only(top: s.rem(0.625)), child: Row(children: [
              Expanded(child: EvSettingsTextField(key: Key('ev_secret_input_${kind.name}'), controller: _ctrl, obscureText: true,
                placeholder: '输入密钥（仅存本机钥匙串）', onSubmitted: (_) => _commit(kind, _ctrl.text.trim()))),
              SizedBox(width: s.rem(0.5)),
              EvButton.primary(key: Key('ev_secret_save_${kind.name}'), small: true, label: '保存', onPressed: _saving ? null : () => _commit(kind, _ctrl.text.trim())),
              if (ok) ...[
                SizedBox(width: s.rem(0.375)),
                EvButton.ghost(key: Key('ev_secret_clear_${kind.name}'), small: true, onPressed: _saving ? null : () => _commit(kind, null),
                  child: Text('清除', style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: evDangerColor))),
              ],
              SizedBox(width: s.rem(0.375)),
              EvButton.ghost(small: true, label: '取消', onPressed: _saving ? null : () { _ctrl.clear(); setState(() => _editing = null); }),
            ])) : null,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              EvStatusIndicator(key: Key('ev_secret_status_${kind.name}'),
                label: widget.loadingSecrets ? '检测中' : ok ? '已设置' : '缺少', tone: ok ? EvStatusTone.ok : EvStatusTone.warn),
              SizedBox(width: s.rem(0.75)),
              EvButton.ghost(key: Key('ev_secret_edit_${kind.name}'), small: true, label: ok ? '更新' : '填写',
                onPressed: () => setState(() { _ctrl.clear(); _editing = _editing == kind ? null : kind; })),
            ]),
          );
        }(),
    ]);
  }
}

/// 10. About pane (`about`).
class EvAboutSettingsPane extends StatelessWidget {
  const EvAboutSettingsPane({super.key});
  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '关于'),
      EvSettingsGroup(children: [
        EvSettingsRow(title: 'EmbyView', subtitle: '基于 Moonfin 3.1.1 · GPL-3.0', trailing: evValueText(t, s, '1.0')),
        EvSettingsRow(title: '播放引擎', subtitle: 'AetherEngine · Anime4K .lineArt', trailing: evValueText(t, s, '已就绪')),
      ]),
    ]);
  }
}
