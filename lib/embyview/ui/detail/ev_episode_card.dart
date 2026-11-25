import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

enum EvEpisodeSubtitleBadgeKind { none, queued, processing, completeAi, completeChinese, partial, failed }

@immutable
class EvEpisodeSubtitleBadge {
  const EvEpisodeSubtitleBadge({this.kind = EvEpisodeSubtitleBadgeKind.none, this.label = '', this.tooltip, this.cancellable = false});
  static const none = EvEpisodeSubtitleBadge();
  final EvEpisodeSubtitleBadgeKind kind;
  final String label;
  final String? tooltip;
  final bool cancellable;
  bool get visible => kind != EvEpisodeSubtitleBadgeKind.none && label.isNotEmpty;
}

/// Episode card matching `.card.ep` in `proto.css` / `proto.js`.
/// Exposes public read-only [card] and [episode] properties for W4.4 quick-look.
class EvEpisodeCard extends StatefulWidget {
  const EvEpisodeCard({
    super.key, required this.card, required this.episode, this.seriesTitle, this.width,
    this.hideUnwatchedOverview = true, this.subtitleBadge = EvEpisodeSubtitleBadge.none,
    this.accentColor, this.focusNode, this.onTap, this.onActivateWithOrigin,
    this.onHoverChanged, this.onFocusChanged, this.onCancelSubtitleJob,
  });

  final MediaCard card;
  final EpisodeCard episode;
  final String? seriesTitle;
  final double? width;
  final bool hideUnwatchedOverview;
  final EvEpisodeSubtitleBadge subtitleBadge;
  final Color? accentColor;
  final FocusNode? focusNode;
  final VoidCallback? onTap, onCancelSubtitleJob;
  final void Function(Rect origin)? onActivateWithOrigin;
  final ValueChanged<bool>? onHoverChanged, onFocusChanged;

  static const Duration spoilerRevealDelay = Duration(milliseconds: 600);

  static String displayTitle(EpisodeCard ep, {String? seriesTitle}) {
    final raw = ep.card.title.trim();
    if (raw.isNotEmpty && !RegExp(r'^第\s*\d+\s*集$').hasMatch(raw) && !RegExp(r'^Episode\s+\d+$', caseSensitive: false).hasMatch(raw)) return raw;
    if (seriesTitle != null && seriesTitle.trim().isNotEmpty) return seriesTitle.trim();
    return ep.episodeNumber != null ? '第 ${ep.episodeNumber} 集' : raw;
  }

  static double? resumeProgress(EpisodeCard ep) {
    final pos = ep.resumePosition, dur = ep.card.duration;
    return (pos == null || pos <= Duration.zero || dur == null || dur <= Duration.zero)
        ? null : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
  }

  @override State<EvEpisodeCard> createState() => _EvEpisodeCardState();
}

class _EvEpisodeCardState extends State<EvEpisodeCard> {
  static const _white = Color(0xFFFFFFFF), _paperInk = Color(0xFF141413);
  final _artKey = GlobalKey();
  bool _hov = false, _foc = false, _pressed = false, _anim = false, _ovOpen = false;
  Timer? _spoilerT;
  Alignment _glare = const Alignment(0, -1);

  bool get _hi => _hov || _foc;
  bool get _hideByDef => widget.hideUnwatchedOverview && widget.episode.played != true && (widget.episode.resumePosition ?? Duration.zero) <= Duration.zero;

  void _syncSpoiler() {
    _spoilerT?.cancel(); _spoilerT = null;
    if (!_hideByDef) { _ovOpen = true; return; }
    if (_hi) {
      if (!_ovOpen) _spoilerT = Timer(EvEpisodeCard.spoilerRevealDelay, () { if (mounted && _hi) setState(() => _ovOpen = true); });
    } else { _ovOpen = false; }
  }

  void _demote() { if (mounted && !_hi && !_pressed && _anim) setState(() => _anim = false); }

