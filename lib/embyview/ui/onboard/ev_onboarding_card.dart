import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/subtitles/ai/local_subtitle_asr.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_widgets.dart';
import 'package:moonfin/embyview/ui/shell/ev_avatar_menu.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

const int _kDefaultModelMb = 574;
const int _kBytesPerMb = 1024 * 1024;
const Color _kCinemaGreen = Color(0xFF34C759);
const Color _kPaperTerracotta = Color(0xFFB5532F);

/// Snapshot overriding [EvOnboardingCard] for the demo launcher or unit tests.
@immutable
class EvOnboardingSnapshot {
  const EvOnboardingSnapshot({
    this.folderAuthorized = false,
    this.folderPath,
    this.asrStatus,
    this.userName,
  });

  /// `onboard` default state: all 3 items actionable.
  const EvOnboardingSnapshot.demoInitial({this.userName = 'sfw'})
    : folderAuthorized = false,
      folderPath = null,
      asrStatus = null;

  /// `onboard:busy` state: NAS folder authorized + Whisper model at 38% (218 / 574 MB).
  const EvOnboardingSnapshot.demoBusy({this.userName = 'sfw'})
    : folderAuthorized = true,
      folderPath = '/Volumes/Media',
      asrStatus = const AsrModelStatus(
        state: AsrModelState.downloading,
        receivedBytes: 218 * _kBytesPerMb,
        totalBytes: _kDefaultModelMb * _kBytesPerMb,
      );

  final bool folderAuthorized;
  final String? folderPath;
  final AsrModelStatus? asrStatus;
  final String? userName;
}

/// First-run readiness card ported from `openReady` / `drawReady` in
/// `.spec/mockups/proto.js` and `.ready` / `.rcard` / `.rrow` in `proto.css`.
///
/// Shown once over Home when [LocalPreferences.onboardingDismissed] is `false`.
/// All three items are optional and skippable; clicking either 「以后再说」 or
/// 「开始看片」 persists `onboardingDismissed = true`.
class EvOnboardingCard extends StatefulWidget {
  const EvOnboardingCard({
    super.key,
    this.preferences,
    this.profile,
    this.asr,
    this.demoOverride,
    this.onOpenAiSettings,
    this.onDismissed,
  });

  final EmbyViewPreferences? preferences;
  final AccountProfile? profile;
  final LocalSubtitleAsr? asr;
  final EvOnboardingSnapshot? demoOverride;
  final VoidCallback? onOpenAiSettings;
  final VoidCallback? onDismissed;

  @override
  State<EvOnboardingCard> createState() => _EvOnboardingCardState();
}

class _EvOnboardingCardState extends State<EvOnboardingCard> {
  StreamSubscription<LocalPreferences>? _prefsSub;
  LocalPreferences? _prefs;
  AsrModelStatus? _asrStatus;
  Timer? _pollTimer;
  bool _folderBusy = false;
  bool _modelBusy = false;
  bool _dismissing = false;

  // Local overrides when running purely on demoOverride without live services.
  bool _demoFolderAuthorized = false;
  String? _demoFolderPath;
  AsrModelStatus? _demoAsrStatus;

  LocalSubtitleAsr get _asr => widget.asr ?? const LocalSubtitleAsr();

  bool get _isDemoOnly => widget.demoOverride != null;

  @override
  void initState() {
    super.initState();
    _syncSources();
  }

  void _syncSources() {
    unawaited(_prefsSub?.cancel());
    _pollTimer?.cancel();
    _pollTimer = null;

    if (widget.demoOverride != null) {
      _demoFolderAuthorized = widget.demoOverride!.folderAuthorized;
      _demoFolderPath = widget.demoOverride!.folderPath;
      _demoAsrStatus = widget.demoOverride!.asrStatus;
    }

    final prefs = widget.preferences;
    if (prefs != null) {
      _prefs = prefs.current;
      _prefsSub = prefs.changes.listen((next) {
        if (mounted) setState(() => _prefs = next);
      });
    } else {
      _prefs = null;
    }

    if (!_isDemoOnly) {
      unawaited(_refreshAsrStatus());
    }
  }

