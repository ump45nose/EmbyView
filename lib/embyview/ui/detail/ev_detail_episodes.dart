import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/detail/ev_episode_card.dart';
import 'package:moonfin/embyview/ui/detail/ev_theme_capsule.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Series seasons selector, AI Chinese subtitle trigger + quote dialog,
/// and horizontal episode track mirroring `#eps` in `proto.js` / `proto.css`.
class EvDetailEpisodesSection extends StatefulWidget {
  const EvDetailEpisodesSection({
    super.key, required this.seriesId, required this.seriesTitle, required this.seasons,
    required this.selectedSeasonIndex, required this.seasonEpisodes, required this.loadingEpisodes,
    required this.hideUnwatchedOverview, required this.navigationStyle, required this.subtitlesEnabled,
    required this.availabilityByEpisode, required this.activeSeasonJob, required this.completedJobEpisodeIds,
    required this.quotingSeason, this.subtitleError, this.onDismissSubtitleError,
    required this.onSelectSeason, required this.onRequestSeasonQuote, required this.onCancelSeasonJob,
    required this.onCancelEpisodeJob, required this.onPlayEpisode, required this.onEpisodeHoverChanged,
    required this.onEpisodeFocusChanged,
  });

  final String seriesId, seriesTitle;
  final List<SeasonSummary> seasons;
  final int selectedSeasonIndex;
  final SeasonEpisodes? seasonEpisodes;
  final bool loadingEpisodes, hideUnwatchedOverview, subtitlesEnabled, quotingSeason;
  final NavigationStyle navigationStyle;
  final Map<String, SubtitleAvailability> availabilityByEpisode;
  final SeasonJob? activeSeasonJob;
  final Set<String> completedJobEpisodeIds;
  final String? subtitleError;
  final VoidCallback? onDismissSubtitleError;
  final ValueChanged<int> onSelectSeason;
  final VoidCallback onRequestSeasonQuote;
  final ValueChanged<String> onCancelSeasonJob;
  final void Function(String jobId, String episodeId) onCancelEpisodeJob;
  final void Function(EpisodeCard ep, Rect origin) onPlayEpisode;
  final void Function(EpisodeCard ep, bool active) onEpisodeHoverChanged, onEpisodeFocusChanged;

  static String formatSeasonName(SeasonSummary s) {
    final t = s.name.trim();
    return t.isEmpty ? '第 ${s.number ?? 1} 季' : t.replaceFirstMapped(RegExp(r'^季\s*(\d+)$'), (m) => '第 ${m[1]} 季');
  }

  static bool isJobActive(SeasonJob? job) =>
      job != null && job.episodes.any((e) => e.state == EpisodeJobState.queued || e.state == EpisodeJobState.reading || e.state == EpisodeJobState.transcribing || e.state == EpisodeJobState.translating);

  @override State<EvDetailEpisodesSection> createState() => _EvDetailEpisodesSectionState();
}

class _EvDetailEpisodesSectionState extends State<EvDetailEpisodesSection> {
  final _track = ScrollController();
  bool _hovered = false;
  int _metricsRev = 0;

  @override void didUpdateWidget(EvDetailEpisodesSection old) { super.didUpdateWidget(old); if (old.selectedSeasonIndex != widget.selectedSeasonIndex && _track.hasClients) _track.jumpTo(0); }
  @override void dispose() { _track.dispose(); super.dispose(); }

