import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/stage/ev_stage_controller.dart';
import 'package:moonfin/embyview/ui/stage/immersion.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Computed scroll veil opacity and blur radius mirroring `.spec/mockups/proto.js`.
@immutable
class EvStageVeilSpec {
  const EvStageVeilSpec({required this.opacity, required this.blurSigma});
  final double opacity;
  final double blurSigma;
}

/// Persistent full-window backdrop stage mirroring `.stage` in `prototype.html`
/// and `proto.css` (ambient tint, dual crossfade stills with Ken Burns or
/// blurred poster fill, muted preview video, scrim + paper bottom edge, scroll
/// veil, film grain, and top-center `.vlabel` capsule).
class EvStage extends StatefulWidget {
  const EvStage({
    super.key,
    required this.controller,
    this.immersion,
    this.enableMotion = true,
  });

  final EvStageController controller;
  final Immersion? immersion;
  final bool enableMotion;

  static const Duration _videoFadeDuration = Duration(milliseconds: 1400);
  static const Duration _veilTransitionDuration = Duration(milliseconds: 900);
  static const Duration _scrimCinemaDuration = Duration(milliseconds: 800);
  static const Duration _scrimPaperDuration = Duration(milliseconds: 500);

  /// Computes veil `(opacity, blurSigma)` matching `proto.js`.
  static EvStageVeilSpec computeVeil({
    required EvStageMode mode,
    required double scrollProgress,
    required bool detailNoBlur,
    required bool veilLifted,
    required bool isPaper,
  }) {
    final p = scrollProgress.clamp(0.0, 1.0);
    return switch (mode) {
      EvStageMode.ambient => EvStageVeilSpec(opacity: 0.35 + p * 0.25, blurSigma: 0.0),
      EvStageMode.hero => isPaper
          ? EvStageVeilSpec(opacity: p * 0.50, blurSigma: p * 36.0)
          : EvStageVeilSpec(
              opacity: p * 0.80 * (veilLifted ? 0.3 : 1.0),
              blurSigma: p * 28.0 * (veilLifted ? 0.3 : 1.0),
            ),
      EvStageMode.detail => veilLifted
          ? EvStageVeilSpec(opacity: p * 0.30, blurSigma: 0.0)
          : detailNoBlur
          ? (isPaper
                ? EvStageVeilSpec(opacity: p * 0.64, blurSigma: p * 22.0)
                : EvStageVeilSpec(opacity: p * 0.62, blurSigma: 0.0))
          : (isPaper
                ? EvStageVeilSpec(opacity: p * 0.50, blurSigma: p * 36.0)
                : EvStageVeilSpec(opacity: p * 0.78, blurSigma: p * 26.0)),
    };
  }

  @override
  State<EvStage> createState() => _EvStageState();
}

