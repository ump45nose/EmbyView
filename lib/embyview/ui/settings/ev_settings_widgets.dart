import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

const Object _keepField = Object();
const Color evTransparent = Color(0x00000000);
const Color evDangerColor = Color(0xFFE5484D);

/// Creates a modified copy of [LocalPreferences] without dropping any field.
LocalPreferences evCopyPreferences(
  LocalPreferences b, {
  ThemeMode? theme, NavigationStyle? navigation, ShelfSort? seriesSort,
  bool? chooseUserOnStartup, bool? backgroundVideo, Duration? backgroundVideoDelay,
  Object? detailTrailerDelay = _keepField, bool? themeMusic, double? themeVolume,
  bool? quickLook, bool? hideUnwatchedOverview, bool? preResolve115,
  int? readAheadBytes, bool? autoPlayNext, bool? anime4kForAnime, bool? anime4kForOther,
  List<String>? subtitleLanguages, bool? autoSelectChineseSubtitle,
  Set<SubtitleSource>? subtitleSources, String? translationBaseUrl, String? translationModel,
  int? monthlyBudgetMicros, MediaFolderStatus? mediaFolder, List<ZonePreference>? zones,
}) => LocalPreferences(
  theme: theme ?? b.theme, navigation: navigation ?? b.navigation, seriesSort: seriesSort ?? b.seriesSort,
  chooseUserOnStartup: chooseUserOnStartup ?? b.chooseUserOnStartup, backgroundVideo: backgroundVideo ?? b.backgroundVideo,
  backgroundVideoDelay: backgroundVideoDelay ?? b.backgroundVideoDelay,
  detailTrailerDelay: identical(detailTrailerDelay, _keepField) ? b.detailTrailerDelay : detailTrailerDelay as Duration?,
  themeMusic: themeMusic ?? b.themeMusic, themeVolume: themeVolume ?? b.themeVolume, quickLook: quickLook ?? b.quickLook,
  hideUnwatchedOverview: hideUnwatchedOverview ?? b.hideUnwatchedOverview, preResolve115: preResolve115 ?? b.preResolve115,
  readAheadBytes: readAheadBytes ?? b.readAheadBytes, autoPlayNext: autoPlayNext ?? b.autoPlayNext,
  anime4kForAnime: anime4kForAnime ?? b.anime4kForAnime, anime4kForOther: anime4kForOther ?? b.anime4kForOther,
  subtitleLanguages: subtitleLanguages ?? b.subtitleLanguages,
  autoSelectChineseSubtitle: autoSelectChineseSubtitle ?? b.autoSelectChineseSubtitle,
  subtitleSources: subtitleSources ?? b.subtitleSources,
  translationBaseUrl: translationBaseUrl ?? b.translationBaseUrl, translationModel: translationModel ?? b.translationModel,
  monthlyBudgetMicros: monthlyBudgetMicros ?? b.monthlyBudgetMicros, mediaFolder: mediaFolder ?? b.mediaFolder, zones: zones ?? b.zones,
);

String evTechFilterLabel(TechFilter tech) => switch (tech) {
  TechFilter.uhd4k => '4K', TechFilter.dolbyVision => '杜比视界', TechFilter.hdr => 'HDR', TechFilter.surround51 => '5.1',
};

String evZoneRuleDescription(ZonePreference z, {ZoneFacets? facets}) => switch (z.rule) {
  LibraryZoneRule(:final libraryId) =>
    '片库「${facets?.libraries.where((o) => o.value == libraryId).firstOrNull?.label ?? (z.name.isNotEmpty ? z.name : libraryId)}」',
  GenreZoneRule(:final genreId) => '类型「${facets?.genres.where((o) => o.value == genreId).firstOrNull?.label ?? genreId}」',
  TechnologyZoneRule(:final technology) =>
    '画质 / 音轨「${facets?.technologies.where((o) => o.value == technology).firstOrNull?.label ?? evTechFilterLabel(technology)}」',
};

String evFormatMicros(int micros, {bool trimZeroCents = false}) {
  final d = micros / 1000000.0;
  return trimZeroCents && micros % 1000000 == 0 ? '\$${d.toInt()}' : '\$${d.toStringAsFixed(2)}';
}

Widget evPaneTitle(EvTheme t, EvScale s, String text) => Padding(
  padding: EdgeInsets.only(top: s.rem(0.5), bottom: s.rem(1.75)),
  child: Text(text, style: t.displayStyle(s.font(2.25))),
);