  EvEpisodeSubtitleBadge _badgeFor(EpisodeCard ep) {
    if (!widget.subtitlesEnabled) return EvEpisodeSubtitleBadge.none;
    final ej = widget.activeSeasonJob?.episodes.where((e) => e.episodeId == ep.card.id).firstOrNull;
    if (ej != null && ej.state != EpisodeJobState.cancelled) {
      return switch (ej.state) {
        EpisodeJobState.queued => EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.queued, label: '排队中', tooltip: ej.waitingReason ?? '排队等待生成 AI 中字', cancellable: true),
        EpisodeJobState.reading => const EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.processing, label: '读取中', tooltip: '正在读取剧集音频', cancellable: true),
        EpisodeJobState.transcribing => const EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.processing, label: '听写中', tooltip: '正在听写对白', cancellable: true),
        EpisodeJobState.translating => const EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.processing, label: '翻译中', tooltip: '正在翻译为简体中文', cancellable: true),
        EpisodeJobState.completed => const EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.completeAi, label: 'AI 中字', tooltip: 'AI 中文字幕已就绪'),
        EpisodeJobState.failed => EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.failed, label: '失败', tooltip: ej.failure?.reason ?? '生成失败'),
        EpisodeJobState.cancelled => EvEpisodeSubtitleBadge.none,
      };
    }
    if (widget.completedJobEpisodeIds.contains(ep.card.id)) {
      return const EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.completeAi, label: 'AI 中字', tooltip: 'AI 中文字幕已就绪');
    }
    final av = widget.availabilityByEpisode[ep.card.id];
    if (av == null) return EvEpisodeSubtitleBadge.none;
    return switch (av.chinese) {
      ChineseSubtitleState.complete => av.hasAiChinese == true
          ? const EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.completeAi, label: 'AI 中字', tooltip: 'AI 中文字幕已就绪')
          : const EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.completeChinese, label: '中字', tooltip: '中文字幕已就绪'),
      ChineseSubtitleState.partial => EvEpisodeSubtitleBadge(kind: EvEpisodeSubtitleBadgeKind.partial, label: '部分字幕', tooltip: av.reason ?? '仅覆盖部分时段，未完整覆盖本集'),
      ChineseSubtitleState.canGenerate || ChineseSubtitleState.unknown => EvEpisodeSubtitleBadge.none,
    };
  }

  int _completeCount(List<EpisodeCard> eps) {
    final doneIds = <String>{
      ...widget.completedJobEpisodeIds,
      for (final ej in widget.activeSeasonJob?.episodes ?? const <EpisodeJob>[]) if (ej.state == EpisodeJobState.completed) ej.episodeId,
    };
    return eps.where((ep) => doneIds.contains(ep.card.id) || widget.availabilityByEpisode[ep.card.id]?.chinese == ChineseSubtitleState.complete).length;
  }

  void _ensureVisible(int i, double w, double gap, double gutter, double vw) {
    if (!_track.hasClients || !_track.position.hasContentDimensions) return;
    final pos = _track.position, l = gutter + i * (w + gap), r = l + w;
    final target = l - gutter < pos.pixels ? (l - gutter).clamp(0.0, pos.maxScrollExtent) : (r + gutter > pos.pixels + vw ? (r + gutter - vw).clamp(0.0, pos.maxScrollExtent) : null);
    if (target != null && (target - pos.pixels).abs() > 0.5) _track.animateTo(target, duration: EvDurations.normal, curve: EvCurves.out);
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), g = s.gutter, gap = EvShelfLayout.gap(s);
    final se = widget.seasonEpisodes, eps = se?.episodes ?? const <EpisodeCard>[];
    final played = se?.playedCount ?? 0;
    final total = se != null ? (se.season.total > 0 ? se.season.total : eps.length)
        : (widget.seasons.isNotEmpty ? widget.seasons[widget.selectedSeasonIndex.clamp(0, widget.seasons.length - 1)].total : 0);
    final job = widget.activeSeasonJob, active = EvDetailEpisodesSection.isJobActive(job);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        key: const Key('ev_detail_episodes_section'), padding: EdgeInsets.only(bottom: s.rem(1.5)),
        child: LayoutBuilder(builder: (ctx, c) {
          final vw = c.hasBoundedWidth && c.maxWidth > 0 ? c.maxWidth : s.size.width;
          final cardW = EvShelfLayout.cardWidth(viewportWidth: vw, scale: s, style: EvCardStyle.landscape, baseRem: EvShelfLayout.episodeBaseRem);
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: g),
              child: SizedBox(height: s.rem(2.75), child: Row(children: [
                Expanded(child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(ctx).copyWith(scrollbars: false),
                  child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(mainAxisSize: MainAxisSize.min, children: [
                    for (var i = 0; i < widget.seasons.length; i++) ...[
                      if (i > 0) SizedBox(width: s.rem(0.25)),
                      _SeasonTab(key: Key('ev_detail_season_tab_${widget.seasons[i].id}'), label: EvDetailEpisodesSection.formatSeasonName(widget.seasons[i]), selected: i == widget.selectedSeasonIndex, onTap: () => widget.onSelectSeason(i)),
                    ],
                  ])),
                )),
                SizedBox(width: s.rem(0.75)),
                Text('$played / $total 已看', key: const Key('ev_detail_season_played_count'), style: t.bodyStyle(s.font(0.9375), color: t.ink3)),
                if (widget.subtitlesEnabled) ...[
                  SizedBox(width: s.rem(0.75)),
                  _AiSeasonButton(
                    complete: _completeCount(eps), epTotal: eps.length, job: job, active: active, quoting: widget.quotingSeason,
                    compactIcon: widget.navigationStyle == NavigationStyle.icon,
                    onTap: active ? () { if (job != null) widget.onCancelSeasonJob(job.id); } : widget.onRequestSeasonQuote,
                    onCancel: active && job != null ? () => widget.onCancelSeasonJob(job.id) : null,
                  ),
                ],
              ])),
            ),
            if (widget.subtitleError?.isNotEmpty ?? false)
              Padding(padding: EdgeInsets.fromLTRB(g, s.rem(0.5), g, 0), child: EvGlass(
                key: const Key('ev_detail_sub_error'), solid: true, borderRadius: BorderRadius.circular(s.rem(0.75)),
                padding: EdgeInsets.symmetric(horizontal: s.rem(1), vertical: s.rem(0.5)),
                child: Row(children: [
                  Expanded(child: Text(widget.subtitleError!, style: t.bodyStyle(s.font(0.875), color: t.ink))),
                  if (widget.onDismissSubtitleError != null) EvButton.ghost(label: '关闭', small: true, glass: false, onPressed: widget.onDismissSubtitleError),
                ]),
              )),
            if (widget.loadingEpisodes && eps.isEmpty)
              const EvShelfSkeleton(style: EvCardStyle.landscape, count: 5, baseRem: EvShelfLayout.episodeBaseRem)
            else ...[
              NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() => _metricsRev++); }); return false; },
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(ctx).copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    key: const Key('ev_detail_episodes_track'), controller: _track, scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none, padding: EdgeInsets.fromLTRB(g, s.rem(1), g, s.rem(1.25)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (var i = 0; i < eps.length; i++) ...[
                        if (i > 0) SizedBox(width: gap),
                        EvEpisodeCard(
                          key: Key('ev_episode_card_${eps[i].card.id}'), card: eps[i].card, episode: eps[i],
                          seriesTitle: widget.seriesTitle, width: cardW, hideUnwatchedOverview: widget.hideUnwatchedOverview,
                          subtitleBadge: _badgeFor(eps[i]), accentColor: t.tv,
                          onActivateWithOrigin: (o) => widget.onPlayEpisode(eps[i], o),
                          onHoverChanged: (h) => widget.onEpisodeHoverChanged(eps[i], h),
                          onFocusChanged: (f) { if (f) _ensureVisible(i, cardW, gap, g, vw); widget.onEpisodeFocusChanged(eps[i], f); },
                          onCancelSubtitleJob: active && job != null ? () => widget.onCancelEpisodeJob(job.id, eps[i].card.id) : null,
                        ),
                      ],
                    ]),
                  ),
                ),
              ),
              Transform.translate(offset: Offset(0, -s.rem(0.375)), child: EvShelfScrollbar(controller: _track, shelfHovered: _hovered, margin: EdgeInsets.symmetric(horizontal: g), metricsRevision: _metricsRev)),
            ],
          ]);
        }),
      ),
    );
  }
}

