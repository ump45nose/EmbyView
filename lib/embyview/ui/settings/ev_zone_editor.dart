import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_widgets.dart';

enum _ZoneRuleKind { genre, technology, library }

/// Standalone overlay for creating or editing a zone, mirroring `.zedit` in
/// `.spec/mockups/proto.css` and `proto.js`. Reusable by settings & ⌘K palette.
class EvZoneEditorOverlay extends StatefulWidget {
  const EvZoneEditorOverlay({
    super.key, this.initialZone, this.facets, this.loadFacets,
    this.zoneTotal, this.zoneUnit = '部', this.onSave, this.onDelete, required this.onClose,
  });

  final ZonePreference? initialZone;
  final ZoneFacets? facets;
  final Future<ZoneFacets> Function()? loadFacets;
  final int? zoneTotal;
  final String zoneUnit;
  final FutureOr<void> Function(ZonePreference zone)? onSave;
  final FutureOr<void> Function(String zoneId)? onDelete;
  final VoidCallback onClose;

  @override State<EvZoneEditorOverlay> createState() => _EvZoneEditorOverlayState();
}

class _EvZoneEditorOverlayState extends State<EvZoneEditorOverlay> {
  late final _nameController = TextEditingController(text: widget.initialZone?.name ?? '');
  final _scopeNode = FocusScopeNode(debugLabel: 'ev_zone_editor_scope');
  late String _iconKey = widget.initialZone?.iconKey ?? EvIcons.star.key;
  late int _colorSlot = (widget.initialZone?.colorSlot ?? 4) % 7;
  late ZoneRule? _rule = widget.initialZone?.rule;
  late _ZoneRuleKind _ruleKind = switch (widget.initialZone?.rule) {
    TechnologyZoneRule() => _ZoneRuleKind.technology,
    LibraryZoneRule() => _ZoneRuleKind.library,
    _ => _ZoneRuleKind.genre,
  };
  ZoneFacets? _facets;
  bool _loadingFacets = false, _submitting = false, _facetsRequested = false;
  String? _facetsError, _submitError;

  bool get _isNew => widget.initialZone == null;
  bool get _isBuiltInLibrary => !_isNew && !widget.initialZone!.custom && widget.initialZone!.rule is LibraryZoneRule;

