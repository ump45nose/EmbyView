import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

const Color _kTransparent = Color(0x00000000);
const Color _kDangerCinema = Color(0xFFE5484D);
const Color _kDangerPaper = Color(0xFFC8463A);

enum _UsersFormMode { none, password, signIn }

/// Multi-user "Who's watching?" profile selector mirroring `vProfiles` in
/// `.spec/mockups/proto.js` and `.profiles` / `.pf` in `.spec/mockups/proto.css`.
class EvUsersPage extends StatefulWidget {
  const EvUsersPage({
    super.key,
    this.initialManageMode = false,
    this.onSelected,
    this.onManageUsers,
    this.onAddUser,
    this.onSwitchServer,
    this.onSignedOutToUserPicker,
  });

  final bool initialManageMode;
  final ValueChanged<AccountProfile>? onSelected;
  final VoidCallback? onManageUsers, onAddUser, onSwitchServer, onSignedOutToUserPicker;

  @override State<EvUsersPage> createState() => _EvUsersPageState();
}

class _EvUsersPageState extends State<EvUsersPage> {
  EmbyViewAccounts? _boundAccounts;
  StreamSubscription<AccountSnapshot>? _accountsSub;
  AccountSnapshot _snapshot = const AccountSnapshot(phase: AccountPhase.choosing);
  String? _activeSessionId, _activeUserId;

  late bool _manageMode = widget.initialManageMode;
  String? _confirmRemoveProfileId;

  bool _busy = false;
  String? _switchingProfileId, _statusText, _errorMessage;
  AccountProfile? _failedProfile, _passwordProfile;
  _UsersFormMode _formMode = _UsersFormMode.none;

  final _serverCtrl = TextEditingController(), _userCtrl = TextEditingController(), _passwordCtrl = TextEditingController();
  final _serverFocus = FocusNode(debugLabel: 'ev_users_server');
  final _userFocus = FocusNode(debugLabel: 'ev_users_username');
  final _passwordFocus = FocusNode(debugLabel: 'ev_users_password');

