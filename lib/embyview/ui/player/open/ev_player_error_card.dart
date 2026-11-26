import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_primitives.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

const _kWhite = Color(0xFFFFFFFF);
const _kCinemaArc = Color(0xFFFFB547);
const _kPaperArc = Color(0xFFD97757);

/// Centered playback open-failure error card rendered on top of the blurred
/// opening backdrop (`.perr` / `.cd` in `.spec/mockups/proto.css` & `proto.js`).
///
/// For 115 HTTP 403 rate-limiting failures, displays a 56×56 clockwise
/// countdown ring (`30` → `1`) that triggers [onRetry] automatically when it
/// finishes, plus the structured error code line and manual retry / back actions.
class EvPlayerErrorCard extends StatefulWidget {
  const EvPlayerErrorCard({
    super.key,
    this.failure,
    this.retryAttempt = 1,
    this.retryNonce = 0,
    this.countdownSeconds = 30,
    this.autoTick = true,
    this.onRetry,
    this.onBack,
  });

  final EmbyViewFailure? failure;
  final int retryAttempt;
  final int retryNonce;
  final int countdownSeconds;
  final bool autoTick;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;

  static bool isRateLimitedFailure(EmbyViewFailure? failure) {
    if (failure == null) return false;
    return failure.isRateLimited ||
        failure.httpStatus == 403 ||
        failure.code == 'rateLimited115';
  }

  @override
  State<EvPlayerErrorCard> createState() => _EvPlayerErrorCardState();
}