class _SeasonTab extends StatefulWidget {
  const _SeasonTab({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override State<_SeasonTab> createState() => _SeasonTabState();
}

class _SeasonTabState extends State<_SeasonTab> {
  bool _hov = false, _foc = false;
  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return Semantics(button: true, selected: widget.selected, label: widget.label, child: Focus(
      onFocusChange: (v) => setState(() => _foc = v),
      onKeyEvent: (_, e) { if (!evIsActivateKey(e)) return KeyEventResult.ignored; widget.onTap(); return KeyEventResult.handled; },
      child: MouseRegion(
        cursor: SystemMouseCursors.click, onEnter: (_) => setState(() => _hov = true), onExit: (_) => setState(() => _hov = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: widget.onTap,
          child: AnimatedContainer(
            duration: EvDurations.fast, curve: EvCurves.soft, height: s.rem(2.375), padding: EdgeInsets.symmetric(horizontal: s.rem(1.0625)), alignment: Alignment.center,
            decoration: BoxDecoration(color: widget.selected ? t.indBg : const Color(0x00000000), borderRadius: BorderRadius.circular(999)),
            child: Text(widget.label, style: t.bodyStyle(s.font(1), fontWeight: FontWeight.w600, color: widget.selected ? t.indFg : (_hov || _foc ? t.ink : t.ink3))),
          ),
        ),
      ),
    ));
  }
}

class _AiSeasonButton extends StatefulWidget {
  const _AiSeasonButton({required this.complete, required this.epTotal, required this.job, required this.active, required this.quoting, required this.compactIcon, required this.onTap, required this.onCancel});
  final int complete, epTotal;
  final SeasonJob? job;
  final bool active, quoting, compactIcon;
  final VoidCallback onTap;
  final VoidCallback? onCancel;
  @override State<_AiSeasonButton> createState() => _AiSeasonButtonState();
}

class _AiSeasonButtonState extends State<_AiSeasonButton> {
  bool _hov = false, _pressed = false;
  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), ringC = t.isPaper ? const Color(0xFFD97757) : const Color(0xFFB9A0FF);
    final total = widget.active && (widget.job?.total ?? 0) > 0 ? widget.job!.total : widget.epTotal;
    final done = widget.active && widget.job != null ? widget.job!.completedCount : widget.complete;
    final prog = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0, allDone = !widget.active && total > 0 && done >= total;
    final (lbl, cnt, tip) = widget.active
        ? ('正在生成 $done / $total', '', '正在生成 $done / $total · 点击取消')
        : widget.quoting ? ('正在估算费用…', '', '正在估算本季生成费用…')
        : allDone ? ('整季中字已就绪', '$done / $total 已有', '整季中字已就绪（$done / $total 已有）')
        : ('AI 中字 · 整季生成', '$done / $total 已有', 'AI 中字 · 整季生成（$done / $total 已有）');

