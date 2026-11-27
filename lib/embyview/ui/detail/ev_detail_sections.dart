import 'dart:math' as math;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Movie detail first-row franchise strip mirroring `collStrip` & `.collrow`
/// in `.spec/mockups/proto.js` & `proto.css`.
class EvDetailCollectionStrip extends StatelessWidget {
  const EvDetailCollectionStrip({
    super.key,
    required this.membership,
    required this.currentItemId,
    required this.onOpenItem,
    required this.onOpenCollection,
    this.onPlayItem,
  });

  final CollectionMembership membership;
  final String currentItemId;
  final ValueChanged<MediaCard> onOpenItem;
  final VoidCallback onOpenCollection;
  final ValueChanged<MediaCard>? onPlayItem;

  @override
  Widget build(BuildContext context) {
    final items = membership.items;
    if (items.isEmpty) return const SizedBox.shrink();
    return EvShelf(
      key: const Key('ev_detail_franchise_shelf'),
      title: '${membership.displayName} 系列',
      badge: '第 ${membership.position} / ${membership.total} 部',
      moreLabel: '查看全部 ›',
      onMoreTap: onOpenCollection,
      itemCount: items.length,
      style: EvCardStyle.poster,
      itemBuilder: (context, i) => _EvCollectionStripCard(
        key: Key('ev_detail_franchise_card_${items[i].id}'),
        index: i,
        card: items[i],
        isCurrent: items[i].id == currentItemId,
        onTap: () => onOpenItem(items[i]),
        onPlay: onPlayItem != null ? () => onPlayItem!(items[i]) : null,
      ),
    );
  }
}

class _EvCollectionStripCard extends StatelessWidget {
  const _EvCollectionStripCard({
    super.key,
    required this.index,
    required this.card,
    required this.isCurrent,
    required this.onTap,
    this.onPlay,
  });

  final int index;
  final MediaCard card;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final radius = BorderRadius.circular(s.rem(t.posterRadius));
    final sub = [
      '第 ${index + 1} 部',
      if (card.year != null) '${card.year}',
    ].join(' · ');

    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (isCurrent && t.isPaper)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    boxShadow: [
                      BoxShadow(
                        offset: Offset(s.rem(0.375), s.rem(0.375)),
                        color: const Color(0xFFD97757),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        EvCard(
          card: card,
          style: EvCardStyle.poster,
          subtitle: sub,
          alwaysShowLabel: true,
          onTap: onTap,
          onPlay: onPlay,
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: Container(
                decoration: isCurrent && !t.isPaper
                    ? BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(color: t.indBg, width: 2),
                      )
                    : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: s.rem(0.5),
                      bottom: s.rem(0.25),
                      child: Text(
                        '${index + 1}',
                        style: t.displayStyle(s.rem(3.25), color: Colors.white, height: 1.0).copyWith(
                          fontWeight: t.isPaper ? FontWeight.w500 : FontWeight.w800,
                          shadows: const [
                            Shadow(offset: Offset(0, 2), blurRadius: 12, color: Color.fromRGBO(0, 0, 0, 0.60)),
                          ],
                        ),
                      ),
                    ),
                    if (isCurrent)
                      Positioned(
                        top: s.rem(0.5),
                        right: s.rem(0.5),
                        child: Container(
                          key: const Key('ev_detail_franchise_here_badge'),
                          height: s.rem(1.5),
                          padding: EdgeInsets.symmetric(horizontal: s.rem(0.5)),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: t.indBg,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '本片',
                            style: t.bodyStyle(s.font(0.75), fontWeight: FontWeight.w700, color: t.indFg),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Horizontal cast & crew carousel reusing [EvShelf] layout & scrollbar (`.person`).
class EvDetailPeopleShelf extends StatelessWidget {
  const EvDetailPeopleShelf({super.key, required this.people, this.onOpenPerson});
  final List<PersonCredit> people;
  final ValueChanged<PersonCredit>? onOpenPerson;

  @override
  Widget build(BuildContext context) => people.isEmpty
      ? const SizedBox.shrink()
      : EvShelf(key: const Key('ev_detail_people_shelf'), title: '演职员', badge: '${people.length} 位',
          itemCount: people.length, cardBaseRem: EvShelfLayout.personBaseRem,
          itemBuilder: (_, i) => _EvPersonTile(
            key: Key('ev_detail_person_${people[i].id}'),
            person: people[i],
            onTap: onOpenPerson != null ? () => onOpenPerson!(people[i]) : null,
          ));
}

class _EvPersonTile extends StatefulWidget {
  const _EvPersonTile({super.key, required this.person, this.onTap});
  final PersonCredit person;
  final VoidCallback? onTap;
  @override State<_EvPersonTile> createState() => _EvPersonTileState();
}

class _EvPersonTileState extends State<_EvPersonTile> {
  bool _hov = false, _focused = false, _failed = false;
  bool get _hi => _hov || _focused;
  @override void didUpdateWidget(_EvPersonTile old) { super.didUpdateWidget(old); if (old.person.avatar?.cacheKey != widget.person.avatar?.cacheKey) _failed = false; }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), p = widget.person;
    final sub = (p.character?.trim().isNotEmpty ?? false)
        ? p.character!.trim()
        : (const {'director': '导演', 'writer': '编剧', 'producer': '制片', 'actor': '演员', 'composer': '配乐'}[p.role.trim().toLowerCase()] ?? p.role.trim());
    Widget init() => Text(p.name.trim().isNotEmpty ? p.name.trim()[0] : '?', style: t.bodyStyle(s.font(1.75), fontWeight: FontWeight.w500, color: t.ink3));
    final clickable = widget.onTap != null;

    return Semantics(
      button: clickable,
      label: sub.isNotEmpty ? '${p.name}，$sub' : p.name,
      child: Focus(
        canRequestFocus: clickable,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, event) {
          if (!clickable || !evIsActivateKey(event)) return KeyEventResult.ignored;
          widget.onTap!();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: clickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hov = true), onExit: (_) => setState(() => _hov = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AnimatedScale(scale: _hi ? 1.06 : 1, duration: EvDurations.normal, curve: EvCurves.spring, child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: t.fill2,
                    border: Border.all(
                      color: _focused ? t.indBg : t.line,
                      width: _focused ? 2.0 : 1.0,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias, alignment: Alignment.center,
                  child: p.avatar != null && !_failed
                      ? Image(image: p.avatar!.image, fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true, filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && !_failed) setState(() => _failed = true); }); return init(); })
                      : init(),
                ),
              )),
              SizedBox(height: s.rem(0.75)),
              Text(
                p.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w500, color: t.ink).copyWith(
                  decoration: _hi && clickable ? TextDecoration.underline : TextDecoration.none,
                  decorationColor: t.ink4,
                ),
              ),
              if (sub.isNotEmpty) ...[SizedBox(height: s.rem(0.125)), Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: t.bodyStyle(s.font(0.8125), color: t.ink3))],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Two-column detail metadata table mirroring `.facts` in `proto.css`.