class _EvPlayerErrorCardState extends State<EvPlayerErrorCard>
    with TickerProviderStateMixin {
  late final AnimationController _enter;
  late final CurvedAnimation _enterCurve;
  Timer? _tickTimer;
  late int _remaining;

  bool get _isRateLimited => EvPlayerErrorCard.isRateLimitedFailure(widget.failure);
  int get _totalSeconds => widget.countdownSeconds > 0 ? widget.countdownSeconds : 30;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: widget.autoTick ? 0.0 : 1.0,
    );
    _enterCurve = CurvedAnimation(parent: _enter, curve: EvCurves.out);
    if (widget.autoTick) _enter.forward();
    _resetCountdown();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.autoTick || (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _enter.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(EvPlayerErrorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.retryNonce != widget.retryNonce ||
        oldWidget.retryAttempt != widget.retryAttempt ||
        oldWidget.countdownSeconds != widget.countdownSeconds ||
        oldWidget.autoTick != widget.autoTick ||
        oldWidget.failure?.code != widget.failure?.code ||
        oldWidget.failure?.httpStatus != widget.failure?.httpStatus ||
        oldWidget.failure?.isRateLimited != widget.failure?.isRateLimited;
    if (changed) {
      _resetCountdown();
    }
  }

  void _resetCountdown() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _remaining = _totalSeconds;
    if (!_isRateLimited || !widget.autoTick) return;
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining > 1) {
        setState(() => _remaining--);
      } else {
        _tickTimer?.cancel();
        _tickTimer = null;
        setState(() => _remaining = _totalSeconds);
        widget.onRetry?.call();
      }
    });
  }

  void _handleManualRetry() {
    _tickTimer?.cancel();
    _tickTimer = null;
    widget.onRetry?.call();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _enterCurve.dispose();
    _enter.dispose();
    super.dispose();
  }

  String _titleText() {
    if (_isRateLimited) return '115 暂时限制了播放';
    final reason = widget.failure?.reason.trim() ?? '';
    return reason.isNotEmpty ? reason : '无法开始播放';
  }

  String _descriptionText() {
    if (_isRateLimited) {
      return '短时间内请求太多，被片源方临时限流，通常 1 分钟内恢复。倒计时结束会自动再试一次。';
    }
    return '播放地址未能打开，请检查网络或服务器连接后再试。';
  }

  String? _codeLine() {
    final failure = widget.failure;
    final attempt = widget.retryAttempt > 0 ? widget.retryAttempt : 1;
    if (_isRateLimited) {
      final status = failure?.httpStatus ?? 403;
      final source = (failure?.sourceLabel ?? '').trim().isNotEmpty
          ? failure!.sourceLabel!.trim()
          : '115 网盘';
      return 'HTTP $status · $source · 第 $attempt 次自动重试';
    }
    final parts = <String>[
      if (failure?.httpStatus != null) 'HTTP ${failure!.httpStatus}',
      if ((failure?.sourceLabel ?? '').trim().isNotEmpty) failure!.sourceLabel!.trim(),
      if (failure?.httpStatus == null && (failure?.code ?? '').trim().isNotEmpty) failure!.code!.trim(),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final code = _codeLine();
    final ringSize = scale.rem(3.5);
    final progress = (_remaining / _totalSeconds).clamp(0.0, 1.0);

    final content = ConstrainedBox(
      key: const Key('ev_player_error_card'),
      constraints: BoxConstraints(maxWidth: scale.rem(32.0)),
      child: Padding(
        padding: EdgeInsets.only(top: scale.rem(0.5)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isRateLimited) ...[
              SizedBox(
                key: const Key('ev_player_error_countdown_ring'),
                width: ringSize,
                height: ringSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: progress),
                      duration: widget.autoTick
                          ? const Duration(seconds: 1)
                          : Duration.zero,
                      builder: (_, value, _) => CustomPaint(
                        size: Size.square(ringSize),
                        painter: _CountdownRingPainter(
                          progress: value,
                          trackColor: const Color.fromRGBO(255, 255, 255, 0.18),
                          arcColor: theme.isPaper ? _kPaperArc : _kCinemaArc,
                          strokeWidth: 3.0 * (ringSize / 56.0),
                        ),
                      ),
                    ),
                    Text(
                      '$_remaining',
                      key: const Key('ev_player_error_countdown_value'),
                      style: theme
                          .bodyStyle(
                            scale.font(1.125),
                            fontWeight: FontWeight.w600,
                            color: _kWhite,
                          )
                          .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
              SizedBox(height: scale.rem(0.625)),
            ],
            Padding(
              padding: EdgeInsets.only(top: scale.rem(0.5)),
              child: Text(
                _titleText(),
                key: const Key('ev_player_error_title'),
                textAlign: TextAlign.center,
                style: theme.bodyStyle(
                  scale.font(1.5),
                  fontWeight: FontWeight.w600,
                  color: _kWhite,
                ),
              ),
            ),
            SizedBox(height: scale.rem(0.625)),
            Text(
              _descriptionText(),
              key: const Key('ev_player_error_desc'),
              textAlign: TextAlign.center,
              style: theme.bodyStyle(
                scale.font(1.0),
                color: const Color.fromRGBO(255, 255, 255, 0.76),
                height: 1.6,
              ),
            ),
            if (code != null) ...[
              SizedBox(height: scale.rem(0.625)),
              Text(
                code,
                key: const Key('ev_player_error_code'),
                textAlign: TextAlign.center,
                style: theme
                    .bodyStyle(
                      scale.font(0.8125),
                      color: const Color.fromRGBO(255, 255, 255, 0.50),
                    )
                    .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
            if (widget.onRetry != null || widget.onBack != null) ...[
              SizedBox(height: scale.rem(1.5)),
              EvOnImage(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: scale.rem(0.625),
                  runSpacing: scale.rem(0.625),
                  children: [
                    if (widget.onRetry != null)
                      EvButton.primary(
                        key: const Key('ev_player_opening_retry'),
                        small: true,
                        icon: EvIcons.refresh,
                        label: '立即重试',
                        onPressed: _handleManualRetry,
                      ),
                    if (widget.onBack != null)
                      EvButton.ghost(
                        key: const Key('ev_player_opening_back'),
                        small: true,
                        label: '返回详情',
                        onPressed: widget.onBack,
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return AnimatedBuilder(
      animation: _enterCurve,
      builder: (_, child) => Opacity(
        opacity: _enterCurve.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, scale.rem(1.0) * (1.0 - _enterCurve.value)),
          child: child,
        ),
      ),
      child: content,
    );
  }
}

class _CountdownRingPainter extends CustomPainter {
  const _CountdownRingPainter({
    required this.progress,
    required this.trackColor,
    required this.arcColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color trackColor;
  final Color arcColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2) - strokeWidth;
    if (radius <= 0) return;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    canvas.drawCircle(center, radius, trackPaint);

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped <= 0) return;

    final arcPaint = Paint()
      ..color = arcColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      math.pi * 2 * clamped,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_CountdownRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.arcColor != arcColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