    final compact = widget.compactIcon && !widget.active, rSz = s.rem(compact ? 2.75 : 1.75);
    final ring = SizedBox(width: rSz, height: rSz, child: Stack(alignment: Alignment.center, children: [
      CustomPaint(key: const Key('ev_detail_ai_progress_ring'), size: Size.square(rSz), painter: EvRingProgressPainter(progress: prog, trackColor: t.fill3, progressColor: ringC, strokeWidth: 2)),
      EvIcon(allDone ? EvIcons.ok : EvIcons.aisub, size: s.rem(compact ? 1.25 : 1), color: t.ink),
    ]));
    final body = compact ? ring : Padding(
      padding: EdgeInsets.fromLTRB(s.rem(0.5), 0, s.rem(1), 0),
      child: SizedBox(height: s.rem(2.5), child: Row(mainAxisSize: MainAxisSize.min, children: [
        ring, SizedBox(width: s.rem(0.5)),
        Text(lbl, style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: t.ink)),
        if (cnt.isNotEmpty) ...[SizedBox(width: s.rem(0.5)), Text(cnt, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: t.ink3))],
      ])),
    );

    final trig = Semantics(button: true, label: tip, tooltip: tip, child: MouseRegion(
      cursor: SystemMouseCursors.click, onEnter: (_) => setState(() => _hov = true), onExit: (_) => setState(() { _hov = false; _pressed = false; }),
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.centerRight, children: [
        GestureDetector(
          key: const Key('ev_detail_ai_season_btn'), behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true), onTapUp: (_) => setState(() => _pressed = false), onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.quoting ? null : widget.onTap,
          child: AnimatedScale(scale: _pressed ? 0.94 : 1, duration: EvDurations.normal, curve: EvCurves.spring,
              child: EvGlass(borderRadius: BorderRadius.circular(999), color: _hov ? t.fill3 : null, child: body)),
        ),
        if (compact && _hov)
          Positioned(right: 0, bottom: s.rem(3.25), child: IgnorePointer(child: EvGlass(
            key: const Key('ev_detail_ai_icon_tip'), solid: true, borderRadius: BorderRadius.circular(s.rem(0.5)),
            padding: EdgeInsets.symmetric(horizontal: s.rem(0.625), vertical: s.rem(0.375)),
            child: Text(tip, softWrap: false, style: t.bodyStyle(s.font(0.8125), fontWeight: FontWeight.w500, color: t.ink)),
          ))),
      ]),
    ));
    return (!widget.active || widget.onCancel == null) ? trig : Row(mainAxisSize: MainAxisSize.min, children: [
      trig, SizedBox(width: s.rem(0.5)),
      EvButton.ghost(key: const Key('ev_detail_ai_cancel_btn'), label: '取消', small: true, glass: true, onPressed: widget.onCancel),
    ]);
  }
}