  @override
  void didUpdateWidget(EvUsersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialManageMode != widget.initialManageMode) {
      _manageMode = widget.initialManageMode;
      _confirmRemoveProfileId = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context);
    if (!identical(_boundAccounts, scope.services.accounts)) {
      _bindScope(scope);
    } else if (scope.services.sessionId != _activeSessionId && scope.services.accounts.snapshot.phase == AccountPhase.signedIn) {
      _onAccountChanged(scope.services.accounts.snapshot);
    }
  }

  void _bindScope(EvScope scope) {
    final accounts = scope.services.accounts;
    _boundAccounts = accounts;
    unawaited(_accountsSub?.cancel());
    _snapshot = accounts.snapshot;
    _activeSessionId = _snapshot.sessionId;
    _activeUserId = _snapshot.current?.id;
    _resetTransientState();
    _accountsSub = accounts.changes.listen(_onAccountChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scope.immersion.onCardHoverEnd();
      scope.stage..setMode(EvStageMode.ambient)..setScrollProgress(0.6)..setVeilLifted(false)..clearPreviewBackdrop();
      scope.shell.updateChrome(clearTitlePlate: true, rightActions: const [], hideTabs: true, hideAvatar: true);
    });
  }

  void _onAccountChanged(AccountSnapshot next) {
    if (!mounted) return;
    final inProgress = next.phase == AccountPhase.switching || next.phase == AccountPhase.signingIn;
    final switched = next.phase == AccountPhase.signedIn &&
        next.failure == null &&
        (next.sessionId != _activeSessionId || next.current?.id != _activeUserId);
    setState(() {
      _snapshot = next;
      if (_confirmRemoveProfileId != null && next.profiles.every((p) => p.id != _confirmRemoveProfileId) && next.current?.id != _confirmRemoveProfileId) {
        _confirmRemoveProfileId = null;
      }
      if (inProgress) return;
      if (switched) {
        _activeSessionId = next.sessionId;
        _activeUserId = next.current?.id;
        _resetTransientState();
      } else if (next.phase == AccountPhase.signedIn && next.failure != null && next.current?.id == _activeUserId) {
        _activeSessionId = next.sessionId;
        if (!_busy) _errorMessage ??= next.failure!.reason;
      } else if (next.phase == AccountPhase.signedIn && next.failure == null && !_busy) {
        _errorMessage = null;
        _failedProfile = null;
      } else if (next.failure != null && !_busy) {
        _errorMessage ??= next.failure!.reason;
      }
    });
  }

  void _resetTransientState() {
    _busy = false;
    _switchingProfileId = _statusText = _errorMessage = null;
    _failedProfile = _passwordProfile = null;
    _formMode = _UsersFormMode.none;
    _passwordCtrl.clear();
  }

  List<AccountProfile> get _profiles => <AccountProfile>[
    ..._snapshot.profiles,
    if (_snapshot.current != null && _snapshot.profiles.every((p) => p.id != _snapshot.current!.id)) _snapshot.current!,
  ];

  bool _needsPassword(EmbyViewFailure failure) {
    const codes = {'password_required', 'auth_required', 'unauthorized', 'invalid_credentials', 'sign_in_failed'};
    return (failure.code != null && codes.contains(failure.code!.toLowerCase())) ||
        failure.reason.contains('密码') || failure.reason.contains('重新登录');
  }

  Future<void> _onProfileActivated(AccountProfile profile) async {
    if (_busy || _manageMode) return;
    if (_snapshot.current?.id == profile.id && _snapshot.phase == AccountPhase.signedIn) {
      setState(_resetTransientState);
      widget.onSelected?.call(profile);
      return;
    }
    await _performSwitch(profile);
  }

  void _applySignedIn(AccountSnapshot snap, [AccountProfile? fallback]) {
    final selected = snap.current ?? fallback;
    setState(() { _snapshot = snap; _activeSessionId = snap.sessionId; _activeUserId = selected?.id; _resetTransientState(); });
    if (selected != null) widget.onSelected?.call(selected);
  }

  Future<void> _performSwitch(AccountProfile profile, {String? password}) async {
    final accounts = _boundAccounts;
    if (accounts == null || _busy) return;
    setState(() {
      _busy = true;
      _switchingProfileId = profile.id;
      _statusText = '正在切换至 ${profile.displayName}…';
      _errorMessage = null;
      _failedProfile = null;
      if (password == null) { _formMode = _UsersFormMode.none; _passwordProfile = null; }
    });
    try {
      await accounts.switchTo(profile.id, password: password);
      if (mounted) _applySignedIn(accounts.snapshot, profile);
    } catch (error) {
      if (!mounted) return;
      final failure = error is EmbyViewFailure ? error : null;
      final showPw = password != null || (failure != null && _needsPassword(failure));
      setState(() {
        _busy = false;
        _switchingProfileId = _statusText = null;
        _errorMessage = failure?.reason ?? '切换用户失败，请重试。';
        _failedProfile = profile;
        if (showPw) { _passwordProfile = profile; _formMode = _UsersFormMode.password; }
      });
      if (showPw) _requestLater(_passwordFocus);
    }
  }

  Future<void> _performRemove(AccountProfile profile) async {
    final accounts = _boundAccounts;
    if (accounts == null || _busy) return;
    final wasCurrent = _snapshot.current?.id == profile.id;
    setState(() {
      _busy = true;
      _statusText = '正在移出 ${profile.displayName}…';
      _errorMessage = null;
      _confirmRemoveProfileId = null;
    });
    try {
      await accounts.removeLocalAccount(profile.id);
      if (!mounted) return;
      setState(() {
        _snapshot = accounts.snapshot;
        _busy = false;
        _statusText = null;
      });
      if (wasCurrent) {
        (widget.onSignedOutToUserPicker ?? EvScope.maybeOf(context)?.shell.onSignedOutToUserPicker)?.call();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusText = null;
        _errorMessage = error is EmbyViewFailure ? error.reason : '无法移出本机账号，请重试。';
      });
    }
  }

  void _openPasswordForm(AccountProfile profile) {
    _passwordCtrl.clear();
    setState(() { _passwordProfile = profile; _formMode = _UsersFormMode.password; });
    _requestLater(_passwordFocus);
  }

  void _onAddUserActivated() {
    if (_busy) return;
    if (widget.onAddUser != null) { widget.onAddUser!(); return; }
    if (_formMode == _UsersFormMode.signIn) { _closeForm(); return; }
    if (_serverCtrl.text.isEmpty && (_snapshot.serverAddress?.isNotEmpty ?? false)) _serverCtrl.text = _snapshot.serverAddress!;
    _passwordCtrl.clear();
    setState(() { _errorMessage = null; _failedProfile = _passwordProfile = null; _formMode = _UsersFormMode.signIn; });
    _requestLater(_serverCtrl.text.isEmpty ? _serverFocus : _userFocus);
  }

  Future<void> _submitSignIn() async {
    final accounts = _boundAccounts;
    if (accounts == null || _busy) return;
    final uri = Uri.tryParse(_serverCtrl.text.trim()), username = _userCtrl.text.trim();
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      setState(() => _errorMessage = '请填写有效的 Emby 服务器地址（如 http://nas.local:8096）。');
      _serverFocus.requestFocus();
      return;
    }
    if (username.isEmpty) {
      setState(() => _errorMessage = '请填写用户名。');
      _userFocus.requestFocus();
      return;
    }
    setState(() { _busy = true; _switchingProfileId = _errorMessage = null; _failedProfile = null; _statusText = '正在登录 $username…'; });
    try {
      await accounts.signIn(uri, username, _passwordCtrl.text);
      if (!mounted) return;
      _userCtrl.clear();
      _applySignedIn(accounts.snapshot);
    } catch (error) {
      if (!mounted) return;
      setState(() { _busy = false; _statusText = null; _errorMessage = error is EmbyViewFailure ? error.reason : '登录失败，请检查信息后重试。'; });
    }
  }

  void _closeForm() {
    _passwordCtrl.clear();
    setState(() { _formMode = _UsersFormMode.none; _passwordProfile = null; _errorMessage = null; });
  }

  void _handleToggleManageMode() {
    if (_busy) return;
    if (_manageMode) {
      setState(() {
        _manageMode = false;
        _confirmRemoveProfileId = null;
      });
      return;
    }
    setState(() {
      _manageMode = true;
      _confirmRemoveProfileId = null;
      _formMode = _UsersFormMode.none;
      _passwordProfile = null;
      _errorMessage = null;
    });
    widget.onManageUsers?.call();
  }

  void _handleSwitchServer() {
    if (_busy) return;
    (widget.onSwitchServer ?? EvScope.maybeOf(context)?.shell.onSwitchServer)?.call();
  }

  void _handleEscape() {
    if (_formMode != _UsersFormMode.none) {
      _closeForm();
    } else if (_confirmRemoveProfileId != null) {
      setState(() => _confirmRemoveProfileId = null);
    } else if (_manageMode) {
      setState(() => _manageMode = false);
    }
  }

  void _requestLater(FocusNode node) => WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && node.canRequestFocus) node.requestFocus(); });

  @override
  void dispose() {
    unawaited(_accountsSub?.cancel());
    _serverCtrl.dispose(); _userCtrl.dispose(); _passwordCtrl.dispose();
    _serverFocus.dispose(); _userFocus.dispose(); _passwordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final profiles = _profiles, currentId = _snapshot.current?.id, avatarSize = scale.rem(7.5);
    final busyPhase = _busy || _snapshot.phase == AccountPhase.switching || _snapshot.phase == AccountPhase.signingIn;
    final statusLabel = _statusText ??
        (_snapshot.phase == AccountPhase.signingIn ? '正在登录…' : _snapshot.phase == AccountPhase.switching ? '正在切换用户…' : null);
    final serverName = _snapshot.serverName?.trim() ?? '';
    final displayAddr = formatServerAddressForDisplay(_snapshot.activeAddress?.url ?? _snapshot.serverAddress ?? '');
    final serverLabel = [
      if (serverName.isNotEmpty) serverName,
      if (displayAddr.isNotEmpty) displayAddr,
    ].join(' · ');

    final hasEscAction = _formMode != _UsersFormMode.none || _confirmRemoveProfileId != null || _manageMode;

    return Shortcuts(
      shortcuts: _formMode == _UsersFormMode.none ? const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(TraversalDirection.left),
        SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(TraversalDirection.right),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
      } : const {},
      child: CallbackShortcuts(
        bindings: {if (hasEscAction) const SingleActivator(LogicalKeyboardKey.escape): _handleEscape},
        child: FocusTraversalGroup(
          child: SizedBox.expand(
            key: const Key('ev_users_page'),
            child: LayoutBuilder(
              builder: (_, c) => SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: scale.gutter, vertical: scale.rem(3.0)),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: (c.maxHeight - scale.rem(6.0)).clamp(0.0, double.infinity)),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Text(
                        _manageMode ? '管理这台 Mac 上的账号' : '谁在看？',
                        key: const Key('ev_users_title'),
                        textAlign: TextAlign.center,
                        style: theme.displayStyle(scale.font(2.75)),
                      ),
                      SizedBox(height: scale.rem(3.0)),
                      Wrap(
                        key: const Key('ev_users_list'),
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.start,
                        spacing: scale.rem(3.0),
                        runSpacing: scale.rem(2.0),
                        children: [
                          for (var i = 0; i < profiles.length; i++)
                            ConstrainedBox(
                              constraints: BoxConstraints(minWidth: scale.rem(9.0)),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _EvUserTile(
                                    key: Key('ev_users_profile_${profiles[i].id}'),
                                    label: profiles[i].displayName,
                                    subtitle: _switchingProfileId == profiles[i].id
                                        ? '切换中…'
                                        : (currentId == profiles[i].id ? '当前' : null),
                                    subtitleKey: currentId == profiles[i].id
                                        ? Key('ev_users_current_${profiles[i].id}')
                                        : null,
                                    avatarSize: avatarSize,
                                    enabled: !busyPhase,
                                    interactive: !_manageMode,
                                    onActivate: () => unawaited(_onProfileActivated(profiles[i])),
                                    avatar: EvAvatarButton(profile: profiles[i], size: avatarSize, colorIndex: i),
                                  ),
                                  if (_manageMode) ...[
                                    SizedBox(height: scale.rem(1.0)),
                                    if (_confirmRemoveProfileId == profiles[i].id)
                                      _buildRemoveConfirmCard(theme, scale, profiles[i], busyPhase)
                                    else
                                      _EvRemovePillButton(
                                        key: Key('ev_users_remove_btn_${profiles[i].id}'),
                                        label: currentId == profiles[i].id ? '退出并移出' : '移出本机',
                                        enabled: !busyPhase,
                                        onTap: () => setState(() => _confirmRemoveProfileId = profiles[i].id),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          if (!_manageMode)
                            _EvUserTile(
                              key: const Key('ev_users_add_btn'),
                              label: '添加用户',
                              avatarSize: avatarSize,
                              enabled: !busyPhase,
                              onActivate: _onAddUserActivated,
                              avatar: Container(
                                width: avatarSize,
                                height: avatarSize,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: theme.fill3, width: 2.0)),
                                child: EvIcon(EvIcons.plus, size: scale.rem(2.75), color: theme.ink3),
                              ),
                            ),
                        ],
                      ),
                      if (statusLabel != null) ...[
                        SizedBox(height: scale.rem(1.75)),
                        Text(statusLabel, key: const Key('ev_users_status'), style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w500, color: theme.ink2)),
                      ],
                      if (_errorMessage != null) ...[SizedBox(height: scale.rem(1.5)), _buildErrorBanner(theme, scale, _errorMessage!)],
                      if (_formMode != _UsersFormMode.none) ...[SizedBox(height: scale.rem(1.75)), _buildInlineForm(theme, scale, busyPhase)],
                      SizedBox(height: scale.rem(3.0)),
                      Wrap(
                        key: const Key('ev_users_footer'),
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: scale.rem(0.625),
                        runSpacing: scale.rem(0.625),
                        children: [
                          Padding(
                            key: const Key('ev_users_server_info'),
                            padding: EdgeInsets.only(right: scale.rem(0.75)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                EvIcon(EvIcons.server, size: scale.rem(1.125), color: theme.ink3),
                                SizedBox(width: scale.rem(0.5)),
                                Text(
                                  serverLabel.isNotEmpty ? serverLabel : '未配置服务器',
                                  style: theme.bodyStyle(scale.font(0.9375), color: theme.ink3),
                                ),
                              ],
                            ),
                          ),
                          if (_manageMode)
                            EvButton.primary(
                              key: const Key('ev_users_manage_btn'),
                              label: '完成',
                              small: true,
                              onPressed: busyPhase ? null : _handleToggleManageMode,
                            )
                          else ...[
                            EvButton.ghost(
                              key: const Key('ev_users_manage_btn'),
                              icon: EvIcons.edit,
                              label: '管理',
                              small: true,
                              onPressed: busyPhase ? null : _handleToggleManageMode,
                            ),
                            EvButton.ghost(
                              key: const Key('ev_users_switch_server_btn'),
                              icon: EvIcons.server,
                              label: '换服务器',
                              small: true,
                              onPressed: busyPhase ? null : _handleSwitchServer,
                            ),
                          ],
                        ],
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRemoveConfirmCard(EvTheme theme, EvScale scale, AccountProfile profile, bool busy) {
    return SizedBox(
      width: scale.rem(16.0),
      child: EvGlass(
        key: Key('ev_users_remove_confirm_${profile.id}'),
        borderRadius: BorderRadius.circular(scale.rem(1.0)),
        padding: EdgeInsets.all(scale.rem(1.0)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '只删这台 Mac 上保存的登录，服务器上的账号不受影响。',
              textAlign: TextAlign.center,
              style: theme.bodyStyle(scale.font(0.875), color: theme.ink2, height: 1.5),
            ),
            SizedBox(height: scale.rem(0.75)),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _EvDangerPrimaryButton(
                  key: Key('ev_users_remove_confirm_ok_${profile.id}'),
                  label: '移出',
                  onPressed: busy ? null : () => unawaited(_performRemove(profile)),
                ),
                SizedBox(width: scale.rem(0.5)),
                EvButton.ghost(
                  key: Key('ev_users_remove_confirm_cancel_${profile.id}'),
                  label: '取消',
                  small: true,
                  onPressed: busy ? null : () => setState(() => _confirmRemoveProfileId = null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner(EvTheme theme, EvScale scale, String message) {
    final failed = _failedProfile;
    final danger = theme.isPaper ? _kDangerPaper : _kDangerCinema;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: scale.rem(34.0)),
      child: Container(
        key: const Key('ev_users_error'),
        padding: EdgeInsets.symmetric(horizontal: scale.rem(1.125), vertical: scale.rem(0.75)),
        decoration: BoxDecoration(
          color: danger.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(scale.rem(0.75)),
          border: Border.all(color: danger.withValues(alpha: 0.45), width: 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(message, style: theme.bodyStyle(scale.font(0.9375), color: danger, height: 1.4))),
          if (failed != null) ...[
            SizedBox(width: scale.rem(0.75)),
            EvButton.ghost(key: const Key('ev_users_retry_btn'), label: '重试', small: true, glass: false, onPressed: _busy ? null : () => unawaited(_performSwitch(failed))),
            if (_formMode != _UsersFormMode.password) ...[
              SizedBox(width: scale.rem(0.375)),
              EvButton.ghost(key: const Key('ev_users_enter_password_btn'), label: '输入密码', small: true, glass: false, onPressed: _busy ? null : () => _openPasswordForm(failed)),
            ],
          ],
        ]),
      ),
    );
  }

  Widget _buildInlineForm(EvTheme theme, EvScale scale, bool busy) {
    final isPw = _formMode == _UsersFormMode.password && _passwordProfile != null;
    void submit() => isPw ? unawaited(_performSwitch(_passwordProfile!, password: _passwordCtrl.text)) : unawaited(_submitSignIn());
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: scale.rem(28.0)),
      child: EvGlass(
        key: Key(isPw ? 'ev_users_password_form' : 'ev_users_signin_form'),
        borderRadius: BorderRadius.circular(scale.rem(1.125)), padding: EdgeInsets.all(scale.rem(1.25)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(isPw ? '为 ${_passwordProfile!.displayName} 输入密码' : '添加用户', style: theme.bodyStyle(scale.font(1.0625), fontWeight: FontWeight.w600, color: theme.ink)),
          SizedBox(height: scale.rem(0.875)),
          if (!isPw) ...[
            _EvTextField(key: const Key('ev_users_server_field'), controller: _serverCtrl, focusNode: _serverFocus,
                placeholder: 'Emby 服务器地址（如 http://nas.local:8096）', onSubmitted: (_) => _userFocus.requestFocus()),
            SizedBox(height: scale.rem(0.625)),
            _EvTextField(key: const Key('ev_users_username_field'), controller: _userCtrl, focusNode: _userFocus,
                placeholder: '用户名', onSubmitted: (_) => _passwordFocus.requestFocus()),
            SizedBox(height: scale.rem(0.625)),
          ],
          _EvTextField(key: const Key('ev_users_password_field'), controller: _passwordCtrl, focusNode: _passwordFocus,
              placeholder: isPw ? '密码' : '密码（可留空）', obscureText: true, onSubmitted: (_) => submit()),
          SizedBox(height: scale.rem(1.0)),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            EvButton.ghost(key: const Key('ev_users_form_cancel_btn'), label: '取消', small: true, glass: false, onPressed: busy ? null : _closeForm),
            SizedBox(width: scale.rem(0.625)),
            EvButton.primary(key: const Key('ev_users_form_submit_btn'), label: isPw ? '验证并切换' : '登录', small: true, onPressed: busy ? null : submit),
          ]),
        ]),
      ),
    );
  }
}