class _EvStageState extends State<EvStage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final List<ArtworkPlan?> _slots = [null, null];
  int _activeSlot = 0;
  String _currentBackdropKey = '';
  String? _lastVideoLabel;
  bool _lastVeilLifted = false;
  EvStageMode _lastMode = EvStageMode.hero;
  bool _veilAnimating = false;
  bool _disableAnimations = false;
  late final AnimationController _kbController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _kbController = AnimationController(vsync: this, duration: EvDurations.kenBurns);
    widget.controller.addListener(_onControllerChanged);
    widget.immersion?.addListener(_onImmersionChanged);
    _syncFromController(initial: true);
  }

  @override
  void didUpdateWidget(EvStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _syncFromController(initial: true);
    }
    if (oldWidget.immersion != widget.immersion) {
      oldWidget.immersion?.removeListener(_onImmersionChanged);
      widget.immersion?.addListener(_onImmersionChanged);
    }
    _syncKenBurns();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncKenBurns();
  }

  void _onImmersionChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    _syncFromController();
    _syncKenBurns();
    if (mounted) setState(() {});
  }

  void _syncFromController({bool initial = false}) {
    final c = widget.controller;
    final key = c.activeBackdropKey;
    if (initial || key != _currentBackdropKey) {
      _currentBackdropKey = key;
      final plan = c.activeBackdrop;
      if (plan == null) {
        _slots[0] = _slots[1] = null;
      } else if (initial) {
        _activeSlot = 0;
        _slots[0] = plan;
        _slots[1] = null;
      } else {
        _activeSlot = 1 - _activeSlot;
        _slots[_activeSlot] = plan;
      }
    }
    if (c.videoLabel != null && c.videoLabel!.isNotEmpty) {
      _lastVideoLabel = c.videoLabel;
    }
    _veilAnimating = !initial && (c.veilLifted != _lastVeilLifted || c.mode != _lastMode);
    _lastVeilLifted = c.veilLifted;
    _lastMode = c.mode;
  }

  void _syncKenBurns() {
    final plan = widget.controller.activeBackdrop;
    final blurred = plan != null && plan.layers.isNotEmpty && plan.layers.first.blurred;
    final shouldRun = widget.enableMotion && !_disableAnimations &&
        widget.controller.mode != EvStageMode.ambient &&
        !widget.controller.videoVisible && plan != null && !blurred;
    if (shouldRun) {
      if (!_kbController.isAnimating) _kbController.repeat(reverse: true);
    } else if (_kbController.isAnimating) {
      _kbController.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.immersion?.setWindowActive(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onControllerChanged);
    widget.immersion?.removeListener(_onImmersionChanged);
    _kbController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final c = widget.controller;
    final isAmbient = c.mode == EvStageMode.ambient;
    final hasBackdrop = c.activeBackdrop != null;
    final frameOpacity = isAmbient ? (theme.isPaper ? 0.14 : 0.30) : 1.0;
    final frameBlur = isAmbient ? (theme.isPaper ? 70.0 : 60.0) : 0.0;
    final frameSat = isAmbient ? (theme.isPaper ? 1.1 : 1.4) : 1.0;

    final veil = EvStage.computeVeil(
      mode: c.mode,
      scrollProgress: c.scrollProgress,
      detailNoBlur: c.detailNoBlur,
      veilLifted: c.veilLifted,
      isPaper: theme.isPaper,
    );

    Widget frame = Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < 2; i++)
          _BackdropSlot(
            key: ValueKey<String>('ev_stage_slot_$i'),
            plan: _slots[i],
            visible: hasBackdrop && _activeSlot == i,
            kenBurns: _kbController,
            enableMotion: widget.enableMotion && !isAmbient,
          ),
        Positioned.fill(
          child: AnimatedOpacity(
            key: const Key('ev_stage_video_layer'),
            opacity: c.videoVisible ? 1.0 : 0.0,
            duration: EvStage._videoFadeDuration,
            curve: EvCurves.soft,
            child: widget.immersion?.videoSurfaceBuilder?.call(context) ?? const SizedBox.shrink(),
          ),
        ),
      ],
    );
    if (frameSat != 1.0) {
      frame = ColorFiltered(colorFilter: ColorFilter.matrix(_saturationMatrix(frameSat)), child: frame);
    }

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: _AmbientBackground(
              bg: theme.bg,
              ambient: c.ambientColor ?? theme.ambient,
              isPaper: theme.isPaper,
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: const Key('ev_stage_frame'),
                opacity: frameOpacity,
                duration: EvDurations.stage,
                curve: EvCurves.soft,
                child: AnimatedScale(
                  scale: isAmbient ? 1.15 : 1.0,
                  duration: EvDurations.ambient,
                  curve: EvCurves.out,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: frameBlur),
                    duration: EvDurations.stage,
                    curve: EvCurves.soft,
                    builder: (_, sigma, child) => sigma > 0.1
                        ? ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: child)
                        : child!,
                    child: frame,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: _StageScrim(theme: theme, scale: scale, mode: c.mode, scrollProgress: c.scrollProgress),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: _StageVeil(
                key: const Key('ev_stage_veil'),
                bg: theme.bg,
                spec: veil,
                duration: _veilAnimating ? EvStage._veilTransitionDuration : Duration.zero,
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _GrainPainter(opacity: theme.isPaper ? 0.03 : 0.05, darkDots: theme.isPaper),
                ),
              ),
            ),
          ),
          if (_lastVideoLabel != null)
            Positioned(
              left: 0,
              right: 0,
              top: scale.rem(1.25),
              child: IgnorePointer(
                child: Center(
                  child: _VideoLabelCapsule(
                    key: const Key('ev_stage_vlabel'),
                    visible: c.videoVisible && (c.videoLabel?.isNotEmpty ?? false),
                    label: _lastVideoLabel!,
                    scale: scale,
                    theme: theme,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground({required this.bg, required this.ambient, required this.isPaper});
  final Color bg, ambient;
  final bool isPaper;

  @override
  Widget build(BuildContext context) {
    if (isPaper) {
      return AnimatedContainer(duration: EvDurations.slow, curve: EvCurves.soft, color: bg);
    }
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: ambient),
      duration: EvDurations.ambient,
      curve: EvCurves.soft,
      builder: (_, tint, _) {
        final amb = tint ?? ambient;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            gradient: RadialGradient(
              center: const Alignment(0.7, -1.0),
              radius: 1.25,
              colors: [amb.withValues(alpha: 0.50), amb.withValues(alpha: 0.14), amb.withValues(alpha: 0.0)],
              stops: const [0.0, 0.45, 0.75],
            ),
          ),
        );
      },
    );
  }
}

class _BackdropSlot extends StatefulWidget {
  const _BackdropSlot({
    super.key,
    required this.plan,
    required this.visible,
    required this.kenBurns,
    required this.enableMotion,
  });

