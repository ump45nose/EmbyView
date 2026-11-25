import 'dart:math' as math;
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Colors, Tooltip;
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/detail/ev_theme_capsule.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Full-bleed detail first screen (`100vh - peek`) mirroring `.detail .first` in `proto.css` / `proto.js`.
class EvDetailHero extends StatefulWidget {
  const EvDetailHero({
    super.key, required this.detail, required this.people, this.seasonsCount, this.quality,
    required this.backdropCount, required this.backdropIndex, required this.onSelectBackdrop,
    required this.canTrailer, required this.isTrailerClip, required this.trailerLive,
    required this.countdownSeconds, required this.countdownTotalSeconds, required this.onToggleTrailer,
    required this.onPlay,
    this.isFavorite = false, this.isPlayed = false,
    this.favoriteBusy = false, this.playedBusy = false,
    this.actionError, this.onDismissActionError,
    this.onToggleFavorite, this.onTogglePlayed,
  });

  final MediaDetail detail;
  final List<PersonCredit> people;
  final int? seasonsCount;
  final MediaQuality? quality;
  final int backdropCount, backdropIndex, countdownSeconds, countdownTotalSeconds;
  final bool canTrailer, isTrailerClip, trailerLive;
  final bool isFavorite, isPlayed, favoriteBusy, playedBusy;
  final String? actionError;
  final VoidCallback? onDismissActionError;
  final ValueChanged<int> onSelectBackdrop;
  final VoidCallback onToggleTrailer;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin) onPlay;
  final VoidCallback? onToggleFavorite, onTogglePlayed;

  @override State<EvDetailHero> createState() => _EvDetailHeroState();
}

class _EvDetailHeroState extends State<EvDetailHero> {
  String? _failedLogoKey;

  @override
  void didUpdateWidget(EvDetailHero old) {
    super.didUpdateWidget(old);
    if (old.detail.card.id != widget.detail.card.id || old.detail.card.art.logo?.cacheKey != widget.detail.card.art.logo?.cacheKey) _failedLogoKey = null;
  }

  void _play(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox?, d = widget.detail;
    widget.onPlay(d.resume?.target ?? d.playTarget ?? PlayTarget(itemId: d.card.id), d.card.art, box != null && box.hasSize ? (box.localToGlobal(Offset.zero) & box.size) : null);
  }

  @override
  Widget build(BuildContext context) {
    final s = EvScale.of(context);
    return SizedBox(
      key: const Key('ev_detail_hero'), height: math.max(0.0, s.vh(100) - s.peek), width: double.infinity,
      child: EvOnImage(
        child: LayoutBuilder(builder: (ctx, c) {
          final t = EvTheme.of(ctx), maxW = c.maxWidth > 0 ? c.maxWidth : s.size.width;
          final infoW = math.min(math.min(s.rem(46), maxW * 0.52), math.max(0.0, maxW - s.gutter * 2));
          return Stack(fit: StackFit.expand, children: [
            Positioned(left: s.gutter, bottom: s.rem(2.25), width: infoW, child: _buildInfo(ctx, t, s)),
            if (widget.backdropCount > 1 || widget.canTrailer) Positioned(right: s.gutter, bottom: s.rem(2.5), child: _buildBgCtl(t, s)),
          ]);
        }),
      ),
    );
  }

