import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Top-match spotlight banner mirroring `.topmatch` in `.spec/mockups/proto.css` / `proto.js`.
class EvSearchTopMatch extends StatelessWidget {
  const EvSearchTopMatch({
    super.key, required this.card, required this.query, required this.onPlay, required this.onOpenDetail,
  });

  final MediaCard card;
  final String query;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin) onPlay;
  final VoidCallback onOpenDetail;

  ArtworkPlan? _backdropPlan() => card.art.stage.layers.isNotEmpty
      ? card.art.stage
      : card.art.backdrops.isEmpty
      ? null
      : ArtworkPlan(layers: [ArtworkLayer(source: card.art.backdrops.first, fit: ArtworkFit.cover)], fallbackColor: card.art.poster.fallbackColor);

  List<TextSpan> _titleSpans(EvTheme t, EvScale s) {
    final base = t.displayStyle(s.font(2.25), color: t.ink, height: 1.15);
    final needle = query.trim();
    if (needle.isEmpty) return [TextSpan(text: card.title, style: base)];
    final lower = card.title.toLowerCase(), qLower = needle.toLowerCase();
    if (qLower.isEmpty || lower.length != card.title.length) return [TextSpan(text: card.title, style: base)];
    final hl = base.copyWith(color: t.isPaper ? const Color(0xFFB5532F) : t.brand);
    final spans = <TextSpan>[];
    for (var i = 0; i < card.title.length;) {
      final hit = lower.indexOf(qLower, i);
      if (hit < 0) { spans.add(TextSpan(text: card.title.substring(i), style: base)); break; }
      final start = hit.clamp(i, card.title.length), end = (hit + qLower.length).clamp(start, card.title.length);
      if (start > i) spans.add(TextSpan(text: card.title.substring(i, start), style: base));
      if (end > start) spans.add(TextSpan(text: card.title.substring(start, end), style: hl));
      if (end <= i) break;
      i = end;
    }
    return spans;
  }

  Widget _buildMeta(EvTheme t, EvScale s) {
    final ts = t.bodyStyle(s.font(1.0625), fontWeight: FontWeight.w500, color: t.ink2);
    final bits = <Widget>[];
    void add(Widget w) {
      if (bits.isNotEmpty) bits.add(SizedBox(width: 1, height: s.rem(0.875), child: ColoredBox(color: t.fill3)));
      bits.add(w);
    }
    if ((card.score ?? 0) > 0) add(EvScoreBadge(score: card.score!));
    if (card.year != null) add(Text('${card.year}', style: ts));
    if (card.genres.isNotEmpty) add(Text(card.genres.take(2).join(' / '), style: ts));
    if (card.kind == MediaKind.movie && (card.duration ?? Duration.zero) > Duration.zero) {
      final m = math.max(1, card.duration!.inMinutes);
      add(Text(m < 60 ? '$m 分' : '${m ~/ 60} 小时 ${m % 60} 分', style: ts));
    } else if (card.kind == MediaKind.series && (card.childCount ?? 0) > 0) {
      add(Text('${card.childCount} 季', style: ts));
    } else if (card.kind == MediaKind.collection && (card.childCount ?? 0) > 0) {
      add(Text('${card.childCount} 部', style: ts));
    }
    if (card.rating?.trim().isNotEmpty ?? false) add(Text(card.rating!.trim(), style: ts));

    final q = card.quality, res = q?.resolution?.trim(), rng = q?.videoRange?.trim(), aud = q?.audioLabel?.trim();
    final badges = <Widget>[
      if (res != null && res.isNotEmpty && res.toLowerCase() != '1080p' && res.toLowerCase() != '720p') EvQualityBadge(label: res),
      if (rng != null && rng.isNotEmpty) EvQualityBadge(label: rng,
          kind: (rng.toLowerCase().contains('dolby') || rng.contains('杜比')) ? EvQualityBadgeKind.dolbyVision : EvQualityBadgeKind.standard),
      if (aud != null && aud.isNotEmpty) EvQualityBadge(label: aud),
      if (q?.origin != null) EvQualityBadge(label: q!.origin == MediaOrigin.direct115 ? '115 直连' : 'NAS 本地', kind: EvQualityBadgeKind.source),
    ];
    return Wrap(key: const Key('ev_search_top_match_meta'), spacing: s.rem(0.875), runSpacing: s.rem(0.5),
      crossAxisAlignment: WrapCrossAlignment.center, children: [...bits, if (badges.isNotEmpty) Wrap(spacing: s.rem(0.375), runSpacing: s.rem(0.375), children: badges)]);
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final bgPlan = _backdropPlan(), hasPoster = card.art.poster.layers.isNotEmpty;
    final posterW = s.rem(9.0), posterH = posterW * 1.5;
    final radius = BorderRadius.circular(s.rem(1.25)), pRadius = BorderRadius.circular(s.rem(t.posterRadius));
    final overview = card.overview?.trim() ?? '';

    return ClipRRect(
      key: const Key('ev_search_top_match'), borderRadius: radius,
      child: ConstrainedBox(constraints: BoxConstraints(minHeight: s.rem(17.0)), child: DecoratedBox(
        decoration: BoxDecoration(color: t.fill, borderRadius: radius),
        child: Stack(children: [
          if (bgPlan != null) Positioned.fill(child: IgnorePointer(child: Opacity(opacity: 0.6,
            child: EvArtwork(plan: bgPlan, overrideFit: BoxFit.cover, showFallbackTitle: false)))),
          Positioned.fill(child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
            begin: Alignment.centerLeft, end: Alignment.centerRight,
            colors: t.isPaper ? [t.bg.withValues(alpha: 0.97), t.bg.withValues(alpha: 0.50)] : [t.bg.withValues(alpha: 0.95), t.bg.withValues(alpha: 0.20)],
          ))))),
          Padding(padding: EdgeInsets.all(s.rem(1.5)), child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (hasPoster) ...[
              DecoratedBox(
                decoration: BoxDecoration(borderRadius: pRadius, boxShadow: [BoxShadow(offset: Offset(0, s.rem(1.0)), blurRadius: s.rem(2.0), color: const Color.fromRGBO(0, 0, 0, 0.40))]),
                child: EvArtwork(key: const Key('ev_search_top_match_poster'), plan: card.art.poster, width: posterW, height: posterH, decodeWidth: posterW, overrideFit: BoxFit.cover, borderRadius: pRadius),
              ),
              SizedBox(width: s.rem(2.0)),
            ],
            Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(TextSpan(children: _titleSpans(t, s)), key: const Key('ev_search_top_match_title'), maxLines: 2, overflow: TextOverflow.ellipsis),
              SizedBox(height: s.rem(0.5)),
              _buildMeta(t, s),
              if (overview.isNotEmpty)
                Padding(padding: EdgeInsets.only(top: s.rem(0.625)), child: ConstrainedBox(constraints: BoxConstraints(maxWidth: s.rem(38.0)),
                  child: Text(overview, key: const Key('ev_search_top_match_overview'), maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: t.bodyStyle(s.font(1.0), color: t.ink2, height: 1.6)))),
              SizedBox(height: s.rem(1.25)),
              Wrap(spacing: s.rem(0.75), runSpacing: s.rem(0.5), children: [
                Builder(builder: (c) => EvButton.primary(key: const Key('ev_search_top_play'), small: true, icon: EvIcons.play, label: '播放',
                  onPressed: () {
                    final box = c.findRenderObject() as RenderBox?;
                    onPlay(PlayTarget(itemId: card.id), card.art, box != null && box.hasSize ? (box.localToGlobal(Offset.zero) & box.size) : null);
                  })),
                EvButton.ghost(key: const Key('ev_search_top_detail'), small: true, glass: true, label: '详情', onPressed: onOpenDetail),
              ]),
            ])),
          ])),
        ]),
      )),
    );
  }
}