Widget evValueText(EvTheme t, EvScale s, String text) =>
    Text(text, style: t.bodyStyle(s.font(0.9375), color: t.ink3));

/// Shared desktop interactive wrapper handling semantics, focus, hover, and click.
class EvInteractive extends StatefulWidget {
  const EvInteractive({
    super.key, this.onTap, this.enabled = true, this.selected, this.toggled, this.label, required this.builder,
  });
  final VoidCallback? onTap;
  final bool enabled;
  final bool? selected, toggled;
  final String? label;
  final Widget Function(BuildContext context, bool hovered, bool focused) builder;
  @override State<EvInteractive> createState() => _EvInteractiveState();
}

class _EvInteractiveState extends State<EvInteractive> {
  bool _hovered = false, _focused = false;
  bool get _active => widget.enabled && widget.onTap != null;

  @override
  Widget build(BuildContext context) => Semantics(
    button: widget.toggled == null ? _active : null, selected: widget.selected, toggled: widget.toggled, enabled: _active, label: widget.label,
    child: Focus(
      canRequestFocus: _active, onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (_, e) { if (!_active || !evIsActivateKey(e)) return KeyEventResult.ignored; widget.onTap!(); return KeyEventResult.handled; },
      child: MouseRegion(
        cursor: _active ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true), onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _active ? widget.onTap : null,
          child: widget.builder(context, _active && _hovered, _active && _focused)),
      ),
    ),
  );
}

/// Settings group container mirroring `.group` + `.gbox` in `proto.css`.
class EvSettingsGroup extends StatelessWidget {
  const EvSettingsGroup({super.key, this.title, required this.children});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), r = BorderRadius.circular(s.rem(1.0));
    return Padding(
      padding: EdgeInsets.only(bottom: s.rem(1.75)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null && title!.isNotEmpty)
          Padding(padding: EdgeInsets.only(left: s.rem(0.25), bottom: s.rem(0.625)),
            child: Text(title!, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w600, color: t.ink3))),
        Container(
          decoration: BoxDecoration(color: t.isPaper ? const Color(0xFFFFFFFF) : t.fill, borderRadius: r, border: Border.all(color: t.line, width: 1)),
          child: ClipRRect(borderRadius: r, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: 1, child: ColoredBox(color: t.line)), children[i]],
          ])),
        ),
      ]),
    );
  }
}

/// Single settings row mirroring `.grow` in `proto.css`.
class EvSettingsRow extends StatelessWidget {
  const EvSettingsRow({super.key, this.leading, required this.title, this.subtitle, this.subtitleColor, this.bottom, this.trailing});
  final Widget? leading, bottom, trailing;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: s.rem(3.75)),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: s.rem(1.125), vertical: s.rem(0.8125)),
        child: Row(children: [
          if (leading != null) ...[leading!, SizedBox(width: s.rem(1.0))],
          Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.bodyStyle(s.font(1.0), fontWeight: FontWeight.w500, color: t.ink)),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              SizedBox(height: s.rem(0.25)),
              Text(subtitle!, style: t.bodyStyle(s.font(0.875), color: subtitleColor ?? t.ink3, height: 1.45)),
            ],
            ?bottom,
          ])),
          if (trailing != null) ...[SizedBox(width: s.rem(1.0)), trailing!],
        ]),
      ),
    );
  }
}

/// Toggle switch mirroring `.toggle` in `proto.css`.
class EvToggle extends StatelessWidget {
  const EvToggle({super.key, required this.value, required this.onChanged, this.semanticLabel});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final onColor = t.isPaper ? const Color(0xFFB5532F) : const Color(0xFF34C759);
    return EvInteractive(
      toggled: value, label: semanticLabel, enabled: onChanged != null,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      builder: (_, _, focused) => Opacity(
        opacity: onChanged != null ? 1.0 : 0.45,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250), curve: EvCurves.soft,
          width: s.rem(2.875), height: s.rem(1.6875), padding: EdgeInsets.all(s.rem(0.1875)),
          decoration: BoxDecoration(color: value ? onColor : t.fill3, borderRadius: BorderRadius.circular(999),
            border: focused ? Border.all(color: t.focusColor, width: 1.5) : null),
          child: AnimatedAlign(
            duration: EvDurations.normal, curve: EvCurves.spring,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(width: s.rem(1.3125), height: s.rem(1.3125),
              decoration: const BoxDecoration(color: Color(0xFFFFFFFF), shape: BoxShape.circle,
                boxShadow: [BoxShadow(offset: Offset(0, 1), blurRadius: 3, color: Color.fromRGBO(0, 0, 0, 0.3))])),
          ),
        ),
      ),
    );
  }
}