  @override
  void initState() {
    super.initState();
    if (widget.facets != null) { _facets = widget.facets; _facetsRequested = true; _ensureRuleFromFacets(widget.facets!); }
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && !_scopeNode.hasFocus) _scopeNode.requestFocus(); });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_facetsRequested) { _facetsRequested = true; unawaited(_fetchFacets()); }
  }

  @override void dispose() { _nameController.dispose(); _scopeNode.dispose(); super.dispose(); }

  Future<void> _fetchFacets() async {
    final loader = widget.loadFacets ?? EvScope.maybeOf(context)?.services.data?.customZoneFacets;
    if (loader == null) { setState(() { _facets = const ZoneFacets(); _loadingFacets = false; }); return; }
    setState(() { _loadingFacets = true; _facetsError = null; });
    try {
      final loaded = await loader();
      if (mounted) setState(() { _facets = loaded; _loadingFacets = false; _ensureRuleFromFacets(loaded); });
    } catch (e) {
      if (mounted) setState(() { _loadingFacets = false; _facetsError = e is EmbyViewFailure ? e.reason : '无法读取筛选条件，请重试。'; });
    }
  }

  List<_ZoneRuleKind> _availableKinds(ZoneFacets f) => [
    if (f.genres.isNotEmpty) _ZoneRuleKind.genre,
    if (f.technologies.isNotEmpty) _ZoneRuleKind.technology,
    if (f.libraries.isNotEmpty) _ZoneRuleKind.library,
  ];

  void _ensureRuleFromFacets(ZoneFacets f) {
    if (_isBuiltInLibrary) return;
    final kinds = _availableKinds(f);
    if (kinds.isEmpty) return;
    if (!kinds.contains(_ruleKind)) _ruleKind = kinds.first;
    _rule ??= _defaultRuleFor(_ruleKind, f);
  }

  ZoneRule? _defaultRuleFor(_ZoneRuleKind k, ZoneFacets f) => switch (k) {
    _ZoneRuleKind.genre => f.genres.isEmpty ? null : ZoneRule.genre(f.genres.first.value),
    _ZoneRuleKind.technology => f.technologies.isEmpty ? null : ZoneRule.technology(f.technologies.first.value),
    _ZoneRuleKind.library => f.libraries.isEmpty ? null : ZoneRule.library(f.libraries.first.value),
  };

  String _defaultNameFor(ZoneRule rule) => switch (rule) {
    GenreZoneRule(:final genreId) => _facets?.genres.where((o) => o.value == genreId).firstOrNull?.label ?? genreId,
    TechnologyZoneRule(:final technology) => _facets?.technologies.where((o) => o.value == technology).firstOrNull?.label ?? evTechFilterLabel(technology),
    LibraryZoneRule(:final libraryId) => _facets?.libraries.where((o) => o.value == libraryId).firstOrNull?.label ?? libraryId,
  };

  Future<void> _submit(FutureOr<void> Function() fn, String fallback) async {
    setState(() { _submitting = true; _submitError = null; });
    try { await fn(); if (mounted) widget.onClose(); } catch (e) {
      if (mounted) setState(() { _submitting = false; _submitError = e is EmbyViewFailure ? e.reason : fallback; });
    }
  }

  void _save() {
    final rule = _rule;
    if (rule == null || _submitting) return;
    final saver = widget.onSave ?? EvScope.maybeOf(context)?.services.preferences.saveZone;
    if (saver == null) { widget.onClose(); return; }
    final trimmed = _nameController.text.trim();
    final zone = ZonePreference(
      id: widget.initialZone?.id ?? 'z_${DateTime.now().microsecondsSinceEpoch}',
      name: trimmed.isNotEmpty ? trimmed : _defaultNameFor(rule),
      iconKey: _iconKey, colorSlot: _colorSlot, rule: rule, custom: widget.initialZone?.custom ?? true,
    );
    unawaited(_submit(() => saver(zone), '保存分区失败，请重试。'));
  }

  void _delete() {
    final init = widget.initialZone;
    if (init == null || !init.custom || _submitting) return;
    final deleter = widget.onDelete ?? EvScope.maybeOf(context)?.services.preferences.removeCustomZone;
    if (deleter == null) { widget.onClose(); return; }
    unawaited(_submit(() => deleter(init.id), '删除分区失败，请重试。'));
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), c = t.zoneColor(_colorSlot);
    final bg = t.isPaper ? const Color.fromRGBO(250, 249, 245, 0.60) : const Color.fromRGBO(0, 0, 0, 0.45);
    Widget lbl(String text) => Padding(padding: EdgeInsets.only(top: s.rem(1.25), bottom: s.rem(0.5)),
      child: Text(text, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w600, color: t.ink3)));

    return FocusScope(
      node: _scopeNode, autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) { widget.onClose(); return KeyEventResult.handled; }
        return KeyEventResult.ignored;
      },
      child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: GestureDetector(key: const Key('ev_zone_editor_scrim'), behavior: HitTestBehavior.opaque, onTap: widget.onClose, child: ColoredBox(color: bg))),
        Center(child: LayoutBuilder(builder: (_, box) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.min(s.rem(40.0), box.maxWidth * 0.90), maxHeight: box.maxHeight * 0.88),
          child: Container(
            key: const Key('ev_zone_editor_dialog'),
            decoration: BoxDecoration(color: t.glassSolid, borderRadius: BorderRadius.circular(s.rem(1.5)),
              border: Border.all(color: t.glassBorder, width: 1),
              boxShadow: const [BoxShadow(offset: Offset(0, 24), blurRadius: 64, color: Color.fromRGBO(0, 0, 0, 0.45))]),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(s.rem(1.75)),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  AnimatedContainer(
                    duration: EvDurations.normal, curve: EvCurves.soft, width: s.rem(3.25), height: s.rem(3.25), padding: EdgeInsets.all(s.rem(0.6875)),
                    decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(s.rem(0.875))),
                    child: EvIcon(EvIcons.byKey(_iconKey), size: s.rem(1.875), color: c, accentColor: c),
                  ),
                  SizedBox(width: s.rem(0.875)),
                  Expanded(child: Text(_isNew ? '添加分区' : '编辑分区', style: t.displayStyle(s.font(1.75)))),
                ]),
                lbl('名字'),
                EvSettingsTextField(key: const Key('ev_zone_name_input'), controller: _nameController,
                  placeholder: '比如：科幻、杜比视界', maxLength: 16, accentColor: c, onSubmitted: (_) => _save()),
                lbl('图标'),
                GridView.builder(
                  shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: EvIcons.zoneIcons.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 10, mainAxisSpacing: s.rem(0.375), crossAxisSpacing: s.rem(0.375)),
                  itemBuilder: (_, i) {
                    final icon = EvIcons.zoneIcons[i], sel = _iconKey == icon.key;
                    return EvInteractive(
                      key: Key('ev_zone_icon_${icon.key}'), selected: sel, label: icon.key, onTap: () => setState(() => _iconKey = icon.key),
                      builder: (_, hovered, focused) => AnimatedScale(
                        scale: (hovered || focused) ? 1.08 : 1.0, duration: EvDurations.normal, curve: EvCurves.spring,
                        child: AnimatedContainer(
                          duration: EvDurations.fast, curve: EvCurves.soft, padding: EdgeInsets.all(s.rem(0.5625)),
                          decoration: BoxDecoration(color: sel ? c.withValues(alpha: 0.18) : (hovered ? t.fill2 : t.fill),
                            borderRadius: BorderRadius.circular(s.rem(0.75)),
                            border: sel ? Border.all(color: c, width: 1.5) : (focused ? Border.all(color: t.focusColor, width: 1.5) : null)),
                          child: EvIcon(icon, color: sel ? c : (hovered ? t.ink : t.ink2), accentColor: sel ? c : t.brand, active: sel || hovered),
                        ),
                      ),
                    );
                  },
                ),
                lbl('颜色'),
                Wrap(spacing: s.rem(0.625), runSpacing: s.rem(0.5), children: [
                  for (var i = 0; i < 7; i++)
                    EvInteractive(
                      key: Key('ev_zone_color_$i'), selected: _colorSlot == i, onTap: () => setState(() => _colorSlot = i),
                      builder: (_, hovered, focused) {
                        final sc = t.zoneColor(i), sel = _colorSlot == i;
                        return AnimatedScale(
                          scale: (sel || hovered || focused) ? 1.08 : 1.0, duration: EvDurations.normal, curve: EvCurves.spring,
                          child: Container(width: s.rem(2.0), height: s.rem(2.0), decoration: BoxDecoration(color: sc, shape: BoxShape.circle,
                            boxShadow: sel ? [BoxShadow(color: sc, spreadRadius: 4), BoxShadow(color: t.glassSolid, spreadRadius: 2)] : null)),
                        );
                      },
                    ),
                ]),
                lbl('内容'),
                _ruleSection(t, s),
                if (_submitError != null) ...[SizedBox(height: s.rem(0.75)), Text(_submitError!, style: t.bodyStyle(s.font(0.875), color: evDangerColor))],
                SizedBox(height: s.rem(1.75)),
                Row(children: [
                  if (!_isNew && (widget.initialZone?.custom ?? false))
                    EvButton.ghost(key: const Key('ev_zone_delete'), small: true, glass: false, onPressed: _submitting ? null : _delete,
                      child: Text('删除分区', style: t.bodyStyle(s.font(0.9375), fontWeight: FontWeight.w600, color: evDangerColor))),
                  const Spacer(),
                  EvButton.ghost(key: const Key('ev_zone_cancel'), small: true, label: '取消', onPressed: _submitting ? null : widget.onClose),
                  SizedBox(width: s.rem(0.75)),
                  EvButton.primary(key: const Key('ev_zone_save'), small: true, label: _isNew ? '添加' : '保存', onPressed: (!_submitting && _rule != null) ? _save : null),
                ]),
              ]),
            ),
          ),
        ))),
      ]),
    );
  }

  Widget _ruleSection(EvTheme t, EvScale s) {
    if (_isBuiltInLibrary) {
      final base = evZoneRuleDescription(widget.initialZone!, facets: _facets);
      return Wrap(children: [EvSettingsChip(label: widget.zoneTotal != null ? '$base · ${evFormatCount(widget.zoneTotal!)} ${widget.zoneUnit}' : base, selected: true)]);
    }
    if (_loadingFacets) return Text('正在读取可用筛选条件…', style: t.bodyStyle(s.font(0.875), color: t.ink3));
    if (_facetsError != null) {
      return Row(children: [
        Expanded(child: Text(_facetsError!, style: t.bodyStyle(s.font(0.875), color: evDangerColor))),
        SizedBox(width: s.rem(0.75)), EvButton.ghost(small: true, label: '重试', onPressed: _fetchFacets),
      ]);
    }
    final f = _facets ?? const ZoneFacets(), kinds = _availableKinds(f);
    if (kinds.isEmpty) return Text('当前服务器没有可用于自定义分区的筛选条件', style: t.bodyStyle(s.font(0.875), color: t.ink3));

    final chips = switch (_ruleKind) {
      _ZoneRuleKind.genre => [for (final o in f.genres) EvSettingsChip(key: Key('ev_zone_facet_genre_${o.value}'), label: o.label, count: o.count,
        selected: _rule is GenreZoneRule && (_rule as GenreZoneRule).genreId == o.value, onTap: () => setState(() => _rule = ZoneRule.genre(o.value)))],
      _ZoneRuleKind.technology => [for (final o in f.technologies) EvSettingsChip(key: Key('ev_zone_facet_tech_${o.value.name}'), label: o.label, count: o.count,
        selected: _rule is TechnologyZoneRule && (_rule as TechnologyZoneRule).technology == o.value, onTap: () => setState(() => _rule = ZoneRule.technology(o.value)))],
      _ZoneRuleKind.library => [for (final o in f.libraries) EvSettingsChip(key: Key('ev_zone_facet_lib_${o.value}'), label: o.label, count: o.count,
        selected: _rule is LibraryZoneRule && (_rule as LibraryZoneRule).libraryId == o.value, onTap: () => setState(() => _rule = ZoneRule.library(o.value)))],
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      EvSegmentedControl<_ZoneRuleKind>(
        value: _ruleKind,
        options: [for (final k in kinds) EvSegmentOption(key: Key('ev_zone_rule_tab_${k.name}'), value: k,
          label: switch (k) { _ZoneRuleKind.genre => '按类型', _ZoneRuleKind.technology => '按画质 / 音轨', _ZoneRuleKind.library => '按片库' })],
        onChanged: (next) => setState(() { _ruleKind = next; _rule = _defaultRuleFor(next, f); }),
      ),
      SizedBox(height: s.rem(0.625)),
      Wrap(spacing: s.rem(0.375), runSpacing: s.rem(0.375), children: chips),
    ]);
  }
}