  final ArtworkPlan? plan;
  final bool visible;
  final Animation<double> kenBurns;
  final bool enableMotion;

  @override
  State<_BackdropSlot> createState() => _BackdropSlotState();
}

class _BackdropSlotState extends State<_BackdropSlot> {
  int _layerIndex = 0;

  @override
  void didUpdateWidget(_BackdropSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (stageArtworkKey(oldWidget.plan) != stageArtworkKey(widget.plan)) _layerIndex = 0;
  }

  void _onLayerError(int failedIndex) {
    if (!mounted || _layerIndex != failedIndex) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _layerIndex == failedIndex) setState(() => _layerIndex = failedIndex + 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    return AnimatedOpacity(
      opacity: widget.visible && plan != null ? 1.0 : 0.0,
      duration: EvDurations.crossfade,
      curve: EvCurves.soft,
      child: plan == null ? const SizedBox.shrink() : _buildPlan(plan),
    );
  }

  Widget _buildPlan(ArtworkPlan plan) {
    if (_layerIndex >= plan.layers.length) {
      final fallback = Color(plan.fallbackColor);
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.65, -0.4),
            radius: 1.3,
            colors: [fallback, Color.lerp(fallback, const Color(0xFF09090B), 0.55)!],
          ),
        ),
      );
    }

    final layer = plan.layers[_layerIndex];
    final image = Image(
      key: ValueKey<String>(layer.source.cacheKey),
      image: layer.source.image,
      fit: layer.fit == ArtworkFit.contain ? BoxFit.contain : BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) {
        _onLayerError(_layerIndex);
        return ColoredBox(color: Color(plan.fallbackColor));
      },
    );

    if (layer.blurred) {
      return Transform.scale(
        scale: 1.2,
        child: ImageFiltered(
          key: const Key('ev_stage_blurfill'),
          imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: ColorFiltered(colorFilter: ColorFilter.matrix(_saturationMatrix(1.3)), child: image),
        ),
      );
    }

    return LayoutBuilder(
      builder: (_, constraints) => AnimatedBuilder(
        animation: widget.kenBurns,
        child: image,
        builder: (_, child) {
          final t = widget.enableMotion ? Curves.easeInOut.transform(widget.kenBurns.value) : 0.0;
          final s = ui.lerpDouble(1.03, 1.14, t)!;
          return Transform(
            key: const Key('ev_stage_kenburns'),
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..translateByDouble(-0.016 * t * constraints.maxWidth, -0.012 * t * constraints.maxHeight, 0.0, 1.0)
              ..scaleByDouble(s, s, 1.0, 1.0),
            child: child,
          );
        },
      ),
    );
  }
}

class _StageScrim extends StatelessWidget {
  const _StageScrim({required this.theme, required this.scale, required this.mode, required this.scrollProgress});
  final EvTheme theme;
  final EvScale scale;
  final EvStageMode mode;
  final double scrollProgress;

  static Widget _grad(
    Alignment begin,
    Alignment end,
    Color base,
    List<double> alphas,
    List<double> stops, {
    Key? key,
  }) => DecoratedBox(
    key: key,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: begin,
        end: end,
        colors: [for (final a in alphas) base.withValues(alpha: a)],
        stops: stops,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isDetail = mode == EvStageMode.detail;
    final opacity = mode == EvStageMode.ambient
        ? 0.0
        : (theme.isPaper ? (1.0 - scrollProgress).clamp(0.0, 1.0) : 1.0);

    return AnimatedOpacity(
      key: const Key('ev_stage_scrim'),
      opacity: opacity,
      duration: theme.isPaper ? EvStage._scrimPaperDuration : EvStage._scrimCinemaDuration,
      curve: EvCurves.soft,
      child: theme.isPaper ? _paperScrim(isDetail) : _cinemaScrim(isDetail),
    );
  }

  Widget _cinemaScrim(bool d) => Stack(
    fit: StackFit.expand,
    children: [
      _grad(Alignment.topCenter, Alignment.bottomCenter, theme.bg, [d ? 0.45 : 0.50, 0.0], [0.0, d ? 0.14 : 0.16]),
      _grad(
        Alignment.bottomCenter,
        Alignment.topCenter,
        theme.bg,
        [1.0, d ? 0.80 : 0.85, 0.0],
        d ? const [0.0, 0.11, 0.34] : const [0.0, 0.16, 0.48],
      ),
      _grad(
        Alignment.centerLeft,
        Alignment.centerRight,
        theme.bg,
        d ? const [0.94, 0.84, 0.50, 0.12, 0.0] : const [0.92, 0.72, 0.34, 0.0],
        d ? const [0.0, 0.22, 0.40, 0.56, 0.68] : const [0.0, 0.24, 0.46, 0.68],
      ),
    ],
  );

