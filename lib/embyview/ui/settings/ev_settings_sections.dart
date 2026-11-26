import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:moonfin/embyview/data/build_info.dart';
import 'package:moonfin/embyview/data/diagnostics_exporter.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/subtitles/ai/subtitle_ai.dart' show AsrModelState, AsrModelStatus, LocalSubtitleAsr, isSubtitleTranslationMetered;
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_widgets.dart';
import 'package:url_launcher/url_launcher.dart';

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
class EvAccountSettingsPane extends StatefulWidget {
  const EvAccountSettingsPane({
    super.key,
    required this.snapshot,
    required this.prefs,
    required this.visibleZoneCount,
    required this.onSwitchProfile,
    required this.onOpenUsers,
    required this.onUpdatePrefs,
    this.onSignOut,
    this.onRemoveAccount,
    this.onAddAccount,
    this.onSwitchServer,
    this.onRemoveServer,
    this.onAddAddress,
    this.onUpdateAddress,
    this.onRemoveAddress,
    this.onReorderAddresses,
    this.onActivateAddress,
  });

  final AccountSnapshot snapshot;
  final LocalPreferences prefs;
  final int visibleZoneCount;
  final ValueChanged<String> onSwitchProfile;
  final VoidCallback? onOpenUsers;
  final ValueChanged<LocalPreferences> onUpdatePrefs;
  final Future<void> Function()? onSignOut;
  final Future<void> Function(String profileId)? onRemoveAccount;
  final VoidCallback? onAddAccount;
  final VoidCallback? onSwitchServer;
  final Future<void> Function()? onRemoveServer;
  final Future<void> Function(ServerAddressEntry entry)? onAddAddress;
  final Future<void> Function(ServerAddressEntry entry)? onUpdateAddress;
  final Future<void> Function(String addressId)? onRemoveAddress;
  final Future<void> Function(List<String> addressIds)? onReorderAddresses;
  final Future<void> Function(String addressId)? onActivateAddress;

  @override
  State<EvAccountSettingsPane> createState() => _EvAccountSettingsPaneState();
}

class _EvAccountSettingsPaneState extends State<EvAccountSettingsPane> {
  String? _editingAddressId;
  bool _addingAddress = false;
  String? _addressFormError;
  String? _confirmRemoveAccountId;
  bool _confirmRemoveServer = false;
  bool _busy = false;

  final _urlCtrl = TextEditingController();
  final _labelCtrl = TextEditingController();
  final _subCtrl = TextEditingController();

  @override
  void dispose() {
    _urlCtrl.dispose();
    _labelCtrl.dispose();
    _subCtrl.dispose();
    super.dispose();
  }

  List<ServerAddressEntry> get _addresses {
    if (widget.snapshot.addresses.isNotEmpty) return widget.snapshot.addresses;
    final raw = widget.snapshot.serverAddress?.trim() ?? '';
    if (raw.isEmpty) return const [];
    return [
      ServerAddressEntry(
        id: 'primary',
        url: raw,
        label: inferServerAddressLabel(raw),
        subtitle: inferServerAddressSubtitle(raw),
      ),
    ];
  }