class EvSegmentOption<T> {
  const EvSegmentOption({required this.value, required this.label, this.key, this.enabled = true});
  final T value;
  final String label;
  final Key? key;
  final bool enabled;
}

/// Segmented selector mirroring `.seg` in `proto.css`.
class EvSegmentedControl<T> extends StatelessWidget {
  const EvSegmentedControl({super.key, required this.options, required this.value, required this.onChanged});
  final List<EvSegmentOption<T>> options;
  final T? value;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), activeBg = t.isPaper ? const Color(0xFFFFFFFF) : t.glassSolid;
    return Container(
      padding: EdgeInsets.all(s.rem(0.1875)),
      decoration: BoxDecoration(color: t.fill2, borderRadius: BorderRadius.circular(s.rem(0.625))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final o in options)
          EvInteractive(
            key: o.key, selected: o.value == value, label: o.label, enabled: o.enabled && onChanged != null,
            onTap: o.enabled && onChanged != null ? () => onChanged!(o.value) : null,
            builder: (_, hovered, focused) {
              final sel = o.value == value;
              return Opacity(
                opacity: o.enabled && onChanged != null ? 1.0 : 0.4,
                child: AnimatedContainer(
                  duration: EvDurations.fast, curve: EvCurves.soft,
                  height: s.rem(1.875), padding: EdgeInsets.symmetric(horizontal: s.rem(0.8125)), alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: sel ? activeBg : evTransparent, borderRadius: BorderRadius.circular(s.rem(0.4375)),
                    border: focused ? Border.all(color: t.focusColor, width: 1.5) : null,
                    boxShadow: sel ? [BoxShadow(offset: const Offset(0, 1), blurRadius: t.isPaper ? 2 : 3,
                      color: t.isPaper ? const Color.fromRGBO(20, 20, 19, 0.12) : const Color.fromRGBO(0, 0, 0, 0.15))] : null,
                  ),
                  child: Text(o.label, maxLines: 1, softWrap: false,
                    style: t.bodyStyle(s.font(0.875), fontWeight: sel ? FontWeight.w500 : FontWeight.w400, color: (sel || hovered) ? t.ink : t.ink2)),
                ),
              );
            },
          ),
      ]),
    );
  }
}

enum EvStatusTone { ok, warn, error }

class EvStatusIndicator extends StatelessWidget {
  const EvStatusIndicator({super.key, required this.label, this.tone = EvStatusTone.ok});
  final String label;
  final EvStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final (dot, txt) = switch (tone) {
      EvStatusTone.ok => (t.isPaper ? const Color(0xFF5F7346) : const Color(0xFF34C759), t.ink),
      EvStatusTone.warn => (const Color(0xFFFFB547), t.isPaper ? const Color(0xFFB56B12) : const Color(0xFFE3A03C)),
      EvStatusTone.error => (evDangerColor, evDangerColor),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: s.rem(0.5), height: s.rem(0.5), decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
      SizedBox(width: s.rem(0.375)),
      Text(label, maxLines: 1, softWrap: false, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: txt)),
    ]);
  }
}

class EvMeterBar extends StatelessWidget {
  const EvMeterBar({super.key, required this.progress, this.exceeded = false});
  final double progress;
  final bool exceeded;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return Container(
      height: s.rem(0.375), margin: EdgeInsets.only(top: s.rem(0.625)),
      decoration: BoxDecoration(color: t.fill2, borderRadius: BorderRadius.circular(3)), clipBehavior: Clip.antiAlias,
      child: Align(
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0)), duration: EvDurations.stage, curve: EvCurves.out,
          builder: (_, v, _) => FractionallySizedBox(widthFactor: v, heightFactor: 1.0, child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: exceeded ? evDangerColor : (t.isPaper ? const Color(0xFFD97757) : null),
              gradient: (!exceeded && !t.isPaper) ? const LinearGradient(colors: [Color(0xFF7BE0A5), Color(0xFF5FB8FF)]) : null,
            ),
          )),
        ),
      ),
    );
  }
}