  Widget _buildInfo(BuildContext ctx, EvTheme t, EvScale s) {
    final d = widget.detail, card = d.card;
    List<String> byRole(List<String> keys, int cap) =>
        widget.people.where((p) => keys.contains(p.role.trim().toLowerCase()) && p.name.trim().isNotEmpty).take(cap).map((p) => p.name.trim()).toList();
    final dirs = byRole(const ['director', '导演'], 2), acts = byRole(const ['actor', '主演', '演员'], 4);
    final credLbl = t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: t.ink2, height: 1.6);

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildStatusPill(ctx, t, s),
      SizedBox(height: s.rem(1.25)),
      _buildTitleArt(t, s, card),
      SizedBox(height: s.rem(1.25)),
      _buildMetaLine(t, s, card),
      if (d.tagline?.trim().isNotEmpty ?? false) ...[
        SizedBox(height: s.rem(1)),
        Text(d.tagline!.trim(), key: const Key('ev_detail_tagline'), maxLines: 2, overflow: TextOverflow.ellipsis,
            style: t.serifStyle(s.font(1.1875), fontStyle: FontStyle.italic, color: t.ink2, height: 1.45)),
      ],
      if (card.overview?.trim().isNotEmpty ?? false) ...[
        SizedBox(height: s.rem(1)),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: s.rem(38)),
          child: Text(card.overview!.trim(), key: const Key('ev_detail_overview'), maxLines: 2, overflow: TextOverflow.ellipsis,
              style: t.bodyStyle(s.font(1.125), color: t.ink2, height: 1.62)),
        ),
      ],
      SizedBox(height: s.rem(1.5)),
      _buildActions(t, s),
      if (widget.actionError?.isNotEmpty ?? false) ...[
        SizedBox(height: s.rem(0.75)),
        EvGlass(
          key: const Key('ev_detail_action_error'),
          solid: true,
          borderRadius: BorderRadius.circular(s.rem(0.625)),
          borderColor: const Color.fromRGBO(229, 72, 77, 0.55),
          padding: EdgeInsets.symmetric(horizontal: s.rem(0.875), vertical: s.rem(0.4375)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.actionError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: t.ink),
                ),
              ),
              if (widget.onDismissActionError != null) ...[
                SizedBox(width: s.rem(0.5)),
                Semantics(
                  button: true,
                  label: '关闭错误提示',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      key: const Key('ev_detail_action_error_dismiss'),
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onDismissActionError,
                      child: Padding(
                        padding: EdgeInsets.all(s.rem(0.125)),
                        child: EvIcon(EvIcons.x, size: s.rem(0.875), color: t.ink2),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
      if (dirs.isNotEmpty || acts.isNotEmpty) ...[
        SizedBox(height: s.rem(1.125)),
        Text.rich(
          TextSpan(style: t.bodyStyle(s.font(0.9375), color: t.ink3, height: 1.6), children: [
            if (dirs.isNotEmpty) ...[TextSpan(text: '导演 ', style: credLbl), TextSpan(text: dirs.join('、'))],
            if (dirs.isNotEmpty && acts.isNotEmpty) const TextSpan(text: '　　'),
            if (acts.isNotEmpty) ...[TextSpan(text: '主演 ', style: credLbl), TextSpan(text: acts.join('、'))],
          ]),
          key: const Key('ev_detail_credits'), maxLines: 2, overflow: TextOverflow.ellipsis,
        ),
      ],
    ]);
  }

  Widget _buildStatusPill(BuildContext ctx, EvTheme t, EvScale s) {
    final d = widget.detail, res = d.resume, sz = s.rem(1.625);
    final Widget lead;
    final String pri;
    final String? sec;
    if (res != null) {
      final p = EvCard.resumeProgress(res) ?? 0.0;
      lead = SizedBox(key: const Key('ev_detail_resume_ring'), width: sz, height: sz, child: Stack(alignment: Alignment.center, children: [
        CustomPaint(size: Size.square(sz), painter: EvRingProgressPainter(progress: p, trackColor: t.fill3, progressColor: t.isPaper ? t.brand : t.ink, strokeWidth: math.max(2.0, sz * 3 / 26))),
        Padding(padding: const EdgeInsets.all(3), child: FittedBox(fit: BoxFit.scaleDown, child: Text('${(p * 100).round().clamp(0, 100)}%', style: t.bodyStyle(s.rem(0.5625), fontWeight: FontWeight.w700, color: t.ink, height: 1)))),
      ]));
      pri = '继续观看'; sec = EvCard.resumeSubtitle(res);
    } else {
      final (libName, libIcon, libColor) = _libraryMeta(ctx, d.card, t);
      lead = Container(width: sz, height: sz, alignment: Alignment.center, decoration: BoxDecoration(shape: BoxShape.circle, color: t.isPaper ? t.brand : libColor),
          child: EvIcon(libIcon, size: s.rem(0.9375), color: t.isPaper ? const Color(0xFF141413) : const Color(0xFF09090B)));
      pri = libName; sec = d.studios.firstOrNull;
    }
    return EvGlass(
      key: const Key('ev_detail_status_pill'), borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.fromLTRB(s.rem(0.3125), 0, s.rem(1), 0),
      child: SizedBox(height: s.rem(2.25), child: Row(mainAxisSize: MainAxisSize.min, children: [
        lead, SizedBox(width: s.rem(0.5)),
        Text(pri, style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: t.ink)),
        if (sec != null && sec.isNotEmpty) ...[
          SizedBox(width: s.rem(0.5)),
          Flexible(child: Text(sec, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: t.ink3))),
        ],
      ])),
    );
  }

  Widget _buildTitleArt(EvTheme t, EvScale s, MediaCard card) {
    final logo = card.art.logo, boxH = s.rem(11);
    Widget wm() => Text(card.title, key: const Key('ev_detail_wordmark'), maxLines: 2, overflow: TextOverflow.ellipsis,
        style: t.displayStyle(s.rem(t.isPaper ? 4.5 : 4.75), color: t.ink, height: t.isPaper ? 1.12 : 1.06));
    if (logo == null || _failedLogoKey == logo.cacheKey) {
      return ConstrainedBox(constraints: BoxConstraints(maxHeight: boxH), child: Align(alignment: Alignment.bottomLeft, child: wm()));
    }
    return SizedBox(height: boxH, child: Align(alignment: Alignment.bottomLeft, child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: s.rem(32), maxHeight: boxH),
      child: Stack(alignment: Alignment.bottomLeft, children: [
        ExcludeSemantics(child: IgnorePointer(child: Transform.translate(offset: Offset(0, s.rem(0.35)), child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: ColorFiltered(colorFilter: const ColorFilter.mode(Color.fromRGBO(0, 0, 0, 0.40), BlendMode.srcIn),
              child: Image(image: logo.image, fit: BoxFit.contain, alignment: Alignment.bottomLeft, gaplessPlayback: true, filterQuality: FilterQuality.low, errorBuilder: (_, _, _) => const SizedBox.shrink())),
        )))),
        Image(
          key: ValueKey<String>('ev_detail_logo_${logo.cacheKey}'), image: logo.image, fit: BoxFit.contain, alignment: Alignment.bottomLeft, gaplessPlayback: true, filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _failedLogoKey != logo.cacheKey) setState(() => _failedLogoKey = logo.cacheKey); }); return wm(); },
        ),
      ]),
    )));
  }

  Widget _buildMetaLine(EvTheme t, EvScale s, MediaCard card) {
    final ts = t.bodyStyle(s.font(1.0625), fontWeight: FontWeight.w500, color: t.ink2);
    final bits = <Widget>[];
    void add(Widget w) { if (bits.isNotEmpty) bits.add(SizedBox(width: 1, height: s.rem(0.875), child: ColoredBox(color: t.fill3))); bits.add(w); }
    if (card.score != null && card.score! > 0) add(EvScoreBadge(score: card.score!));
    if (card.year != null) add(Text('${card.year}', style: ts));
    if (card.genres.isNotEmpty) add(Text(card.genres.take(3).join(' / '), style: ts));
    if (card.kind == MediaKind.movie && card.duration != null && card.duration! > Duration.zero) {
      final m = math.max(1, card.duration!.inMinutes);
      add(Text(m < 60 ? '$m 分钟' : (m % 60 == 0 ? '${m ~/ 60} 小时' : '${m ~/ 60} 小时 ${m % 60} 分'), style: ts));
    } else if (card.kind == MediaKind.series) {
      final sc = widget.seasonsCount ?? card.childCount, ec = widget.detail.episodeCount;
      if (sc != null && sc > 0) { add(Text('$sc 季', style: ts)); } else if (ec != null && ec > 0) { add(Text('$ec 集', style: ts)); }
    } else if (card.kind == MediaKind.collection) {
      final n = widget.detail.collectionItems.isNotEmpty ? widget.detail.collectionItems.length : card.childCount;
      if (n != null && n > 0) add(Text('$n 部', style: ts));
    }
    if (card.rating?.trim().isNotEmpty ?? false) add(Text(card.rating!.trim(), style: ts));

    final q = widget.quality ?? card.quality;
    final res = q?.resolution?.trim(), rng = q?.videoRange?.trim(), aud = q?.audioLabel?.trim();
    final badges = <Widget>[
      if (res != null && res.isNotEmpty && res.toLowerCase() != '1080p' && res.toLowerCase() != '720p') EvQualityBadge(label: res),
      if (rng != null && rng.isNotEmpty) EvQualityBadge(label: rng, kind: (rng.toLowerCase().contains('dolby') || rng.contains('杜比')) ? EvQualityBadgeKind.dolbyVision : EvQualityBadgeKind.standard),
      if (aud != null && aud.isNotEmpty) EvQualityBadge(label: aud),
      if (q?.origin != null) EvQualityBadge(label: q!.origin == MediaOrigin.direct115 ? '115 直连' : 'NAS 本地', kind: EvQualityBadgeKind.source),
    ];
    return Wrap(key: const Key('ev_detail_meta'), spacing: s.rem(0.875), runSpacing: s.rem(0.5), crossAxisAlignment: WrapCrossAlignment.center,
        children: [...bits, if (badges.isNotEmpty) Wrap(spacing: s.rem(0.375), runSpacing: s.rem(0.375), crossAxisAlignment: WrapCrossAlignment.center, children: badges)]);
  }

  Widget _buildActions(EvTheme t, EvScale s) {
    final d = widget.detail, res = d.resume;
    final ep = res?.target.episodeNumber ?? d.card.episodeNumber;
    final pri = res != null ? (ep != null ? '继续第 $ep 集' : '继续') : (d.card.kind == MediaKind.series ? '播放第 1 集' : '播放');
    final tot = res?.duration ?? d.card.duration;
    final sec = res != null && tot != null && tot > Duration.zero ? '· ${EvCard.formatRemaining(tot > res.position ? tot - res.position : Duration.zero)}' : null;
    return Wrap(spacing: s.rem(0.75), runSpacing: s.rem(0.5), crossAxisAlignment: WrapCrossAlignment.center, children: [
      Builder(builder: (c) => EvButton.primary(key: const Key('ev_detail_play_btn'), icon: EvIcons.play, label: pri, secondaryLabel: sec, progress: EvCard.resumeProgress(res), onPressed: () => _play(c))),
      _EvDetailActionButton(
        key: const Key('ev_detail_favorite_btn'),
        icon: widget.isFavorite ? EvIcons.star : EvIcons.plus,
        tooltip: widget.isFavorite ? '已加入片单' : '加入片单',
        active: widget.isFavorite,
        busy: widget.favoriteBusy,
        kind: _EvDetailActionKind.favorite,
        onPressed: widget.onToggleFavorite,
      ),
      _EvDetailActionButton(
        key: const Key('ev_detail_played_btn'),
        icon: EvIcons.check,
        tooltip: widget.isPlayed ? '已看' : '标为已看',
        active: widget.isPlayed,
        busy: widget.playedBusy,
        kind: _EvDetailActionKind.played,
        onPressed: widget.onTogglePlayed,
      ),
    ]);
  }

  Widget _buildBgCtl(EvTheme t, EvScale s) {
    final hasDots = widget.backdropCount > 1;
    final trText = widget.trailerLive ? (widget.isTrailerClip ? '预告片播放中 · 点此停止' : '正片片段 · 点此停止') : '${widget.countdownSeconds} 秒后播放${widget.isTrailerClip ? '预告' : '片段'}';
    final ringP = widget.trailerLive ? 1.0 : (widget.countdownTotalSeconds > 0 ? (1.0 - widget.countdownSeconds / widget.countdownTotalSeconds).clamp(0.0, 1.0) : 0.0);
    final liveBg = t.isPaper ? const Color(0xFFB5532F) : t.indBg, liveFg = t.isPaper ? const Color(0xFFFFFFFF) : t.indFg;

    return EvGlass(
      key: const Key('ev_detail_bgctl'), borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.fromLTRB(s.rem(hasDots ? 1 : 0.375), 0, s.rem(widget.canTrailer ? 0.375 : 1), 0),
      child: SizedBox(height: s.rem(2.5), child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (hasDots) ...[
          for (var i = 0; i < widget.backdropCount; i++)
            Semantics(button: true, selected: i == widget.backdropIndex, label: '第 ${i + 1} 张剧照', child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: Key('ev_detail_bg_dot_$i'), behavior: HitTestBehavior.opaque, onTap: () => widget.onSelectBackdrop(i),
                child: Padding(padding: EdgeInsets.symmetric(horizontal: s.rem(0.22), vertical: s.rem(0.5)), child: AnimatedScale(
                  scale: i == widget.backdropIndex ? 1.3 : 1, duration: EvDurations.medium, curve: EvCurves.spring,
                  child: Container(width: s.rem(0.4375), height: s.rem(0.4375), decoration: BoxDecoration(shape: BoxShape.circle, color: i == widget.backdropIndex ? t.ink : t.fill3)),
                )),
              ),
            )),
          if (widget.canTrailer) SizedBox(width: s.rem(0.75)),
        ],
        if (widget.canTrailer)
          Semantics(button: true, label: trText, child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const Key('ev_detail_trailer_btn'), behavior: HitTestBehavior.opaque, onTap: widget.onToggleTrailer,
              child: AnimatedContainer(
                duration: EvDurations.normal, curve: EvCurves.soft, height: s.rem(1.875),
                padding: EdgeInsets.fromLTRB(s.rem(0.5), 0, s.rem(0.75), 0),
                decoration: BoxDecoration(color: widget.trailerLive ? liveBg : t.fill2, borderRadius: BorderRadius.circular(999)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(key: const Key('ev_detail_trailer_ring'), width: s.rem(1.125), height: s.rem(1.125),
                      child: CustomPaint(painter: EvRingProgressPainter(progress: ringP, trackColor: widget.trailerLive ? liveFg.withValues(alpha: 0.25) : t.fill3, progressColor: widget.trailerLive ? liveFg : t.ink, strokeWidth: 2.2))),
                  SizedBox(width: s.rem(0.4375)),
                  Text(trText, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w600, color: widget.trailerLive ? liveFg : t.ink)),
                ]),
              ),
            ),
          )),
      ])),
    );
  }

  static (String, EvIconData, Color) _libraryMeta(BuildContext ctx, MediaCard card, EvTheme t) {
    if (card.libraryId != null && card.libraryId!.isNotEmpty) {
      for (final z in EvScope.maybeOf(ctx)?.shell.zones ?? const <ZoneTile>[]) {
        if (z.id == card.libraryId) return (z.name, EvIcons.byKey(z.iconKey), t.zoneColor(z.colorSlot));
      }
    }
    return switch (card.kind) {
      MediaKind.movie => ('电影', EvIcons.navMovie, t.movie),
      MediaKind.series || MediaKind.episode => ('剧集', EvIcons.navTv, t.tv),
      MediaKind.collection => ('合集', EvIcons.navBox, t.box),
    };
  }
}

