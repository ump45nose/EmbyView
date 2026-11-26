import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Transforms the player video frame between full-bleed playback, side-panel
/// inset (`.player.paneled .pic`), and bottom-left credits mini-view (`.player.credits .pic`).
class EvCreditsVideoFrame extends StatelessWidget {
  const EvCreditsVideoFrame({
    super.key, required this.creditsActive, required this.panelOpen,
    required this.child, this.videoAspectRatio = 16 / 9, this.onTapMiniVideo,
  });

  final bool creditsActive;
  final bool panelOpen;
  final Widget child;
  final double videoAspectRatio;
  final VoidCallback? onTapMiniVideo;

  @override
  Widget build(BuildContext context) {
    final scale = EvScale.of(context);
    final insetForPanel = !creditsActive && panelOpen;
    final duration = Duration(milliseconds: creditsActive ? 900 : 600);
    final ar = (videoAspectRatio.isFinite && videoAspectRatio > 0) ? videoAspectRatio : (16 / 9);

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.hasBoundedWidth ? constraints.maxWidth : scale.size.width;
        final h = constraints.hasBoundedHeight ? constraints.maxHeight : scale.size.height;

        var left = 0.0;
        var top = 0.0;
        var right = 0.0;
        var bottom = 0.0;

        if (insetForPanel) {
          final availLeft = scale.rem(1);
          final availTop = scale.rem(1);
          final availRight = scale.rem(30);
          final availBottom = scale.rem(1);
          final availW = math.max(0.0, w - availLeft - availRight);
          final availH = math.max(0.0, h - availTop - availBottom);
          if (availW > 0 && availH > 0) {
            final double fittedW;
            final double fittedH;
            if (availW / availH > ar) {
              fittedH = availH;
              fittedW = availH * ar;
            } else {
              fittedW = availW;
              fittedH = availW / ar;
            }
            final dx = (availW - fittedW) / 2;
            final dy = (availH - fittedH) / 2;
            left = availLeft + dx;
            top = availTop + dy;
            right = availRight + dx;
            bottom = availBottom + dy;
          } else {
            left = availLeft;
            top = availTop;
            right = availRight;
            bottom = availBottom;
          }
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: insetForPanel ? const Color(0xFF000000) : const Color(0x00000000),
                ),
              ),
            ),
            AnimatedPositioned(
              key: const ValueKey('ev_credits_video_frame_pos'),
              duration: duration,
              curve: EvCurves.out,
              left: left,
              top: top,
              right: right,
              bottom: bottom,
              child: AnimatedContainer(
                key: const Key('ev_credits_video_frame_box'),
                duration: duration,
                curve: EvCurves.out,
                transform: creditsActive
                    ? (Matrix4.translationValues(scale.gutter - scale.vw(2), -scale.vh(4), 0)
                        ..multiply(Matrix4.diagonal3Values(0.36, 0.36, 1)))
                    : Matrix4.identity(),
                transformAlignment: Alignment.bottomLeft,
                clipBehavior: creditsActive ? Clip.antiAlias : Clip.hardEdge,
                decoration: BoxDecoration(
                  color: const Color(0xFF000000),
                  borderRadius: creditsActive
                      ? BorderRadius.circular(scale.rem(2.5))
                      : BorderRadius.zero,
                  boxShadow: creditsActive
                      ? [BoxShadow(offset: Offset(0, scale.rem(1.5)), blurRadius: scale.rem(4), color: const Color.fromRGBO(0, 0, 0, 0.6))]
                      : const [],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    child,
                    if (creditsActive && onTapMiniVideo != null)
                      Positioned.fill(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque, onTap: onTapMiniVideo,
                            child: Semantics(button: true, label: '返回全屏观看片尾', child: const SizedBox.expand()),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Credits next-episode overlay mirroring `.nextup` and `credits()`.
class EvCreditsOverlay extends StatefulWidget {
  const EvCreditsOverlay({
    super.key, required this.visible, required this.snapshot,
    required this.onPlayNext, required this.onStay,
    this.countdownSeconds = 5, this.autoTick = true,
  });

  final bool visible;
  final PlaybackSnapshot snapshot;
  final VoidCallback onPlayNext;
  final VoidCallback onStay;
  final int countdownSeconds;
  final bool autoTick;

  @override
  State<EvCreditsOverlay> createState() => _EvCreditsOverlayState();
}

class _EvCreditsOverlayState extends State<EvCreditsOverlay> {
  late int _remaining = math.max(0, widget.countdownSeconds);
  int _runId = 0;
  bool _fired = false;
  Timer? _tickTimer, _fireTimer;

  bool get _isActive => widget.visible && widget.snapshot.nextEpisode != null;

  @override
  void initState() {
    super.initState();
    if (_isActive) _startCountdown();
  }

  @override
  void didUpdateWidget(EvCreditsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasActive = oldWidget.visible && oldWidget.snapshot.nextEpisode != null;
    if (!_isActive) {
      _cancelTimers();
      _fired = false;
      _remaining = math.max(0, widget.countdownSeconds);
      return;
    }
    final reset = !wasActive ||
        oldWidget.snapshot.generation != widget.snapshot.generation ||
        oldWidget.snapshot.nextEpisode?.id != widget.snapshot.nextEpisode?.id ||
        oldWidget.countdownSeconds != widget.countdownSeconds;
    if (reset) {
      _startCountdown();
    } else if (oldWidget.autoTick != widget.autoTick) {
      widget.autoTick ? (_fired ? null : _scheduleTicking()) : _cancelTimers();
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _cancelTimers() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _fireTimer?.cancel();
    _fireTimer = null;
  }

  void _startCountdown() {
    _cancelTimers();
    _fired = false;
    _runId++;
    _remaining = math.max(0, widget.countdownSeconds);
    if (widget.autoTick) _scheduleTicking();
  }

  void _scheduleTicking() {
    _cancelTimers();
    if (_remaining <= 0) return _scheduleAutoPlayNext();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !_isActive || _fired) return t.cancel();
      final next = math.max(0, _remaining - 1);
      setState(() => _remaining = next);
      if (next <= 0) {
        t.cancel();
        _tickTimer = null;
        _scheduleAutoPlayNext();
      }
    });
  }

  void _scheduleAutoPlayNext() {
    _fireTimer?.cancel();
    _fireTimer = Timer(const Duration(milliseconds: 500), () {
      _fireTimer = null;
      if (!mounted || !_isActive || _fired) return;
      _fired = true;
      widget.onPlayNext();
    });
  }

  void _handlePlayNextTap() {
    _cancelTimers();
    if (_fired) return;
    _fired = true;
    widget.onPlayNext();
  }

  void _handleStayTap() {
    _cancelTimers();
    _fired = true;
    widget.onStay();
  }

  ArtworkPlan? _pickBackdrop(CardArtwork art) {
    if (art.stage.layers.isNotEmpty) return art.stage;
    if (art.landscape.layers.isNotEmpty) return art.landscape;
    if (art.poster.layers.isNotEmpty) return art.poster;
    if (art.backdrops.isNotEmpty) {
      return ArtworkPlan(layers: [ArtworkLayer(source: art.backdrops.first, fit: ArtworkFit.cover)]);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final next = widget.snapshot.nextEpisode;
    final active = _isActive;
    final ringProgress = (_remaining / math.max(1, widget.countdownSeconds)).clamp(0.0, 1.0);
    final curEp = widget.snapshot.item?.episodeNumber ?? widget.snapshot.target.episodeNumber;
    final eyebrowSize = scale.font(0.875);
    final ringSize = scale.rem(3.25);
    final backdrop = next != null ? _pickBackdrop(next.art) : null;
    final overview = next?.overview?.trim();

    return IgnorePointer(
      key: const Key('ev_player_credits_overlay'),
      ignoring: !active,
      child: AnimatedOpacity(
        opacity: active ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 900),
        curve: EvCurves.soft,
        child: next == null
            ? const SizedBox.expand()
            : Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFF000000)),
                  if (backdrop != null)
                    Opacity(
                      opacity: 0.5,
                      child: EvArtwork(plan: backdrop, overrideFit: BoxFit.cover, animateFade: false, showFallbackTitle: false),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft, end: Alignment.centerRight, stops: [0.0, 0.6, 1.0],
                        colors: [Color.fromRGBO(0, 0, 0, 0.25), Color.fromRGBO(0, 0, 0, 0.85), Color.fromRGBO(0, 0, 0, 0.85)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: scale.gutter, bottom: scale.vh(41) + scale.rem(0.75),
                    child: Text(
                      curEp != null ? '片尾 · 第 $curEp 集' : '片尾',
                      style: theme.bodyStyle(scale.font(0.875), color: const Color.fromRGBO(255, 255, 255, 0.72)),
                    ),
                  ),
                  Positioned(
                    right: scale.gutter, top: 0, bottom: 0,
                    width: math.min(scale.rem(32), scale.size.width * 0.42),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: EvOnImage(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              next.episodeNumber != null ? '下一集 · 第 ${next.episodeNumber} 集' : '下一集',
                              style: theme.bodyStyle(eyebrowSize, fontWeight: FontWeight.w600, color: const Color.fromRGBO(255, 255, 255, 0.62))
                                  .copyWith(letterSpacing: eyebrowSize * 0.12),
                            ),
                            SizedBox(height: scale.rem(0.75)),
                            Text(
                              next.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: theme.bodyStyle(scale.rem(2.375), fontWeight: FontWeight.w700, color: const Color(0xFFFFFFFF), height: 1.2),
                            ),
                            if (overview != null && overview.isNotEmpty)
                              Padding(
                                padding: EdgeInsets.only(top: scale.rem(0.75)),
                                child: Text(
                                  overview, maxLines: 4, overflow: TextOverflow.ellipsis,
                                  style: theme.bodyStyle(scale.rem(1.0625), color: const Color.fromRGBO(255, 255, 255, 0.78), height: 1.62),
                                ),
                              ),
                            SizedBox(height: scale.rem(1.5)),
                            Wrap(
                              spacing: scale.rem(0.75), runSpacing: scale.rem(0.75),
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  key: const Key('ev_credits_countdown'), width: ringSize, height: ringSize,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Positioned.fill(
                                        child: TweenAnimationBuilder<double>(
                                          key: ValueKey(_runId), tween: Tween(begin: 1.0, end: ringProgress),
                                          duration: const Duration(seconds: 1), curve: Curves.linear,
                                          builder: (_, v, _) => CustomPaint(
                                            painter: _CountdownRingPainter(progress: v, strokeWidth: scale.rem(0.1875)),
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '$_remaining',
                                        style: theme.bodyStyle(scale.rem(1.125), fontWeight: FontWeight.w700, color: const Color(0xFFFFFFFF))
                                            .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                                      ),
                                    ],
                                  ),
                                ),
                                EvButton.primary(key: const Key('ev_credits_play_next'), icon: EvIcons.play, label: '立即播放', onPressed: _handlePlayNextTap),
                                EvButton.ghost(key: const Key('ev_credits_stay'), label: '看完片尾', onPressed: _handleStayTap),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _CountdownRingPainter extends CustomPainter {
  const _CountdownRingPainter({required this.progress, required this.strokeWidth});

  final double progress, strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.max(0.0, (size.shortestSide - strokeWidth) / 2);
    if (radius <= 0) return;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawCircle(center, radius, p..color = const Color.fromRGBO(255, 255, 255, 0.2));
    final clamped = progress.clamp(0.0, 1.0);
    if (clamped > 0) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, 2 * math.pi * clamped, false, p..color = const Color(0xFFFFFFFF));
    }
  }

  @override
  bool shouldRepaint(_CountdownRingPainter old) => old.progress != progress || old.strokeWidth != strokeWidth;
}
