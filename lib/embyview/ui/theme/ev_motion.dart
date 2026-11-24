import 'package:flutter/animation.dart';

/// Motion curves from `.spec/mockups/proto.css`.
abstract final class EvCurves {
  /// `--out: cubic-bezier(.16, 1, .3, 1)`
  static const Cubic out = Cubic(0.16, 1.0, 0.3, 1.0);

  /// `--spring: cubic-bezier(.3, 1.35, .55, 1)`
  static const Cubic spring = Cubic(0.3, 1.35, 0.55, 1.0);

  /// `--soft: cubic-bezier(.4, 0, .2, 1)`
  static const Cubic soft = Cubic(0.4, 0.0, 0.2, 1.0);
}

/// Standard motion durations from `.spec/mockups/proto.css` and `proto.js`.
abstract final class EvDurations {
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration heroSwap = Duration(milliseconds: 230);
  static const Duration normal = Duration(milliseconds: 350);
  static const Duration medium = Duration(milliseconds: 450);
  static const Duration slow = Duration(milliseconds: 600);
  static const Duration stage = Duration(milliseconds: 700);
  static const Duration crossfade = Duration(milliseconds: 1100);
  static const Duration ambient = Duration(milliseconds: 1200);
  static const Duration heroCycle = Duration(seconds: 9);
  static const Duration staggerStep = Duration(milliseconds: 70);
  static const Duration staggerBase = Duration(milliseconds: 120);
  static const Duration kenBurns = Duration(seconds: 30);
}