enum _EvDetailActionKind { favorite, played }

/// Glass round toggle button for detail hero actions (`+` favorite / `✓` played).
/// Renders clear frosted glass when inactive and crisp high-contrast highlight
/// when active across both cinema and paper (`EvOnImage`) themes.
class _EvDetailActionButton extends StatefulWidget {
  const _EvDetailActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.busy,
    required this.kind,
    required this.onPressed,
  });

  final EvIconData icon;
  final String tooltip;
  final bool active;
  final bool busy;
  final _EvDetailActionKind kind;
  final VoidCallback? onPressed;

  @override
  State<_EvDetailActionButton> createState() => _EvDetailActionButtonState();
}

class _EvDetailActionButtonState extends State<_EvDetailActionButton> {
  bool _hovered = false, _focused = false, _pressed = false;
  bool get _enabled => widget.onPressed != null;
  bool get _interactive => _enabled && !widget.busy;
  bool get _highlighted => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final size = s.rem(3.25);
    final radius = BorderRadius.circular(t.isPaper ? s.rem(0.625) : 999.0);

    final Color bg;
    final Color fg;
    Color? border;
    List<BoxShadow>? shadows;
    var useGlass = false;

    if (widget.active) {
      if (widget.kind == _EvDetailActionKind.favorite) {
        bg = _highlighted ? const Color(0xFFFFFFFF) : t.indBg;
        fg = t.isPaper ? const Color(0xFFB5532F) : t.indFg;
        border = t.isPaper ? const Color.fromRGBO(255, 255, 255, 0.45) : null;
        shadows = _highlighted && !t.isPaper ? [BoxShadow(color: t.fill2, spreadRadius: 4)] : t.glassShadow;
      } else {
        bg = _highlighted
            ? (t.isPaper ? const Color(0xFFCC6848) : const Color(0xFFE08566))
            : t.brand;
        fg = Colors.white;
        border = Color.fromRGBO(255, 255, 255, t.isPaper ? 0.30 : 0.22);
        shadows = _highlighted && !t.isPaper ? [BoxShadow(color: t.fill2, spreadRadius: 4)] : t.glassShadow;
      }
    } else if (t.isPaper) {
      fg = Colors.white;
      bg = Color.fromRGBO(255, 255, 255, _highlighted ? 0.24 : 0.14);
      border = const Color.fromRGBO(255, 255, 255, 0.28);
      useGlass = true;
    } else {
      fg = t.ink;
      bg = _highlighted ? t.fill3 : t.glass;
      border = t.glassBorder;
      shadows = t.glassShadow;
      useGlass = !_highlighted;
    }

