import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_widgets.dart';

enum _PersonWorkSort { year, score }

/// Actor / director / crew detail page mirroring `vPerson` in `.spec/mockups/proto.js`.
class EvPersonPage extends StatefulWidget {
  const EvPersonPage({
    super.key,
    required this.personId,
    this.personName,
    this.roleHint,
    this.sourceItem,
    this.onOpenItem,
    this.onPlayTarget,
    this.now,
    this.birthdayLocalOffset,
  });

  final String personId;
  final String? personName;
  final String? roleHint;
  final MediaCard? sourceItem;
  final ValueChanged<String>? onOpenItem;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin)? onPlayTarget;
  final DateTime Function()? now;
  final Duration? birthdayLocalOffset;

  @override
  State<EvPersonPage> createState() => _EvPersonPageState();
}

class _EvPersonPageState extends State<EvPersonPage> {
  final _scroll = ScrollController();
  EvScope? _scope;
  EmbyViewData? _attachedData;
  String? _attachedSessionId;
  int _loadToken = 0;
  bool _loading = true;
  bool _bioExpanded = false;
  bool _portraitFailed = false;
  Object? _error;
  PersonDetail? _person;

  /// `'all'`, `'tv'`, or a [PersonWorkRole.name].
  String _filter = 'all';
  _PersonWorkSort _sort = _PersonWorkSort.year;
  Timer? _previewTimer;

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
        ..setMode(EvStageMode.person)
        ..setScrollProgress(0)
        ..setVeilLifted(false)
        ..clearPreviewBackdrop();
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(EvPersonPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.personId == widget.personId) return;
    _previewTimer?.cancel();
    _filter = 'all';
    _sort = _PersonWorkSort.year;
    _bioExpanded = false;
    _portraitFailed = false;
    if (_scroll.hasClients && _scroll.offset != 0) _scroll.jumpTo(0);
    unawaited(_load());
  }

  Future<void> _load() async {
    final scope = _scope, data = scope?.services.data, id = widget.personId, token = ++_loadToken;
    _previewTimer?.cancel();
    _filter = 'all';
    _sort = _PersonWorkSort.year;
    _bioExpanded = false;
    _portraitFailed = false;
    if (scope == null || data == null) {
      if (mounted) setState(() { _loading = false; _error = null; });
      return;
    }
    if (mounted) setState(() { _loading = true; _error = null; _person = null; });
    try {
      final loaded = await data.person(
        id,
        name: widget.personName,
        roleHint: widget.roleHint,
        sourceItem: widget.sourceItem,
      );
      if (!mounted || token != _loadToken) return;
      setState(() {
        _person = loaded;
        _loading = false;
        _error = null;
      });
      _applyTopBackdrop(loaded);
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _applyTopBackdrop(PersonDetail person) {
    final stage = _scope?.stage;
    if (stage == null) return;
    final ranked = [...person.works]
      ..sort((a, b) => (b.card.score ?? 0).compareTo(a.card.score ?? 0));
    ArtworkPlan? plan;
    for (final w in ranked) {
      if (w.card.art.backdrops.isNotEmpty) {
        plan = ArtworkPlan(
          layers: [ArtworkLayer(source: w.card.art.backdrops.first, fit: ArtworkFit.cover)],
          fallbackTitle: w.card.title,
        );
        break;
      }
    }
    stage
      ..setMode(EvStageMode.person)
      ..setScrollProgress(0)
      ..setVeilLifted(false)
      ..clearPreviewBackdrop()
      ..setBaseBackdrop(plan);
  }

  void _onScroll() {
    if (_scope == null || !_scroll.hasClients) return;
    _scope!.shell.setScrollOffset(_scroll.position.pixels);
  }

  void _onWorkHighlight(MediaCard card, bool active) {
    _previewTimer?.cancel();
    if (!active) return;
    _previewTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final backdrop = card.art.backdrops.firstOrNull;
      final stage = _scope?.stage;
      if (backdrop != null && stage != null) {
        stage
          ..setMode(EvStageMode.person)
          ..setBaseBackdrop(
            ArtworkPlan(
              layers: [ArtworkLayer(source: backdrop, fit: ArtworkFit.cover)],
              fallbackTitle: card.title,
            ),
          );
      }
    });
  }

  void _openWork(MediaCard card) {
    if (widget.onOpenItem != null) {
      widget.onOpenItem!(card.id);
      return;
    }
    _scope?.shell.openCard(card);
  }

  void _playWork(MediaCard card) {
    final target = PlayTarget(itemId: card.id);
    if (widget.onPlayTarget != null) {
      widget.onPlayTarget!(target, card.art, null);
      return;
    }
    unawaited(EvPlayer.open(context, target, art: card.art));
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return ScrollConfiguration(
      key: const Key('ev_person_page'),
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        key: const Key('ev_person_scroller'),
        controller: _scroll,
        child: _buildBody(t, s),
      ),
    );
  }

  Widget _buildBody(EvTheme t, EvScale s) {
    final p = _person;
    if (_error != null && p == null) {
      return SizedBox(
        height: math.max(0.0, s.vh(100)),
        child: Center(
          child: Padding(
            key: const Key('ev_person_error'),
            padding: EdgeInsets.symmetric(horizontal: s.gutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('无法加载人物资料', style: t.shelfStyle(s.font(1.5))),
                SizedBox(height: s.rem(0.75)),
                Text(
                  _error is EmbyViewFailure ? (_error as EmbyViewFailure).reason : '$_error',
                  style: t.bodyStyle(s.font(0.9375), color: t.ink3),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: s.rem(1.5)),
                EvButton.ghost(
                  key: const Key('ev_person_retry_btn'),
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
    if (_loading && p == null) {
      return Column(
        key: const Key('ev_person_loading'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: math.max(0.0, s.vh(52))),
          const EvShelfSkeleton(style: EvCardStyle.poster, count: 6),
        ],
      );
    }
    if (p == null) {
      return SizedBox(
        height: math.max(0.0, s.vh(100)),
        child: Center(child: Text('未找到人物信息', style: t.shelfStyle(s.font(1.25)))),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(t, s, p),
        _buildWorksSection(t, s, p),
      ],
    );
  }

  Widget _buildHeader(EvTheme t, EvScale s, PersonDetail p) {
    final displayName = p.name.trim().isNotEmpty ? p.name.trim() : (widget.personName?.trim() ?? '');
    final initial = displayName.isNotEmpty ? displayName.substring(0, 1) : '?';
    final roleLabel = personIdentityLabel(p);
    final birthText = p.birthDateUtc != null
        ? formatPersonBirthDate(
            p.birthDateUtc!,
            now: widget.now?.call(),
            localOffset: widget.birthdayLocalOffset,
          )
        : '';
    final place = p.birthPlace?.trim() ?? '';
    final facts = [if (birthText.isNotEmpty) birthText, if (place.isNotEmpty) place];

    final works = p.works;
    final seenCount = works.where((w) => w.card.played == true).length;
    final years = [for (final w in works) if (w.card.year != null) w.card.year!];
    final yearSpan = years.isEmpty
        ? null
        : (years.reduce(math.min) == years.reduce(math.max)
            ? '${years.first}'
            : '${years.reduce(math.min)}–${years.reduce(math.max)}');

    final portRadius = BorderRadius.circular(s.rem(t.isPaper ? 0.5 : 1.25));
    final portShadows = t.isPaper
        ? [BoxShadow(offset: Offset(s.rem(0.625), s.rem(0.625)), color: const Color(0xFFD97757))]
        : [BoxShadow(offset: Offset(0, s.rem(1.5)), blurRadius: s.rem(4), color: const Color.fromRGBO(0, 0, 0, 0.45))];

    final portrait = Container(
      key: const Key('ev_person_portrait'),
      width: s.rem(17),
      decoration: BoxDecoration(
        color: t.fill2,
        borderRadius: portRadius,
        border: Border.all(
          color: t.isPaper ? const Color(0xFF141413) : t.line,
          width: t.isPaper ? 1.5 : 1.0,
        ),
        boxShadow: portShadows,
      ),
      child: ClipRRect(
        borderRadius: portRadius,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: p.portrait != null && !_portraitFailed
              ? Image(
                  image: p.portrait!.image,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && !_portraitFailed) setState(() => _portraitFailed = true);
                    });
                    return Center(
                      child: Text(initial, style: t.displayStyle(s.rem(6), color: t.ink3)),
                    );
                  },
                )
              : Center(
                  child: Text(
                    initial,
                    key: const Key('ev_person_portrait_fallback'),
                    style: t.displayStyle(s.rem(6), color: t.ink3),
                  ),
                ),
        ),
      ),
    );

    Widget stat(String value, String label) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: t.displayStyle(s.rem(2), color: t.ink, height: 1.1).copyWith(
            fontWeight: t.isPaper ? FontWeight.w500 : FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(label, style: t.bodyStyle(s.font(0.875), color: t.ink3)),
      ],
    );

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: math.max(0.0, s.vh(68))),
      child: Padding(
        key: const Key('ev_person_header'),
        padding: EdgeInsets.fromLTRB(s.gutter, s.rem(8.5), s.gutter, s.rem(2.5)),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              portrait,
              SizedBox(width: s.rem(3.5)),
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: s.rem(50)),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: s.rem(0.5)),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          roleLabel,
                          key: const Key('ev_person_role'),
                          style: t.bodyStyle(
                            s.font(0.9375),
                            fontWeight: FontWeight.w700,
                            color: t.isPaper ? const Color(0xFFB5532F) : t.ink3,
                          ).copyWith(letterSpacing: s.font(0.9375) * 0.12),
                        ),
                        SizedBox(height: s.rem(0.5)),
                        Text(
                          displayName,
                          key: const Key('ev_person_name'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.displayStyle(s.rem(4.5), color: t.ink, height: 1.05),
                        ),
                        if (facts.isNotEmpty) ...[
                          SizedBox(height: s.rem(1)),
                          Wrap(
                            key: const Key('ev_person_facts'),
                            spacing: s.rem(0.875),
                            runSpacing: s.rem(0.375),
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              for (var i = 0; i < facts.length; i++) ...[
                                if (i > 0) SizedBox(width: 1, height: s.rem(0.875), child: ColoredBox(color: t.fill3)),
                                Text(facts[i], style: t.bodyStyle(s.font(1.0625), color: t.ink2)),
                              ],
                            ],
                          ),
                        ],
                        SizedBox(height: s.rem(1.5)),
                        Wrap(
                          key: const Key('ev_person_stats'),
                          spacing: s.rem(2.5),
                          runSpacing: s.rem(0.75),
                          children: [
                            stat('${works.length}', '部在片库里'),
                            stat('$seenCount', '部看过'),
                            if (yearSpan != null) stat(yearSpan, '作品年代'),
                          ],
                        ),
                        SizedBox(height: s.rem(1.5)),
                        _buildBio(t, s, p.overview),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBio(EvTheme t, EvScale s, String? overview) {
    final text = overview?.trim() ?? '';
    if (text.isEmpty) {
      return Text(
        'Emby 里没有这位的简介。',
        key: const Key('ev_person_bio_empty'),
        style: t.bodyStyle(s.font(1.0), color: t.ink3),
      );
    }
    final style = t.bodyStyle(s.font(1.0), color: t.ink2, height: 1.7);
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final maxW = constraints.hasBoundedWidth && constraints.maxWidth > 0 ? constraints.maxWidth : s.rem(50);
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 3,
          textDirection: Directionality.of(ctx),
          textScaler: MediaQuery.textScalerOf(ctx),
        )..layout(maxWidth: maxW);
        final overflows = painter.didExceedMaxLines;
        return Column(
          key: const Key('ev_person_bio'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              maxLines: _bioExpanded ? null : 3,
              overflow: _bioExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: style,
            ),
            if (overflows || _bioExpanded) ...[
              SizedBox(height: s.rem(0.5)),
              EvInteractive(
                key: const Key('ev_person_bio_toggle'),
                label: _bioExpanded ? '收起简介' : '展开全部简介',
                onTap: () => setState(() => _bioExpanded = !_bioExpanded),
                builder: (_, hovered, _) => Text(
                  _bioExpanded ? '收起' : '展开全部',
                  style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: t.ink).copyWith(
                    decoration: hovered ? TextDecoration.underline : TextDecoration.none,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildWorksSection(EvTheme t, EvScale s, PersonDetail p) {
    final works = p.works;
    final kinds = personWorkFilterKinds(works);
    final hasSeries =
        works.any((w) => w.card.kind == MediaKind.series) &&
        works.any((w) => w.card.kind != MediaKind.series);
    final activeRole = PersonWorkRole.values.where((r) => r.name == _filter).firstOrNull;

    var filtered = works.where((w) {
      if (_filter == 'all') return true;
      if (_filter == 'tv') return w.card.kind == MediaKind.series;
      return activeRole != null && w.hasRole(activeRole);
    }).toList();
    filtered.sort((a, b) {
      if (_sort == _PersonWorkSort.score) {
        final sc = (b.card.score ?? 0).compareTo(a.card.score ?? 0);
        if (sc != 0) return sc;
      }
      final yr = (b.card.year ?? 0).compareTo(a.card.year ?? 0);
      if (yr != 0) return yr;
      return a.card.title.compareTo(b.card.title);
    });

    return Padding(
      key: const Key('ev_person_works'),
      padding: EdgeInsets.only(bottom: s.rem(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(s.gutter, 0, s.gutter, s.rem(0.75)),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: s.rem(1),
              runSpacing: s.rem(0.75),
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('在你的片库里', style: t.shelfStyle(s.font(1.5))),
                    SizedBox(width: s.rem(0.75)),
                    Text(
                      '${works.length} 部',
                      style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w500, color: t.ink3),
                    ),
                  ],
                ),
                Wrap(
                  spacing: s.rem(1),
                  runSpacing: s.rem(0.5),
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Wrap(
                      key: const Key('ev_person_filter_chips'),
                      spacing: s.rem(0.5),
                      runSpacing: s.rem(0.5),
                      children: [
                        EvSettingsChip(
                          key: const Key('ev_person_filter_all'),
                          label: '全部',
                          count: works.length,
                          selected: _filter == 'all',
                          onTap: () => setState(() => _filter = 'all'),
                        ),
                        if (kinds.length > 1)
                          for (final k in kinds)
                            EvSettingsChip(
                              key: Key('ev_person_filter_${k.name}'),
                              label: personRoleFilterLabel(k),
                              count: works.where((w) => w.hasRole(k)).length,
                              selected: _filter == k.name,
                              onTap: () => setState(() => _filter = k.name),
                            ),
                        if (hasSeries)
                          EvSettingsChip(
                            key: const Key('ev_person_filter_tv'),
                            label: '剧集',
                            count: works.where((w) => w.card.kind == MediaKind.series).length,
                            selected: _filter == 'tv',
                            onTap: () => setState(() => _filter = 'tv'),
                          ),
                      ],
                    ),
                    EvSegmentedControl<_PersonWorkSort>(
                      value: _sort,
                      onChanged: (v) => setState(() => _sort = v),
                      options: const [
                        EvSegmentOption(
                          key: Key('ev_person_sort_year'),
                          value: _PersonWorkSort.year,
                          label: '按年份',
                        ),
                        EvSegmentOption(
                          key: Key('ev_person_sort_score'),
                          value: _PersonWorkSort.score,
                          label: '按评分',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (filtered.isEmpty)
            Padding(
              key: const Key('ev_person_works_empty'),
              padding: EdgeInsets.fromLTRB(s.gutter, s.rem(2), s.gutter, 0),
              child: Text(
                works.isNotEmpty ? '这一类没有作品' : '片库里还没有这位的其他作品',
                style: t.bodyStyle(s.font(1.0), color: t.ink3),
              ),
            )
          else
            Padding(
              key: const Key('ev_person_works_grid'),
              padding: EdgeInsets.fromLTRB(s.gutter, s.rem(1), s.gutter, 0),
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final avail = constraints.maxWidth > 0 ? constraints.maxWidth : (s.size.width - s.gutter * 2);
                  final gap = s.rem(1.25), runGap = s.rem(1.75), minW = s.rem(10.5);
                  final cols = math.max(1, ((avail + gap) / (minW + gap)).floor());
                  final cardW = math.max(1.0, (avail - (cols - 1) * gap) / cols);
                  return Wrap(
                    spacing: gap,
                    runSpacing: runGap,
                    children: [
                      for (final w in filtered)
                        EvCard(
                          key: ValueKey<String>('ev_person_work_${w.card.id}'),
                          card: w.card,
                          style: EvCardStyle.poster,
                          width: cardW,
                          posterHeight: cardW * 1.5,
                          alwaysShowLabel: true,
                          subtitle: formatPersonWorkSubtitle(w, activeFilter: activeRole),
                          onTap: () => _openWork(w.card),
                          onPlay: () => _playWork(w.card),
                          onHoverChanged: (hovered) => _onWorkHighlight(w.card, hovered),
                          onFocusChanged: (focused) => _onWorkHighlight(w.card, focused),
                        ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