class EvSettingsChip extends StatelessWidget {
  const EvSettingsChip({super.key, required this.label, this.count, this.selected = false, this.onTap});
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return EvInteractive(
      selected: selected, label: label, enabled: onTap != null, onTap: onTap,
      builder: (_, hovered, focused) {
        final hi = hovered || focused;
        final bg = selected ? t.indBg : hi ? t.fill2 : (t.isPaper ? const Color(0xFFFFFFFF) : t.fill);
        final fg = selected ? t.indFg : (hi ? t.ink : t.ink2);
        return AnimatedContainer(
          duration: EvDurations.fast, curve: EvCurves.soft,
          height: s.rem(2.0), padding: EdgeInsets.symmetric(horizontal: s.rem(0.75)),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999),
            border: focused ? Border.all(color: t.focusColor, width: 1.5) : (selected ? null : Border.all(color: t.line, width: 1))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, maxLines: 1, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w500, color: fg)),
            if (count != null) ...[
              SizedBox(width: s.rem(0.375)),
              Text('$count', style: t.bodyStyle(s.font(0.8125), fontWeight: FontWeight.w500, color: fg.withValues(alpha: fg.a * 0.55))
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ]),
        );
      },
    );
  }
}

class EvPulseDot extends StatelessWidget {
  const EvPulseDot({super.key});
  @override
  Widget build(BuildContext context) {
    final d = EvScale.of(context).rem(0.5);
    final c = EvTheme.of(context).isPaper ? const Color(0xFFD97757) : const Color(0xFFB28CFF);
    return Container(width: d, height: d, decoration: BoxDecoration(color: c, shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.45), blurRadius: d)]));
  }
}

class EvChevronIcon extends StatelessWidget {
  const EvChevronIcon({super.key, required this.up, required this.size, required this.color});
  final bool up; final double size; final Color color;
  @override
  Widget build(BuildContext context) => Transform.rotate(angle: up ? math.pi : 0, child: EvIcon(EvIcons.down, size: size, color: color));
}

/// Compact themed text input matching `.zedit input.tx` in `proto.css`.
class EvSettingsTextField extends StatefulWidget {
  const EvSettingsTextField({
    super.key, required this.controller, this.placeholder,
    this.obscureText = false, this.maxLength, this.accentColor, this.keyboardType, this.onSubmitted,
  });
  final TextEditingController controller;
  final String? placeholder;
  final bool obscureText;
  final int? maxLength;
  final Color? accentColor;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  @override State<EvSettingsTextField> createState() => _EvSettingsTextFieldState();
}

class _EvSettingsTextFieldState extends State<EvSettingsTextField> {
  final _node = FocusNode();
  @override void dispose() { _node.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque, onTap: _node.requestFocus,
      child: ListenableBuilder(
        listenable: Listenable.merge([_node, widget.controller]),
        builder: (_, _) {
          final focused = _node.hasFocus, border = focused ? (widget.accentColor ?? (t.isPaper ? t.brand : t.ink2)) : t.line;
          return Container(
            height: s.rem(2.875), padding: EdgeInsets.symmetric(horizontal: s.rem(1.0)), alignment: Alignment.centerLeft,
            decoration: BoxDecoration(color: t.fill2, borderRadius: BorderRadius.circular(s.rem(0.75)), border: Border.all(color: border, width: focused ? 2.0 : 1.0)),
            child: Stack(alignment: Alignment.centerLeft, children: [
              if (widget.placeholder != null && widget.placeholder!.isNotEmpty && widget.controller.text.isEmpty)
                IgnorePointer(child: Text(widget.placeholder!, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.9375), color: t.ink3))),
              EditableText(
                controller: widget.controller, focusNode: _node, obscureText: widget.obscureText, keyboardType: widget.keyboardType, maxLines: 1,
                inputFormatters: [if (widget.maxLength != null) LengthLimitingTextInputFormatter(widget.maxLength)],
                onSubmitted: widget.onSubmitted, style: t.bodyStyle(s.font(1.0), color: t.ink),
                cursorColor: widget.accentColor ?? t.ink, backgroundCursorColor: t.ink4,
                selectionColor: (widget.accentColor ?? t.brand).withValues(alpha: 0.28),
              ),
            ]),
          );
        },
      ),
    );
  }
}