  String? _formatLastUsed(AccountProfile p) {
    if (p.lastUsedLabel != null && p.lastUsedLabel!.trim().isNotEmpty) {
      return p.lastUsedLabel!.trim();
    }
    final dt = p.lastUsedAt;
    if (dt == null) return null;
    final diff = DateTime.now().difference(dt);
    if (diff.inDays <= 0) return '今天用过';
    if (diff.inDays == 1) return '昨天用过';
    if (diff.inDays < 30) return '${diff.inDays} 天前用过';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} 用过';
  }

  void _startAddAddress() {
    setState(() {
      _editingAddressId = null;
      _addingAddress = true;
      _addressFormError = null;
      _urlCtrl.clear();
      _labelCtrl.clear();
      _subCtrl.clear();
    });
  }

  void _startEditAddress(ServerAddressEntry entry) {
    setState(() {
      _addingAddress = false;
      _editingAddressId = entry.id;
      _addressFormError = null;
      _urlCtrl.text = entry.url;
      _labelCtrl.text = entry.label;
      _subCtrl.text = entry.subtitle;
    });
  }

  void _closeAddressForm() {
    setState(() {
      _addingAddress = false;
      _editingAddressId = null;
      _addressFormError = null;
    });
  }

  Future<void> _saveAddressForm() async {
    if (_busy) return;
    final rawUrl = _urlCtrl.text.trim();
    final parsed = parseEmbyServerAddress(rawUrl);
    if (parsed == null) {
      setState(() => _addressFormError = '请填写有效的服务器地址（如 http://nas.local:8096 或 https://emby.example.com）。');
      return;
    }
    final normalizedUrl = parsed.toString();
    final label = _labelCtrl.text.trim().isEmpty ? inferServerAddressLabel(normalizedUrl) : _labelCtrl.text.trim();
    final subtitle = _subCtrl.text.trim().isEmpty ? inferServerAddressSubtitle(normalizedUrl) : _subCtrl.text.trim();
    final isAdd = _addingAddress;
    final id = isAdd ? 'addr_${DateTime.now().microsecondsSinceEpoch}' : _editingAddressId!;
    final entry = ServerAddressEntry(id: id, url: normalizedUrl, label: label, subtitle: subtitle);

    setState(() { _busy = true; _addressFormError = null; });
    try {
      if (isAdd) {
        await widget.onAddAddress?.call(entry);
      } else {
        await widget.onUpdateAddress?.call(entry);
      }
      if (mounted) {
        setState(() { _busy = false; _addingAddress = false; _editingAddressId = null; });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _busy = false; _addressFormError = e is EmbyViewFailure ? e.reason : '保存地址失败，请重试。'; });
      }
    }
  }

  Future<void> _moveAddress(int index, int delta) async {
    final addrs = _addresses;
    final target = index + delta;
    if (_busy || index < 0 || index >= addrs.length || target < 0 || target >= addrs.length) return;
    final ids = [for (final a in addrs) a.id];
    ids.insert(target, ids.removeAt(index));
    await widget.onReorderAddresses?.call(ids);
  }

  Widget _dangerBtn(EvTheme t, EvScale s, {Key? key, required String label, required bool primary, required VoidCallback? onPressed}) {
    final bg = primary ? (t.isPaper ? const Color(0xFFC8463A) : const Color(0xFFE5484D)) : evTransparent;
    final fg = primary ? const Color(0xFFFFFFFF) : (t.isPaper ? const Color(0xFFC8463A) : const Color(0xFFFF6B5A));
    final radius = BorderRadius.circular(t.isPaper ? s.rem(0.625) : 999.0);
    return EvInteractive(
      key: key, label: label, enabled: onPressed != null, onTap: onPressed,
      builder: (_, hovered, focused) => AnimatedScale(
        scale: (onPressed != null && (hovered || focused)) ? 1.04 : 1.0,
        duration: EvDurations.normal, curve: EvCurves.spring,
        child: Opacity(
          opacity: onPressed != null ? 1.0 : 0.45,
          child: Container(
            height: s.rem(2.375),
            padding: EdgeInsets.symmetric(horizontal: s.rem(1.0625)),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: primary
                  ? bg
                  : (hovered ? t.fill3 : (t.isPaper ? const Color(0xFFFFFFFF) : t.glass)),
              borderRadius: radius,
              border: Border.all(
                color: focused ? t.focusColor : (primary ? evTransparent : (t.isPaper ? const Color(0xFFD1CFC5) : t.glassBorder)),
                width: focused ? 1.5 : 1.0,
              ),
            ),
            child: Text(label, style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: fg)),
          ),
        ),
      ),
    );
  }

  Widget _gaddRow(EvTheme t, EvScale s, {required Key key, required String label, required String hint, required VoidCallback? onTap}) {
    return EvInteractive(
      key: key, label: label, enabled: onTap != null, onTap: onTap,
      builder: (_, hovered, focused) => Opacity(
        opacity: onTap != null ? 1.0 : 0.45,
        child: AnimatedContainer(
          duration: EvDurations.fast, curve: EvCurves.soft,
          constraints: BoxConstraints(minHeight: s.rem(3.5)),
          padding: EdgeInsets.symmetric(horizontal: s.rem(1.125), vertical: s.rem(0.75)),
          decoration: BoxDecoration(
            color: hovered ? (t.isPaper ? const Color(0xFFF7F5EF) : t.fill2) : (t.isPaper ? const Color(0xFFFFFFFF) : evTransparent),
            border: focused ? Border.all(color: t.focusColor, width: 1.5) : null,
          ),
          child: Row(children: [
            EvIcon(EvIcons.plus, size: s.rem(1.25), color: hovered ? t.ink : t.ink2),
            SizedBox(width: s.rem(0.75)),
            Text(label, style: t.bodyStyle(s.font(1.0), fontWeight: FontWeight.w500, color: hovered ? t.ink : t.ink2)),
            SizedBox(width: s.rem(1.0)),
            Expanded(
              child: Text(hint, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: t.bodyStyle(s.font(0.875), color: t.ink3)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildAddressForm(EvTheme t, EvScale s, {required bool isAdd, String? editId, required bool canDelete}) {
    return Padding(
      key: Key(isAdd ? 'ev_settings_add_addr_form' : 'ev_addr_edit_form_$editId'),
      padding: EdgeInsets.fromLTRB(s.rem(1.125), s.rem(0.75), s.rem(1.125), s.rem(1.0)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EvSettingsTextField(
            key: const Key('ev_addr_url_input'),
            controller: _urlCtrl,
            placeholder: '服务器地址（如 https://nas.tail-example.ts.net 或 192.168.1.20:8096）',
            onSubmitted: (_) => unawaited(_saveAddressForm()),
          ),
          SizedBox(height: s.rem(0.5)),
          Row(children: [
            Expanded(
              child: EvSettingsTextField(
                key: const Key('ev_addr_label_input'),
                controller: _labelCtrl,
                placeholder: '标签（如 内网、Tailscale）',
              ),
            ),
            SizedBox(width: s.rem(0.5)),
            Expanded(
              flex: 2,
              child: EvSettingsTextField(
                key: const Key('ev_addr_sub_input'),
                controller: _subCtrl,
                placeholder: '说明（如 在家时用、出门时自动换到这里）',
                onSubmitted: (_) => unawaited(_saveAddressForm()),
              ),
            ),
          ]),
          if (_addressFormError != null) ...[
            SizedBox(height: s.rem(0.5)),
            Text(_addressFormError!, key: const Key('ev_addr_form_error'),
              style: t.bodyStyle(s.font(0.8125), color: t.isPaper ? const Color(0xFFC8463A) : evDangerColor)),
          ],
          SizedBox(height: s.rem(0.75)),
          Row(children: [
            if (!isAdd && canDelete && editId != null)
              _dangerBtn(t, s, key: Key('ev_addr_delete_$editId'), label: '删除', primary: false,
                onPressed: _busy ? null : () => unawaited(() async {
                  setState(() => _busy = true);
                  try {
                    await widget.onRemoveAddress?.call(editId);
                    if (mounted) setState(() { _busy = false; _editingAddressId = null; });
                  } finally {
                    if (mounted && _busy) setState(() => _busy = false);
                  }
                }())),
            const Spacer(),
            EvButton.ghost(key: const Key('ev_addr_cancel'), small: true, label: '取消', onPressed: _busy ? null : _closeAddressForm),
            SizedBox(width: s.rem(0.5)),
            EvButton.primary(key: Key(isAdd ? 'ev_addr_add_save' : 'ev_addr_save'), small: true,
              label: isAdd ? '添加' : '保存', onPressed: _busy ? null : () => unawaited(_saveAddressForm())),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final snapshot = widget.snapshot, prefs = widget.prefs, cur = snapshot.current;
    final profiles = [...snapshot.profiles, if (cur != null && snapshot.profiles.every((p) => p.id != cur.id)) cur];
    final addresses = _addresses;
    final activeAddr = snapshot.activeAddress ?? (addresses.isNotEmpty ? addresses.first : null);
    final serverName = (snapshot.serverName?.trim().isNotEmpty ?? false) ? snapshot.serverName!.trim() : 'Emby 服务器';
    final ver = snapshot.serverVersion?.trim();
    final activeLabel = activeAddr?.label.trim().isNotEmpty == true
        ? activeAddr!.label.trim()
        : (activeAddr != null ? inferServerAddressLabel(activeAddr.url) : '');
    final overviewParts = <String>[
      if (ver != null && ver.isNotEmpty) 'Emby $ver',
      if (activeLabel.isNotEmpty) '走$activeLabel',
      if (snapshot.latencyMs != null) '${snapshot.latencyMs} ms',
    ];
    final serverDesc = overviewParts.isNotEmpty
        ? overviewParts.join(' · ')
        : (activeAddr != null ? formatServerAddressForDisplay(activeAddr.url) : '未配置服务器');
    final (connLabel, connTone) = switch (snapshot.connection) {
      ConnectionState.connected => ('已连接', EvStatusTone.ok),
      ConnectionState.disconnected => ('已断开', EvStatusTone.error),
      ConnectionState.unknown => ('未检测', EvStatusTone.warn),
    };
    final checkColor = t.isPaper ? const Color(0xFFB5532F) : const Color(0xFF34C759);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      evPaneTitle(t, s, '用户与服务器'),
      EvSettingsGroup(title: '服务器', children: [
        EvSettingsRow(
          key: const Key('ev_settings_server_overview'),
          leading: Container(
            width: s.rem(2.75), height: s.rem(2.75), alignment: Alignment.center,
            decoration: BoxDecoration(color: t.fill2, borderRadius: BorderRadius.circular(s.rem(0.75))),
            child: EvIcon(EvIcons.server, size: s.rem(1.5), color: t.ink),
          ),
          title: serverName,
          subtitle: serverDesc,
          trailing: EvStatusIndicator(key: const Key('ev_settings_connection_status'), label: connLabel, tone: connTone),
        ),
        for (var i = 0; i < addresses.length; i++) ...[
          () {
            final addr = addresses[i];
            final isActive = activeAddr?.id == addr.id;
            final tagText = [
              if (addr.label.trim().isNotEmpty) addr.label.trim(),
              if (addr.subtitle.trim().isNotEmpty) addr.subtitle.trim(),
            ].join(' · ');
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EvSettingsRow(
                  key: Key('ev_addr_row_${addr.id}'),
                  leading: SizedBox(
                    width: s.rem(1.25),
                    child: isActive ? Center(child: EvIcon(EvIcons.check, size: s.rem(1.0), color: checkColor)) : null,
                  ),
                  title: formatServerAddressForDisplay(addr.url),
                  subtitle: tagText.isNotEmpty ? tagText : null,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (isActive) ...[
                      EvStatusIndicator(key: Key('ev_addr_active_${addr.id}'), label: '正在用', tone: EvStatusTone.ok),
                      SizedBox(width: s.rem(0.625)),
                    ] else if (widget.onActivateAddress != null) ...[
                      EvButton.ghost(
                        key: Key('ev_addr_use_${addr.id}'), small: true, label: '使用',
                        onPressed: _busy ? null : () => unawaited(widget.onActivateAddress!(addr.id)),
                      ),
                      SizedBox(width: s.rem(0.375)),
                    ],
                    if (addresses.length > 1) ...[
                      EvButton.ghost(
                        key: Key('ev_addr_move_up_${addr.id}'), small: true, round: true, tooltip: '上移',
                        onPressed: (!_busy && i > 0) ? () => unawaited(_moveAddress(i, -1)) : null,
                        child: EvChevronIcon(up: true, size: s.rem(1.0), color: t.ink),
                      ),
                      SizedBox(width: s.rem(0.25)),
                      EvButton.ghost(
                        key: Key('ev_addr_move_down_${addr.id}'), small: true, round: true, tooltip: '下移',
                        onPressed: (!_busy && i < addresses.length - 1) ? () => unawaited(_moveAddress(i, 1)) : null,
                        child: EvChevronIcon(up: false, size: s.rem(1.0), color: t.ink),
                      ),
                      SizedBox(width: s.rem(0.375)),
                    ],
                    EvButton.ghost(
                      key: Key('ev_addr_edit_${addr.id}'), small: true, round: true, tooltip: '修改',
                      icon: EvIcons.edit,
                      onPressed: _busy ? null : () => _editingAddressId == addr.id ? _closeAddressForm() : _startEditAddress(addr),
                    ),
                  ]),
                ),
                if (_editingAddressId == addr.id)
                  _buildAddressForm(t, s, isAdd: false, editId: addr.id, canDelete: addresses.length > 1),
              ],
            );
          }(),
        ],
        if (_addingAddress)
          _buildAddressForm(t, s, isAdd: true, canDelete: false)
        else
          _gaddRow(
            t, s,
            key: const Key('ev_settings_add_addr'),
            label: '添加地址',
            hint: '比如 Tailscale 或公网域名',
            onTap: _busy ? null : _startAddAddress,
          ),
        _toggleRow(
          'ev_toggle_auto_switch_addr',
          '连不上时自动换下一个地址',
          '按上面的顺序试，可拖动调整；换地址时顶部提示一下',
          prefs.autoSwitchServerAddress,
          (v) => widget.onUpdatePrefs(evCopyPreferences(prefs, autoSwitchServerAddress: v)),
        ),
      ]),
      EvSettingsGroup(title: '这台 Mac 上保存的账号', children: [
        for (var i = 0; i < profiles.length; i++) () {
          final p = profiles[i];
          final isCurrent = cur?.id == p.id;
          final keyDesc = p.hasPassword == false ? '不用密码' : '密码存在钥匙串';
          final lastUsed = _formatLastUsed(p);
          final sub = isCurrent
              ? '当前 · 可见 ${p.visibleLibraryCount ?? widget.visibleZoneCount} 个片库 · $keyDesc'
              : [keyDesc, ?lastUsed].join(' · ');
          return ConstrainedBox(
            key: Key('ev_settings_account_row_${p.id}'),
            constraints: BoxConstraints(minHeight: s.rem(3.75)),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: s.rem(1.125), vertical: s.rem(0.8125)),
              child: Row(children: [
                Expanded(
                  child: EvInteractive(
                    key: Key('ev_settings_profile_${p.id}'),
                    selected: isCurrent,
                    label: p.displayName,
                    onTap: () => widget.onSwitchProfile(p.id),
                    builder: (_, hovered, focused) => Row(children: [
                      EvAvatarButton(profile: p, size: s.rem(2.5), colorIndex: i),
                      SizedBox(width: s.rem(1.0)),
                      Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: t.bodyStyle(s.font(1.0), fontWeight: FontWeight.w500, color: (hovered || focused) ? t.ink : t.ink)),
                        SizedBox(height: s.rem(0.25)),
                        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: t.bodyStyle(s.font(0.875), color: t.ink3, height: 1.45)),
                      ])),
                    ]),
                  ),
                ),
                SizedBox(width: s.rem(1.0)),
                if (isCurrent)
                  EvButton.ghost(
                    key: Key('ev_settings_logout_${p.id}'),
                    small: true, icon: EvIcons.logout, label: '退出登录',
                    onPressed: _busy ? null : () => unawaited(widget.onSignOut?.call() ?? Future.value()),
                  )
                else if (_confirmRemoveAccountId == p.id)
                  Wrap(
                    key: Key('ev_settings_remove_confirm_${p.id}'),
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: s.rem(0.5),
                    runSpacing: s.rem(0.375),
                    children: [
                      Text('只删这台 Mac 上的登录', style: t.bodyStyle(s.font(0.875), color: t.ink2)),
                      _dangerBtn(
                        t, s,
                        key: Key('ev_settings_remove_ok_${p.id}'),
                        label: '移出', primary: true,
                        onPressed: _busy ? null : () => unawaited(() async {
                          setState(() { _busy = true; _confirmRemoveAccountId = null; });
                          try {
                            await widget.onRemoveAccount?.call(p.id);
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        }()),
                      ),
                      EvButton.ghost(
                        key: Key('ev_settings_remove_cancel_${p.id}'),
                        small: true, label: '取消',
                        onPressed: _busy ? null : () => setState(() => _confirmRemoveAccountId = null),
                      ),
                    ],
                  )
                else
                  EvButton.ghost(
                    key: Key('ev_settings_remove_btn_${p.id}'),
                    small: true, label: '移出本机',
                    onPressed: _busy ? null : () => setState(() => _confirmRemoveAccountId = p.id),
                  ),
              ]),
            ),
          );
        }(),
        _gaddRow(
          t, s,
          key: const Key('ev_settings_profiles_manage'),
          label: '添加账号',
          hint: '从这台服务器的用户里选',
          onTap: widget.onAddAccount ?? widget.onOpenUsers,
        ),
        _toggleRow(
          'ev_toggle_choose_user',
          '打开时询问“谁在看”',
          '多人共用这台 Mac 时开启；关着就直接进上次的账号',
          prefs.chooseUserOnStartup,
          (v) => widget.onUpdatePrefs(evCopyPreferences(prefs, chooseUserOnStartup: v)),
        ),
      ]),
      EvSettingsGroup(children: [
        EvSettingsRow(
          title: '连接其他服务器',
          subtitle: '添加或换到另一台 Emby 服务器',
          trailing: EvButton.ghost(
            key: const Key('ev_settings_connect_other_server'),
            small: true, icon: EvIcons.server, label: '连接…',
            onPressed: widget.onSwitchServer,
          ),
        ),
        EvSettingsRow(
          title: '移除这台服务器',
          subtitle: '删掉这台服务器的地址和这里保存的所有账号，回到登录页',
          trailing: _confirmRemoveServer
              ? Wrap(
                  key: const Key('ev_settings_remove_server_confirm'),
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: s.rem(0.5),
                  runSpacing: s.rem(0.375),
                  children: [
                    Text('只删这台 Mac 上的记录', style: t.bodyStyle(s.font(0.875), color: t.ink2)),
                    _dangerBtn(
                      t, s,
                      key: const Key('ev_settings_remove_server_ok'),
                      label: '移除', primary: true,
                      onPressed: _busy ? null : () => unawaited(() async {
                        setState(() { _busy = true; _confirmRemoveServer = false; });
                        try {
                          await widget.onRemoveServer?.call();
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      }()),
                    ),
                    EvButton.ghost(
                      key: const Key('ev_settings_remove_server_cancel'),
                      small: true, label: '取消',
                      onPressed: _busy ? null : () => setState(() => _confirmRemoveServer = false),
                    ),
                  ],
                )
              : _dangerBtn(
                  t, s,
                  key: const Key('ev_settings_remove_server_btn'),
                  label: '移除…', primary: false,
                  onPressed: _busy ? null : () => setState(() => _confirmRemoveServer = true),
                ),
        ),
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
    required this.configuredSecrets, required this.loadingSecrets, required this.savingAddress, required this.onSaveSecret,
  });
  final LocalPreferences prefs;
  final bool subtitlesAvailable, loadingUsage, loadingSecrets, savingAddress;
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
    if (widget.savingAddress) return;
    final valid = parseTranslationBaseUrl(address) != null;
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
      ListenableBuilder(listenable: Listenable.merge([_address, _model]), builder: (_, _) {
        final addressChanged = _address.text.trim() != prefs.translationBaseUrl;
        final origin = parseTranslationBaseUrl(prefs.translationBaseUrl)?.origin;
        final changed = addressChanged || _model.text.trim() != prefs.translationModel;
        return _SecretGroup(title: '翻译服务', items: const [_translationKey], origin: origin,
          keyNotice: widget.savingAddress ? '正在保存地址' : addressChanged || origin == null ? '请先保存地址' : null,
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
                EvButton.ghost(key: const Key('ev_ai_translation_save'), small: true,
                  label: '保存配置', onPressed: changed && !widget.savingAddress ? _applyTranslation : null),
              ]))),
          ]);
      }),
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
  const EvKeysSettingsPane({super.key, required this.configuredSecrets, required this.loadingSecrets, required this.onSaveSecret,
    required this.origin, required this.savingAddress});
  final String? origin;
  final bool savingAddress;
  final Set<SecretKind> configuredSecrets;
  final bool loadingSecrets;
  final Future<void> Function(SecretKind kind, String? value) onSaveSecret;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    evPaneTitle(EvTheme.of(context), EvScale.of(context), '密钥'),
    _SecretGroup(title: '存在本机钥匙串', origin: origin, keyNotice: savingAddress ? '正在保存地址' : origin == null ? '请先保存地址' : null,
      configuredSecrets: configuredSecrets, loadingSecrets: loadingSecrets, onSaveSecret: onSaveSecret,
      items: const [_translationKey, (SecretKind.assrt, '射手网 assrt', '字幕检索'), (SecretKind.openSubtitles, 'OpenSubtitles', '字幕检索')]),
  ]);
}