  @override
  void didUpdateWidget(EvOnboardingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences != widget.preferences ||
        oldWidget.asr != widget.asr ||
        oldWidget.demoOverride != widget.demoOverride) {
      _syncSources();
    }
  }

  @override
  void dispose() {
    unawaited(_prefsSub?.cancel());
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAsrStatus() async {
    _pollTimer?.cancel();
    try {
      final status = await _asr.modelStatus();
      if (!mounted) return;
      setState(() {
        _asrStatus = status;
        _modelBusy = false;
      });
      if (status.state == AsrModelState.downloading) {
        _pollTimer = Timer(
          const Duration(milliseconds: 500),
          () => unawaited(_refreshAsrStatus()),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _modelBusy = false);
      }
    }
  }

  Future<void> _handleSelectFolder() async {
    if (_folderBusy) return;
    final prefs = widget.preferences;
    if (prefs == null) {
      setState(() {
        _demoFolderAuthorized = true;
        _demoFolderPath = '/Volumes/Media';
      });
      return;
    }
    setState(() => _folderBusy = true);
    try {
      final root = _prefs?.mediaFolder.embyRoot.trim();
      await prefs.authorizeMediaFolder(
        embyRoot: (root != null && root.isNotEmpty) ? root : '/mnt/media',
      );
      if (mounted) {
        setState(() {
          _prefs = prefs.current;
          _folderBusy = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _folderBusy = false);
    }
  }

  Future<void> _handleDownloadModel() async {
    if (_modelBusy) return;
    if (_isDemoOnly && widget.asr == null) {
      setState(() {
        _demoAsrStatus = const AsrModelStatus(
          state: AsrModelState.downloading,
          receivedBytes: 218 * _kBytesPerMb,
          totalBytes: _kDefaultModelMb * _kBytesPerMb,
        );
      });
      return;
    }
    setState(() => _modelBusy = true);
    try {
      await _asr.downloadModel();
      await _refreshAsrStatus();
    } catch (_) {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Future<void> _dismiss({bool openAiSettings = false}) async {
    if (_dismissing) return;
    _dismissing = true;
    final prefs = widget.preferences;
    if (prefs != null && !prefs.current.onboardingDismissed) {
      try {
        await prefs.update(
          evCopyPreferences(prefs.current, onboardingDismissed: true),
        );
      } catch (_) {}
    }
    if (!mounted) return;
    widget.onDismissed?.call();
    if (openAiSettings) {
      widget.onOpenAiSettings?.call();
    }
  }

  bool get _folderAuthorized {
    if (_isDemoOnly && widget.preferences == null) return _demoFolderAuthorized;
    return _prefs?.mediaFolder.state == MediaFolderState.authorized;
  }

  String get _folderDisplayPath {
    if (_isDemoOnly && widget.preferences == null) {
      return _demoFolderPath?.isNotEmpty == true
          ? _demoFolderPath!
          : '/Volumes/Media';
    }
    final local = _prefs?.mediaFolder.localRoot?.trim();
    return (local != null && local.isNotEmpty) ? local : '/Volumes/Media';
  }

  AsrModelStatus? get _effectiveAsrStatus =>
      _isDemoOnly && widget.asr == null ? _demoAsrStatus : _asrStatus;

  String get _displayName {
    final fromProfile = widget.profile?.displayName.trim();
    if (fromProfile != null && fromProfile.isNotEmpty) return fromProfile;
    final fromDemo = widget.demoOverride?.userName?.trim();
    if (fromDemo != null && fromDemo.isNotEmpty) return fromDemo;
    return 'sfw';
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final scrimColor = t.isPaper
        ? const Color.fromRGBO(250, 249, 245, 0.45)
        : const Color.fromRGBO(0, 0, 0, 0.58);
    final avatarProfile =
        widget.profile ?? AccountProfile(id: _displayName, displayName: _displayName);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(_dismiss()),
      },
      child: FocusScope(
        autofocus: true,
        child: Stack(
          key: const Key('ev_onboarding_overlay'),
          fit: StackFit.expand,
          children: [
            BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: ColoredBox(color: scrimColor),
            ),
            Center(
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final maxW = math.max(
                    0.0,
                    math.min(s.rem(46.0), constraints.maxWidth - s.rem(4.0)),
                  );
                  return SingleChildScrollView(
                    padding: EdgeInsets.all(s.rem(2.0)),
                    child: SizedBox(
                      width: maxW,
                      child: EvGlass(
                        key: const Key('ev_onboarding_card'),
                        solid: true,
                        borderRadius: BorderRadius.circular(s.rem(1.75)),
                        padding: EdgeInsets.fromLTRB(
                          s.rem(2.25),
                          s.rem(2.25),
                          s.rem(2.25),
                          s.rem(1.75),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildHeader(t, s, avatarProfile),
                            SizedBox(height: s.rem(1.75)),
                            _buildChecklist(t, s),
                            SizedBox(height: s.rem(1.5)),
                            _buildFooter(t, s),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(EvTheme t, EvScale s, AccountProfile profile) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        EvAvatarButton(profile: profile, size: s.rem(3.75)),
        SizedBox(width: s.rem(1.25)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '欢迎，$_displayName',
                key: const Key('ev_onboarding_title'),
                style: t.displayStyle(s.font(1.875)),
              ),
              SizedBox(height: s.rem(0.375)),
              Text(
                '下面三件事可以现在做，也可以以后在设置里做，都不影响先看片。',
                style: t.bodyStyle(
                  s.font(1.0),
                  color: t.ink3,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChecklist(EvTheme t, EvScale s) {
    final radius = BorderRadius.circular(s.rem(1.125));
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: t.line, width: 1.0),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildRow(
              t,
              s,
              key: const Key('ev_onboard_row_folder'),
              icon: EvIcons.folder,
              title: Text(
                '字幕存到 NAS',
                style: t.bodyStyle(
                  s.font(1.0625),
                  fontWeight: FontWeight.w600,
                  color: t.ink,
                ),
              ),
              subtitle: 'AI 字幕和下载的字幕写到片子同目录，电视、手机上的 Emby 也能用。需要允许访问 NAS 的媒体文件夹。',
              trailing: _folderAuthorized
                  ? _DoneStatus(
                      key: const Key('ev_onboard_folder_done'),
                      label: _folderDisplayPath,
                    )
                  : EvButton.ghost(
                      key: const Key('ev_onboard_folder_btn'),
                      small: true,
                      label: _folderBusy ? '授权中…' : '选择文件夹…',
                      onPressed: _folderBusy
                          ? null
                          : () => unawaited(_handleSelectFolder()),
                    ),
            ),
            SizedBox(height: 1, child: ColoredBox(color: t.line)),
            _buildRow(
              t,
              s,
              key: const Key('ev_onboard_row_model'),
              icon: EvIcons.download,
              title: Text(
                '本机听写模型',
                style: t.bodyStyle(
                  s.font(1.0625),
                  fontWeight: FontWeight.w600,
                  color: t.ink,
                ),
              ),
              subtitle: '日语、英语对白在这台 Mac 上转成文字，音频不上传。约 574 MB，后台下载。',
              trailing: _buildModelTrailing(t, s),
            ),
            SizedBox(height: 1, child: ColoredBox(color: t.line)),
            _buildRow(
              t,
              s,
              key: const Key('ev_onboard_row_gate'),
              icon: EvIcons.globe,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '翻译通道',
                    style: t.bodyStyle(
                      s.font(1.0625),
                      fontWeight: FontWeight.w600,
                      color: t.ink,
                    ),
                  ),
                  SizedBox(width: s.rem(0.5)),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: s.rem(0.5),
                      vertical: s.rem(0.0625),
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: t.fill3, width: 1.0),
                    ),
                    child: Text(
                      '选填',
                      style: t.bodyStyle(
                        s.font(0.8125),
                        fontWeight: FontWeight.w500,
                        color: t.ink3,
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: '填一个 OpenAI 兼容的地址和密钥，把听写出的原文译成中文。不填就只出原文字幕。',
              trailing: EvButton.ghost(
                key: const Key('ev_onboard_gate_btn'),
                small: true,
                label: '填写…',
                onPressed: () => unawaited(_dismiss(openAiSettings: true)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelTrailing(EvTheme t, EvScale s) {
    final status = _effectiveAsrStatus;
    if (status?.state == AsrModelState.ready) {
      return const _DoneStatus(
        key: Key('ev_onboard_model_done'),
        label: '已就绪',
      );
    }
    if (status?.state == AsrModelState.downloading) {
      final totalMb = status!.totalBytes > 0
          ? (status.totalBytes / _kBytesPerMb).round()
          : _kDefaultModelMb;
      final receivedMb = status.totalBytes > 0
          ? (status.receivedBytes / _kBytesPerMb).round().clamp(0, totalMb)
          : 0;
      final progress = status.totalBytes > 0
          ? (status.receivedBytes / status.totalBytes).clamp(0.0, 1.0)
          : 0.0;
      return Row(
        key: const Key('ev_onboard_model_progress'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: s.rem(1.75),
            height: s.rem(1.75),
            child: CustomPaint(
              painter: _ProgressRingPainter(
                progress: progress,
                trackColor: t.fill3,
                activeColor: t.isPaper ? _kPaperTerracotta : t.ink,
              ),
            ),
          ),
          SizedBox(width: s.rem(0.625)),
          Text(
            '$receivedMb / $totalMb MB',
            style: t
                .bodyStyle(s.font(0.875), color: t.ink2)
                .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      );
    }
    return EvButton.ghost(
      key: const Key('ev_onboard_model_btn'),
      small: true,
      label: _modelBusy ? '准备中…' : '后台下载',
      onPressed: _modelBusy ? null : () => unawaited(_handleDownloadModel()),
    );
  }

  Widget _buildRow(
    EvTheme t,
    EvScale s, {
    Key? key,
    required EvIconData icon,
    required Widget title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Container(
      key: key,
      color: t.fill,
      padding: EdgeInsets.symmetric(
        horizontal: s.rem(1.25),
        vertical: s.rem(1.125),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: s.rem(3.0),
            height: s.rem(3.0),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.fill2,
              borderRadius: BorderRadius.circular(s.rem(0.75)),
            ),
            child: EvIcon(icon, size: s.rem(1.5), color: t.ink),
          ),
          SizedBox(width: s.rem(1.125)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                title,
                SizedBox(height: s.rem(0.3125)),
                Text(
                  subtitle,
                  style: t.bodyStyle(
                    s.font(0.875),
                    color: t.ink3,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: s.rem(1.125)),
          trailing,
        ],
      ),
    );
  }

  Widget _buildFooter(EvTheme t, EvScale s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _FooterLink(
          key: const Key('ev_onboard_later_btn'),
          label: '以后再说',
          onPressed: () => unawaited(_dismiss()),
        ),
        EvButton.primary(
          key: const Key('ev_onboard_start_btn'),
          icon: EvIcons.play,
          label: '开始看片',
          onPressed: () => unawaited(_dismiss()),
        ),
      ],
    );
  }
}

class _DoneStatus extends StatelessWidget {
  const _DoneStatus({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final okBg = t.isPaper ? _kPaperTerracotta : _kCinemaGreen;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: s.rem(1.5),
          height: s.rem(1.5),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: okBg, shape: BoxShape.circle),
          child: EvIcon(
            EvIcons.check,
            size: s.rem(0.875),
            color: const Color(0xFFFFFFFF),
          ),
        ),
        SizedBox(width: s.rem(0.5)),
        Text(
          label,
          style: t.bodyStyle(s.font(0.9375), color: t.ink2),
        ),
      ],
    );
  }
}

class _FooterLink extends StatefulWidget {
  const _FooterLink({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  State<_FooterLink> createState() => _FooterLinkState();
}

class _FooterLinkState extends State<_FooterLink> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final hi = _hovered || _focused;
    return Semantics(
      button: true,
      label: widget.label,
      child: Focus(
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (!evIsActivateKey(e)) return KeyEventResult.ignored;
          widget.onPressed();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: s.rem(0.25),
                vertical: s.rem(0.25),
              ),
              child: Text(
                widget.label,
                style: t
                    .bodyStyle(
                      s.font(1.0),
                      fontWeight: FontWeight.w500,
                      color: hi ? t.ink : t.ink3,
                    )
                    .copyWith(
                      decoration: TextDecoration.underline,
                      decorationColor: hi ? t.ink : t.ink4,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  const _ProgressRingPainter({
    required this.progress,
    required this.trackColor,
    required this.activeColor,
  });

  final double progress;
  final Color trackColor;
  final Color activeColor;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 3.25;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    if (radius <= 0) return;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress > 0) {
      final activePaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        activePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.activeColor != activeColor;
}
