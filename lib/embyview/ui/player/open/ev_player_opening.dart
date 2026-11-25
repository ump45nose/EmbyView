import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

const _kWhite = Color(0xFFFFFFFF);
const _kBlack = Color(0xFF000000);

/// Tracks UI first-frame latency from player mount until the first post-frame
/// callback after [PlaybackSnapshot] enters a renderable video phase, while
/// logging native [PlaybackSnapshot.firstFrameLatency] separately.
class EvFirstFrameTracker {
  EvFirstFrameTracker({
    DateTime Function()? clock,
    DateTime? startedAt,
    void Function(String message)? log,
  }) : _clock = clock ?? (startedAt != null ? DateTime.now : null),
       _log = log ?? debugPrint,
       _startedAt = startedAt ?? clock?.call(),
       _sw = (clock == null && startedAt == null) ? (Stopwatch()..start()) : null;

  final DateTime Function()? _clock;
  final void Function(String message) _log;
  DateTime? _startedAt;
  final Stopwatch? _sw;
  Duration? _uiLatency, _nativeLatency;
  int? _gen;
  bool _awaiting = false, _loggedNative = false, _disposed = false;

  Duration? get uiFirstFrameLatency => _uiLatency;
  Duration? get nativeFirstFrameLatency => _nativeLatency;
  bool get recorded => _uiLatency != null;

  Duration get elapsed {
    if (_uiLatency != null) return _uiLatency!;
    if (_clock != null && _startedAt != null) {
      final d = _clock().difference(_startedAt!);
      return d.isNegative ? Duration.zero : d;
    }
    return _sw?.elapsed ?? Duration.zero;
  }

  static bool isVideoReady(PlaybackSnapshot s) =>
      s.phase == PlaybackPhase.playing ||
      ((s.phase == PlaybackPhase.paused || s.phase == PlaybackPhase.buffering) &&
          s.firstFrameLatency != null);

  void observe(PlaybackSnapshot snap, {VoidCallback? onRecorded}) {
    if (_disposed) return;
    if (_gen != null && snap.generation != _gen) {
      reset(generation: snap.generation);
    } else {
      _gen ??= snap.generation;
    }
    if (snap.firstFrameLatency != null) {
      _nativeLatency = snap.firstFrameLatency;
      if (recorded && !_loggedNative) {
        _loggedNative = true;
        _log('[EvFirstFrameTracker] gen=${snap.generation} item=${snap.target.itemId} nativeFirstFrameLatency=${_nativeLatency!.inMilliseconds}ms');
      }
    }
    if (recorded || _awaiting || !isVideoReady(snap)) return;
    _awaiting = true;
    final gen = snap.generation, id = snap.target.itemId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _gen != gen) return;
      _awaiting = false;
      if (recorded) return;
      final measured = elapsed;
      _uiLatency = measured;
      _sw?.stop();
      final nativeMs = _nativeLatency?.inMilliseconds;
      _loggedNative = nativeMs != null;
      _log('[EvFirstFrameTracker] gen=$gen item=$id uiFirstFrameLatency=${measured.inMilliseconds}ms nativeFirstFrameLatency=${nativeMs != null ? '${nativeMs}ms' : 'null'}');
      onRecorded?.call();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void reset({int? generation}) {
    if (_disposed) return;
    _gen = generation;
    _uiLatency = _nativeLatency = null;
    _awaiting = _loggedNative = false;
    if (_clock != null) { _startedAt = _clock(); } else { _sw?..reset()..start(); }
  }

  void dispose() { _disposed = true; _sw?.stop(); }
}

/// Clips the player surface from [origin] (or 12% inset) to fullscreen (`0->1`).
class EvPlayerOpeningClip extends StatelessWidget {
  const EvPlayerOpeningClip({
    super.key, required this.child, this.origin,
    required this.expandProgress, this.cornerRadius = 20.0,
  });

  final Widget child;
  final Rect? origin;
  final double expandProgress, cornerRadius;

  @override
  Widget build(BuildContext context) {
    final t = expandProgress.clamp(0.0, 1.0);
    return t >= 1.0 ? child : ClipRRect(clipper: _OpeningClipper(origin, t, cornerRadius), child: child);
  }
}

class _OpeningClipper extends CustomClipper<RRect> {
  const _OpeningClipper(this.origin, this.progress, this.cornerRadius);
  final Rect? origin;
  final double progress, cornerRadius;

  @override
  RRect getClip(Size s) {
    final full = Offset.zero & s;
    final raw = origin ?? Rect.fromLTRB(s.width * 0.12, s.height * 0.12, s.width * 0.88, s.height * 0.88);
    final start = Rect.fromLTRB(
      raw.left.clamp(0.0, s.width), raw.top.clamp(0.0, s.height),
      raw.right.clamp(0.0, s.width), raw.bottom.clamp(0.0, s.height),
    );
    return RRect.fromRectAndRadius(
      Rect.lerp(start, full, progress) ?? full,
      Radius.circular(ui.lerpDouble(cornerRadius, 0.0, progress) ?? 0.0),
    );
  }

  @override
  bool shouldReclip(_OpeningClipper o) =>
      o.origin != origin || o.progress != progress || o.cornerRadius != cornerRadius;
}

/// Full-screen opening overlay (`.prep`) with blurred backdrop, shimmering logo,
/// first-frame status text, and failure retry/back actions.
class EvPlayerOpeningOverlay extends StatefulWidget {
  const EvPlayerOpeningOverlay({
    super.key, required this.snapshot, this.art, required this.uiFirstFrameLatency,
    required this.done, this.holdVisible = false, this.onBack, this.onRetry,
  });

