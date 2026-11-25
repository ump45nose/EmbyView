import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_format.dart';

const _kWhite = Color(0xFFFFFFFF);
const _kDarkBg = Color(0xFF111111);
const _kMs300 = Duration(milliseconds: 300);

/// Full-width player scrub bar (`.scrub`, `.aurora`, `.trick`, `.times`) with
/// chapter ticks, buffer bar, hover/drag thumbnail preview, and AI aurora stream.
class EvPlayerScrubBar extends StatefulWidget {
  const EvPlayerScrubBar({
    super.key, required this.position, required this.duration, required this.bufferedUntil,
    this.chapters = const [], this.aiRun, this.flashAuroraTip = false,
    this.visible = true, this.generation = 0,
    this.onThumbnailAt, required this.onSeek, this.onHoverChanged, this.onScrubbingChanged,
    this.forcedHoverFraction, this.clock = DateTime.now,
  });

  final Duration position, bufferedUntil;
  final Duration? duration;
  final List<ChapterMark> chapters;
  final AiRun? aiRun;
  final bool flashAuroraTip, visible;
  final int generation;
  final Future<ThumbnailFrame?> Function(Duration position)? onThumbnailAt;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<bool>? onHoverChanged, onScrubbingChanged;
  final double? forcedHoverFraction;
  final DateTime Function() clock;

  /// Computes normalized `[start, end]` aurora coverage segments in `[0.0, 1.0]`,
  /// preserving real seek gaps when [AiRun.coverage] has multiple ranges.
  static List<(double, double)> computeAuroraSegments(AiRun? run, Duration position, Duration? duration) {
    final total = duration?.inMilliseconds ?? 0;
    if (run == null || total <= 0) return const [];
    if (run.coverage.isNotEmpty) {
      return [
        for (final r in run.coverage)
          if (r.end > r.start)
            ((r.start.inMilliseconds / total).clamp(0.0, 1.0), (r.end.inMilliseconds / total).clamp(0.0, 1.0)),
      ];
    }
    final end = run.coverageEnd;
    if (end == null || end <= position) return const [];
    return [((position.inMilliseconds / total).clamp(0.0, 1.0), (end.inMilliseconds / total).clamp(0.0, 1.0))];
  }

  @override
  State<EvPlayerScrubBar> createState() => _EvPlayerScrubBarState();
}

class _EvPlayerScrubBarState extends State<EvPlayerScrubBar> with SingleTickerProviderStateMixin {
  late final AnimationController _auroraCtrl;
  bool _hovered = false, _scrubbing = false;
  double? _hoverFrac, _scrubFrac, _lastHoverFrac;
  Timer? _debounce;
  int _reqId = 0;
  ThumbnailFrame? _thumb;

  bool get _hasDur => (widget.duration?.inMilliseconds ?? 0) > 0;
  bool get _auroraOn {
    final s = widget.aiRun?.state;
    return _hasDur && (s == AiRunState.generating || s == AiRunState.catchingUp || s == AiRunState.completed);
  }
  bool get _auroraAnimating {
    final s = widget.aiRun?.state;
    return widget.visible && _hasDur && (s == AiRunState.generating || s == AiRunState.catchingUp);
  }

