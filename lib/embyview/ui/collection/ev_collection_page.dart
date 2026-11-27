import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Colors, Tooltip;
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Collection / franchise page mirroring `vColl` in `.spec/mockups/proto.js` & `proto.css`.
class EvCollectionPage extends StatefulWidget {
  const EvCollectionPage({
    super.key,
    required this.collectionId,
    this.onOpenItem,
    this.onPlayTarget,
  });

  final String collectionId;
  final ValueChanged<String>? onOpenItem;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin)? onPlayTarget;

  @override
  State<EvCollectionPage> createState() => _EvCollectionPageState();
}

class _EvCollectionPageState extends State<EvCollectionPage> {
  final _scroll = ScrollController();
  final _trackScroll = ScrollController();
  EvScope? _scope;
  EmbyViewData? _attachedData;
  String? _attachedSessionId;
  StreamSubscription<EvPlaybackEnded>? _playbackEndedSub;
  int _loadToken = 0;
  bool _loading = true;
  bool _savingAllPlayed = false;
  bool _trackHovered = false;
  Object? _error;
  String? _actionError;
  CollectionDetail? _detail;
  String? _failedLogoKey;
  Timer? _previewTimer;
  Timer? _actionErrTimer;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context);
    final changed =
        _scope == null ||
        !identical(_attachedData, scope.services.data) ||
        _attachedSessionId != scope.services.sessionId;
    if (!identical(_scope?.shell, scope.shell)) {
      unawaited(_playbackEndedSub?.cancel());
      _playbackEndedSub = scope.shell.playbackEnded.listen((event) {
        final services = _scope?.services;
        if (!mounted || services == null || !event.matches(services)) return;
        final current = _detail;
        if (current == null ||
            event.targets.any((t) => current.items.any((x) => x.card.id == t.itemId))) {
          unawaited(_load(silent: true));
        }
      });
    }
    _scope = scope;
    if (!changed) return;
    _attachedData = scope.services.data;
    _attachedSessionId = scope.services.sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scope.shell.updateChrome(
        hideTabs: true,
        hideAvatar: true,
        showBack: true,
        clearTitlePlate: true,
        rightActions: const [],
        topFade: 0,
        scrolled: false,
      );
      scope.stage
        ..setMode(EvStageMode.detail, detailNoBlur: false)
        ..setScrollProgress(0)
        ..setVeilLifted(false)
        ..clearPreviewBackdrop();
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(EvCollectionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collectionId == widget.collectionId) return;
    _previewTimer?.cancel();
    _failedLogoKey = null;
    if (_scroll.hasClients && _scroll.offset != 0) _scroll.jumpTo(0);
    unawaited(_load());
  }

  Future<void> _load({bool silent = false}) async {
    final scope = _scope, data = scope?.services.data, id = widget.collectionId, token = ++_loadToken;
    _previewTimer?.cancel();
    if (scope == null || data == null) {
      if (mounted) setState(() { _loading = false; _error = null; });
      return;
    }
    if (!silent && mounted) {
      setState(() { _loading = true; _error = null; _detail = null; });
    }
    try {
      final loaded = await data.collection(id);
      if (!mounted || token != _loadToken) return;
      setState(() {
        _detail = loaded;
        _loading = false;
        _error = null;
      });
      _applyBaseBackdrop(loaded);
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      if (!silent) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _applyBaseBackdrop(CollectionDetail detail) {
    final stage = _scope?.stage;
    if (stage == null) return;
    ArtworkPlan? plan;
    if (detail.card.art.backdrops.isNotEmpty) {
      plan = ArtworkPlan(
        layers: [ArtworkLayer(source: detail.card.art.backdrops.first, fit: ArtworkFit.cover)],
        fallbackTitle: detail.displayName,
      );
    } else {
      for (final item in detail.items) {
        if (item.card.art.backdrops.isNotEmpty) {
          plan = ArtworkPlan(
            layers: [ArtworkLayer(source: item.card.art.backdrops.first, fit: ArtworkFit.cover)],
            fallbackTitle: item.card.title,
          );
          break;
        }
      }
    }
    stage
      ..setMode(EvStageMode.detail, detailNoBlur: false)
      ..setScrollProgress(_scrollProgress())
      ..setVeilLifted(false)
      ..clearPreviewBackdrop()
      ..setBaseBackdrop(plan ?? detail.card.art.stage);
  }

  double _scrollProgress() {
    if (!_scroll.hasClients) return 0.0;
    final pos = _scroll.position;
    final vh = pos.hasViewportDimension && pos.viewportDimension > 0 ? pos.viewportDimension : 900.0;
    return (pos.pixels / (vh * 0.6)).clamp(0.0, 1.0);
  }

  void _onScroll() {
    final s = _scope;
    if (s == null || !_scroll.hasClients) return;
    s.shell.setScrollOffset(_scroll.position.pixels);
    s.stage.setScrollProgress(_scrollProgress());
  }

  void _onFilmHighlight(CollectionItem item, bool active) {
    _previewTimer?.cancel();
    if (!active) return;
    _previewTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final backdrop = item.card.art.backdrops.firstOrNull;
      if (backdrop != null) {
        _scope?.stage.setBaseBackdrop(
          ArtworkPlan(
            layers: [ArtworkLayer(source: backdrop, fit: ArtworkFit.cover)],
            fallbackTitle: item.card.title,
          ),
        );
      }
    });
  }

  void _play(PlayTarget target, CardArtwork art, Rect? origin) {
    final im = _scope?.immersion;
    if (im != null) {
      unawaited(im.stopTheme());
      unawaited(im.stopVideo());
    }
    if (widget.onPlayTarget != null) {
      widget.onPlayTarget!(target, art, origin);
      return;
    }
    unawaited(EvPlayer.open(context, target, origin: origin, art: art));
  }

  void _playPrimary(BuildContext btnCtx, CollectionNextTarget next, {bool sequential = false}) {
    final d = _detail;
    if (d == null) return;
    final box = btnCtx.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize ? (box.localToGlobal(Offset.zero) & box.size) : null;
    final queueIds = sequential
        ? [for (var i = next.index; i < d.items.length; i++) d.items[i].card.id]
        : const <String>[];
    final target = PlayTarget(
      itemId: next.item.card.id,
      startAt: next.item.isInProgress ? next.item.resume?.position : null,
      queueItemIds: queueIds,
    );
    _play(target, next.item.card.art, origin);
  }

  Future<void> _toggleAllPlayed() async {
    final d = _detail, data = _scope?.services.data;
    if (d == null || data == null || _savingAllPlayed || d.items.isEmpty) return;
    final allDone = d.items.every((x) => x.isDone);
    final nextPlayed = !allDone;
    setState(() { _savingAllPlayed = true; _actionError = null; });
    try {
      for (final item in d.items) {
        if (item.isDone != nextPlayed) {
          await data.setPlayed(item.card.id, nextPlayed);
        }
      }
      if (!mounted) return;
      setState(() => _savingAllPlayed = false);
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      final reason = e is EmbyViewFailure ? e.reason : '请稍后重试';
      _actionErrTimer?.cancel();
      setState(() {
        _savingAllPlayed = false;
        _actionError = nextPlayed ? '全部标为已看失败：$reason' : '取消全部已看失败：$reason';
      });
      _actionErrTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _actionError = null);
      });
    }
  }

  static String formatHoursMinutes(int totalMinutes) {
    if (totalMinutes <= 0) return '';
    final h = totalMinutes ~/ 60, m = totalMinutes % 60;
    if (h == 0) return '$m 分';
    if (m == 0) return '$h 小时';
    return '$h 小时 $m 分';
  }

  @override
  void dispose() {
    unawaited(_playbackEndedSub?.cancel());
    _previewTimer?.cancel();
    _actionErrTimer?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _trackScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return ScrollConfiguration(
      key: const Key('ev_collection_page'),
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        key: const Key('ev_collection_scroller'),
        controller: _scroll,
        child: _buildBody(t, s),
      ),
    );
  }

  Widget _buildBody(EvTheme t, EvScale s) {
    final d = _detail;
    if (_error != null && d == null) {
      return SizedBox(
        height: math.max(0.0, s.vh(100)),
        child: Center(
          child: Padding(
            key: const Key('ev_collection_error'),
            padding: EdgeInsets.symmetric(horizontal: s.gutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('无法加载系列', style: t.shelfStyle(s.font(1.5))),
                SizedBox(height: s.rem(0.75)),
                Text(
                  _error is EmbyViewFailure ? (_error as EmbyViewFailure).reason : '$_error',
                  style: t.bodyStyle(s.font(0.9375), color: t.ink3),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: s.rem(1.5)),
                EvButton.ghost(
                  key: const Key('ev_collection_retry_btn'),
                  label: '重试',
                  small: true,
                  onPressed: () => unawaited(_load()),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_loading && d == null) {
      return Column(
        key: const Key('ev_collection_loading'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: math.max(0.0, s.vh(100) - s.peek)),
          const EvShelfSkeleton(style: EvCardStyle.landscape, count: 4),
        ],
      );
    }
    if (d == null) {
      return SizedBox(
        height: math.max(0.0, s.vh(100)),
        child: Center(child: Text('未找到系列信息', style: t.shelfStyle(s.font(1.25)))),
      );
    }

    final openItem = widget.onOpenItem ?? _scope?.shell.onOpenDetail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHero(t, s, d),
        _buildOrderedSection(t, s, d, openItem),
        _buildFactsSection(t, s, d),
      ],
    );
  }

  Widget _buildHero(EvTheme hostTheme, EvScale s, CollectionDetail d) {
    final items = d.items;
    final seen = items.where((x) => x.isDone).length;
    final next = selectCollectionNextTarget(items);
    final years = [for (final x in items) if (x.card.year != null) x.card.year!];
    final yearSpan = years.isEmpty
        ? ''
        : (years.reduce(math.min) == years.reduce(math.max)
            ? '${years.first}'
            : '${years.reduce(math.min)}–${years.reduce(math.max)}');
    final totalMinutes = items.fold<int>(
      0,
      (sum, x) => sum + (x.card.duration != null ? x.card.duration!.inMinutes : 0),
    );
    final scores = [for (final x in items) if (x.card.score != null && x.card.score! > 0) x.card.score!];
    final avgScore = scores.isEmpty ? null : scores.reduce((a, b) => a + b) / scores.length;
    final allDone = items.isNotEmpty && seen == items.length;

    return SizedBox(
      key: const Key('ev_collection_hero'),
      height: math.max(0.0, s.vh(100) - s.peek),
      width: double.infinity,
      child: EvOnImage(
        child: LayoutBuilder(
          builder: (ctx, c) {
            final t = EvTheme.of(ctx);
            final maxW = c.maxWidth > 0 ? c.maxWidth : s.size.width;
            final infoW = math.min(math.min(s.rem(46), maxW * 0.52), math.max(0.0, maxW - s.gutter * 2));
            final metaStyle = t.bodyStyle(s.font(1.0625), fontWeight: FontWeight.w500, color: t.ink2);
            final metaBits = <Widget>[];
            void addMeta(Widget w) {
              if (metaBits.isNotEmpty) {
                metaBits.add(SizedBox(width: 1, height: s.rem(0.875), child: ColoredBox(color: t.fill3)));
              }
              metaBits.add(w);
            }
            if (avgScore != null) addMeta(EvScoreBadge(score: avgScore));
            if (totalMinutes > 0) addMeta(Text('共 ${formatHoursMinutes(totalMinutes)}', style: metaStyle));
            addMeta(Text('按上映顺序', style: metaStyle));

            final logo = !t.isPaper ? d.card.art.logo : null;
            final showLogo = logo != null && _failedLogoKey != logo.cacheKey;
            final wordmark = Text(
              d.displayName,
              key: const Key('ev_collection_wordmark'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.displayStyle(
                s.rem(t.isPaper ? 4.5 : 4.75),
                color: t.ink,
                height: t.isPaper ? 1.12 : 1.06,
              ),
            );
            final titleArt = showLogo
                ? SizedBox(
                    height: s.rem(11),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: s.rem(32), maxHeight: s.rem(11)),
                        child: Stack(
                          alignment: Alignment.bottomLeft,
                          children: [
                            ExcludeSemantics(
                              child: IgnorePointer(
                                child: Transform.translate(
                                  offset: Offset(0, s.rem(0.35)),
                                  child: ImageFiltered(
                                    imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                    child: ColorFiltered(
                                      colorFilter: const ColorFilter.mode(
                                        Color.fromRGBO(0, 0, 0, 0.40),
                                        BlendMode.srcIn,
                                      ),
                                      child: Image(
                                        image: logo.image,
                                        fit: BoxFit.contain,
                                        alignment: Alignment.bottomLeft,
                                        gaplessPlayback: true,
                                        filterQuality: FilterQuality.low,
                                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Image(
                              key: ValueKey<String>('ev_collection_logo_${logo.cacheKey}'),
                              image: logo.image,
                              fit: BoxFit.contain,
                              alignment: Alignment.bottomLeft,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, _, _) {
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (mounted && _failedLogoKey != logo.cacheKey) {
                                    setState(() => _failedLogoKey = logo.cacheKey);
                                  }
                                });
                                return wordmark;
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: s.rem(11)),
                    child: Align(alignment: Alignment.bottomLeft, child: wordmark),
                  );

            final barWidth = math.min(items.length * s.rem(2.5), s.rem(24));
            final segActive = t.isPaper ? const Color(0xFFD97757) : t.ink;
            final segHalfTrack = t.isPaper ? const Color.fromRGBO(255, 255, 255, 0.30) : t.fill3;

            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: s.gutter,
                  bottom: s.rem(2.25),
                  width: infoW,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      EvGlass(
                        key: const Key('ev_collection_status_pill'),
                        borderRadius: BorderRadius.circular(999),
                        padding: EdgeInsets.fromLTRB(s.rem(0.3125), 0, s.rem(1), 0),
                        child: SizedBox(
                          height: s.rem(2.25),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: s.rem(1.625),
                                height: s.rem(1.625),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: t.isPaper ? const Color(0xFFC46686) : t.box,
                                ),
                                child: EvIcon(
                                  EvIcons.stack,
                                  size: s.rem(0.9375),
                                  color: t.isPaper ? Colors.white : const Color(0xFF09090B),
                                ),
                              ),
                              SizedBox(width: s.rem(0.5)),
                              Text('系列', style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: t.ink)),
                              SizedBox(width: s.rem(0.5)),
                              Flexible(
                                child: Text(
                                  [if (items.isNotEmpty) '${items.length} 部', if (yearSpan.isNotEmpty) yearSpan].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: t.ink3),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: s.rem(1.25)),
                      titleArt,
                      SizedBox(height: s.rem(1.25)),
                      Wrap(
                        key: const Key('ev_collection_meta'),
                        spacing: s.rem(0.875),
                        runSpacing: s.rem(0.5),
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: metaBits,
                      ),
                      if (d.card.overview?.trim().isNotEmpty ?? false) ...[
                        SizedBox(height: s.rem(1)),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: s.rem(38)),
                          child: Text(
                            d.card.overview!.trim(),
                            key: const Key('ev_collection_overview'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyStyle(s.font(1.125), color: t.ink2, height: 1.62),
                          ),
                        ),
                      ],
                      if (items.isNotEmpty) ...[
                        SizedBox(height: s.rem(1.25)),
                        Row(
                          key: const Key('ev_collection_progress'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: barWidth,
                              child: Row(
                                children: [
                                  for (var i = 0; i < items.length; i++) ...[
                                    if (i > 0) SizedBox(width: s.rem(0.25)),
                                    Expanded(
                                      child: Tooltip(
                                        message: items[i].card.title,
                                        child: Container(
                                          key: Key('ev_collection_seg_$i'),
                                          height: s.rem(0.375),
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(999),
                                            color: items[i].isDone
                                                ? segActive
                                                : items[i].isInProgress
                                                ? null
                                                : t.fill3,
                                            gradient: items[i].isInProgress
                                                ? LinearGradient(
                                                    colors: [segActive, segActive, segHalfTrack, segHalfTrack],
                                                    stops: const [0.0, 0.5, 0.5, 1.0],
                                                  )
                                                : null,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            SizedBox(width: s.rem(1)),
                            Text(
                              '看过 $seen / ${items.length} 部',
                              key: const Key('ev_collection_progress_text'),
                              style: t.bodyStyle(s.font(0.9375), color: t.ink2),
                            ),
                          ],
                        ),
                      ],
                      SizedBox(height: s.rem(1.5)),
                      Wrap(
                        spacing: s.rem(0.75),
                        runSpacing: s.rem(0.5),
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (next != null)
                            Builder(
                              builder: (btnCtx) => EvButton.primary(
                                key: const Key('ev_collection_play_btn'),
                                icon: EvIcons.play,
                                label: next.buttonLabel,
                                secondaryLabel: '· ${next.item.card.title}',
                                progress: next.item.isInProgress ? next.item.resumeFraction : null,
                                onPressed: () => _playPrimary(btnCtx, next),
                              ),
                            ),
                          if (next != null)
                            Builder(
                              builder: (btnCtx) => EvButton.ghost(
                                key: const Key('ev_collection_sequential_btn'),
                                icon: EvIcons.stack,
                                label: '按顺序连播',
                                onPressed: () => _playPrimary(btnCtx, next, sequential: true),
                              ),
                            ),
                          EvButton.ghost(
                            key: const Key('ev_collection_mark_all_btn'),
                            icon: EvIcons.check,
                            round: true,
                            tooltip: allDone ? '全部标为未看' : '全部标为已看',
                            onPressed: _savingAllPlayed || items.isEmpty ? null : () => unawaited(_toggleAllPlayed()),
                          ),
                        ],
                      ),
                      if (_actionError != null) ...[
                        SizedBox(height: s.rem(0.75)),
                        Text(
                          _actionError!,
                          style: t.bodyStyle(s.font(0.875), color: const Color(0xFFFF6B5A)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildOrderedSection(EvTheme t, EvScale s, CollectionDetail d, ValueChanged<String>? openItem) {
    final items = d.items;
    final horizontal = items.length > 6;
    return Padding(
      key: const Key('ev_collection_order_section'),
      padding: EdgeInsets.only(bottom: s.rem(2.5)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(s.gutter, 0, s.gutter, s.rem(0.25)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('按上映顺序', style: t.shelfStyle(s.font(1.5))),
                SizedBox(width: s.rem(0.75)),
                Text(
                  '${items.length} 部',
                  style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w500, color: t.ink3),
                ),
              ],
            ),
          ),
          if (horizontal)
            MouseRegion(
              onEnter: (_) => setState(() => _trackHovered = true),
              onExit: (_) => setState(() => _trackHovered = false),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      key: const Key('ev_collection_horizontal_track'),
                      controller: _trackScroll,
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      padding: EdgeInsets.fromLTRB(s.gutter, s.rem(1), s.gutter, s.rem(1.25)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) SizedBox(width: s.rem(1.25)),
                            SizedBox(
                              width: s.rem(22),
                              child: _EvCollectionFilmCard(
                                key: Key('ev_collection_film_${items[i].card.id}'),
                                index: i,
                                item: items[i],
                                onTap: openItem != null ? () => openItem(items[i].card.id) : null,
                                onHighlightChanged: (active) => _onFilmHighlight(items[i], active),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  EvShelfScrollbar(
                    controller: _trackScroll,
                    shelfHovered: _trackHovered,
                    margin: EdgeInsets.symmetric(horizontal: s.gutter),
                  ),
                ],
              ),
            )
          else
            Padding(
              key: const Key('ev_collection_grid'),
              padding: EdgeInsets.fromLTRB(s.gutter, s.rem(1), s.gutter, s.rem(1.25)),
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final maxW = constraints.maxWidth > 0 ? constraints.maxWidth : (s.size.width - s.gutter * 2);
                  final gapX = s.rem(1.75), gapY = s.rem(2.0), minCardW = s.rem(24);
                  final cols = math.max(1, ((maxW + gapX) / (minCardW + gapX)).floor());
                  final rows = (items.length / cols).ceil();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var r = 0; r < rows; r++) ...[
                        if (r > 0) SizedBox(height: gapY),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var c = 0; c < cols; c++) ...[
                              if (c > 0) SizedBox(width: gapX),
                              Expanded(
                                child: r * cols + c < items.length
                                    ? _EvCollectionFilmCard(
                                        key: Key('ev_collection_film_${items[r * cols + c].card.id}'),
                                        index: r * cols + c,
                                        item: items[r * cols + c],
                                        onTap: openItem != null ? () => openItem(items[r * cols + c].card.id) : null,
                                        onHighlightChanged: (active) => _onFilmHighlight(items[r * cols + c], active),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFactsSection(EvTheme t, EvScale s, CollectionDetail d) {
    final items = d.items;
    final years = [for (final x in items) if (x.card.year != null) x.card.year!];
    final yearText = years.isEmpty
        ? '—'
        : (years.reduce(math.min) == years.reduce(math.max)
            ? '${years.first}'
            : '${years.reduce(math.min)} – ${years.reduce(math.max)}');
    final totalMinutes = items.fold<int>(
      0,
      (sum, x) => sum + (x.card.duration != null ? x.card.duration!.inMinutes : 0),
    );
    final scores = [for (final x in items) if (x.card.score != null && x.card.score! > 0) x.card.score!];
    final avgText = scores.isEmpty ? '—' : '★ ${(scores.reduce((a, b) => a + b) / scores.length).toStringAsFixed(1)}';
    final base = t.bodyStyle(s.font(0.9375), color: t.ink, height: 1.5);
    final entries = <(String, String)>[
      ('部数', '${items.length} 部'),
      ('年代', yearText),
      ('总片长', totalMinutes > 0 ? formatHoursMinutes(totalMinutes) : '—'),
      ('平均评分', avgText),
      ('来源', 'Emby 合集「${d.rawName.isNotEmpty ? d.rawName : d.card.title}」'),
      ('排序', '按上映年份，同年按片名'),
    ];
    Widget row(String dt, String dd) => Container(
      padding: EdgeInsets.symmetric(vertical: s.rem(0.6875)),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: s.rem(5), child: Text(dt, style: t.bodyStyle(s.font(0.9375), color: t.ink3, height: 1.5))),
          SizedBox(width: s.rem(1.25)),
          Expanded(child: Text(dd, style: base)),
        ],
      ),
    );

    return Padding(
      key: const Key('ev_collection_facts'),
      padding: EdgeInsets.fromLTRB(s.gutter, 0, s.gutter, s.rem(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: EdgeInsets.only(bottom: s.rem(0.75)), child: Text('信息', style: t.shelfStyle(s.font(1.5)))),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: s.rem(64)),
            child: Column(
              children: [
                for (var i = 0; i < entries.length; i += 2)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: row(entries[i].$1, entries[i].$2)),
                      SizedBox(width: s.rem(3)),
                      Expanded(
                        child: i + 1 < entries.length
                            ? row(entries[i + 1].$1, entries[i + 1].$2)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EvCollectionFilmCard extends StatefulWidget {
  const _EvCollectionFilmCard({
    super.key,
    required this.index,
    required this.item,
    this.onTap,
    this.onHighlightChanged,
  });

  final int index;
  final CollectionItem item;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onHighlightChanged;

  @override
  State<_EvCollectionFilmCard> createState() => _EvCollectionFilmCardState();
}

class _EvCollectionFilmCardState extends State<_EvCollectionFilmCard> {
  bool _hovered = false, _focused = false;
  bool get _hi => _hovered || _focused;

  void _updateHighlight({bool? hovered, bool? focused}) {
    final prev = _hi;
    setState(() {
      if (hovered != null) _hovered = hovered;
      if (focused != null) _focused = focused;
    });
    if (_hi != prev) widget.onHighlightChanged?.call(_hi);
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final card = widget.item.card;
    final radius = BorderRadius.circular(s.rem(t.radius));
    final progress = widget.item.resumeFraction;
    final mins = card.duration?.inMinutes ?? 0;
    final meta = [
      if (card.year != null) '${card.year}',
      if (mins > 0) _EvCollectionPageState.formatHoursMinutes(mins),
      if (card.score != null && card.score! > 0) '★ ${card.score!.toStringAsFixed(1)}',
    ].join(' · ');

    final artOverlay = Stack(
      fit: StackFit.expand,
      children: [
        if (widget.item.isDone)
          Positioned(
            right: s.rem(0.5),
            top: s.rem(0.5),
            child: Container(
              width: s.rem(1.625),
              height: s.rem(1.625),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: t.isPaper ? t.brand : const Color.fromRGBO(0, 0, 0, 0.50),
                border: t.isPaper ? Border.all(color: const Color(0xFF141413), width: 1.25) : null,
              ),
              alignment: Alignment.center,
              child: EvIcon(
                EvIcons.check,
                size: s.rem(t.isPaper ? 1.0 : 0.875),
                color: t.isPaper ? const Color(0xFF141413) : Colors.white,
              ),
            ),
          )
        else if (progress != null && progress > 0)
          Positioned(
            left: s.rem(0.75),
            right: s.rem(0.75),
            bottom: s.rem(0.75),
            height: s.rem(0.25),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: ColoredBox(
                color: t.isPaper ? const Color.fromRGBO(255, 255, 255, 0.55) : const Color.fromRGBO(255, 255, 255, 0.30),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: ColoredBox(color: t.isPaper ? t.brand : Colors.white),
                  ),
                ),
              ),
            ),
          ),
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: _hi ? t.focusColor : t.line, width: _hi ? 1.5 : 1.0),
            ),
          ),
        ),
      ],
    );

    final shadows = _hi
        ? (t.isPaper
            ? [BoxShadow(offset: Offset(s.rem(0.5), s.rem(0.5)), color: t.movie)]
            : t.cardShadowHi)
        : t.cardShadow;

    return Semantics(
      button: true,
      label: '第 ${widget.index + 1} 部 ${card.title}',
      child: Focus(
        onFocusChange: (v) => _updateHighlight(focused: v),
        onKeyEvent: (_, event) {
          if (widget.onTap == null || !evIsActivateKey(event)) return KeyEventResult.ignored;
          widget.onTap!();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _updateHighlight(hovered: true),
          onExit: (_) => _updateHighlight(hovered: false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.index + 1}'.padLeft(2, '0'),
                  style: t.displayStyle(s.rem(3.5), color: _hi ? t.ink : t.ink4, height: 0.9).copyWith(
                    fontWeight: t.isPaper ? FontWeight.w500 : FontWeight.w800,
                    letterSpacing: s.rem(3.5) * -0.04,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                SizedBox(width: s.rem(1)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: EvDurations.medium,
                        curve: EvCurves.out,
                        decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
                        child: EvArtwork(
                          plan: card.art.landscape,
                          aspectRatio: 16 / 9,
                          overrideFit: BoxFit.cover,
                          borderRadius: radius,
                          overlay: artOverlay,
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.only(top: s.rem(0.75)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              card.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodyStyle(s.font(1.0625), fontWeight: FontWeight.w600, color: t.ink).copyWith(
                                decoration: t.isPaper && _hi ? TextDecoration.underline : TextDecoration.none,
                                decorationColor: t.brand,
                                decorationThickness: 2.0,
                              ),
                            ),
                            if (meta.isNotEmpty) ...[
                              SizedBox(height: s.rem(0.25)),
                              Text(
                                meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodyStyle(s.font(0.875), color: t.ink3),
                              ),
                            ],
                            if (card.overview?.trim().isNotEmpty ?? false) ...[
                              SizedBox(height: s.rem(0.5)),
                              Text(
                                card.overview!.trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodyStyle(s.font(0.875), color: t.ink2, height: 1.55),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
