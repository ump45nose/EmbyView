import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Vertical A–Z index bar (`#` + `A`–`Z`) mirroring `.az` in `.spec/mockups/proto.css`
/// and `proto.js`: equal-size vertically aligned letters, elastic highlight thumb,
/// distance brightness decay (following active letter or pointer hover/drag), and
/// a left-floating glass letter bubble with vertical flip while scrolling.
class EvAlphaIndexBar extends StatefulWidget {
  const EvAlphaIndexBar({
    super.key,
    required this.letterOffsets,
    required this.activeLetter,
    required this.scrolling,
    required this.onSelectLetter,
  });

  /// Canonical index keys in display order (`#`, then `A`..`Z`).
  static const List<String> letters = [
    '#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  ];

  final Map<String, int> letterOffsets;
  final String activeLetter;
  final bool scrolling;
  final ValueChanged<String> onSelectLetter;

  /// Distance-attenuated opacity matching `proto.js`: `max(0.26, 1 - |i - c| * 0.15)`.
  static double letterOpacity({
    required int index,
    required int focusIndex,
    required bool enabled,
    required bool isCurrent,
  }) {
    if (!enabled) return 0.12;
    if (isCurrent) return 1.0;
    if (focusIndex < 0) return 0.40;
    return math.max(0.26, 1.0 - (index - focusIndex).abs() * 0.15);
  }

  @override
  State<EvAlphaIndexBar> createState() => _EvAlphaIndexBarState();
}

class _EvAlphaIndexBarState extends State<EvAlphaIndexBar> {
  static const _paperThumb = Color(0xFFB5532F);
  static const _white = Color(0xFFFFFFFF);

  bool _hovered = false, _dragging = false;
  int _hoverIndex = -1, _lastActiveIndex = -1, _flipDirection = 0;
  String? _lastDragSelected;

  int get _activeIndex {
    final direct = EvAlphaIndexBar.letters.indexOf(widget.activeLetter.toUpperCase());
    if (direct >= 0 && widget.letterOffsets.containsKey(EvAlphaIndexBar.letters[direct])) return direct;
    for (var i = 0; i < EvAlphaIndexBar.letters.length; i++) {
      if (widget.letterOffsets.containsKey(EvAlphaIndexBar.letters[i])) return i;
    }
    return -1;
  }

  @override
  void initState() {
    super.initState();
    _lastActiveIndex = _activeIndex;
  }

  @override
  void didUpdateWidget(EvAlphaIndexBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _activeIndex;
    if (next >= 0 && next != _lastActiveIndex) {
      _flipDirection = _lastActiveIndex < 0 ? 0 : (next > _lastActiveIndex ? 1 : -1);
      _lastActiveIndex = next;
    }
  }

  int _indexForDy(double dy, double itemHeight) =>
      itemHeight <= 0 ? 0 : (dy / itemHeight).floor().clamp(0, EvAlphaIndexBar.letters.length - 1);

  void _selectIndexIfEnabled(int index) {
    if (index < 0 || index >= EvAlphaIndexBar.letters.length) return;
    final letter = EvAlphaIndexBar.letters[index];
    if (!widget.letterOffsets.containsKey(letter)) return;
    if (_dragging && _lastDragSelected == letter) return;
    _lastDragSelected = letter;
    widget.onSelectLetter(letter);
  }

  void _endDrag() => setState(() {
    _dragging = false;
    _lastDragSelected = null;
    if (!_hovered) _hoverIndex = -1;
  });

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final itemW = scale.rem(1.875), itemH = scale.rem(1.375), bubbleSz = scale.rem(3.25);
    final activeIdx = _activeIndex, ready = activeIdx >= 0;
    final showBubble = ready && (widget.scrolling || _dragging);
    final focusIdx = (_hovered || _dragging) && _hoverIndex >= 0 ? _hoverIndex : activeIdx;
    final targetY = ready ? activeIdx * itemH : 0.0;
    final thumbColor = theme.isPaper ? _paperThumb : theme.indBg;
    final currentFg = theme.isPaper ? _white : theme.indFg;

