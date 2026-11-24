import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Value equality for [WallScope] (contracts do not override `==`).
bool evSameWallScope(WallScope a, WallScope b) => switch ((a, b)) {
  (ZoneWallScope(zoneId: final x), ZoneWallScope(zoneId: final y)) => x == y,
  (FeatureWallScope(feature: final x), FeatureWallScope(feature: final y)) => x == y,
  _ => false,
};

/// Value equality for [YearRange] (contracts do not override `==`).
bool evSameYearRange(YearRange? a, YearRange? b) => a?.from == b?.from && a?.to == b?.to;

/// Value equality for [WallQuery] records.
bool evSameWallQuery(WallQuery a, WallQuery b) =>
    evSameWallScope(a.scope, b.scope) &&
    a.sort == b.sort &&
    a.watched == b.watched &&
    a.genreId == b.genreId &&
    evSameYearRange(a.years, b.years) &&
    a.technology == b.technology;

/// Active non-default filter count displayed on the wall filter trigger badge.
int evWallActiveFilterCount(WallQuery q) =>
    (q.watched != WatchFilter.all ? 1 : 0) +
    (q.genreId != null ? 1 : 0) +
    (q.years != null ? 1 : 0) +
    (q.technology != null ? 1 : 0);

/// Pill chip mirroring `.chip` / `.pop .chip` in `.spec/mockups/proto.css`.
class EvWallChip extends StatefulWidget {
  const EvWallChip({
    super.key, required this.label, this.count, this.selected = false,
    this.compact = false, this.dimmed = false, this.removable = false, this.onTap,
  });

  final String label;
  final int? count;
  final bool selected, compact, dimmed, removable;
  final VoidCallback? onTap;

  @override
  State<EvWallChip> createState() => _EvWallChipState();
}

class _EvWallChipState extends State<EvWallChip> {
  bool _hovered = false, _focused = false, _pressed = false;
  bool get _hi => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final bg = widget.selected
        ? theme.indBg
        : _hi
        ? theme.fill2
        : (theme.isPaper ? const Color(0xFFFFFFFF) : theme.fill);
    final fg = widget.selected ? theme.indFg : (_hi ? theme.ink : theme.ink2);