const _translationKey = (SecretKind.openAi, '翻译密钥', '仅存本机钥匙串');

class _SecretGroup extends StatefulWidget {
  const _SecretGroup({required this.title, this.prefix = const [], required this.items, required this.origin, this.keyNotice,
    required this.configuredSecrets, required this.loadingSecrets, required this.onSaveSecret});
  final String title;
  final List<Widget> prefix;
  final List<(SecretKind, String, String)> items;
  final String? origin, keyNotice;
  final Set<SecretKind> configuredSecrets;
  final bool loadingSecrets;
  final Future<void> Function(SecretKind kind, String? value) onSaveSecret;
  @override State<_SecretGroup> createState() => _SecretGroupState();
}

class _SecretGroupState extends State<_SecretGroup> {
  SecretKind? _editing;
  final _ctrl = TextEditingController();
  bool _saving = false;
  String? _error;
  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override void didUpdateWidget(_SecretGroup old) {
    super.didUpdateWidget(old);
    if (_editing == SecretKind.openAi && (old.origin != widget.origin || widget.keyNotice != null)) {
      _ctrl.clear();
      _editing = null;
      _error = null;
    }
  }

  Future<void> _commit(SecretKind kind, String? value) async {
    if (_saving || _editing != kind || (value != null && value.isEmpty)) return;
    setState(() { _saving = true; _error = null; });
    try {
      await widget.onSaveSecret(kind, value);
      if (mounted) { _ctrl.clear(); setState(() => _editing = null); }
    } catch (error) {
      if (mounted && _editing == kind) {
        final reason = error is EmbyViewFailure ? error.reason : '密钥保存失败。';
        setState(() => _error = reason.contains('重试') ? reason : '$reason请重试。');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return EvSettingsGroup(title: widget.title, children: [
        ...widget.prefix,
        for (final (kind, title, sub) in widget.items) () {
          final notice = kind == SecretKind.openAi ? widget.keyNotice : null;
          final ok = notice == null && widget.configuredSecrets.contains(kind);
          final error = _editing == kind ? _error : null;
          return EvSettingsRow(
            key: Key('ev_secret_row_${kind.name}'), title: title, subtitle: error ?? sub, subtitleColor: error == null ? null : evDangerColor,
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
                label: notice ?? (widget.loadingSecrets ? '检测中' : ok ? '已设置' : '缺少'), tone: ok && !widget.loadingSecrets ? EvStatusTone.ok : EvStatusTone.warn),
              SizedBox(width: s.rem(0.75)),
              EvButton.ghost(key: Key('ev_secret_edit_${kind.name}'), small: true, label: ok ? '更新' : '填写',
                onPressed: _saving || widget.loadingSecrets || notice != null ? null : () => setState(() {
                  _ctrl.clear(); _error = null; _editing = _editing == kind ? null : kind;
                })),
            ]),
          );
        }(),
    ]);
  }
}