  final PlaybackSnapshot snapshot;
  final CardArtwork? art;
  final Duration? uiFirstFrameLatency;
  final bool done, holdVisible;
  final VoidCallback? onBack, onRetry;

  @override
  State<EvPlayerOpeningOverlay> createState() => _EvPlayerOpeningOverlayState();
}

class _EvPlayerOpeningOverlayState extends State<EvPlayerOpeningOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;
  bool _logoFailed = false;
  bool get _hidden => widget.done && !widget.holdVisible;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    if (!_hidden) _shimmer.repeat();
  }

  @override
  void didUpdateWidget(EvPlayerOpeningOverlay old) {
    super.didUpdateWidget(old);
    if ((old.art?.logo ?? old.snapshot.item?.art.logo)?.cacheKey !=
        (widget.art?.logo ?? widget.snapshot.item?.art.logo)?.cacheKey) {
      _logoFailed = false;
    }
    if (_hidden) {
      if (_shimmer.isAnimating) _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() { _shimmer.dispose(); super.dispose(); }

  ArtworkRef? _backdrop() =>
      widget.art?.stage.layers.firstOrNull?.source ??
      widget.snapshot.item?.art.stage.layers.firstOrNull?.source ??
      widget.art?.backdrops.firstOrNull ?? widget.snapshot.item?.art.backdrops.firstOrNull ??
      widget.art?.landscape.layers.firstOrNull?.source ??
      widget.snapshot.item?.art.landscape.layers.firstOrNull?.source;

  String _status() {
    final s = widget.snapshot;
    if (s.phase == PlaybackPhase.failed) {
      return s.failure?.reason.trim().isNotEmpty == true ? s.failure!.reason : '播放失败';
    }
    final local = (s.quality?.origin ?? s.item?.quality?.origin) == MediaOrigin.nasLocal;
    final lat = widget.uiFirstFrameLatency;
    if (lat != null) {
      final secs = (lat.inMilliseconds / 1000.0).toStringAsFixed(1);
      return local ? '首帧 $secs 秒' : '已拿到直连地址 · 首帧 $secs 秒';
    }
    return local ? 'Emby 静态流 · 不转码' : '正在预解析 115 地址…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final bg = _backdrop();
    final logo = widget.art?.logo ?? widget.snapshot.item?.art.logo;
    final title = widget.snapshot.item?.title.trim().isNotEmpty == true
        ? widget.snapshot.item!.title : widget.snapshot.target.itemId;
    final failed = widget.snapshot.phase == PlaybackPhase.failed;

    Widget emblem = logo != null && !_logoFailed
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: scale.rem(6.5), maxWidth: scale.rem(24)),
            child: Image(
              key: ValueKey('ev_opening_logo_${logo.cacheKey}'),
              image: logo.image, fit: BoxFit.contain, filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && !_logoFailed) setState(() => _logoFailed = true);
                });
                return const SizedBox.shrink();
              },
            ),
          )
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: scale.rem(36)),
            child: Text(
              title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: theme.displayStyle(scale.rem(3.5), color: _kWhite, height: 1.08),
            ),
          );

    if (!failed) {
      emblem = AnimatedBuilder(
        animation: _shimmer,
        builder: (_, child) {
          final x = 2.0 - Curves.easeInOut.transform(_shimmer.value) * 4.0;
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (b) => LinearGradient(
              begin: Alignment(x - 0.9, -0.18), end: Alignment(x + 0.9, 0.18),
              stops: const [0.25, 0.5, 0.75],
              colors: const [Color(0x80FFFFFF), _kWhite, Color(0x80FFFFFF)],
            ).createShader(b),
            child: child,
          );
        },
        child: emblem,
      );
    }

    return IgnorePointer(
      ignoring: _hidden,
      child: AnimatedOpacity(
        key: const Key('ev_player_opening'),
        opacity: _hidden ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 800),
        curve: EvCurves.soft,
        child: ColoredBox(
          color: _kBlack,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (bg != null)
                ClipRect(
                  child: Opacity(
                    opacity: 0.35,
                    child: Transform.scale(
                      scale: 1.1,
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                        child: Image(
                          key: ValueKey('ev_opening_bg_${bg.cacheKey}'),
                          image: bg.image, fit: BoxFit.cover, filterQuality: FilterQuality.low,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: scale.gutter),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      emblem,
                      SizedBox(height: scale.rem(1.5)),
                      Text(
                        _status(), key: const Key('ev_player_opening_status'), textAlign: TextAlign.center,
                        style: theme
                            .bodyStyle(scale.rem(0.9375), color: Color.fromRGBO(255, 255, 255, failed ? 0.9 : 0.72))
                            .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                      if (failed && (widget.onBack != null || widget.onRetry != null)) ...[
                        SizedBox(height: scale.rem(1.5)),
                        EvOnImage(
                          child: Row(
                            mainAxisSize: MainAxisSize.min, spacing: scale.rem(0.75),
                            children: [
                              if (widget.onRetry != null)
                                EvButton.primary(key: const Key('ev_player_opening_retry'), small: true, label: '重试', onPressed: widget.onRetry),
                              if (widget.onBack != null)
                                EvButton.ghost(key: const Key('ev_player_opening_back'), small: true, icon: EvIcons.left, label: '返回', onPressed: widget.onBack),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