class EvDetailFactsSection extends StatelessWidget {
  const EvDetailFactsSection({
    super.key, required this.detail, this.seasons = const [], this.quality,
    this.subtitlesEnabled = false, this.subtitleAvailability, this.activeVersion,
  });
  final MediaDetail detail;
  final List<SeasonSummary> seasons;
  final MediaQuality? quality;
  final bool subtitlesEnabled;
  final SubtitleAvailability? subtitleAvailability;
  final MediaVersion? activeVersion;

  static String _lang(String raw) => const {
    'zh': '简体中文', 'chi': '简体中文', 'zho': '简体中文', 'zh-cn': '简体中文', 'zh-hans': '简体中文', 'chs': '简体中文',
    'zh-tw': '繁体中文', 'zh-hk': '繁体中文', 'zh-hant': '繁体中文', 'cht': '繁体中文',
    'en': '英文', 'eng': '英文', 'ja': '日语', 'jpn': '日语', 'ko': '韩语', 'kor': '韩语',
  }[raw.trim().toLowerCase()] ?? raw.trim();

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), card = detail.card;
    final v = activeVersion;
    final q = v != null ? v.toQuality() : (quality ?? card.quality);
    final isSeries = card.kind == MediaKind.series, isCol = card.kind == MediaKind.collection;
    final base = t.bodyStyle(s.font(0.9375), color: t.ink, height: 1.5);
    final ok = base.copyWith(color: t.isPaper ? const Color(0xFF5F7346) : const Color(0xFF4FBF7F), fontWeight: FontWeight.w500);

    final sCount = seasons.isNotEmpty ? seasons.length : (card.childCount ?? 0);
    final eCount = detail.episodeCount ?? seasons.fold<int>(0, (a, x) => a + x.total);
    final cCount = detail.collectionItems.isNotEmpty ? detail.collectionItems.length : (card.childCount ?? 0);
    final scaleVal = isSeries ? [if (sCount > 0) '$sCount 季', if (eCount > 0) '$eCount 集'].join(' · ')
        : isCol ? (cCount > 0 ? '$cCount 部' : '—')
        : (card.duration != null && card.duration! > Duration.zero ? '${math.max(1, card.duration!.inMinutes)} 分钟' : '—');

    final subSpans = <InlineSpan>[];
    final rawEmb = (v != null && v.embeddedSubtitleLanguages.isNotEmpty)
        ? v.embeddedSubtitleLanguages
        : detail.embeddedSubtitleLanguages;
    final emb = rawEmb.map(_lang).where((x) => x.isNotEmpty).toSet().toList();
    if (emb.isNotEmpty) subSpans.add(TextSpan(text: '内嵌 ${emb.join('、')}', style: base));
    if (subtitlesEnabled && subtitleAvailability != null) {
      final av = subtitleAvailability!;
      void add(String text, TextStyle st) { if (subSpans.isNotEmpty) subSpans.add(TextSpan(text: ' · ', style: base)); subSpans.add(TextSpan(text: text, style: st)); }
      if ((av.nasTrackCount ?? 0) > 0) { add('NAS 外挂 ${av.nasTrackCount} 条', ok); }
      else if (av.hasAiChinese == true) { add('AI 中字已就绪', ok); }
      else if (av.chinese == ChineseSubtitleState.partial) { add('部分字幕', base); }
      else if (av.chinese == ChineseSubtitleState.complete && emb.isEmpty) { add('中文字幕已就绪', ok); }
    }
    if (subSpans.isEmpty) subSpans.add(TextSpan(text: '—', style: base));

    final versionSummary = detail.versions.length > 1 && v != null
        ? '${detail.versions.length} 个 · 正在用 ${v.resolution} ${v.name}${v.formattedSizeGb.isNotEmpty ? '（${v.formattedSizeGb}）' : ''}'
        : null;

    Widget txt(String v) => Text(v.isEmpty ? '—' : v, style: base);
    final entries = <(String, Widget)>[
      (isSeries ? '首播' : '上映', txt(card.year?.toString() ?? '—')),
      (isSeries || isCol ? '规模' : '片长', txt(scaleVal)),
      ('出品', txt(detail.studios.join('、'))),
      ('评分', txt([if (card.score != null && card.score! > 0) '★ ${card.score!.toStringAsFixed(1)}', if (card.rating?.trim().isNotEmpty ?? false) card.rating!.trim()].join(' · '))),
      if (versionSummary != null)
        ('版本', Text(versionSummary, key: const Key('ev_detail_facts_version'), style: base)),
      ('文件来源', txt(switch (q?.origin) { MediaOrigin.direct115 => '115 网盘 strm · 起播前预解析直连', MediaOrigin.nasLocal => 'NAS 本地文件 · Emby 静态流，不转码', null => '—' })),
      ('视频', txt([if (q?.resolution?.trim().isNotEmpty ?? false) q!.resolution!.trim(), if (q?.videoRange?.trim().isNotEmpty ?? false) q!.videoRange!.trim()].join(' · '))),
      ('音频', txt(q?.audioLabel?.trim() ?? '')),
      ('字幕', Text.rich(TextSpan(children: subSpans))),
    ];
    Widget row(String dt, Widget dd) => Container(
      padding: EdgeInsets.symmetric(vertical: s.rem(0.6875)), decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: s.rem(5), child: Text(dt, style: t.bodyStyle(s.font(0.9375), color: t.ink3, height: 1.5))),
        SizedBox(width: s.rem(1.25)), Expanded(child: dd),
      ]),
    );

    return Padding(
      key: const Key('ev_detail_facts'), padding: EdgeInsets.fromLTRB(s.gutter, 0, s.gutter, s.rem(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: EdgeInsets.only(bottom: s.rem(0.75)), child: Text('信息', style: t.shelfStyle(s.font(1.5)))),
        ConstrainedBox(constraints: BoxConstraints(maxWidth: s.rem(64)), child: Column(children: [
          for (var i = 0; i < entries.length; i += 2)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: row(entries[i].$1, entries[i].$2)), SizedBox(width: s.rem(3)),
              Expanded(child: i + 1 < entries.length ? row(entries[i + 1].$1, entries[i + 1].$2) : const SizedBox.shrink()),
            ]),
        ])),
      ]),
    );
  }
}