/// 10. Keyboard shortcuts pane (`settings:shortcuts`) mirroring `paneKeys` in `.spec/mockups/proto.js`.
class EvShortcutsSettingsPane extends StatelessWidget {
  const EvShortcutsSettingsPane({super.key, this.groups = evShortcutGroups});

  final List<EvShortcutGroup> groups;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return Column(
      key: const Key('ev_settings_shortcuts_pane'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        evPaneTitle(t, s, '快捷键'),
        for (final group in groups)
          EvSettingsGroup(
            title: group.title,
            children: [
              for (final item in group.items)
                EvSettingsRow(
                  title: item.label,
                  trailing: EvKeycapSequence(item.keys),
                ),
            ],
          ),
        Padding(
          padding: EdgeInsets.only(top: s.rem(0.25)),
          child: Wrap(
            key: const Key('ev_settings_shortcuts_note'),
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: s.rem(0.375),
            runSpacing: s.rem(0.375),
            children: [
              Text('随时按', style: t.bodyStyle(s.font(0.9375), color: t.ink3)),
              const EvKeycapSequence('?'),
              Text('或', style: t.bodyStyle(s.font(0.9375), color: t.ink3)),
              const EvKeycapSequence('⌘ /'),
              Text('打开速查卡。', style: t.bodyStyle(s.font(0.9375), color: t.ink3)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 11. About pane (`about`) mirroring `paneAbout` in `.spec/mockups/proto.js`.
class EvAboutSettingsPane extends StatefulWidget {
  const EvAboutSettingsPane({
    super.key,
    this.buildInfo = EvBuildInfo.current,
    this.asr = const LocalSubtitleAsr(),
    this.diagnosticsExporter = const EvDiagnosticsExporter(),
    this.onExportDiagnostics,
    this.onOpenSourceUrl,
  });

  final EvBuildInfo buildInfo;
  final LocalSubtitleAsr asr;
  final EvDiagnosticsExporter diagnosticsExporter;

  /// Optional override for exporting sanitized diagnostic logs (used by tests or
  /// custom hosts). When null, prompts with a save dialog and exports via
  /// [diagnosticsExporter].
  final Future<EvDiagnosticsExportResult?> Function()? onExportDiagnostics;

  /// Optional override for opening [EvBuildInfo.sourceRepoUrl].
  final Future<void> Function(Uri uri)? onOpenSourceUrl;

  @override
  State<EvAboutSettingsPane> createState() => _EvAboutSettingsPaneState();
}

class _EvAboutSettingsPaneState extends State<EvAboutSettingsPane> {
  AsrModelStatus? _asrStatus;
  bool _asrLoaded = false;
  Timer? _asrTimer;
  int? _recentLogBytes;
  bool _exporting = false;
  String? _exportMessage;
  bool _exportIsError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshAsrStatus());
    unawaited(_refreshLogSize());
  }

  @override
  void dispose() {
    _asrTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAsrStatus() async {
    _asrTimer?.cancel();
    try {
      final status = await widget.asr.modelStatus();
      if (!mounted) return;
      setState(() {
        _asrStatus = status;
        _asrLoaded = true;
      });
      if (status.state == AsrModelState.downloading) {
        _asrTimer = Timer(const Duration(milliseconds: 500), _refreshAsrStatus);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _asrStatus = null;
        _asrLoaded = true;
      });
    }
  }

  Future<void> _refreshLogSize() async {
    try {
      final bytes = await widget.diagnosticsExporter.estimateRecentLogsBytes();
      if (!mounted) return;
      setState(() => _recentLogBytes = bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _recentLogBytes = 0);
    }
  }

  Future<void> _handleExport() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _exportMessage = null;
      _exportIsError = false;
    });
    try {
      EvDiagnosticsExportResult? result;
      if (widget.onExportDiagnostics != null) {
        result = await widget.onExportDiagnostics!();
      } else {
        final ts = DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
        final path = await FilePicker.saveFile(
          dialogTitle: '导出诊断日志',
          fileName: 'EmbyView-diagnostics-$ts.log',
          type: FileType.custom,
          allowedExtensions: const ['log', 'txt'],
        );
        if (path != null && path.isNotEmpty) {
          result = await widget.diagnosticsExporter.exportSanitizedBundle(
            destinationPath: path,
            buildInfo: widget.buildInfo,
          );
        }
      }
      if (!mounted) return;
      if (result != null) {
        setState(() {
          _exportMessage = '已导出脱敏日志（${EvDiagnosticsExporter.formatByteSize(result!.byteCount)}）：${result.path}';
          _exportIsError = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exportMessage = e is EmbyViewFailure ? e.reason : '导出诊断日志失败，请重试。';
        _exportIsError = true;
      });
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _handleOpenSource() async {
    final uri = Uri.parse(widget.buildInfo.sourceRepoUrl);
    if (widget.onOpenSourceUrl != null) {
      await widget.onOpenSourceUrl!(uri);
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _exportMessage = '无法打开浏览器，请手动访问 ${widget.buildInfo.sourceRepoUrl}';
        _exportIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final status = _asrStatus;
    final state = status?.state;
    final received = status?.receivedBytes ?? 0;
    final total = status?.totalBytes ?? 0;
    final pct = total > 0 ? ((received / total).clamp(0.0, 1.0) * 100).round() : 0;
    final modelSizeLabel = total > 0 ? '${(total / 1000000).round()} MB' : '574 MB';
    final (asrLabel, asrTone) = switch (state) {
      AsrModelState.ready => ('已下载', EvStatusTone.ok),
      AsrModelState.downloading => ('下载中 $pct%', EvStatusTone.warn),
      AsrModelState.failed => ('下载失败', EvStatusTone.error),
      AsrModelState.notDownloaded => (received > 0 ? '已暂停' : '未下载', EvStatusTone.warn),
      null => (_asrLoaded ? '未下载' : '检测中', EvStatusTone.warn),
    };
    final logSizeText = _recentLogBytes == null
        ? '计算中…'
        : EvDiagnosticsExporter.formatByteSize(_recentLogBytes!);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.only(top: s.rem(0.5), bottom: s.rem(2.0)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EvAppIcon(key: const Key('ev_about_app_icon'), size: s.rem(9.0)),
            SizedBox(height: s.rem(0.25)),
            Text('EmbyView', style: t.displayStyle(s.font(2.25))),
            SizedBox(height: s.rem(0.25)),
            Text(
              widget.buildInfo.formattedVersion,
              key: const Key('ev_about_version'),
              style: t.bodyStyle(s.font(1.0), color: t.ink3)
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            SizedBox(height: s.rem(1.25)),
            Wrap(
              spacing: s.rem(0.625),
              runSpacing: s.rem(0.5),
              alignment: WrapAlignment.center,
              children: [
                EvButton.ghost(
                  key: const Key('ev_about_export_logs'),
                  small: true,
                  icon: EvIcons.download,
                  label: _exporting ? '正在导出…' : '导出诊断日志…',
                  onPressed: _exporting ? null : () => unawaited(_handleExport()),
                ),
                EvButton.ghost(
                  key: const Key('ev_about_source_code'),
                  small: true,
                  icon: EvIcons.globe,
                  label: '源代码',
                  onPressed: () => unawaited(_handleOpenSource()),
                ),
              ],
            ),
            if (_exportMessage != null) ...[
              SizedBox(height: s.rem(0.75)),
              Text(
                _exportMessage!,
                key: const Key('ev_about_export_feedback'),
                textAlign: TextAlign.center,
                style: t.bodyStyle(
                  s.font(0.875),
                  color: _exportIsError ? evDangerColor : t.ink3,
                ),
              ),
            ],
          ],
        ),
      ),
      EvSettingsGroup(children: [
        EvSettingsRow(
          title: '基于 ${widget.buildInfo.upstreamBase}',
          subtitle: '按 ${widget.buildInfo.license} 开源，改过的源代码同样公开',
          trailing: evValueText(t, s, widget.buildInfo.license),
        ),
        const EvSettingsRow(
          title: '播放引擎',
          subtitle: 'AetherEngine · Anime4K',
          trailing: EvStatusIndicator(
            key: Key('ev_about_engine_status'),
            label: '就绪',
            tone: EvStatusTone.ok,
          ),
        ),
        EvSettingsRow(
          title: '本机听写模型',
          subtitle: 'whisper large-v3-turbo · $modelSizeLabel',
          trailing: EvStatusIndicator(
            key: const Key('ev_about_asr_status'),
            label: asrLabel,
            tone: asrTone,
          ),
        ),
        EvSettingsRow(
          title: '诊断日志',
          subtitle: '最近 7 天的连接、起播和字幕记录；导出时去掉密码、密钥和服务器地址',
          trailing: Text(
            logSizeText,
            key: const Key('ev_about_log_size'),
            style: t.bodyStyle(s.font(0.9375), color: t.ink3)
                .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ]),
    ]);
  }
}