    final body = SizedBox(
      width: size,
      height: size,
      child: Center(
        child: EvIcon(widget.icon, size: s.rem(1.125), color: fg),
      ),
    );

    final surface = useGlass
        ? EvGlass(
            borderRadius: radius,
            color: bg,
            borderColor: border,
            shadows: shadows,
            blurSigma: t.isPaper ? 20 : null,
            child: body,
          )
        : AnimatedContainer(
            duration: EvDurations.fast,
            curve: EvCurves.soft,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: border != null ? Border.all(color: border, width: 1) : null,
              boxShadow: shadows,
            ),
            child: body,
          );

    Widget button = Focus(
      canRequestFocus: _enabled,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (_, event) {
        if (!_interactive || !evIsActivateKey(event)) return KeyEventResult.ignored;
        widget.onPressed!();
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: _interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _interactive ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _interactive ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _interactive ? () => setState(() => _pressed = false) : null,
          onTap: _interactive ? widget.onPressed : null,
          child: AnimatedScale(
            scale: !_interactive ? 1.0 : _pressed ? 0.96 : _highlighted ? 1.04 : 1.0,
            duration: EvDurations.normal,
            curve: EvCurves.spring,
            child: Opacity(opacity: _enabled ? 1.0 : 0.45, child: surface),
          ),
        ),
      ),
    );
    button = Tooltip(message: widget.tooltip, child: button);
    return Semantics(
      button: true,
      toggled: widget.active,
      enabled: _interactive,
      label: widget.tooltip,
      child: button,
    );
  }
}