class _EvRemovePillButton extends StatefulWidget {
  const _EvRemovePillButton({super.key, required this.label, required this.enabled, required this.onTap});
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  @override State<_EvRemovePillButton> createState() => _EvRemovePillButtonState();
}

class _EvRemovePillButtonState extends State<_EvRemovePillButton> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final hi = widget.enabled && (_hovered || _focused);
    return Semantics(
      button: true, enabled: widget.enabled, label: widget.label,
      child: Focus(
        canRequestFocus: widget.enabled,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!widget.enabled || !evIsActivateKey(e)) return KeyEventResult.ignored;
          widget.onTap();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onTap : null,
            child: AnimatedContainer(
              duration: EvDurations.fast,
              curve: EvCurves.soft,
              height: scale.rem(2.25),
              padding: EdgeInsets.symmetric(horizontal: scale.rem(0.875)),
              decoration: BoxDecoration(
                color: hi ? theme.fill2 : theme.fill,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: _focused ? theme.focusColor : theme.line, width: _focused ? 1.5 : 1.0),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EvIcon(EvIcons.x, size: scale.rem(0.875), color: hi ? theme.ink : theme.ink2),
                  SizedBox(width: scale.rem(0.375)),
                  Text(widget.label, style: theme.bodyStyle(scale.font(0.875), color: hi ? theme.ink : theme.ink2)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvDangerPrimaryButton extends StatefulWidget {
  const _EvDangerPrimaryButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override State<_EvDangerPrimaryButton> createState() => _EvDangerPrimaryButtonState();
}

class _EvDangerPrimaryButtonState extends State<_EvDangerPrimaryButton> {
  bool _hovered = false, _focused = false;
  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final bg = theme.isPaper ? _kDangerPaper : _kDangerCinema;
    final radius = BorderRadius.circular(theme.isPaper ? scale.rem(0.625) : 999.0);
    return Semantics(
      button: true, enabled: _enabled, label: widget.label,
      child: Focus(
        canRequestFocus: _enabled,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!_enabled || !evIsActivateKey(e)) return KeyEventResult.ignored;
          widget.onPressed!();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _enabled ? widget.onPressed : null,
            child: AnimatedScale(
              scale: (_enabled && (_hovered || _focused)) ? 1.04 : 1.0,
              duration: EvDurations.normal, curve: EvCurves.spring,
              child: Opacity(
                opacity: _enabled ? 1.0 : 0.45,
                child: Container(
                  height: scale.rem(2.375),
                  padding: EdgeInsets.symmetric(horizontal: scale.rem(1.0625)),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: radius,
                    border: _focused ? Border.all(color: theme.focusColor, width: 1.5) : null,
                  ),
                  child: Text(widget.label, style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w600, color: const Color(0xFFFFFFFF))),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvUserTile extends StatefulWidget {
  const _EvUserTile({
    super.key,
    required this.label,
    required this.avatar,
    required this.avatarSize,
    required this.enabled,
    required this.onActivate,
    this.interactive = true,
    this.subtitle,
    this.subtitleKey,
  });
  final String label;
  final String? subtitle;
  final Key? subtitleKey;
  final Widget avatar;
  final double avatarSize;
  final bool enabled;
  final bool interactive;
  final VoidCallback onActivate;
  @override State<_EvUserTile> createState() => _EvUserTileState();
}

class _EvUserTileState extends State<_EvUserTile> {
  bool _hovered = false, _focused = false;
  bool get _canTap => widget.enabled && widget.interactive;
  bool get _highlighted => _canTap && (_hovered || _focused);

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final lift = _highlighted ? -scale.rem(0.25) : 0.0, ringScale = _highlighted ? 1.08 : 1.0;
    return Semantics(
      button: widget.interactive, enabled: widget.enabled, focused: _focused,
      label: widget.subtitle != null ? '${widget.label}（${widget.subtitle}）' : widget.label,
      child: Focus(
        canRequestFocus: _canTap, onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) { if (!_canTap || !evIsActivateKey(e)) return KeyEventResult.ignored; widget.onActivate(); return KeyEventResult.handled; },
        child: MouseRegion(
          cursor: _canTap ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: _canTap ? widget.onActivate : null,
            child: Opacity(
              opacity: widget.enabled ? 1.0 : 0.6,
              child: SizedBox(
                width: widget.avatarSize + scale.rem(1.75),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedContainer(
                    duration: EvDurations.medium, curve: EvCurves.spring, transformAlignment: Alignment.center,
                    transform: Matrix4.identity()..translateByDouble(0.0, lift, 0.0, 1.0)..scaleByDouble(ringScale, ringScale, 1.0, 1.0),
                    padding: const EdgeInsets.all(3.0),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle, color: _highlighted ? theme.bg : _kTransparent,
                      border: Border.all(color: _highlighted ? theme.ink : _kTransparent, width: 3.0),
                      boxShadow: _highlighted ? theme.cardShadowHi : null,
                    ),
                    child: widget.avatar,
                  ),
                  SizedBox(height: scale.rem(1.0)),
                  Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                      style: theme.bodyStyle(scale.font(1.1875), fontWeight: FontWeight.w500, color: _highlighted ? theme.ink : theme.ink2)),
                  if (widget.subtitle != null) ...[
                    SizedBox(height: scale.rem(0.25)),
                    Text(widget.subtitle!, key: widget.subtitleKey, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                        style: theme.bodyStyle(scale.font(0.875), color: theme.ink3)),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvTextField extends StatelessWidget {
  const _EvTextField({super.key, required this.controller, required this.focusNode, required this.placeholder, this.obscureText = false, this.onSubmitted});
  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final bool obscureText;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque, onTap: focusNode.requestFocus,
      child: ListenableBuilder(
        listenable: Listenable.merge([focusNode, controller]),
        builder: (_, _) {
          final focused = focusNode.hasFocus;
          final border = focused ? (theme.isPaper ? theme.brand : theme.ink2) : theme.line;
          return Container(
            height: scale.rem(2.75), padding: EdgeInsets.symmetric(horizontal: scale.rem(0.875)), alignment: Alignment.centerLeft,
            decoration: BoxDecoration(color: theme.fill2, borderRadius: BorderRadius.circular(scale.rem(0.625)), border: Border.all(color: border, width: focused ? 1.75 : 1.0)),
            child: Stack(alignment: Alignment.centerLeft, children: [
              if (controller.text.isEmpty)
                IgnorePointer(child: Text(placeholder, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.bodyStyle(scale.font(0.9375), color: theme.ink3))),
              EditableText(
                controller: controller, focusNode: focusNode, obscureText: obscureText, maxLines: 1,
                onSubmitted: onSubmitted, style: theme.bodyStyle(scale.font(1.0), color: theme.ink),
                cursorColor: theme.isPaper ? theme.brand : theme.ink, backgroundCursorColor: theme.ink4,
                selectionColor: theme.brand.withValues(alpha: 0.28),
              ),
            ]),
          );
        },
      ),
    );
  }
}