/// Modal confirmation dialog displaying [SeasonQuote] cost estimate & [BudgetState].
class EvSeasonQuoteDialog extends StatefulWidget {
  const EvSeasonQuoteDialog({super.key, required this.quote, required this.onConfirm});
  final SeasonQuote quote;
  final Future<void> Function(SeasonQuote quote) onConfirm;
  @override State<EvSeasonQuoteDialog> createState() => _EvSeasonQuoteDialogState();
}

class _EvSeasonQuoteDialogState extends State<EvSeasonQuoteDialog> {
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() { _submitting = true; _error = null; });
    try { await widget.onConfirm(widget.quote); if (mounted) Navigator.of(context).pop(true); }
    catch (e) { if (mounted) setState(() { _submitting = false; _error = e is EmbyViewFailure ? e.reason : '$e'; }); }
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), q = widget.quote;
    final usd = q.estimatedCostMicros <= 0 ? '\$0.00' : (q.estimatedCostMicros < 10000 ? '< \$0.01' : '\$${(q.estimatedCostMicros / 1e6).toStringAsFixed(2)}');
    final (bLbl, bCol) = switch (q.budget) {
      BudgetState.available => ('预算可用', t.isPaper ? const Color(0xFF5F7346) : const Color(0xFF4FBF7F)),
      BudgetState.exceeded => ('已超出本月预算', const Color(0xFFE5484D)),
      BudgetState.missingCredentials => ('缺少所需 API 密钥', const Color(0xFFE3A03C)),
      BudgetState.unknown => ('无法确认本月预算', const Color(0xFFE3A03C)),
    };
    Widget row(String k, String v, {Color? c}) => Container(
      padding: EdgeInsets.symmetric(vertical: s.rem(0.5625)),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
      child: Row(children: [
        SizedBox(width: s.rem(6), child: Text(k, style: t.bodyStyle(s.font(0.9375), color: t.ink3))),
        Expanded(child: Text(v, textAlign: TextAlign.right, style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: c ?? t.ink))),
      ]),
    );

    return Center(child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: s.rem(30)),
      child: EvGlass(
        key: const Key('ev_season_quote_dialog'), solid: true, borderRadius: BorderRadius.circular(s.rem(1.25)), padding: EdgeInsets.all(s.rem(1.5)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [EvIcon(EvIcons.aisub, size: s.rem(1.5), color: t.ink), SizedBox(width: s.rem(0.625)), Expanded(child: Text('AI 中字 · 整季费用估算', style: t.shelfStyle(s.font(1.25))))]),
          SizedBox(height: s.rem(0.375)), Text(q.seasonName, style: t.bodyStyle(s.font(0.9375), color: t.ink3)), SizedBox(height: s.rem(1.25)),
          row('待生成集数', '${q.pendingCount} 集（已有完整中字 ${q.completedCount} 集）'),
          row('预估费用', usd), row('预算状态', bLbl, c: bCol),
          if (q.reason?.trim().isNotEmpty ?? false) ...[SizedBox(height: s.rem(0.625)), Text(q.reason!.trim(), key: const Key('ev_season_quote_reason'), style: t.bodyStyle(s.font(0.875), color: t.ink3, height: 1.5))],
          if (_error != null) ...[SizedBox(height: s.rem(0.75)), Text(_error!, style: t.bodyStyle(s.font(0.875), color: const Color(0xFFE5484D)))],
          SizedBox(height: s.rem(1.5)),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            EvButton.ghost(key: const Key('ev_season_quote_cancel'), label: '取消', small: true, onPressed: _submitting ? null : () => Navigator.of(context).pop(false)),
            SizedBox(width: s.rem(0.75)),
            EvButton.primary(key: const Key('ev_season_quote_confirm'), label: _submitting ? '提交中…' : '确认生成', small: true, onPressed: (q.budget == BudgetState.available && q.pendingCount > 0 && !_submitting) ? _submit : null),
          ]),
        ]),
      ),
    ));
  }
}
