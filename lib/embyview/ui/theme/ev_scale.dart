import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Linear viewport scale matching `.spec/mockups/proto.js`:
/// `rem = 10.86 + 0.00357 * width` (1440 px -> 16.00 px, 2560 px -> 20.00 px).
@immutable
class EvScale {
  const EvScale._(this.size, this.remSize);

  factory EvScale.fromSize(Size size) {
    final width = size.width < 0 ? 0.0 : size.width;
    final remSize = ((10.86 + 0.00357 * width) * 100).roundToDouble() / 100;
    return EvScale._(size, remSize);
  }

  static EvScale of(BuildContext context) =>
      EvScale.fromSize(MediaQuery.sizeOf(context));

  final Size size;

  /// Root `rem` size in logical pixels (16.00 at 1440w, 20.00 at 2560w).
  final double remSize;

  /// Scale factor relative to the 1440 px reference width (1.0 at 1440w, 1.25 at 2560w).
  double get factor => remSize / 16.0;

  /// Minimum font size floor (`0.8125rem`, 13 px at 1440w).
  double get minFontSize => rem(0.8125);

  /// Horizontal page gutter (`--g: 4.5rem`).
  double get gutter => rem(4.5);

  /// Bottom peek height revealing the first shelf row (`--peek: 8.5rem`).
  double get peek => rem(8.5);

  /// Converts `rem` units to logical pixels.
  double rem(double units) => units * remSize;

  /// Converts a pixel value designed for 1440 px width to current viewport pixels.
  double px(double pxAt1440) => pxAt1440 * factor;

  /// Viewport height percentage (`--vh = height / 100`).
  double vh(double percent) => size.height * (percent / 100.0);

  /// Viewport width percentage (`--vw = width / 100`).
  double vw(double percent) => size.width * (percent / 100.0);

  /// Font size clamped to [minFontSize].
  double font(double remUnits) => math.max(minFontSize, rem(remUnits));

  /// Shelf card width matching `proto.js` `fit(base)` so `N + 0.25` cards span
  /// the visible track width (`avail = width - gutter`).
  double shelfCardWidth(double baseRem, {double gapRem = 1.25}) {
    final avail = math.max(0.0, size.width - gutter);
    final gap = rem(gapRem);
    final unit = rem(baseRem) + gap;
    final n = unit <= 0 ? 1 : math.max(1, (avail / unit - 0.25).round());
    return math.max(0.0, (avail - n * gap) / (n + 0.25));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EvScale && other.size == size && other.remSize == remSize;

  @override
  int get hashCode => Object.hash(size, remSize);
}
