import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/theme/ev_motion.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Consumes an [ArtworkPlan] in layer order with automatic decode-error fallback,
/// covering Backdrop+Logo, Backdrop+title, portrait cropped Backdrop+title, and
/// fallback color block + title from `.spec/mockups/proto.js`.
class EvArtwork extends StatefulWidget {
  const EvArtwork({
    super.key,
    required this.plan,
    this.aspectRatio,
    this.borderRadius,
    this.overrideFit,
    this.showFallbackTitle = true,
    this.overlay,
  });

  final ArtworkPlan plan;
  final double? aspectRatio;
  final BorderRadius? borderRadius;
  final BoxFit? overrideFit;
  final bool showFallbackTitle;
  final Widget? overlay;

  @override
  State<EvArtwork> createState() => _EvArtworkState();
}

class _EvArtworkState extends State<EvArtwork> {
  static const _white = Color(0xFFFFFFFF);
  static const _paperInk = Color(0xFF141413);

  int _layerIndex = 0;
  bool _logoFailed = false;
  bool _imageSettled = false;
  int? _pendingAdvanceFrom;

  @override
  void didUpdateWidget(EvArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePlanLayers(oldWidget.plan, widget.plan)) {
      _layerIndex = 0;
      _logoFailed = false;
      _imageSettled = false;
      _pendingAdvanceFrom = null;
    }
  }

  static bool _samePlanLayers(ArtworkPlan a, ArtworkPlan b) {
    if (identical(a, b)) return true;
    if (a.layers.length != b.layers.length) return false;
    for (var i = 0; i < a.layers.length; i++) {
      final la = a.layers[i], lb = b.layers[i];
      if (la.source.cacheKey != lb.source.cacheKey ||
          la.logo?.cacheKey != lb.logo?.cacheKey ||
          la.fit != lb.fit || la.blurred != lb.blurred || la.text != lb.text) {
        return false;
      }
    }
    return true;
  }

  void _advanceLayer(int failedIndex) {
    if (_pendingAdvanceFrom == failedIndex || _layerIndex != failedIndex) return;
    _pendingAdvanceFrom = failedIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layerIndex != failedIndex) return;
      setState(() {
        _layerIndex = failedIndex + 1;
        _logoFailed = false;
        _imageSettled = false;
        _pendingAdvanceFrom = null;
      });
    });
  }

  void _fallbackLogo(int layerIndex) {
    if (_logoFailed || _layerIndex != layerIndex) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layerIndex != layerIndex) return;
      setState(() {
        if (layerIndex + 1 < widget.plan.layers.length) {
          _layerIndex = layerIndex + 1;
          _logoFailed = false;
          _imageSettled = false;
        } else {
          _logoFailed = true;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);

    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.hasBoundedWidth && constraints.maxWidth > 0 ? constraints.maxWidth : 0.0;
        final h = constraints.hasBoundedHeight && constraints.maxHeight > 0
            ? constraints.maxHeight
            : (widget.aspectRatio != null && w > 0 ? w / widget.aspectRatio! : 0.0);
        final isPortrait = widget.aspectRatio != null
            ? widget.aspectRatio! < 1.0
            : (h > 0 && w > 0 && h > w);
        final layers = widget.plan.layers;

        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: theme.cardBg),
            if (_layerIndex < layers.length)
              _buildLayer(theme, scale, layers[_layerIndex], _layerIndex, w, h, isPortrait)
            else
              _buildFallbackBlock(theme, scale),
            if (widget.overlay != null) Positioned.fill(child: widget.overlay!),
          ],
        );
      },
    );

    if (widget.borderRadius != null) {
      content = ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }
    if (widget.aspectRatio != null) {
      content = AspectRatio(aspectRatio: widget.aspectRatio!, child: content);
    }
    return content;
  }

  Widget _buildLayer(
    EvTheme theme, EvScale scale, ArtworkLayer layer, int idx,
    double w, double h, bool isPortrait,
  ) {
    final fit = widget.overrideFit ??
        (layer.fit == ArtworkFit.cover ? BoxFit.cover : BoxFit.contain);
    final hasLogo = layer.logo != null && !_logoFailed;
    final text = hasLogo
        ? null
        : (layer.text ?? (_logoFailed && widget.plan.fallbackTitle.isNotEmpty ? widget.plan.fallbackTitle : null));
    final hasOverlay = hasLogo || (text != null && text.isNotEmpty);
    final alignment = isPortrait && fit == BoxFit.cover && hasOverlay
        ? const Alignment(-0.4, 0.0)
        : Alignment.center;

    Widget image = Image(
      key: ValueKey('ev_art_layer_${idx}_${layer.source.cacheKey}'),
      image: layer.source.image,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      frameBuilder: (_, child, frame, sync) => sync || _imageSettled
          ? child
          : AnimatedOpacity(
              opacity: frame == null ? 0.0 : 1.0,
              duration: EvDurations.slow,
              curve: EvCurves.soft,
              onEnd: frame != null
                  ? () { if (mounted && !_imageSettled) setState(() => _imageSettled = true); }
                  : null,
              child: child,
            ),
      errorBuilder: (_, _, _) {
        _advanceLayer(idx);
        return idx + 1 >= widget.plan.layers.length
            ? _buildFallbackBlock(theme, scale)
            : const SizedBox.shrink();
      },
    );

    if (layer.blurred) {
      image = ClipRect(
        child: Transform.scale(
          scale: 1.2,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: image,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        if (hasOverlay)
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: isPortrait
                    ? const LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment(0.0, -0.2),
                        colors: [Color.fromRGBO(0, 0, 0, 0.75), Color.fromRGBO(0, 0, 0, 0.0)],
                      )
                    : const LinearGradient(
                        begin: Alignment(-0.36, 1.0),
                        end: Alignment(0.45, -0.35),
                        stops: [0.0, 0.58],
                        colors: [Color.fromRGBO(0, 0, 0, 0.62), Color.fromRGBO(0, 0, 0, 0.0)],
                      ),
              ),
            ),
          ),
        if (hasLogo)
          Positioned(
            left: w * 0.07,
            bottom: h * 0.12,
            child: IgnorePointer(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: w > 0 ? w * 0.52 : double.infinity,
                  maxHeight: h > 0 ? h * 0.34 : double.infinity,
                ),
                child: Image(
                  key: ValueKey('ev_art_logo_${idx}_${layer.logo!.cacheKey}'),
                  image: layer.logo!.image,
                  fit: BoxFit.contain,
                  alignment: Alignment.bottomLeft,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) {
                    _fallbackLogo(idx);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          ),
        if (text != null && text.isNotEmpty)
          Positioned(
            left: w * 0.07,
            right: w * 0.07,
            bottom: h * 0.11,
            child: IgnorePointer(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme
                    .displayStyle(scale.font(1.375), color: _white, height: 1.15)
                    .copyWith(shadows: const [
                      Shadow(offset: Offset(0, 2), blurRadius: 12, color: Color.fromRGBO(0, 0, 0, 0.6)),
                    ]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFallbackBlock(EvTheme theme, EvScale scale) {
    final tint = Color(widget.plan.fallbackColor);
    final isPaper = theme.isPaper;
    return DecoratedBox(
      key: const ValueKey('ev_artwork_fallback'),
      decoration: isPaper
          ? const BoxDecoration(color: Color(0xFFE8E6DC))
          : const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-0.35, -1.0),
                end: Alignment(0.35, 1.0),
                colors: [Color(0xFF26262D), Color(0xFF141418)],
              ),
            ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.bottomLeft,
            radius: 1.2,
            stops: isPaper ? const [0.0, 0.65] : const [0.0, 0.60],
            colors: [tint.withValues(alpha: isPaper ? 0.45 : 0.50), tint.withValues(alpha: 0.0)],
          ),
        ),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.all(scale.rem(1.0)),
            child: widget.showFallbackTitle && widget.plan.fallbackTitle.isNotEmpty
                ? Text(
                    widget.plan.fallbackTitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.displayStyle(
                      scale.font(1.25),
                      color: isPaper ? _paperInk : _white,
                      height: 1.2,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