    return Semantics(
      key: const Key('ev_alpha_bar'), container: true, label: '字母索引条',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onHover: (e) {
          final idx = _indexForDy(e.localPosition.dy, itemH);
          if (idx != _hoverIndex) setState(() => _hoverIndex = idx);
        },
        onExit: (_) => setState(() { _hovered = false; _hoverIndex = -1; }),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (d) {
            final idx = _indexForDy(d.localPosition.dy, itemH);
            setState(() { _dragging = true; _hoverIndex = idx; _lastDragSelected = null; });
            _selectIndexIfEnabled(idx);
          },
          onVerticalDragUpdate: (d) {
            final idx = _indexForDy(d.localPosition.dy, itemH);
            if (idx != _hoverIndex) setState(() => _hoverIndex = idx);
            _selectIndexIfEnabled(idx);
          },
          onVerticalDragEnd: (_) => _endDrag(),
          onVerticalDragCancel: _endDrag,
          child: SizedBox(
            width: itemW, height: itemH * EvAlphaIndexBar.letters.length,
            child: AnimatedOpacity(
              opacity: (_hovered || _dragging || widget.scrolling) ? 1.0 : 0.55,
              duration: const Duration(milliseconds: 400), curve: EvCurves.soft,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: targetY),
                    duration: const Duration(milliseconds: 500), curve: EvCurves.spring,
                    builder: (_, ty, child) => Positioned(left: 0, top: ty, width: itemW, height: itemH, child: child!),
                    child: AnimatedOpacity(
                      key: const Key('ev_alpha_thumb'), opacity: ready ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300), curve: EvCurves.soft,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: thumbColor, borderRadius: BorderRadius.circular(scale.rem(0.4375))),
                      ),
                    ),
                  ),
                  if (ready)
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: targetY),
                      duration: const Duration(milliseconds: 500), curve: EvCurves.spring,
                      builder: (_, ty, child) => Positioned(right: itemW + scale.rem(0.75), top: ty - scale.rem(0.9375), child: child!),
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          key: const Key('ev_alpha_bubble'), opacity: showBubble ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 300), curve: EvCurves.soft,
                          child: AnimatedSlide(
                            offset: showBubble ? Offset.zero : const Offset(0.16, 0),
                            duration: const Duration(milliseconds: 500), curve: EvCurves.spring,
                            child: AnimatedScale(
                              scale: showBubble ? 1.0 : 0.85,
                              duration: const Duration(milliseconds: 500), curve: EvCurves.spring,
                              child: EvGlass(
                                borderRadius: BorderRadius.circular(scale.rem(1.0)),
                                child: SizedBox(
                                  width: bubbleSz, height: bubbleSz,
                                  child: ClipRect(
                                    child: Center(
                                      child: AnimatedSwitcher(
                                        duration: const Duration(milliseconds: 400),
                                        switchInCurve: EvCurves.out, switchOutCurve: EvCurves.soft,
                                        transitionBuilder: (child, anim) {
                                          final incoming = child.key == ValueKey<String>(EvAlphaIndexBar.letters[activeIdx]);
                                          final dir = _flipDirection.toDouble();
                                          return FadeTransition(
                                            opacity: anim,
                                            child: SlideTransition(
                                              position: Tween<Offset>(
                                                begin: Offset(0, incoming ? dir * 0.45 : -dir * 0.35),
                                                end: Offset.zero,
                                              ).animate(anim),
                                              child: child,
                                            ),
                                          );
                                        },
                                        child: Text(
                                          EvAlphaIndexBar.letters[activeIdx],
                                          key: ValueKey<String>(EvAlphaIndexBar.letters[activeIdx]),
                                          style: theme.displayStyle(scale.font(1.625), color: theme.ink, height: 1.0),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < EvAlphaIndexBar.letters.length; i++)
                        _AlphaLetterCell(
                          letter: EvAlphaIndexBar.letters[i], width: itemW, height: itemH,
                          enabled: widget.letterOffsets.containsKey(EvAlphaIndexBar.letters[i]),
                          isCurrent: i == activeIdx,
                          opacity: EvAlphaIndexBar.letterOpacity(
                            index: i, focusIndex: focusIdx,
                            enabled: widget.letterOffsets.containsKey(EvAlphaIndexBar.letters[i]),
                            isCurrent: i == activeIdx,
                          ),
                          textColor: i == activeIdx ? currentFg : theme.ink,
                          fontSize: scale.font(0.8125),
                          onTap: () => widget.onSelectLetter(EvAlphaIndexBar.letters[i]),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AlphaLetterCell extends StatelessWidget {
  const _AlphaLetterCell({
    required this.letter, required this.width, required this.height,
    required this.enabled, required this.isCurrent, required this.opacity,
    required this.textColor, required this.fontSize, required this.onTap,
  });

  final String letter;
  final double width, height, opacity, fontSize;
  final bool enabled, isCurrent;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    return Semantics(
      button: enabled, enabled: enabled, selected: isCurrent, label: letter,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          key: Key('ev_alpha_letter_$letter'), behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: width, height: height,
            child: Center(
              child: AnimatedOpacity(
                opacity: opacity, duration: EvDurations.normal, curve: EvCurves.soft,
                child: Text(
                  letter, maxLines: 1, textAlign: TextAlign.center,
                  style: theme.bodyStyle(fontSize, fontWeight: FontWeight.w600, color: textColor, height: 1.0),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
