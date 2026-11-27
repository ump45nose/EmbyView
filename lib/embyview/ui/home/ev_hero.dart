import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Reusable full-bleed first-screen hero shared by the home page and zone pages.
/// Height is strictly `100vh - peek` so the first content row peeks at the bottom.
class EvHero extends StatefulWidget {
  const EvHero({
    super.key,
    required this.recommendations,
    this.previewCard,
    this.defaultReasonLabel = '今日推荐',
    this.onDetail,
    this.onPlay,
    this.onToggleFavorite,
    this.onActiveChanged,
    this.enableAutoRotate = true,
    this.pauseAutoRotate,
  });

  final List<HomeRecommendation> recommendations;
  final MediaCard? previewCard;
  final String defaultReasonLabel;
  final VoidCallback? onDetail;
  final void Function(HomeRecommendation recommendation, Rect? origin)? onPlay;
  final VoidCallback? onToggleFavorite;
  final ValueChanged<HomeRecommendation>? onActiveChanged;
  final bool enableAutoRotate;
  final ValueListenable<bool>? pauseAutoRotate;

  @override
  State<EvHero> createState() => _EvHeroState();
}

class _EvHeroState extends State<EvHero> with SingleTickerProviderStateMixin {
  late final AnimationController _cycleController;
  int _activeIndex = 0;
  String? _failedLogoKey;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _cycleController = AnimationController(vsync: this, duration: EvDurations.heroCycle)
      ..addStatusListener(_onCycleStatus);
    widget.pauseAutoRotate?.addListener(_onPauseChanged);
    _syncRotation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncRotation();
  }

  @override
  void didUpdateWidget(EvHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pauseAutoRotate != widget.pauseAutoRotate) {
      oldWidget.pauseAutoRotate?.removeListener(_onPauseChanged);
      widget.pauseAutoRotate?.addListener(_onPauseChanged);
    }
    final oldRecs = oldWidget.recommendations, newRecs = widget.recommendations;
    final oldActiveRec = (_activeIndex >= 0 && _activeIndex < oldRecs.length)
        ? oldRecs[_activeIndex]
        : null;
    var activeChanged = false;
    var restartRotation = false;
    if (newRecs.isEmpty) {
      _activeIndex = 0;
    } else {
      final preservedIdx = oldActiveRec == null
          ? -1
          : newRecs.indexWhere((r) => r.card.id == oldActiveRec.card.id);
      if (preservedIdx >= 0) {
        _activeIndex = preservedIdx;
        if (stageArtworkKey(oldActiveRec!.card.art.stage) !=
            stageArtworkKey(newRecs[preservedIdx].card.art.stage)) {
          activeChanged = true;
        }
      } else {
        _activeIndex = 0;
        _failedLogoKey = null;
        activeChanged = true;
        restartRotation = true;
      }
    }
    if (activeChanged && newRecs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.recommendations.isNotEmpty) {
          widget.onActiveChanged?.call(
            widget.recommendations[_activeIndex.clamp(0, widget.recommendations.length - 1)],
          );
        }
      });
    }
    if (oldWidget.previewCard?.id != widget.previewCard?.id) _failedLogoKey = null;
    _syncRotation(restart: restartRotation || (oldWidget.previewCard != null && widget.previewCard == null));
  }

  bool get _shouldRotate =>
      widget.enableAutoRotate &&
      !(widget.pauseAutoRotate?.value ?? false) &&
      !_disableAnimations &&
      widget.recommendations.length > 1 &&
      widget.previewCard == null;

  void _onPauseChanged() {
    if (!mounted) return;
    _syncRotation(restart: !(widget.pauseAutoRotate?.value ?? false));
  }

  void _syncRotation({bool restart = false}) {
    if (_shouldRotate) {
      if (restart || !_cycleController.isAnimating) _cycleController.forward(from: 0.0);
    } else if (_cycleController.isAnimating) {
      _cycleController.stop();
    }
  }

  void _onCycleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted || !_shouldRotate) return;
    final next = (_activeIndex + 1) % widget.recommendations.length;
    setState(() { _activeIndex = next; _failedLogoKey = null; });
    widget.onActiveChanged?.call(widget.recommendations[next]);
    _cycleController.forward(from: 0.0);
  }

  void _selectIndex(int index) {
    if (index < 0 || index >= widget.recommendations.length) return;
    if (_activeIndex != index) {
      setState(() { _activeIndex = index; _failedLogoKey = null; });
      widget.onActiveChanged?.call(widget.recommendations[index]);
    }
    if (_shouldRotate) _cycleController.forward(from: 0.0);
  }

  HomeRecommendation? get _displayed {
    final preview = widget.previewCard;
    if (preview != null) {
      for (final r in widget.recommendations) {
        if (r.card.id == preview.id) return r;
      }
      return HomeRecommendation(card: preview, reason: RecommendationReason.daily);
    }
    if (widget.recommendations.isEmpty) return null;
    return widget.recommendations[_activeIndex.clamp(0, widget.recommendations.length - 1)];
  }

  void _handlePlay(HomeRecommendation rec, BuildContext btnContext) {
    final box = btnContext.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize ? (box.localToGlobal(Offset.zero) & box.size) : null;
    if (widget.onPlay != null) { widget.onPlay!(rec, origin); return; }
    final target = rec.resume?.target ?? PlayTarget(itemId: rec.card.id);
    unawaited(EvPlayer.open(context, target, origin: origin, art: rec.card.art));
  }

  void _handleDetail(HomeRecommendation rec) {
    if (widget.onDetail != null) { widget.onDetail!(); return; }
    EvScope.maybeOf(context)?.shell.openCard(rec.card);
  }

  @override
  void dispose() {
    widget.pauseAutoRotate?.removeListener(_onPauseChanged);
    _cycleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = EvScale.of(context);
    final displayed = _displayed;
    return SizedBox(
      key: const Key('ev_hero'),
      height: math.max(0.0, scale.vh(100) - scale.peek),
      width: double.infinity,
      child: EvOnImage(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth > 0 ? constraints.maxWidth : scale.size.width;
            final bbW = math.min(math.min(scale.rem(46.0), maxW * 0.52), math.max(0.0, maxW - scale.gutter * 2));
            return Stack(
              fit: StackFit.expand,
              children: [
                if (displayed != null)
                  Positioned(
                    left: scale.gutter, bottom: scale.rem(2.25), width: bbW,
                    child: AnimatedSwitcher(
                      duration: EvDurations.heroSwap, switchInCurve: EvCurves.out, switchOutCurve: EvCurves.soft,
                      layoutBuilder: (cur, prev) => Stack(alignment: Alignment.bottomLeft, children: [...prev, ?cur]),
                      child: _buildBillboard(context, displayed, scale),
                    ),
                  ),
                if (widget.recommendations.length > 1)
                  Positioned(right: scale.gutter, bottom: scale.rem(2.5), child: _buildDots(context, scale)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBillboard(BuildContext context, HomeRecommendation rec, EvScale scale) {
    final theme = EvTheme.of(context), card = rec.card;
    final isPreview = widget.previewCard != null && widget.previewCard!.id == card.id;
    final previewMeta = [if (card.year != null) '${card.year}', if (card.genres.isNotEmpty) card.genres.first].join(' · ');
    final reasonText = isPreview && previewMeta.isNotEmpty ? previewMeta : widget.defaultReasonLabel;

    return Column(
      key: ValueKey<String>('ev_hero_bb_${card.id}_${isPreview ? 'p' : 'r'}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildReasonCapsule(context, theme, scale, rec, reasonText),
        SizedBox(height: scale.rem(1.25)),
        _buildTitleArtwork(theme, scale, card),
        SizedBox(height: scale.rem(1.25)),
        _buildMetaLine(theme, scale, card),
        if (card.overview != null && card.overview!.trim().isNotEmpty) ...[
          SizedBox(height: scale.rem(1.0)),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: scale.rem(38.0)),
            child: Text(
              card.overview!.trim(), key: const Key('ev_hero_overview'),
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: theme.bodyStyle(scale.font(1.125), color: theme.ink2, height: 1.62),
            ),
          ),
        ],
        SizedBox(height: scale.rem(1.5)),
        _buildActions(scale, rec),
      ],
    );
  }

  Widget _buildReasonCapsule(BuildContext context, EvTheme theme, EvScale scale, HomeRecommendation rec, String reasonText) {
    final isContinue = rec.resume != null || rec.reason == RecommendationReason.continueWatching;
    final badgeSize = scale.rem(1.625);
    late final Widget leading;
    late final String primaryLabel;
    String? secondaryLabel;

    if (isContinue) {
      final progress = EvCard.resumeProgress(rec.resume) ?? 0.0;
      final pct = (progress * 100).round().clamp(0, 100);
      leading = SizedBox(
        key: const Key('ev_hero_resume_ring'), width: badgeSize, height: badgeSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size.square(badgeSize),
              painter: _HeroRingPainter(
                progress: progress, trackColor: theme.fill3,
                progressColor: theme.isPaper ? theme.brand : theme.ink,
                strokeWidth: math.max(2.0, badgeSize * (3.0 / 26.0)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(3),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('$pct%', style: theme.bodyStyle(scale.rem(0.5625), fontWeight: FontWeight.w700, color: theme.ink, height: 1.0)),
              ),
            ),
          ],
        ),
      );
      primaryLabel = '继续观看';
      secondaryLabel = EvCard.resumeSubtitle(rec.resume);
    } else {
      final (libName, libIcon, libColor) = _libraryMeta(context, rec.card, theme);
      leading = Container(
        width: badgeSize, height: badgeSize, alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: theme.isPaper ? theme.brand : libColor),
        child: EvIcon(libIcon, size: scale.rem(0.9375), color: theme.isPaper ? const Color(0xFF141413) : const Color(0xFF09090B)),
      );
      primaryLabel = libName ?? reasonText;
      secondaryLabel = libName != null ? reasonText : null;
    }

    return EvGlass(
      key: const Key('ev_hero_reason'),
      borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.fromLTRB(scale.rem(0.3125), 0, scale.rem(1.0), 0),
      child: SizedBox(
        height: scale.rem(2.25),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            SizedBox(width: scale.rem(0.5)),
            Text(primaryLabel, style: theme.bodyStyle(scale.font(0.9375), fontWeight: FontWeight.w600, color: theme.ink)),
            if (secondaryLabel != null && secondaryLabel.isNotEmpty) ...[
              SizedBox(width: scale.rem(0.5)),
              Text(secondaryLabel, style: theme.bodyStyle(scale.font(0.875), fontWeight: FontWeight.w500, color: theme.ink3)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTitleArtwork(EvTheme theme, EvScale scale, MediaCard card) {
    final logo = card.art.logo;
    final boxH = scale.rem(11.0);
    if (logo == null || _failedLogoKey == logo.cacheKey) {
      return SizedBox(height: boxH, child: Align(alignment: Alignment.bottomLeft, child: _wordmark(theme, scale, card.title)));
    }
    return SizedBox(
      height: boxH,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: scale.rem(32.0), maxHeight: boxH),
          child: Stack(
            alignment: Alignment.bottomLeft,
            children: [
              ExcludeSemantics(
                child: IgnorePointer(
                  child: Transform.translate(
                    offset: Offset(0, scale.rem(0.35)),
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: ColorFiltered(
                        colorFilter: const ColorFilter.mode(Color.fromRGBO(0, 0, 0, 0.40), BlendMode.srcIn),
                        child: Image(image: logo.image, fit: BoxFit.contain, alignment: Alignment.bottomLeft, gaplessPlayback: true, filterQuality: FilterQuality.low, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                      ),
                    ),
                  ),
                ),
              ),
              Image(
                key: ValueKey<String>('ev_hero_logo_${logo.cacheKey}'),
                image: logo.image, fit: BoxFit.contain, alignment: Alignment.bottomLeft,
                gaplessPlayback: true, filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _failedLogoKey != logo.cacheKey) setState(() => _failedLogoKey = logo.cacheKey);
                  });
                  return _wordmark(theme, scale, card.title);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _wordmark(EvTheme theme, EvScale scale, String title) => Text(
    title, key: const Key('ev_hero_wordmark'), maxLines: 2, overflow: TextOverflow.ellipsis,
    style: theme.displayStyle(scale.rem(theme.isPaper ? 4.5 : 4.75), color: theme.ink, height: theme.isPaper ? 1.12 : 1.06),
  );

  Widget _buildMetaLine(EvTheme theme, EvScale scale, MediaCard card) {
    final ts = theme.bodyStyle(scale.font(1.0625), fontWeight: FontWeight.w500, color: theme.ink2);
    final bits = <Widget>[];
    void add(Widget w) {
      if (bits.isNotEmpty) bits.add(SizedBox(width: 1, height: scale.rem(0.875), child: ColoredBox(color: theme.fill3)));
      bits.add(w);
    }

    if (card.score != null && card.score! > 0) add(EvScoreBadge(score: card.score!));
    if (card.year != null) add(Text('${card.year}', style: ts));
    if (card.genres.isNotEmpty) add(Text(card.genres.take(2).join(' / '), style: ts));
    if (card.kind == MediaKind.movie && card.duration != null && card.duration! > Duration.zero) {
      add(Text(_formatDuration(card.duration!), style: ts));
    } else if (card.kind == MediaKind.series && (card.childCount ?? 0) > 0) {
      add(Text('${card.childCount} 季', style: ts));
    } else if (card.kind == MediaKind.collection && (card.childCount ?? 0) > 0) {
      add(Text('${card.childCount} 部', style: ts));
    }
    if (card.rating != null && card.rating!.trim().isNotEmpty) add(Text(card.rating!.trim(), style: ts));

    final badges = _qualityBadges(card.quality);
    return Wrap(
      key: const Key('ev_hero_meta'),
      spacing: scale.rem(0.875), runSpacing: scale.rem(0.5),
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...bits,
        if (badges.isNotEmpty)
          Wrap(spacing: scale.rem(0.375), runSpacing: scale.rem(0.375), crossAxisAlignment: WrapCrossAlignment.center, children: badges),
      ],
    );
  }

  List<Widget> _qualityBadges(MediaQuality? q) {
    if (q == null) return const [];
    final res = q.resolution?.trim(), range = q.videoRange?.trim(), audio = q.audioLabel?.trim();
    return [
      if (res != null && res.isNotEmpty && res.toLowerCase() != '1080p' && res.toLowerCase() != '720p')
        EvQualityBadge(label: res),
      if (range != null && range.isNotEmpty)
        EvQualityBadge(
          label: range,
          kind: (range.toLowerCase().contains('dolby') || range.contains('杜比'))
              ? EvQualityBadgeKind.dolbyVision
              : EvQualityBadgeKind.standard,
        ),
      if (audio != null && audio.isNotEmpty) EvQualityBadge(label: audio),
    ];
  }

  Widget _buildActions(EvScale scale, HomeRecommendation rec) {
    final resume = rec.resume;
    String primaryLabel = '立即播放';
    String? secondaryLabel;
    double? progress;
    if (resume != null) {
      final ep = resume.target.episodeNumber ?? rec.card.episodeNumber;
      primaryLabel = ep != null ? '继续第 $ep 集' : '继续';
      final total = resume.duration ?? rec.card.duration;
      if (total != null && total > Duration.zero) {
        secondaryLabel = '· ${EvCard.formatRemaining(total > resume.position ? total - resume.position : Duration.zero)}';
      }
      progress = EvCard.resumeProgress(resume);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Builder(
          builder: (btnCtx) => EvButton.primary(
            key: const Key('ev_hero_play_btn'), icon: EvIcons.play,
            label: primaryLabel, secondaryLabel: secondaryLabel, progress: progress,
            onPressed: () => _handlePlay(rec, btnCtx),
          ),
        ),
        SizedBox(width: scale.rem(0.75)),
        EvButton.ghost(key: const Key('ev_hero_detail_btn'), label: '详情', glass: true, onPressed: () => _handleDetail(rec)),
        SizedBox(width: scale.rem(0.75)),
        EvButton.ghost(
          key: const Key('ev_hero_favorite_btn'),
          round: true,
          glass: true,
          icon: EvIcons.plus,
          tooltip: '加入片单',
          onPressed: () => widget.onToggleFavorite?.call(),
        ),
      ],
    );
  }

  Widget _buildDots(BuildContext context, EvScale scale) {
    final theme = EvTheme.of(context), n = widget.recommendations.length, active = _activeIndex.clamp(0, n - 1);
    return EvGlass(
      key: const Key('ev_hero_dots'),
      borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.symmetric(horizontal: scale.rem(0.625)),
      child: SizedBox(
        height: scale.rem(2.5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < n; i++)
              Semantics(
                button: true, selected: i == active, label: '第 ${i + 1} 部推荐',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: Key('ev_hero_dot_$i'), behavior: HitTestBehavior.opaque, onTap: () => _selectIndex(i),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: scale.rem(0.3125)),
                      child: SizedBox(
                        height: scale.rem(2.5),
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 550), curve: EvCurves.spring,
                            width: scale.rem(i == active ? 2.25 : 0.5), height: scale.rem(0.5),
                            decoration: BoxDecoration(color: theme.fill3, borderRadius: BorderRadius.circular(999)),
                            clipBehavior: Clip.antiAlias,
                            child: i == active
                                ? AnimatedBuilder(
                                    animation: widget.pauseAutoRotate == null
                                        ? _cycleController
                                        : Listenable.merge([_cycleController, widget.pauseAutoRotate!]),
                                    builder: (_, _) => Align(
                                      alignment: Alignment.centerLeft,
                                      child: FractionallySizedBox(
                                        widthFactor: (_shouldRotate ? _cycleController.value : 1.0).clamp(0.0, 1.0),
                                        heightFactor: 1.0,
                                        child: ColoredBox(color: theme.ink),
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final mTotal = math.max(1, d.inMinutes), h = mTotal ~/ 60, m = mTotal % 60;
    return h == 0 ? '$m 分钟' : (m == 0 ? '$h 小时' : '$h 小时 $m 分');
  }

  static (String?, EvIconData, Color) _libraryMeta(BuildContext context, MediaCard card, EvTheme theme) {
    final libId = card.libraryId;
    if (libId != null && libId.isNotEmpty) {
      for (final z in EvScope.maybeOf(context)?.shell.zones ?? const <ZoneTile>[]) {
        if (z.id == libId) {
          return (z.name, EvIcons.byKey(z.iconKey), theme.zoneColor(z.colorSlot));
        }
      }
    }
    return switch (card.kind) {
      MediaKind.movie => (null, EvIcons.navMovie, theme.movie),
      MediaKind.series || MediaKind.episode => (null, EvIcons.navTv, theme.tv),
      MediaKind.collection => (null, EvIcons.navBox, theme.box),
    };
  }
}

class _HeroRingPainter extends CustomPainter {
  const _HeroRingPainter({required this.progress, required this.trackColor, required this.progressColor, required this.strokeWidth});
  final double progress, strokeWidth;
  final Color trackColor, progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.max(0.0, size.shortestSide / 2 - strokeWidth / 2);
    canvas.drawCircle(c, r, Paint()..color = trackColor..style = PaintingStyle.stroke..strokeWidth = strokeWidth);
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r), -math.pi / 2, sweep, false,
        Paint()..color = progressColor..style = PaintingStyle.stroke..strokeWidth = strokeWidth..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_HeroRingPainter old) =>
      old.progress != progress || old.trackColor != trackColor || old.progressColor != progressColor || old.strokeWidth != strokeWidth;
}