  void _setStateFlag({bool? hov, bool? foc}) {
    if (hov != null && _hov == hov) return;
    if (foc != null && _foc == foc) return;
    setState(() {
      if (hov != null) { _hov = hov; if (hov) { _anim = true; } else { _pressed = false; } }
      if (foc != null) { _foc = foc; if (foc) _anim = true; }
      _syncSpoiler();
    });
    if (hov != null) widget.onHoverChanged?.call(hov);
    if (foc != null) widget.onFocusChanged?.call(foc);
  }

  void _activate() {
    final box = _artKey.currentContext?.findRenderObject() as RenderBox?;
    widget.onActivateWithOrigin?.call(box != null && box.hasSize ? (box.localToGlobal(Offset.zero) & box.size) : Rect.zero);
    widget.onTap?.call();
  }

  @override void initState() { super.initState(); _ovOpen = !_hideByDef; }
  @override
  void didUpdateWidget(EvEpisodeCard old) {
    super.didUpdateWidget(old);
    if (old.hideUnwatchedOverview != widget.hideUnwatchedOverview || old.episode.played != widget.episode.played ||
        old.episode.resumePosition != widget.episode.resumePosition || old.episode.card.id != widget.episode.card.id) { _syncSpoiler(); }
  }
  @override void dispose() { _spoilerT?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), ep = widget.episode, p = EvEpisodeCard.resumeProgress(ep);
    final mins = ep.card.duration != null && ep.card.duration! > Duration.zero ? math.max(1, ep.card.duration!.inMinutes) : null;
    final meta = [if (ep.episodeNumber != null) '第 ${ep.episodeNumber} 集', if (mins != null) '$mins 分钟', if (p != null) '看到一半'];
    final title = EvEpisodeCard.displayTitle(ep, seriesTitle: widget.seriesTitle), ov = ep.card.overview?.trim() ?? '';
    final showOv = ov.isNotEmpty && (!_hideByDef || _ovOpen);
    final lblOff = _hi ? (t.isPaper ? Offset(-s.rem(0.3125), s.rem(0.125)) : Offset(0, s.rem(0.375))) : Offset.zero;

