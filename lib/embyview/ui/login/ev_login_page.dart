import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/login/ev_login_models.dart';
import 'package:moonfin/embyview/ui/shell/ev_avatar_menu.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

const Color _kTransparent = Color(0x00000000);
const Color _kCinemaGreen = Color(0xFF34C759);
const Color _kPaperTerracotta = Color(0xFFB5532F);
const Color _kCinemaWarn = Color(0xFFFFB547);
const Color _kCinemaErr = Color(0xFFFF6B5A);
const Color _kPaperErr = Color(0xFFC8463A);

/// Unified 5-step EmbyView login screen ported from `vLogin` in
/// `.spec/mockups/proto.js` and `.login` / `.lcard` / `.lpass` in `proto.css`.
///
/// Supports both cinema and paper themes, real backend integration via
/// [EvLoginBackend], and explicit [initialStep] / fixture injection for tests
/// and the Stage 7 demo launcher.
class EvLoginPage extends StatefulWidget {
  const EvLoginPage({
    super.key,
    this.backend,
    this.initialStep = EvLoginStep.server,
    this.initialServerId,
    this.initialAddress,
    this.initialServer,
    this.initialDiscoveredServers,
    this.initialUsers,
    this.initialSelectedUser,
    this.initialPassword,
    this.initialCertChallenge,
    this.initialFailure,
    this.initialRememberPassword = true,
    this.darkIcon = false,
    this.windowDragBuilder,
    this.onStepChanged,
    this.onSignedIn,
  });

  final EvLoginBackend? backend;
  final EvLoginStep initialStep;
  final String? initialServerId;
  final String? initialAddress;
  final EvConnectedServer? initialServer;
  final List<EvDiscoveredServer>? initialDiscoveredServers;
  final List<EvLoginUser>? initialUsers;
  final EvLoginUser? initialSelectedUser;
  final String? initialPassword;
  final EvCertChallenge? initialCertChallenge;
  final EvConnectFailure? initialFailure;
  final bool initialRememberPassword;
  final bool darkIcon;
  final WidgetBuilder? windowDragBuilder;
  final ValueChanged<EvLoginStep>? onStepChanged;
  final VoidCallback? onSignedIn;

  @override
  State<EvLoginPage> createState() => EvLoginPageState();
}