    return Semantics(
      button: true, selected: widget.selected, focused: _focused, label: widget.label,
      child: Focus(
        canRequestFocus: widget.onTap != null,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (_, e) {
          if (widget.onTap == null || !evIsActivateKey(e)) return KeyEventResult.ignored;
          widget.onTap!();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() { _hovered = false; _pressed = false; }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _pressed ? 0.95 : 1.0,
              duration: const Duration(milliseconds: 300), curve: EvCurves.spring,
              child: Opacity(
                opacity: widget.dimmed && !widget.selected ? 0.40 : 1.0,
                child: AnimatedContainer(
                  duration: EvDurations.fast, curve: EvCurves.soft,
                  height: scale.rem(widget.compact ? 2.0 : 2.375),
                  padding: EdgeInsets.symmetric(horizontal: scale.rem(widget.compact ? 0.75 : 1.0625)),
                  decoration: BoxDecoration(
                    color: bg, borderRadius: BorderRadius.circular(999),
                    border: _focused
                        ? Border.all(color: theme.focusColor, width: 1.5)
                        : (widget.selected ? null : Border.all(color: theme.line, width: 1)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.label, maxLines: 1,
                        style: theme.bodyStyle(scale.font(widget.compact ? 0.875 : 0.9375), fontWeight: FontWeight.w500, color: fg),
                      ),
                      if (widget.count != null) ...[
                        SizedBox(width: scale.rem(0.375)),
                        Text(
                          '${widget.count}',
                          style: theme
                              .bodyStyle(scale.font(0.8125), fontWeight: FontWeight.w500, color: fg.withValues(alpha: fg.a * 0.55))
                              .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ],
                      if (widget.removable) ...[
                        SizedBox(width: scale.rem(0.375)),
                        EvIcon(EvIcons.x, size: scale.rem(0.75), color: fg.withValues(alpha: fg.a * 0.65)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sort & filter popover rendered strictly from [WallFacets] (no hardcoded options),
/// mirroring `.pop.glass.filterpop` in `.spec/mockups/proto.css` and `proto.js`.
class EvWallFilterPopover extends StatelessWidget {
  const EvWallFilterPopover({
    super.key, required this.current, required this.facets,
    required this.onChanged, required this.onReset, required this.onClose,
    this.totalCount, this.unit = '部', this.loading = false,
  });

  final WallQuery current;
  final WallFacets facets;
  final ValueChanged<WallQuery> onChanged;
  final VoidCallback onReset, onClose;
  final int? totalCount;
  final String unit;
  final bool loading;

  static const Object _keep = Object();

  WallQuery _patch({
    WallSort? sort, WatchFilter? watched,
    Object? genreId = _keep, Object? years = _keep, Object? technology = _keep,
  }) => (
    scope: current.scope,
    sort: sort ?? current.sort,
    watched: watched ?? current.watched,
    genreId: identical(genreId, _keep) ? current.genreId : genreId as String?,
    years: identical(years, _keep) ? current.years : years as YearRange?,
    technology: identical(technology, _keep) ? current.technology : technology as TechFilter?,
  );

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final hasAny = facets.sorts.isNotEmpty || facets.watched.isNotEmpty ||
        facets.genres.isNotEmpty || facets.years.isNotEmpty || facets.technologies.isNotEmpty;

    return SizedBox(
      width: scale.rem(29.0),
      child: EvGlass(
        key: const Key('ev_wall_filter_popover'),
        borderRadius: BorderRadius.circular(scale.rem(1.0)),
        padding: EdgeInsets.all(scale.rem(0.375)),
        child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: scale.vh(68)),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (loading && !hasAny)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: scale.rem(0.75), vertical: scale.rem(1.25)),
                          child: Text('正在加载筛选项…', style: theme.bodyStyle(scale.font(0.9375), color: theme.ink3)),
                        ),
                      if (facets.sorts.isNotEmpty)
                        _section(context, '排序', [
                          for (final o in facets.sorts)
                            EvWallChip(
                              key: Key('ev_wall_facet_sort_${o.value.name}'), label: o.label, count: o.count,
                              compact: true, selected: current.sort == o.value,
                              onTap: () => onChanged(_patch(sort: o.value)),
                            ),
                        ]),
                      if (facets.watched.isNotEmpty)
                        _section(context, '观看状态', [
                          for (final o in facets.watched)
                            EvWallChip(
                              key: Key('ev_wall_facet_watched_${o.value.name}'), label: o.label, count: o.count,
                              compact: true, selected: current.watched == o.value, dimmed: o.count == 0,
                              onTap: () => onChanged(_patch(
                                watched: current.watched == o.value && o.value != WatchFilter.all
                                    ? WatchFilter.all
                                    : o.value,
                              )),
                            ),
                        ]),
                      if (facets.genres.isNotEmpty)
                        _section(context, '类型', [
                          for (final o in facets.genres)
                            EvWallChip(
                              key: Key('ev_wall_facet_genre_${o.value}'), label: o.label, count: o.count,
                              compact: true, selected: current.genreId == o.value, dimmed: o.count == 0,
                              onTap: () => onChanged(_patch(genreId: current.genreId == o.value ? null : o.value)),
                            ),
                        ]),
                      if (facets.years.isNotEmpty)
                        _section(context, '年份', [
                          for (final o in facets.years)
                            EvWallChip(
                              key: Key('ev_wall_facet_year_${o.value.from ?? ''}_${o.value.to ?? ''}'),
                              label: o.label, count: o.count, compact: true,
                              selected: evSameYearRange(current.years, o.value), dimmed: o.count == 0,
                              onTap: () => onChanged(_patch(years: evSameYearRange(current.years, o.value) ? null : o.value)),
                            ),
                        ]),
                      if (facets.technologies.isNotEmpty)
                        _section(context, '画质 / 音轨', [
                          for (final o in facets.technologies)
                            EvWallChip(
                              key: Key('ev_wall_facet_tech_${o.value.name}'), label: o.label, count: o.count,
                              compact: true, selected: current.technology == o.value, dimmed: o.count == 0,
                              onTap: () => onChanged(_patch(technology: current.technology == o.value ? null : o.value)),
                            ),
                        ]),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              margin: EdgeInsets.only(top: scale.rem(0.5)),
              padding: EdgeInsets.fromLTRB(scale.rem(0.75), scale.rem(0.75), scale.rem(0.75), scale.rem(0.375)),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.line, width: 1))),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  EvButton.ghost(key: const Key('ev_wall_popover_reset'), small: true, glass: false, label: '清除', onPressed: onReset),
                  EvButton.primary(
                    key: const Key('ev_wall_popover_close'), small: true,
                    label: totalCount != null ? '显示 ${evFormatCount(totalCount!)} $unit' : '完成',
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), fs = scale.font(0.8125);
    return Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(scale.rem(0.75), scale.rem(0.75), scale.rem(0.75), scale.rem(0.25)),
          child: Text(title, style: theme.bodyStyle(fs, fontWeight: FontWeight.w600, color: theme.ink3).copyWith(letterSpacing: fs * 0.04)),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(scale.rem(0.75), scale.rem(0.25), scale.rem(0.75), scale.rem(0.5)),
          child: Wrap(spacing: scale.rem(0.375), runSpacing: scale.rem(0.375), children: children),
        ),
      ],
    );
  }
}