    Widget label = Padding(
      padding: EdgeInsets.only(top: s.rem(0.875)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (meta.isNotEmpty) Text(meta.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w600, color: t.ink3)),
        Padding(
          padding: EdgeInsets.only(top: s.rem(0.25)),
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: t.bodyStyle(s.font(1), fontWeight: FontWeight.w600, color: t.ink).copyWith(
                decoration: t.isPaper && _hi ? TextDecoration.underline : TextDecoration.none, decorationColor: t.brand, decorationThickness: 2)),
        ),
        if (ov.isNotEmpty)
          AnimatedSize(
            duration: EvDurations.medium, curve: EvCurves.out, alignment: Alignment.topLeft,
            child: showOv
                ? Padding(padding: EdgeInsets.only(top: s.rem(0.375)), child: Text(ov, key: Key('ev_episode_overview_${ep.card.id}'), maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.875), color: t.ink3, height: 1.55)))
                : const SizedBox.shrink(),
          ),
      ]),
    );
    if (_anim) {
      label = TweenAnimationBuilder<Offset>(tween: Tween(begin: Offset.zero, end: lblOff), duration: EvDurations.medium, curve: EvCurves.spring,
          builder: (_, o, c) => Transform.translate(offset: o, child: c), child: label);
    }

    Widget body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [_buildArt(t, s, BorderRadius.circular(s.rem(t.radius)), p, ep.played == true), label]);
    if (widget.width != null) body = SizedBox(width: widget.width, child: body);

    return Semantics(
      button: true, focused: _foc, label: '${meta.join(' ')} $title',
      child: Focus(
        focusNode: widget.focusNode, onFocusChange: (v) => _setStateFlag(foc: v),
        onKeyEvent: (_, e) { if (!evIsActivateKey(e)) return KeyEventResult.ignored; _activate(); return KeyEventResult.handled; },
        child: MouseRegion(
          cursor: SystemMouseCursors.click, onEnter: (_) => _setStateFlag(hov: true), onExit: (_) => _setStateFlag(hov: false),
          onHover: (e) {
            if (t.isPaper) return;
            final box = _artKey.currentContext?.findRenderObject() as RenderBox?;
            if (box == null || !box.hasSize) return;
            final loc = box.globalToLocal(e.position);
            setState(() => _glare = Alignment((loc.dx / box.size.width * 2 - 1).clamp(-1.0, 1.0), (loc.dy / box.size.height * 2 - 1).clamp(-1.0, 1.0)));
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: _activate,
            onTapDown: (_) => setState(() { _pressed = true; _anim = true; }),
            onTapUp: (_) => setState(() => _pressed = false), onTapCancel: () => setState(() => _pressed = false),
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _buildArt(EvTheme t, EvScale s, BorderRadius rad, double? prog, bool played) {
    final isP = t.isPaper, b = widget.subtitleBadge;
    final sc = isP ? (_pressed ? 0.99 : 1.0) : (_pressed ? 1.01 : (_hi ? 1.07 : 1.0));
    final off = isP && _hi ? Offset(-s.rem(_pressed ? 0.125 : 0.3125), -s.rem(_pressed ? 0.125 : 0.3125)) : Offset.zero;
    final sh = _hi ? (isP ? [BoxShadow(offset: Offset(s.rem(0.625), s.rem(0.625)), color: widget.accentColor ?? t.tv)] : t.cardShadowHi) : t.cardShadow;
    final bDec = BoxDecoration(borderRadius: rad, border: Border.all(color: _hi ? t.focusColor : t.line, width: _hi ? 1.5 : 1));

    final overlay = Stack(fit: StackFit.expand, children: [
      if (!isP && _anim)
        IgnorePointer(child: AnimatedOpacity(
          opacity: _hi ? 1 : 0, duration: EvDurations.normal, curve: EvCurves.soft,
          child: DecoratedBox(decoration: BoxDecoration(gradient: RadialGradient(center: _glare, radius: 0.7, colors: const [Color.fromRGBO(255, 255, 255, 0.24), Color.fromRGBO(255, 255, 255, 0)]))),
        )),
      if (b.visible) Positioned(left: s.rem(0.5), top: s.rem(0.5), child: _subBadge(t, s, b)),
      if (played)
        Positioned(right: s.rem(0.5), top: s.rem(0.5), child: Container(
          key: Key('ev_episode_played_${widget.episode.card.id}'), width: s.rem(1.625), height: s.rem(1.625), alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: isP ? t.brand : const Color.fromRGBO(0, 0, 0, 0.50), border: isP ? Border.all(color: _paperInk, width: 1.25) : null),
          child: EvIcon(EvIcons.check, size: s.rem(isP ? 1 : 0.875), color: isP ? _paperInk : _white),
        )),
      if (prog != null)
        Positioned(left: s.rem(0.75), right: s.rem(0.75), bottom: s.rem(0.75), height: s.rem(0.25), child: ClipRRect(
          key: Key('ev_episode_progress_${widget.episode.card.id}'), borderRadius: BorderRadius.circular(2),
          child: ColoredBox(color: Color.fromRGBO(255, 255, 255, isP ? 0.55 : 0.30),
              child: Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: prog.clamp(0.0, 1.0), child: ColoredBox(color: isP ? t.brand : _white)))),
        )),
      IgnorePointer(child: _anim ? AnimatedContainer(duration: EvDurations.normal, curve: EvCurves.soft, decoration: bDec) : DecoratedBox(decoration: bDec)),
    ]);

    final art = EvArtwork(plan: widget.episode.still, aspectRatio: 16 / 9, overrideFit: BoxFit.cover, borderRadius: rad, overlay: overlay);
    final dec = BoxDecoration(borderRadius: rad, boxShadow: sh);
    final surf = _anim ? AnimatedContainer(key: _artKey, duration: EvDurations.medium, curve: EvCurves.out, decoration: dec, child: art) : DecoratedBox(key: _artKey, decoration: dec, child: art);
    if (!_anim) return surf;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: sc), duration: EvDurations.medium, curve: EvCurves.spring, onEnd: _demote,
      builder: (_, v, c) => isP
          ? TweenAnimationBuilder<Offset>(tween: Tween(begin: Offset.zero, end: off), duration: EvDurations.medium, curve: EvCurves.spring, onEnd: _demote,
              builder: (_, o, inner) => Transform(alignment: Alignment.center, transform: Matrix4.translationValues(o.dx, o.dy, 0)..multiply(Matrix4.diagonal3Values(v, v, 1)), child: inner), child: c)
          : Transform(alignment: Alignment.center, transform: Matrix4.diagonal3Values(v, v, 1), child: c),
      child: surf,
    );
  }

  Widget _subBadge(EvTheme t, EvScale s, EvEpisodeSubtitleBadge b) {
    final p = t.isPaper;
    final (bg, fg, ic, icon) = switch (b.kind) {
      EvEpisodeSubtitleBadgeKind.completeAi => (const Color.fromRGBO(0, 0, 0, 0.56), _white, p ? const Color(0xFFE8A88A) : const Color(0xFFCDB6FF), EvIcons.aisub),
      EvEpisodeSubtitleBadgeKind.completeChinese => (const Color.fromRGBO(0, 0, 0, 0.56), _white, p ? const Color(0xFFE8A88A) : const Color(0xFF7BE0A5), EvIcons.cc),
      EvEpisodeSubtitleBadgeKind.partial => (const Color.fromRGBO(40, 32, 16, 0.72), const Color(0xFFFFD88A), const Color(0xFFFFB547), EvIcons.cc),
      EvEpisodeSubtitleBadgeKind.queued => (const Color.fromRGBO(0, 0, 0, 0.38), const Color.fromRGBO(255, 255, 255, 0.78), const Color.fromRGBO(255, 255, 255, 0.56), EvIcons.aisub),
      EvEpisodeSubtitleBadgeKind.processing => (p ? const Color.fromRGBO(181, 83, 47, 0.85) : const Color.fromRGBO(68, 52, 118, 0.78), _white, p ? const Color(0xFFFFE5D9) : const Color(0xFFDCD0FF), EvIcons.aisub),
      EvEpisodeSubtitleBadgeKind.failed => (const Color.fromRGBO(110, 24, 24, 0.78), const Color(0xFFFFC2C2), const Color(0xFFFF7A7A), EvIcons.aisub),
      EvEpisodeSubtitleBadgeKind.none => (const Color(0x00000000), _white, _white, EvIcons.aisub),
    };
    final canCancel = b.cancellable && widget.onCancelSubtitleJob != null;
    final pill = Container(
      key: Key('ev_episode_sub_badge_${widget.episode.card.id}'), height: s.rem(1.625),
      padding: EdgeInsets.fromLTRB(s.rem(0.4375), 0, s.rem(canCancel ? 0.3125 : 0.5625), 0),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        EvIcon(icon, size: s.rem(1), color: ic), SizedBox(width: s.rem(0.3125)),
        Text(b.label, style: t.bodyStyle(s.font(0.8125), fontWeight: FontWeight.w600, color: fg, height: 1)),
        if (canCancel) ...[
          SizedBox(width: s.rem(0.25)),
          Semantics(button: true, label: '取消本集生成', child: GestureDetector(
            key: Key('ev_episode_sub_cancel_${widget.episode.card.id}'), behavior: HitTestBehavior.opaque, onTap: widget.onCancelSubtitleJob,
            child: Padding(padding: EdgeInsets.all(s.rem(0.125)), child: EvIcon(EvIcons.x, size: s.rem(0.75), color: fg)),
          )),
        ],
      ]),
    );
    return (b.tooltip?.isNotEmpty ?? false) ? Semantics(tooltip: b.tooltip!, child: pill) : pill;
  }
}