  Widget _paperScrim(bool d) {
    const ink = Color(0xFF141413);
    const paperAlphas = [1.0, 1.0, 0.96, 0.86, 0.68, 0.46, 0.26, 0.11, 0.03, 0.0];
    const paperRemOffsets = [-4.0, -2.5, -1.0, 0.5, 2.0, 3.5, 5.0, 6.5, 8.0];
    return LayoutBuilder(
      builder: (_, constraints) {
        final h = constraints.maxHeight > 0 ? constraints.maxHeight : 900.0;
        final stops = [0.0, for (final r in paperRemOffsets) ((scale.peek + scale.rem(r)) / h).clamp(0.0, 1.0)];
        return Stack(
          fit: StackFit.expand,
          children: [
            _grad(Alignment.topCenter, Alignment.bottomCenter, ink, [d ? 0.42 : 0.45, 0.0], [0.0, d ? 0.18 : 0.16]),
            _grad(
              Alignment.centerLeft,
              Alignment.centerRight,
              ink,
              d ? const [0.90, 0.78, 0.44, 0.10, 0.0] : const [0.88, 0.68, 0.32, 0.0],
              d ? const [0.0, 0.22, 0.40, 0.56, 0.68] : const [0.0, 0.24, 0.46, 0.68],
            ),
            _grad(
              Alignment.bottomCenter,
              Alignment.topCenter,
              theme.bg,
              paperAlphas,
              stops,
              key: const Key('ev_stage_paper_edge'),
            ),
          ],
        );
      },
    );
  }
}

class _StageVeil extends StatelessWidget {
  const _StageVeil({super.key, required this.bg, required this.spec, required this.duration});
  final Color bg;
  final EvStageVeilSpec spec;
  final Duration duration;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(end: spec.opacity),
    duration: duration,
    curve: EvCurves.soft,
    builder: (_, opacity, _) => TweenAnimationBuilder<double>(
      tween: Tween<double>(end: spec.blurSigma),
      duration: duration,
      curve: EvCurves.soft,
      builder: (_, sigma, _) {
        if (opacity <= 0.001 && sigma <= 0.1) return const SizedBox.shrink();
        Widget fill = ColoredBox(color: bg.withValues(alpha: opacity.clamp(0.0, 1.0)));
        return sigma > 0.1
            ? BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: fill)
            : fill;
      },
    ),
  );
}

class _VideoLabelCapsule extends StatelessWidget {
  const _VideoLabelCapsule({
    super.key,
    required this.visible,
    required this.label,
    required this.scale,
    required this.theme,
  });

  final bool visible;
  final String label;
  final EvScale scale;
  final EvTheme theme;

  @override
  Widget build(BuildContext context) => AnimatedSlide(
    offset: visible ? Offset.zero : const Offset(0, -0.25),
    duration: EvDurations.slow,
    curve: EvCurves.out,
    child: AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 500),
      curve: EvCurves.soft,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            height: scale.rem(2.0),
            padding: EdgeInsets.symmetric(horizontal: scale.rem(0.875)),
            color: const Color.fromRGBO(0, 0, 0, 0.42),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                EvIcon(EvIcons.film, size: scale.rem(0.875), color: const Color(0xFFFFFFFF)),
                SizedBox(width: scale.rem(0.5)),
                Text(
                  label,
                  style: theme.bodyStyle(scale.font(0.875), fontWeight: FontWeight.w500, color: const Color(0xFFFFFFFF)),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter({required this.opacity, required this.darkDots});
  final double opacity;
  final bool darkDots;

  static final List<Offset> _points = _makePoints();

  static List<Offset> _makePoints() {
    final rng = math.Random(1337);
    return List<Offset>.generate(220, (_) => Offset(rng.nextDouble() * 160.0, rng.nextDouble() * 160.0), growable: false);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || opacity <= 0) return;
    final paint = Paint()
      ..color = (darkDots ? const Color(0xFF000000) : const Color(0xFFFFFFFF)).withValues(alpha: opacity)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.square;
    const tile = 160.0;
    for (var r = 0; r < (size.height / tile).ceil(); r++) {
      for (var c = 0; c < (size.width / tile).ceil(); c++) {
        canvas.drawPoints(ui.PointMode.points, [for (final p in _points) Offset(c * tile + p.dx, r * tile + p.dy)], paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.opacity != opacity || old.darkDots != darkDots;
}

List<double> _saturationMatrix(double s) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final inv = 1.0 - s;
  final sr = inv * r, sg = inv * g, sb = inv * b;
  return [sr + s, sg, sb, 0, 0, sr, sg + s, sb, 0, 0, sr, sg, sb + s, 0, 0, 0, 0, 0, 1, 0];
}