class EvLoginPageState extends State<EvLoginPage>
    with TickerProviderStateMixin {
  late EvLoginStep _step;
  late List<EvDiscoveredServer> _discovered;
  EvConnectedServer? _server;
  List<EvLoginUser> _users = const [];
  EvLoginUser? _selectedUser;
  bool _manualUserMode = false;
  EvCertChallenge? _cert;
  EvConnectFailure? _failure;
  late bool _rememberPassword;

  bool _discovering = false;
  bool _busy = false;
  String? _authError;

  final _addressCtrl = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'ev_login_address');
  final _usernameCtrl = TextEditingController();
  final _usernameFocus = FocusNode(debugLabel: 'ev_login_username');
  final _passwordCtrl = TextEditingController();
  final _passwordFocus = FocusNode(debugLabel: 'ev_login_password');

  StreamSubscription<List<EvDiscoveredServer>>? _discoverySub;
  AnimationController? _scanPingCtrl;

  @override
  void initState() {
    super.initState();
    _initFromWidget();
  }

  void _initFromWidget() {
    _step = widget.initialStep;
    _rememberPassword = widget.initialRememberPassword;
    _discovered = List<EvDiscoveredServer>.from(
      widget.initialDiscoveredServers ?? const [],
    );
    _server = widget.initialServer;
    _users = List<EvLoginUser>.from(widget.initialUsers ?? const []);
    _selectedUser = widget.initialSelectedUser;
    _cert = widget.initialCertChallenge;
    _failure = widget.initialFailure;
    _manualUserMode = false;
    _authError = null;
    _busy = false;

    if (widget.initialAddress != null) {
      _addressCtrl.text = widget.initialAddress!;
    } else if (_step == EvLoginStep.cert) {
      _cert ??= EvLoginDemoData.certChallenge;
      _addressCtrl.text = _cert!.address;
    } else if (_step == EvLoginStep.fail) {
      _failure ??= EvLoginDemoData.connectFailure;
      _addressCtrl.text = _failure!.address;
    } else {
      _addressCtrl.clear();
    }

    if (_step == EvLoginStep.pass) {
      if (_selectedUser == null && _users.isNotEmpty) {
        _selectedUser =
            _users.where((u) => u.hasPassword).firstOrNull ?? _users.first;
      }
      final initialPassword = widget.initialPassword ?? '';
      _passwordCtrl.value = TextEditingValue(
        text: initialPassword,
        selection: TextSelection.collapsed(offset: initialPassword.length),
      );
      _focusPasswordLater();
    } else {
      _passwordCtrl.clear();
    }

    if (widget.initialDiscoveredServers == null && widget.backend != null) {
      _startDiscovery();
    }
    if ((_step == EvLoginStep.users || _step == EvLoginStep.pass) &&
        _users.isEmpty &&
        widget.backend != null) {
      unawaited(_bootstrapUsersStep());
    }
  }

  @override
  void didUpdateWidget(EvLoginPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialStep != widget.initialStep ||
        oldWidget.initialServer != widget.initialServer ||
        oldWidget.initialServerId != widget.initialServerId ||
        oldWidget.initialSelectedUser != widget.initialSelectedUser ||
        oldWidget.initialCertChallenge != widget.initialCertChallenge ||
        oldWidget.initialFailure != widget.initialFailure ||
        oldWidget.initialAddress != widget.initialAddress) {
      unawaited(_discoverySub?.cancel());
      _discoverySub = null;
      _initFromWidget();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncScanAnimation(MediaQuery.disableAnimationsOf(context));
  }

  void _syncScanAnimation(bool disableAnimations) {
    if (disableAnimations) {
      _scanPingCtrl?.dispose();
      _scanPingCtrl = null;
    } else {
      _scanPingCtrl ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1600),
      )..repeat();
    }
  }

  @override
  void dispose() {
    unawaited(_discoverySub?.cancel());
    _scanPingCtrl?.dispose();
    _addressCtrl.dispose();
    _addressFocus.dispose();
    _usernameCtrl.dispose();
    _usernameFocus.dispose();
    _passwordCtrl.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _setStep(EvLoginStep next) {
    if (_step == next) return;
    _step = next;
    widget.onStepChanged?.call(next);
  }

  void _focusPasswordLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _passwordFocus.canRequestFocus) {
        _passwordFocus.requestFocus();
        final len = _passwordCtrl.text.length;
        if (_passwordCtrl.selection.baseOffset != len ||
            _passwordCtrl.selection.extentOffset != len) {
          _passwordCtrl.selection = TextSelection.collapsed(offset: len);
        }
      }
    });
  }

  /// Navigates one step back inside the login flow (used by Escape and the
  /// macOS menu bar "返回" action). Returns `true` when handled.
  bool handleBack() {
    if (_busy) return true;
    switch (_step) {
      case EvLoginStep.pass:
        setState(() {
          _selectedUser = null;
          _manualUserMode = false;
          _authError = null;
          _passwordCtrl.clear();
          _setStep(EvLoginStep.users);
        });
        return true;
      case EvLoginStep.cert:
        _cancelCert();
        return true;
      case EvLoginStep.fail:
        setState(() {
          _failure = null;
          _setStep(EvLoginStep.server);
        });
        return true;
      case EvLoginStep.users:
        _switchServer();
        return true;
      case EvLoginStep.server:
        return false;
    }
  }

  void _focusUsernameLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _usernameFocus.canRequestFocus) {
        _usernameFocus.requestFocus();
      }
    });
  }

  void _startDiscovery() {
    final backend = widget.backend;
    if (backend == null) return;
    unawaited(_discoverySub?.cancel());
    setState(() => _discovering = true);
    _discoverySub = backend.discoverServers().listen(
      (servers) {
        if (!mounted) return;
        setState(() => _discovered = List<EvDiscoveredServer>.unmodifiable(servers));
      },
      onError: (_) {
        if (mounted) setState(() => _discovering = false);
      },
      onDone: () {
        if (mounted) setState(() => _discovering = false);
      },
    );
  }

  Future<void> _bootstrapUsersStep() async {
    final backend = widget.backend;
    if (backend == null) return;
    setState(() => _busy = true);
    try {
      final server = _server ??
          await backend.loadSavedServer(serverId: widget.initialServerId);
      if (!mounted) return;
      if (server == null) {
        setState(() {
          _busy = false;
          _setStep(EvLoginStep.server);
        });
        return;
      }
      final users = await backend.loadUsers(server);
      if (!mounted) return;
      setState(() {
        _server = server;
        _users = users;
        _busy = false;
        if (_step == EvLoginStep.pass && _selectedUser == null && users.isNotEmpty) {
          _selectedUser =
              users.where((u) => u.hasPassword).firstOrNull ?? users.first;
        }
        if (users.isEmpty) {
          _manualUserMode = true;
          _setStep(EvLoginStep.pass);
        }
      });
      if (_manualUserMode) _focusUsernameLater();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectToAddress(String rawAddress) async {
    final trimmed = rawAddress.trim();
    if (trimmed.isEmpty || _busy) return;
    final backend = widget.backend;
    if (backend == null) return;

    setState(() {
      _busy = true;
      _authError = null;
      _addressCtrl.text = trimmed;
    });
    try {
      final result = await backend.connectServer(trimmed);
      if (!mounted) return;
      _applyConnectResult(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _cert = null;
        _failure = EvConnectFailure(
          address: formatServerAddressForDisplay(trimmed),
          reason: error is EmbyViewFailure
              ? error.reason
              : '无法连接服务器。请确认 NAS 已开机、地址和端口没写错（Emby 默认 8096，HTTPS 是 8920）。',
        );
        _setStep(EvLoginStep.fail);
      });
    }
  }

  Future<void> _trustCertAndContinue() async {
    final challenge = _cert;
    final backend = widget.backend;
    if (challenge == null || _busy) return;
    if (backend == null) {
      setState(() {
        _cert = null;
        _server ??= EvLoginDemoData.server;
        if (_users.isEmpty) _users = EvLoginDemoData.users;
        _setStep(EvLoginStep.users);
      });
      return;
    }

    setState(() {
      _busy = true;
      _authError = null;
    });
    try {
      final result = await backend.trustCertificateAndConnect(challenge);
      if (!mounted) return;
      _applyConnectResult(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _cert = null;
        _failure = EvConnectFailure(
          address: formatServerAddressForDisplay(challenge.address),
          reason: error is EmbyViewFailure
              ? error.reason
              : '信任证书后仍无法连接服务器。请检查地址和端口（Emby 默认 8096，HTTPS 是 8920）。',
        );
        _setStep(EvLoginStep.fail);
      });
    }
  }

  void _cancelCert() {
    if (_busy) return;
    setState(() {
      _cert = null;
      _failure = null;
      _setStep(EvLoginStep.server);
    });
  }

  void _applyConnectResult(EvServerConnectResult result) {
    switch (result) {
      case EvServerConnectSuccess(:final server, :final users):
        setState(() {
          _busy = false;
          _server = server;
          _users = List<EvLoginUser>.unmodifiable(users);
          _selectedUser = null;
          _manualUserMode = users.isEmpty;
          _cert = null;
          _failure = null;
          _authError = null;
          _passwordCtrl.clear();
          _setStep(users.isEmpty ? EvLoginStep.pass : EvLoginStep.users);
        });
        if (users.isEmpty) _focusUsernameLater();
      case EvServerConnectUntrustedCert(:final challenge):
        setState(() {
          _busy = false;
          _cert = challenge;
          _failure = null;
          _addressCtrl.text = challenge.address;
          _setStep(EvLoginStep.cert);
        });
      case EvServerConnectFailure(:final failure):
        setState(() {
          _busy = false;
          _cert = null;
          _failure = failure;
          _setStep(EvLoginStep.fail);
        });
    }
  }

  void _switchServer() {
    if (_busy) return;
    setState(() {
      _selectedUser = null;
      _manualUserMode = false;
      _authError = null;
      _cert = null;
      _failure = null;
      _passwordCtrl.clear();
      _setStep(EvLoginStep.server);
    });
    if (_discovered.isEmpty && widget.backend != null) {
      _startDiscovery();
    }
  }

  Future<void> _activateUser(EvLoginUser user) async {
    if (_busy) return;
    if (!user.hasPassword) {
      await _submitUserSignIn(user, password: null);
      return;
    }
    setState(() {
      _manualUserMode = false;
      _selectedUser = user;
      _authError = null;
      _passwordCtrl.clear();
      _setStep(EvLoginStep.pass);
    });
    _focusPasswordLater();
  }

  void _activateOtherUser() {
    if (_busy) return;
    setState(() {
      _selectedUser = null;
      _manualUserMode = true;
      _authError = null;
      _usernameCtrl.clear();
      _passwordCtrl.clear();
      _setStep(EvLoginStep.pass);
    });
    _focusUsernameLater();
  }

  Future<void> _submitUserSignIn(EvLoginUser user, {String? password}) async {
    final server = _server ?? EvLoginDemoData.server;
    final backend = widget.backend;
    if (backend == null) {
      widget.onSignedIn?.call();
      return;
    }
    setState(() {
      _busy = true;
      _authError = null;
    });
    try {
      await backend.signInWithUser(
        server: server,
        user: user,
        password: password,
        rememberPassword: _rememberPassword,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onSignedIn?.call();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _selectedUser = user;
        _manualUserMode = false;
        _authError = error is EmbyViewFailure
            ? error.reason
            : '登录失败，请检查密码后重试。';
        _setStep(EvLoginStep.pass);
      });
      _focusPasswordLater();
    }
  }

  Future<void> _submitPasswordStep() async {
    if (_busy) return;
    if (_manualUserMode) {
      final username = _usernameCtrl.text.trim();
      if (username.isEmpty) {
        setState(() => _authError = '请先输入用户名。');
        _usernameFocus.requestFocus();
        return;
      }
      final server = _server ?? EvLoginDemoData.server;
      final backend = widget.backend;
      if (backend == null) {
        widget.onSignedIn?.call();
        return;
      }
      setState(() {
        _busy = true;
        _authError = null;
      });
      try {
        await backend.signInManually(
          server: server,
          username: username,
          password: _passwordCtrl.text,
          rememberPassword: _rememberPassword,
        );
        if (!mounted) return;
        setState(() => _busy = false);
        widget.onSignedIn?.call();
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _authError = error is EmbyViewFailure
              ? error.reason
              : '登录失败，请检查用户名和密码。';
        });
      }
      return;
    }

    final user = _selectedUser;
    if (user == null) return;
    await _submitUserSignIn(user, password: _passwordCtrl.text);
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final isUserPhase =
        _step == EvLoginStep.users || _step == EvLoginStep.pass;

    return CallbackShortcuts(
      bindings: {
        if (_step == EvLoginStep.pass)
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_busy) return;
            setState(() {
              _selectedUser = null;
              _manualUserMode = false;
              _authError = null;
              _passwordCtrl.clear();
              _setStep(EvLoginStep.users);
            });
          },
      },
      child: EvBrandBackground(
        child: Stack(
          key: const Key('ev_login_page'),
          fit: StackFit.expand,
          children: [
            LayoutBuilder(
              builder: (_, constraints) => SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  s.gutter,
                  s.rem(4.5),
                  s.gutter,
                  s.rem(3.0),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - s.rem(7.5))
                        .clamp(0.0, double.infinity),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildBrandHeader(t, s),
                        SizedBox(height: s.rem(2.0)),
                        if (isUserPhase)
                          _buildUsersPhase(t, s)
                        else
                          _buildServerCard(t, s),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (widget.windowDragBuilder != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: s.rem(3.25),
                child: widget.windowDragBuilder!(context),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrandHeader(EvTheme t, EvScale s) {
    return Row(
      key: const Key('ev_login_brand'),
      mainAxisSize: MainAxisSize.min,
      children: [
        EvAppIcon(size: s.rem(3.5), dark: widget.darkIcon),
        SizedBox(width: s.rem(0.75)),
        Text('EmbyView', style: t.displayStyle(s.font(1.5))),
      ],
    );
  }

  Widget _buildServerCard(EvTheme t, EvScale s) {
    final isBadAddr = _step == EvLoginStep.fail;
    final scanHeading = _discovered.isNotEmpty
        ? '在局域网里找到 ${_discovered.length} 台'
        : _discovering
        ? '正在扫描局域网里的 Emby…'
        : '局域网里未找到 Emby 服务器';

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: s.rem(35.0)),
      child: SizedBox(
        width: double.infinity,
        child: EvGlass(
          key: const Key('ev_login_server_card'),
          borderRadius: BorderRadius.circular(s.rem(1.5)),
          padding: EdgeInsets.fromLTRB(
            s.rem(2.0),
            s.rem(2.0),
            s.rem(2.0),
            s.rem(1.75),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '连接到你的 Emby',
                style: t.displayStyle(s.font(2.0)),
              ),
              SizedBox(height: s.rem(1.5)),
              Row(
                children: [
                  _ScanDot(animation: _scanPingCtrl),
                  SizedBox(width: s.rem(0.625)),
                  Expanded(
                    child: Text(
                      scanHeading,
                      key: const Key('ev_login_scan_heading'),
                      style: t.bodyStyle(
                        s.font(0.9375),
                        fontWeight: FontWeight.w500,
                        color: t.ink3,
                      ),
                    ),
                  ),
                  if (!_discovering && widget.backend != null)
                    _EvLinkButton(
                      key: const Key('ev_login_rescan_btn'),
                      label: '重新扫描',
                      color: t.ink3,
                      onPressed: _busy ? null : _startDiscovery,
                    ),
                ],
              ),
              SizedBox(height: s.rem(0.75)),
              if (_discovered.isNotEmpty) ...[
                Column(
                  key: const Key('ev_login_discovered_list'),
                  children: [
                    for (var i = 0; i < _discovered.length; i++) ...[
                      if (i > 0) SizedBox(height: s.rem(0.5)),
                      _DiscoveredServerRow(
                        key: Key('ev_login_discovered_${_discovered[i].id}'),
                        server: _discovered[i],
                        enabled: !_busy,
                        onTap: () => unawaited(
                          _connectToAddress(_discovered[i].address),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: s.rem(1.5)),
              ] else
                SizedBox(height: s.rem(0.75)),
              Text(
                '或者输入地址',
                style: t.bodyStyle(
                  s.font(0.9375),
                  fontWeight: FontWeight.w500,
                  color: t.ink3,
                ),
              ),
              SizedBox(height: s.rem(0.75)),
              Row(
                children: [
                  Expanded(
                    child: _AddressInputField(
                      key: const Key('ev_login_address_input'),
                      controller: _addressCtrl,
                      focusNode: _addressFocus,
                      bad: isBadAddr,
                      enabled: !_busy,
                      placeholder:
                          '192.168.1.20:8096 或 https://emby.example.com',
                      onSubmitted: (v) => unawaited(_connectToAddress(v)),
                    ),
                  ),
                  SizedBox(width: s.rem(0.625)),
                  _TallPrimaryButton(
                    key: const Key('ev_login_connect_btn'),
                    label: _busy ? '连接中…' : '连接',
                    height: s.rem(3.0),
                    onPressed: _busy
                        ? null
                        : () => unawaited(_connectToAddress(_addressCtrl.text)),
                  ),
                ],
              ),
              if (_step == EvLoginStep.cert && _cert != null)
                _buildCertMessage(t, s, _cert!)
              else if (_step == EvLoginStep.fail && _failure != null)
                _buildFailMessage(t, s, _failure!)
              else
                Padding(
                  padding: EdgeInsets.only(top: s.rem(0.875)),
                  child: Text(
                    '内网地址和外网地址（比如 Tailscale）都可以。登录后能在设置里再加一个备用地址，连不上时自动换。',
                    key: const Key('ev_login_addr_hint'),
                    style: t.bodyStyle(
                      s.font(0.875),
                      color: t.ink3,
                      height: 1.55,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCertMessage(EvTheme t, EvScale s, EvCertChallenge cert) {
    final bg = t.isPaper
        ? const Color(0xFFFBF3E6)
        : const Color.fromRGBO(255, 181, 71, 0.10);
    final border = t.isPaper
        ? const Color(0xFFECD9B8)
        : const Color.fromRGBO(255, 181, 71, 0.30);
    final iconColor = t.isPaper ? _kPaperTerracotta : _kCinemaWarn;

    return Container(
      key: const Key('ev_login_cert_box'),
      margin: EdgeInsets.only(top: s.rem(1.0)),
      padding: EdgeInsets.symmetric(
        horizontal: s.rem(1.125),
        vertical: s.rem(1.0),
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(s.rem(1.0)),
        border: Border.all(color: border, width: 1.0),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EvIcon(EvIcons.shield, size: s.rem(1.75), color: iconColor),
          SizedBox(width: s.rem(0.875)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '这台服务器用的是自签名证书',
                  style: t.bodyStyle(
                    s.font(1.0),
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                SizedBox(height: s.rem(0.375)),
                Text(
                  '系统不认识它的证书。确认这是你自己的服务器再信任；以后会记住这张证书，证书变了会再问你。',
                  style: t.bodyStyle(
                    s.font(0.875),
                    color: t.ink2,
                    height: 1.55,
                  ),
                ),
                Container(
                  key: const Key('ev_login_cert_fingerprint'),
                  width: double.infinity,
                  margin: EdgeInsets.only(top: s.rem(0.75)),
                  padding: EdgeInsets.symmetric(
                    horizontal: s.rem(0.75),
                    vertical: s.rem(0.5),
                  ),
                  decoration: BoxDecoration(
                    color: t.fill,
                    borderRadius: BorderRadius.circular(s.rem(0.5)),
                  ),
                  child: Text(
                    cert.formattedFingerprint,
                    style: TextStyle(
                      fontFamily: 'SF Mono',
                      fontFamilyFallback: const ['Menlo', 'monospace'],
                      fontSize: s.font(0.8125),
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                      color: t.ink2,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                SizedBox(height: s.rem(0.875)),
                Row(
                  children: [
                    EvButton.primary(
                      key: const Key('ev_login_cert_trust_btn'),
                      small: true,
                      label: _busy ? '正在连接…' : '信任并继续',
                      onPressed: _busy
                          ? null
                          : () => unawaited(_trustCertAndContinue()),
                    ),
                    SizedBox(width: s.rem(0.5)),
                    EvButton.ghost(
                      key: const Key('ev_login_cert_cancel_btn'),
                      small: true,
                      label: '取消',
                      onPressed: _busy ? null : _cancelCert,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFailMessage(EvTheme t, EvScale s, EvConnectFailure failure) {
    final bg = t.isPaper
        ? const Color(0xFFFBECE8)
        : const Color.fromRGBO(255, 107, 90, 0.10);
    final border = t.isPaper
        ? const Color(0xFFEFC9BF)
        : const Color.fromRGBO(255, 107, 90, 0.30);
    final iconColor = t.isPaper ? _kPaperErr : _kCinemaErr;

    return Container(
      key: const Key('ev_login_fail_box'),
      margin: EdgeInsets.only(top: s.rem(1.0)),
      padding: EdgeInsets.symmetric(
        horizontal: s.rem(1.125),
        vertical: s.rem(1.0),
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(s.rem(1.0)),
        border: Border.all(color: border, width: 1.0),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EvIcon(EvIcons.nowifi, size: s.rem(1.75), color: iconColor),
          SizedBox(width: s.rem(0.875)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '连不上 ${failure.address}',
                  style: t.bodyStyle(
                    s.font(1.0),
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                SizedBox(height: s.rem(0.375)),
                Text(
                  failure.reason,
                  style: t.bodyStyle(
                    s.font(0.875),
                    color: t.ink2,
                    height: 1.55,
                  ),
                ),
                SizedBox(height: s.rem(0.875)),
                EvButton.primary(
                  key: const Key('ev_login_retry_btn'),
                  small: true,
                  icon: EvIcons.refresh,
                  label: _busy ? '重试中…' : '重试',
                  onPressed: _busy
                      ? null
                      : () => unawaited(
                          _connectToAddress(
                            _addressCtrl.text.trim().isNotEmpty
                                ? _addressCtrl.text
                                : failure.address,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUsersPhase(EvTheme t, EvScale s) {
    final serverName = _server?.name.trim().isNotEmpty == true
        ? _server!.name.trim()
        : EvLoginDemoData.server.name;
    final avatarSize = s.rem(7.5);
    final isPassStep = _step == EvLoginStep.pass;
    final selectedId = isPassStep && !_manualUserMode ? _selectedUser?.id : null;
    final dimOthers = isPassStep && (selectedId != null || _manualUserMode);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          '谁在看？',
          key: const Key('ev_login_users_title'),
          textAlign: TextAlign.center,
          style: t.displayStyle(s.font(2.75)),
        ),
        SizedBox(height: s.rem(0.75)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            EvIcon(EvIcons.server, size: s.rem(1.125), color: t.ink3),
            SizedBox(width: s.rem(0.5)),
            Text(
              serverName,
              key: const Key('ev_login_server_name'),
              style: t.bodyStyle(s.font(1.0), color: t.ink3),
            ),
            SizedBox(width: s.rem(0.5)),
            _EvLinkButton(
              key: const Key('ev_login_switch_server_btn'),
              label: '换服务器',
              color: t.ink,
              fontWeight: FontWeight.w600,
              onPressed: _busy ? null : _switchServer,
            ),
          ],
        ),
        SizedBox(height: s.rem(2.0)),
        Wrap(
          key: const Key('ev_login_users_grid'),
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.start,
          spacing: s.rem(2.5),
          runSpacing: s.rem(1.75),
          children: [
            for (var i = 0; i < _users.length; i++)
              _LoginProfileTile(
                key: Key('ev_login_user_${_users[i].id}'),
                label: _users[i].name,
                subtitle: _users[i].hasPassword ? null : '不用密码',
                avatarSize: avatarSize,
                selected: selectedId == _users[i].id,
                dimmed: dimOthers && selectedId != _users[i].id,
                enabled: !_busy,
                onActivate: () => unawaited(_activateUser(_users[i])),
                avatar: EvAvatarButton(
                  profile: _users[i].toProfile(),
                  size: avatarSize,
                  colorIndex: i,
                ),
              ),
            _LoginProfileTile(
              key: const Key('ev_login_other_user_btn'),
              label: '其他用户',
              subtitle: '输入用户名',
              avatarSize: avatarSize,
              selected: isPassStep && _manualUserMode,
              dimmed: isPassStep && !_manualUserMode && selectedId != null,
              enabled: !_busy,
              onActivate: _activateOtherUser,
              avatar: Container(
                width: avatarSize,
                height: avatarSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: t.fill3, width: 2.0),
                ),
                child: EvIcon(
                  EvIcons.plus,
                  size: s.rem(2.75),
                  color: t.ink3,
                ),
              ),
            ),
          ],
        ),
        if (isPassStep) ...[
          SizedBox(height: s.rem(2.0)),
          if (_manualUserMode)
            _buildManualLoginForm(t, s)
          else if (_selectedUser != null)
            _buildPasswordBar(t, s, _selectedUser!),
          SizedBox(height: s.rem(0.875)),
          _RememberCheckbox(
            key: const Key('ev_login_remember_checkbox'),
            checked: _rememberPassword,
            enabled: !_busy,
            onToggle: () => setState(() => _rememberPassword = !_rememberPassword),
          ),
          if (_authError != null) ...[
            SizedBox(height: s.rem(0.875)),
            Container(
              key: const Key('ev_login_auth_error'),
              padding: EdgeInsets.symmetric(
                horizontal: s.rem(1.0),
                vertical: s.rem(0.625),
              ),
              decoration: BoxDecoration(
                color: (t.isPaper ? _kPaperErr : _kCinemaErr).withValues(
                  alpha: 0.12,
                ),
                borderRadius: BorderRadius.circular(s.rem(0.75)),
                border: Border.all(
                  color: (t.isPaper ? _kPaperErr : _kCinemaErr).withValues(
                    alpha: 0.35,
                  ),
                ),
              ),
              child: Text(
                _authError!,
                style: t.bodyStyle(
                  s.font(0.875),
                  color: t.isPaper ? _kPaperErr : _kCinemaErr,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildPasswordBar(EvTheme t, EvScale s, EvLoginUser user) {
    return SizedBox(
      width: s.rem(27.0),
      child: EvGlass(
        key: const Key('ev_login_password_bar'),
        borderRadius: BorderRadius.circular(999),
        padding: EdgeInsets.fromLTRB(
          s.rem(1.125),
          s.rem(0.375),
          s.rem(0.375),
          s.rem(0.375),
        ),
        child: Row(
          children: [
            EvIcon(EvIcons.lock, size: s.rem(1.125), color: t.ink3),
            SizedBox(width: s.rem(0.75)),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _passwordFocus.requestFocus,
                child: ListenableBuilder(
                  listenable: _passwordCtrl,
                  builder: (_, _) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      if (_passwordCtrl.text.isEmpty)
                        IgnorePointer(
                          child: Text(
                            '${user.name} 的密码',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyStyle(
                              s.font(1.0),
                              color: t.ink4,
                            ),
                          ),
                        ),
                      EditableText(
                        key: const Key('ev_login_password_input'),
                        controller: _passwordCtrl,
                        focusNode: _passwordFocus,
                        obscureText: true,
                        maxLines: 1,
                        onSubmitted: (_) => unawaited(_submitPasswordStep()),
                        style: t
                            .bodyStyle(s.font(1.0625), color: t.ink)
                            .copyWith(letterSpacing: s.font(1.0625) * 0.12),
                        cursorColor: t.isPaper ? t.brand : t.ink,
                        backgroundCursorColor: t.ink4,
                        selectionColor: t.brand.withValues(alpha: 0.28),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: s.rem(0.5)),
            _TallPrimaryButton(
              key: const Key('ev_login_submit_btn'),
              label: _busy ? '登录中…' : '登录',
              trailingIcon: _busy ? null : EvIcons.right,
              height: s.rem(2.75),
              pill: !t.isPaper,
              onPressed: _busy ? null : () => unawaited(_submitPasswordStep()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildManualLoginForm(EvTheme t, EvScale s) {
    return SizedBox(
      width: s.rem(27.0),
      child: EvGlass(
        key: const Key('ev_login_manual_form'),
        borderRadius: BorderRadius.circular(s.rem(1.25)),
        padding: EdgeInsets.all(s.rem(1.0)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AddressInputField(
              key: const Key('ev_login_manual_username_input'),
              controller: _usernameCtrl,
              focusNode: _usernameFocus,
              icon: EvIcons.users,
              enabled: !_busy,
              placeholder: '输入用户名',
              onSubmitted: (_) => _passwordFocus.requestFocus(),
            ),
            SizedBox(height: s.rem(0.625)),
            Row(
              children: [
                Expanded(
                  child: _AddressInputField(
                    key: const Key('ev_login_password_input'),
                    controller: _passwordCtrl,
                    focusNode: _passwordFocus,
                    icon: EvIcons.lock,
                    obscureText: true,
                    enabled: !_busy,
                    placeholder: '密码（无密码可留空）',
                    onSubmitted: (_) => unawaited(_submitPasswordStep()),
                  ),
                ),
                SizedBox(width: s.rem(0.5)),
                _TallPrimaryButton(
                  key: const Key('ev_login_submit_btn'),
                  label: _busy ? '登录中…' : '登录',
                  trailingIcon: _busy ? null : EvIcons.right,
                  height: s.rem(3.0),
                  onPressed: _busy
                      ? null
                      : () => unawaited(_submitPasswordStep()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanDot extends StatelessWidget {
  const _ScanDot({required this.animation});
  final AnimationController? animation;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final d = s.rem(0.5);
    final color = t.isPaper ? _kPaperTerracotta : _kCinemaGreen;
    final core = Container(
      width: d,
      height: d,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    final anim = animation;
    if (anim == null) return core;
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: anim,
            builder: (_, _) {
              final v = EvCurves.out.transform(anim.value);
              return Transform.scale(
                scale: 1.0 + 2.2 * v,
                child: Opacity(
                  opacity: (1.0 - v).clamp(0.0, 1.0),
                  child: Container(
                    width: d,
                    height: d,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          ),
          core,
        ],
      ),
    );
  }
}

class _DiscoveredServerRow extends StatefulWidget {
  const _DiscoveredServerRow({
    super.key,
    required this.server,
    required this.enabled,
    required this.onTap,
  });

  final EvDiscoveredServer server;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_DiscoveredServerRow> createState() => _DiscoveredServerRowState();
}

class _DiscoveredServerRowState extends State<_DiscoveredServerRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final hi = widget.enabled && (_hovered || _focused);

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: '${widget.server.name} ${widget.server.subtitle}',
      child: Focus(
        canRequestFocus: widget.enabled,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!widget.enabled || !evIsActivateKey(e)) {
            return KeyEventResult.ignored;
          }
          widget.onTap();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onTap : null,
            child: AnimatedContainer(
              duration: EvDurations.normal,
              curve: EvCurves.spring,
              transform: Matrix4.translationValues(
                hi ? s.rem(0.25) : 0.0,
                0.0,
                0.0,
              ),
              padding: EdgeInsets.fromLTRB(
                s.rem(0.75),
                s.rem(0.75),
                s.rem(1.0),
                s.rem(0.75),
              ),
              decoration: BoxDecoration(
                color: hi ? t.fill2 : t.fill,
                borderRadius: BorderRadius.circular(s.rem(1.0)),
                border: Border.all(
                  color: _focused ? t.focusColor : t.line,
                  width: _focused ? 1.5 : 1.0,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: s.rem(2.75),
                    height: s.rem(2.75),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.fill2,
                      borderRadius: BorderRadius.circular(s.rem(0.75)),
                    ),
                    child: EvIcon(EvIcons.server, size: s.rem(1.5), color: t.ink),
                  ),
                  SizedBox(width: s.rem(1.0)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.server.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodyStyle(
                            s.font(1.0625),
                            fontWeight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                        SizedBox(height: s.rem(0.1875)),
                        Text(
                          widget.server.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodyStyle(s.font(0.875), color: t.ink3),
                        ),
                      ],
                    ),
                  ),
                  if (widget.server.latencyMs != null) ...[
                    SizedBox(width: s.rem(0.75)),
                    Text(
                      '${widget.server.latencyMs} ms',
                      style: t
                          .bodyStyle(s.font(0.875), color: t.ink3)
                          .copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                  ],
                  SizedBox(width: s.rem(0.75)),
                  EvIcon(EvIcons.right, size: s.rem(1.0), color: t.ink3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddressInputField extends StatelessWidget {
  const _AddressInputField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    this.icon = EvIcons.globe,
    this.bad = false,
    this.obscureText = false,
    this.enabled = true,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final EvIconData icon;
  final bool bad;
  final bool obscureText;
  final bool enabled;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? focusNode.requestFocus : null,
      child: ListenableBuilder(
        listenable: Listenable.merge([focusNode, controller]),
        builder: (_, _) {
          final focused = focusNode.hasFocus;
          final borderColor = bad
              ? _kCinemaErr
              : focused
              ? (t.isPaper ? t.brand : t.ink2)
              : t.line;
          final borderWidth = bad || focused ? 1.5 : 1.0;

          return Container(
            height: s.rem(3.0),
            padding: EdgeInsets.symmetric(horizontal: s.rem(1.0)),
            decoration: BoxDecoration(
              color: t.fill,
              borderRadius: BorderRadius.circular(s.rem(0.875)),
              border: Border.all(color: borderColor, width: borderWidth),
            ),
            child: Row(
              children: [
                EvIcon(icon, size: s.rem(1.125), color: t.ink3),
                SizedBox(width: s.rem(0.625)),
                Expanded(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      if (controller.text.isEmpty)
                        IgnorePointer(
                          child: Text(
                            placeholder,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyStyle(s.font(1.0), color: t.ink4),
                          ),
                        ),
                      EditableText(
                        controller: controller,
                        focusNode: focusNode,
                        obscureText: obscureText,
                        readOnly: !enabled,
                        maxLines: 1,
                        onSubmitted: enabled ? onSubmitted : null,
                        style: t.bodyStyle(s.font(1.0), color: t.ink),
                        cursorColor: t.isPaper ? t.brand : t.ink,
                        backgroundCursorColor: t.ink4,
                        selectionColor: t.brand.withValues(alpha: 0.28),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TallPrimaryButton extends StatefulWidget {
  const _TallPrimaryButton({
    super.key,
    required this.label,
    required this.height,
    this.trailingIcon,
    this.pill,
    required this.onPressed,
  });

  final String label;
  final double height;
  final EvIconData? trailingIcon;
  final bool? pill;
  final VoidCallback? onPressed;

  @override
  State<_TallPrimaryButton> createState() => _TallPrimaryButtonState();
}

class _TallPrimaryButtonState extends State<_TallPrimaryButton> {
  bool _hovered = false;
  bool _focused = false;
  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final hi = _enabled && (_hovered || _focused);
    final isPill = widget.pill ?? !t.isPaper;
    final radius = BorderRadius.circular(isPill ? 999.0 : s.rem(0.625));
    final bg = hi && t.isPaper ? const Color(0xFF9F4829) : t.priBg;

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
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
              scale: hi ? 1.03 : 1.0,
              duration: EvDurations.normal,
              curve: EvCurves.spring,
              child: Opacity(
                opacity: _enabled ? 1.0 : 0.45,
                child: Container(
                  height: widget.height,
                  padding: EdgeInsets.symmetric(horizontal: s.rem(1.125)),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: radius,
                    border: _focused
                        ? Border.all(color: t.focusColor, width: 1.5)
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.label,
                        style: t.bodyStyle(
                          s.font(0.9375),
                          fontWeight: FontWeight.w600,
                          color: t.priFg,
                        ),
                      ),
                      if (widget.trailingIcon != null) ...[
                        SizedBox(width: s.rem(0.375)),
                        EvIcon(
                          widget.trailingIcon!,
                          size: s.rem(1.0),
                          color: t.priFg,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvLinkButton extends StatefulWidget {
  const _EvLinkButton({
    super.key,
    required this.label,
    required this.color,
    this.fontWeight = FontWeight.w500,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final FontWeight fontWeight;
  final VoidCallback? onPressed;

  @override
  State<_EvLinkButton> createState() => _EvLinkButtonState();
}

class _EvLinkButtonState extends State<_EvLinkButton> {
  bool _hovered = false;
  bool _focused = false;
  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final hi = _enabled && (_hovered || _focused);
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
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
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: s.rem(0.25),
                vertical: s.rem(0.125),
              ),
              child: Text(
                widget.label,
                style: t
                    .bodyStyle(
                      s.font(0.9375),
                      fontWeight: widget.fontWeight,
                      color: widget.color,
                    )
                    .copyWith(
                      decoration: TextDecoration.underline,
                      decorationColor: hi ? widget.color : t.ink4,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoginProfileTile extends StatefulWidget {
  const _LoginProfileTile({
    super.key,
    required this.label,
    this.subtitle,
    required this.avatar,
    required this.avatarSize,
    required this.selected,
    required this.dimmed,
    required this.enabled,
    required this.onActivate,
  });

  final String label;
  final String? subtitle;
  final Widget avatar;
  final double avatarSize;
  final bool selected;
  final bool dimmed;
  final bool enabled;
  final VoidCallback onActivate;

  @override
  State<_LoginProfileTile> createState() => _LoginProfileTileState();
}

class _LoginProfileTileState extends State<_LoginProfileTile> {
  bool _hovered = false;
  bool _focused = false;
  bool get _highlighted =>
      widget.selected || (widget.enabled && (_hovered || _focused));

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final lift = _highlighted ? -s.rem(0.25) : 0.0;
    final ringScale = _highlighted ? 1.08 : 1.0;

    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: widget.enabled,
      label: widget.subtitle != null
          ? '${widget.label}（${widget.subtitle}）'
          : widget.label,
      child: Focus(
        canRequestFocus: widget.enabled,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!widget.enabled || !evIsActivateKey(e)) {
            return KeyEventResult.ignored;
          }
          widget.onActivate();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onActivate : null,
            child: AnimatedOpacity(
              duration: EvDurations.normal,
              opacity: widget.dimmed ? 0.35 : (widget.enabled ? 1.0 : 0.6),
              child: SizedBox(
                width: widget.avatarSize + s.rem(1.75),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: EvDurations.medium,
                      curve: EvCurves.out,
                      transformAlignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..translateByDouble(0.0, lift, 0.0, 1.0)
                        ..scaleByDouble(ringScale, ringScale, 1.0, 1.0),
                      padding: const EdgeInsets.all(3.0),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _highlighted ? t.bg : _kTransparent,
                        border: Border.all(
                          color: _highlighted ? t.ink : _kTransparent,
                          width: 3.0,
                        ),
                        boxShadow: _highlighted ? t.cardShadowHi : null,
                      ),
                      child: widget.avatar,
                    ),
                    SizedBox(height: s.rem(1.0)),
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: t.bodyStyle(
                        s.font(1.1875),
                        fontWeight: FontWeight.w500,
                        color: _highlighted ? t.ink : t.ink2,
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      SizedBox(height: s.rem(0.25)),
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: t.bodyStyle(s.font(0.875), color: t.ink3),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RememberCheckbox extends StatefulWidget {
  const _RememberCheckbox({
    super.key,
    required this.checked,
    required this.enabled,
    required this.onToggle,
  });

  final bool checked;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  State<_RememberCheckbox> createState() => _RememberCheckboxState();
}

class _RememberCheckboxState extends State<_RememberCheckbox> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    return Semantics(
      checked: widget.checked,
      enabled: widget.enabled,
      label: '记住密码（存在这台 Mac 的钥匙串里）',
      child: Focus(
        canRequestFocus: widget.enabled,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!widget.enabled || !evIsActivateKey(e)) {
            return KeyEventResult.ignored;
          }
          widget.onToggle();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onToggle : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: EvDurations.fast,
                  width: s.rem(1.125),
                  height: s.rem(1.125),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.checked ? t.priBg : t.fill,
                    borderRadius: BorderRadius.circular(s.rem(0.3125)),
                    border: Border.all(
                      color: _focused
                          ? t.focusColor
                          : (widget.checked ? t.priBg : t.line),
                      width: _focused ? 1.5 : 1.0,
                    ),
                  ),
                  child: widget.checked
                      ? EvIcon(
                          EvIcons.check,
                          size: s.rem(0.75),
                          color: t.priFg,
                        )
                      : null,
                ),
                SizedBox(width: s.rem(0.5)),
                Text(
                  '记住密码（存在这台 Mac 的钥匙串里）',
                  style: t.bodyStyle(s.font(0.9375), color: t.ink3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
