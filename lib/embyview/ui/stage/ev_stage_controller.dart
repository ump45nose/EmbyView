import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:moonfin/embyview/embyview.dart';

/// Visual presentation mode of the persistent full-window stage.
enum EvStageMode { hero, detail, ambient }

/// Computes a stable identity key for [plan] so identical backdrops do not
/// restart crossfade or Ken Burns animations.
String stageArtworkKey(ArtworkPlan? plan) {
  if (plan == null) return '';
  if (plan.layers.isEmpty) {
    return 'fallback:${plan.fallbackColor}:${plan.fallbackTitle}';
  }
  final buf = StringBuffer();
  for (final l in plan.layers) {
    buf..write(l.source.cacheKey)..write('|')..write(l.fit.name)..write('|')..write(l.blurred ? '1' : '0')..write(';');
  }
  return (buf..write(plan.fallbackColor)..write('|')..write(plan.fallbackTitle)).toString();
}

/// App-wide single stage state shared by browse, detail, wall, search, and settings pages.
class EvStageController extends ChangeNotifier {
  ArtworkPlan? _baseBackdrop;
  ArtworkPlan? _previewBackdrop;
  EvStageMode _mode = EvStageMode.hero;
  double _scrollProgress = 0.0;
  bool _detailNoBlur = false;
  bool _veilLifted = false;
  bool _videoVisible = false;
  String? _videoLabel;
  Color? _ambientColor;

  ArtworkPlan? get baseBackdrop => _baseBackdrop;
  ArtworkPlan? get previewBackdrop => _previewBackdrop;
  ArtworkPlan? get activeBackdrop => _previewBackdrop ?? _baseBackdrop;
  String get activeBackdropKey => stageArtworkKey(activeBackdrop);

  EvStageMode get mode => _mode;
  double get scrollProgress => _scrollProgress;
  bool get detailNoBlur => _detailNoBlur;
  bool get veilLifted => _veilLifted;
  bool get videoVisible => _videoVisible;
  String? get videoLabel => _videoLabel;
  Color? get ambientColor => _ambientColor;

  void setBaseBackdrop(ArtworkPlan? plan) {
    if (stageArtworkKey(_baseBackdrop) == stageArtworkKey(plan) && (_baseBackdrop == null) == (plan == null)) return;
    _baseBackdrop = plan;
    notifyListeners();
  }

  void setPreviewBackdrop(ArtworkPlan? plan) {
    if (stageArtworkKey(_previewBackdrop) == stageArtworkKey(plan) && (_previewBackdrop == null) == (plan == null)) {
      return;
    }
    _previewBackdrop = plan;
    notifyListeners();
  }

  void clearPreviewBackdrop() {
    if (_previewBackdrop == null) return;
    _previewBackdrop = null;
    notifyListeners();
  }

  void setMode(EvStageMode mode, {bool? detailNoBlur}) {
    final nextNoBlur = detailNoBlur ?? _detailNoBlur;
    if (_mode == mode && _detailNoBlur == nextNoBlur) return;
    _mode = mode;
    _detailNoBlur = nextNoBlur;
    notifyListeners();
  }

  void setDetailNoBlur(bool noBlur) {
    if (_detailNoBlur == noBlur) return;
    _detailNoBlur = noBlur;
    notifyListeners();
  }

  void setScrollProgress(double progress) {
    final clamped = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    if ((_scrollProgress - clamped).abs() < 1e-4) return;
    _scrollProgress = clamped;
    notifyListeners();
  }

  void setVeilLifted(bool lifted) {
    if (_veilLifted == lifted) return;
    _veilLifted = lifted;
    notifyListeners();
  }

  void setVideoState({required bool visible, String? label}) {
    final nextLabel = visible && label != null && label.isNotEmpty ? label : null;
    if (_videoVisible == visible && _videoLabel == nextLabel) return;
    _videoVisible = visible;
    _videoLabel = nextLabel;
    notifyListeners();
  }

  void setAmbientColor(Color? color) {
    if (_ambientColor == color) return;
    _ambientColor = color;
    notifyListeners();
  }

  void reset() {
    final changed = _baseBackdrop != null || _previewBackdrop != null || _mode != EvStageMode.hero ||
        _scrollProgress != 0.0 || _detailNoBlur || _veilLifted || _videoVisible ||
        _videoLabel != null || _ambientColor != null;
    if (!changed) return;
    _baseBackdrop = _previewBackdrop = null;
    _mode = EvStageMode.hero;
    _scrollProgress = 0.0;
    _detailNoBlur = _veilLifted = _videoVisible = false;
    _videoLabel = null;
    _ambientColor = null;
    notifyListeners();
  }
}