  @override
  void initState() {
    super.initState();
    _auroraCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3));
    _syncAurora();
    if (widget.forcedHoverFraction != null && _hasDur) {
      _lastHoverFrac = widget.forcedHoverFraction!.clamp(0.0, 1.0);
      _requestThumb(widget.forcedHoverFraction!, immediate: true);
    }
  }

  @override
  void didUpdateWidget(EvPlayerScrubBar old) {
    super.didUpdateWidget(old);
    final genChanged = old.generation != widget.generation;
    if (genChanged || old.duration != widget.duration) {
      _debounce?.cancel();
      _debounce = null;
      _reqId++;
      _thumb = null;
      if (genChanged) {
        _scrubbing = false;
        _scrubFrac = null;
        _lastHoverFrac = null;
      }
    }
    _syncAurora();
    if (widget.forcedHoverFraction != null && _hasDur &&
        (genChanged || widget.forcedHoverFraction != old.forcedHoverFraction || widget.onThumbnailAt != old.onThumbnailAt)) {
      _lastHoverFrac = widget.forcedHoverFraction!.clamp(0.0, 1.0);
      _requestThumb(widget.forcedHoverFraction!, immediate: true);
    }
  }

  void _syncAurora() {
    if (_auroraAnimating) {
      if (!_auroraCtrl.isAnimating) _auroraCtrl.repeat();
    } else if (_auroraCtrl.isAnimating) {
      _auroraCtrl.stop();
    }
  }

  @override
  void dispose() { _debounce?.cancel(); _auroraCtrl.dispose(); super.dispose(); }

  Duration _posFor(double f) {
    final total = widget.duration?.inMilliseconds ?? 0;
    return total <= 0 ? Duration.zero : Duration(milliseconds: (f.clamp(0.0, 1.0) * total).round());
  }

  double _frac(double dx, double w) => w <= 0 ? 0.0 : (dx / w).clamp(0.0, 1.0);

  void _requestThumb(double f, {bool immediate = false}) {
    final loader = widget.onThumbnailAt;
    if (loader == null || !_hasDur) return;
    final target = _posFor(f);
    _debounce?.cancel();
    void fire() {
      final id = ++_reqId;
      loader(target).then((frame) {
        if (mounted && id == _reqId && frame != null) setState(() => _thumb = frame);
      }).catchError((_) {});
    }
    immediate ? fire() : _debounce = Timer(const Duration(milliseconds: 30), fire);
  }

  void _onHover(double dx, double w) {
    final f = _frac(dx, w);
    final moved = !_hovered || _hoverFrac == null || (_hoverFrac! - f).abs() > 0.002;
    if (!_hovered) { _hovered = true; widget.onHoverChanged?.call(true); }
    if (moved) { setState(() { _hoverFrac = f; _lastHoverFrac = f; }); _requestThumb(f, immediate: _thumb == null); }
  }

  void _onScrub(double dx, double w, {bool start = false}) {
    if (!_hasDur || (!start && !_scrubbing)) return;
    final f = _frac(dx, w);
    setState(() { _scrubbing = true; _scrubFrac = f; _lastHoverFrac = f; });
    if (start) widget.onScrubbingChanged?.call(true);
    _requestThumb(f, immediate: start && _thumb == null);
  }

  void _endScrub(bool commit) {
    if (!_scrubbing) return;
    final f = _scrubFrac;
    setState(() { _scrubbing = false; _scrubFrac = null; });
    widget.onScrubbingChanged?.call(false);
    if (commit && f != null && _hasDur) widget.onSeek(_posFor(f));
  }

  String? _auroraTip() {
    final r = widget.aiRun;
    if (r == null) return null;
    if (r.state == AiRunState.catchingUp) return 'AI 中字追赶中';
    final end = r.coverageEnd;
    if (end == null) return null;
    final lead = end - widget.position;
    return lead > Duration.zero ? 'AI 中字已领先 ${evFormatLeadDuration(lead)}' : null;
  }

  String? _chapterLabel(Duration pos) {
    if (widget.chapters.isEmpty) return null;
    var idx = -1;
    for (var i = 0; i < widget.chapters.length; i++) {
      if (widget.chapters[i].start <= pos) idx = i;
    }
    final name = (idx < 0 ? widget.chapters.first : widget.chapters[idx]).name?.trim();
    return (name != null && name.isNotEmpty) ? name : (idx < 0 ? null : '第 ${idx + 1} 章');
  }

  Widget _tipPill(EvTheme t, EvScale s, String text) {
    final bg = t.isPaper ? const Color(0xFFFAF9F5) : const Color(0xC71E1A32);
    final fg = t.isPaper ? const Color(0xFFB5532F) : const Color(0xFFDCD0FF);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          key: const Key('ev_player_aurora_tip'),
          padding: EdgeInsets.symmetric(horizontal: s.rem(0.6875), vertical: s.rem(0.375)),
          decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(999),
            boxShadow: t.isPaper ? const [BoxShadow(offset: Offset(0, 4), blurRadius: 16, color: Color(0x38000000))] : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min, spacing: s.rem(0.375),
            children: [
              EvIcon(EvIcons.aisub, size: s.rem(0.9375), color: fg),
              Text(
                text, maxLines: 1, softWrap: false,
                style: t.bodyStyle(s.rem(0.8125), fontWeight: FontWeight.w600, color: fg)
                    .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewCard(EvTheme t, EvScale s, Duration pos, String? chapter) {
    final r = s.rem(0.75);
    const sh = [Shadow(offset: Offset(0, 1), blurRadius: 4, color: Color(0xCC000000))];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: _kDarkBg, borderRadius: BorderRadius.circular(r),
            border: Border.all(color: const Color(0xBFFFFFFF), width: 1.5),
            boxShadow: [BoxShadow(offset: Offset(0, s.rem(1.0)), blurRadius: s.rem(2.0), color: const Color(0x80000000))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(math.max(0.0, r - 1.5)),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _thumb != null
                  ? Image(
                      key: ValueKey('ev_trick_img_${_thumb!.image.cacheKey}'),
                      image: _thumb!.image.image, fit: BoxFit.cover, gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => const ColoredBox(color: _kDarkBg),
                    )
                  : const ColoredBox(color: _kDarkBg),
            ),
          ),
        ),
        SizedBox(height: s.rem(0.5)),
        Text(
          evFormatPlayerTime(pos), maxLines: 1,
          style: t.bodyStyle(s.rem(0.9375), fontWeight: FontWeight.w600, color: _kWhite)
              .copyWith(fontFeatures: const [FontFeature.tabularFigures()], shadows: sh),
        ),
        if (chapter != null && chapter.isNotEmpty)
          Text(
            chapter, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: t.bodyStyle(s.rem(0.8125), fontWeight: FontWeight.w500, color: const Color(0xBFFFFFFF)).copyWith(shadows: sh),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final total = widget.duration?.inMilliseconds ?? 0, hasDur = total > 0;
    final pos = _scrubbing && _scrubFrac != null && hasDur ? _posFor(_scrubFrac!) : widget.position;
    final prog = hasDur ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    final buf = hasDur ? (widget.bufferedUntil.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    final hover = widget.forcedHoverFraction?.clamp(0.0, 1.0) ??
        (_scrubbing ? _scrubFrac : (_hovered ? _hoverFrac : null));
    final expanded = _hovered || _scrubbing || widget.forcedHoverFraction != null;
    final trackH = scale.rem(1.5), barH = scale.rem(expanded ? 0.5625 : 0.3125), knob = scale.rem(1.125);
    final segs = _auroraOn ? EvPlayerScrubBar.computeAuroraSegments(widget.aiRun, widget.position, widget.duration) : const <(double, double)>[];
    final tip = _auroraOn ? _auroraTip() : null;
    final chaps = hasDur
        ? [for (final c in widget.chapters) if (c.start.inMilliseconds > 0 && c.start.inMilliseconds < total) c.start.inMilliseconds / total]
        : const <double>[];
    final timeStyle = theme.bodyStyle(scale.rem(0.875), color: const Color(0xC7FFFFFF))
        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

    return Column(
      key: const Key('ev_player_scrub_bar'),
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (_, c) {
            final w = c.maxWidth.isFinite ? c.maxWidth : 0.0, barTop = (trackH - barH) / 2;
            final pvW = math.min(scale.rem(15.0), w);
            final displayHover = hover ?? _lastHoverFrac;
            final pvPos = displayHover != null ? _posFor(displayHover) : Duration.zero;
            final pvLeft = displayHover != null ? (displayHover * w - pvW / 2).clamp(0.0, math.max(0.0, w - pvW)).toDouble() : 0.0;
            final anchor = segs.isNotEmpty
                ? segs.last.$2
                : (widget.aiRun?.coverageEnd != null && hasDur
                    ? (widget.aiRun!.coverageEnd!.inMilliseconds / total).clamp(0.0, 1.0) : prog);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (e) => _onHover(e.localPosition.dx, w),
                  onHover: (e) => _onHover(e.localPosition.dx, w),
                  onExit: (_) {
                    if (!_hovered) return;
                    setState(() { _hovered = false; _hoverFrac = null; });
                    widget.onHoverChanged?.call(false);
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) { if (hasDur) widget.onSeek(_posFor(_frac(d.localPosition.dx, w))); },
                    onHorizontalDragStart: (d) => _onScrub(d.localPosition.dx, w, start: true),
                    onHorizontalDragUpdate: (d) => _onScrub(d.localPosition.dx, w),
                    onHorizontalDragEnd: (_) => _endScrub(true),
                    onHorizontalDragCancel: () => _endScrub(false),
                    child: SizedBox(
                      height: trackH, width: w,
                      child: Stack(
                        clipBehavior: Clip.none, alignment: Alignment.centerLeft,
                        children: [
                          AnimatedContainer(
                            duration: _kMs300, curve: EvCurves.out, height: barH, width: w,
                            child: CustomPaint(painter: _ScrubTrackPainter(prog, buf, chaps)),
                          ),
                          if (_auroraOn)
                            Positioned(
                              key: const Key('ev_player_aurora'), left: 0, right: 0, bottom: trackH - barTop + 3, height: 3,
                              child: IgnorePointer(
                                child: AnimatedBuilder(
                                  animation: _auroraCtrl,
                                  builder: (_, _) => CustomPaint(painter: _AuroraPainter(segs, _auroraCtrl.value, theme.isPaper)),
                                ),
                              ),
                            ),
                          Positioned(
                            left: (w * prog - knob / 2).clamp(-knob / 2, math.max(0.0, w - knob / 2)),
                            top: (trackH - knob) / 2,
                            child: IgnorePointer(
                              child: AnimatedScale(
                                scale: expanded ? 1.0 : 0.0, duration: _kMs300, curve: EvCurves.spring,
                                child: Container(
                                  width: knob, height: knob,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle, color: _kWhite,
                                    boxShadow: [BoxShadow(offset: Offset(0, 2), blurRadius: 8, color: Color(0x66000000))],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (tip != null)
                  Positioned(
                    bottom: trackH - barTop + 6 + scale.rem(0.875), left: 0, right: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: (expanded || widget.flashAuroraTip) ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 250), curve: EvCurves.soft,
                        child: Align(alignment: Alignment((anchor * 2 - 1).clamp(-1.0, 1.0), 1.0), child: _tipPill(theme, scale, tip)),
                      ),
                    ),
                  ),
                if (displayHover != null && hasDur && pvW > 0)
                  Positioned(
                    key: const Key('ev_player_trick_preview'), left: pvLeft, bottom: scale.rem(2.25), width: pvW,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: hover != null ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200), curve: EvCurves.soft,
                        child: _previewCard(theme, scale, pvPos, _chapterLabel(pvPos)),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        SizedBox(height: scale.rem(0.125)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(evFormatPlayerTime(pos), key: const Key('ev_player_time_current'), style: timeStyle),
            if (hasDur)
              Text(evFormatRemainingLine(widget.duration! - pos, widget.clock()), key: const Key('ev_player_time_remaining'), style: timeStyle),
          ],
        ),
      ],
    );
  }
}

class _ScrubTrackPainter extends CustomPainter {
  const _ScrubTrackPainter(this.progress, this.buffered, this.chapters);
  final double progress, buffered;
  final List<double> chapters;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(3)));
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0x38FFFFFF));
    if (buffered > 0) canvas.drawRect(Rect.fromLTWH(0, 0, size.width * buffered, size.height), Paint()..color = const Color(0x42FFFFFF));
    if (progress > 0) canvas.drawRect(Rect.fromLTWH(0, 0, size.width * progress, size.height), Paint()..color = _kWhite);
    if (chapters.isNotEmpty) {
      final cp = Paint()..color = const Color(0x8C000000);
      for (final f in chapters) { canvas.drawRect(Rect.fromLTWH(f * size.width - 1, 0, 2, size.height), cp); }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScrubTrackPainter o) {
    if (o.progress != progress || o.buffered != buffered || o.chapters.length != chapters.length) return true;
    for (var i = 0; i < chapters.length; i++) {
      if (o.chapters[i] != chapters[i]) return true;
    }
    return false;
  }
}

class _AuroraPainter extends CustomPainter {
  const _AuroraPainter(this.segments, this.phase, this.isPaper);
  final List<(double, double)> segments;
  final double phase;
  final bool isPaper;

  @override
  void paint(Canvas canvas, Size size) {
    if (segments.isEmpty || size.width <= 0 || size.height <= 0) return;
    final colors = isPaper
        ? const [Color(0xFFD97757), Color(0xFFE8A88A), Color(0xFFD97757), Color(0xFFE8A88A)]
        : const [Color(0xFF9F7BFF), Color(0xFF6FB8FF), Color(0xFF5FE0C0), Color(0xFF9F7BFF)];
    final shift = -phase * size.width * 2;
    final shader = ui.Gradient.linear(
      Offset(shift, 0), Offset(shift + size.width * 3, 0),
      colors, const [0.0, 0.33, 0.66, 1.0], TileMode.repeated,
    );
    final glow = Paint()
      ..color = isPaper ? const Color(0xB3D97757) : const Color(0xCC8C8CFF)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isPaper ? 4 : 5);
    final fill = Paint()..shader = shader;
    for (final (s, e) in segments) {
      final rr = RRect.fromRectAndRadius(Rect.fromLTWH(s * size.width, 0, math.max(2.0, (e - s) * size.width), size.height), const Radius.circular(2));
      canvas.drawRRect(rr, glow);
      canvas.drawRRect(rr, fill);
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter o) {
    if (o.phase != phase || o.isPaper != isPaper || o.segments.length != segments.length) return true;
    for (var i = 0; i < segments.length; i++) {
      if (o.segments[i] != segments[i]) return true;
    }
    return false;
  }
}
