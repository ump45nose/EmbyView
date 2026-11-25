import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart' hide ThemeMode;
import 'package:moonfin/embyview/embyview.dart';

/// Complete EmbyView visual theme mirroring `:root`, `[data-theme="anthropic"]`,
/// and `.onimage` variables from `.spec/mockups/proto.css`.
@immutable
class EvTheme extends ThemeExtension<EvTheme> {
  const EvTheme({
    required this.isPaper, required this.onImage,
    required this.bg, required this.fg,
    required this.ink, required this.ink2, required this.ink3, required this.ink4,
    required this.line, required this.fill, required this.fill2, required this.fill3,
    required this.glass, required this.glassSolid, required this.glassEdge,
    required this.glassBorder, required this.glassShadow, required this.blurSigma,
    required this.priBg, required this.priFg, required this.indBg, required this.indFg,
    required this.focusColor, required this.cardBg,
    required this.cardShadow, required this.cardShadowHi,
    required this.radius, required this.posterRadius,
    required this.brand, required this.accent, required this.ambient,
    required this.zoneColors,
    required this.sansFamily, required this.displayFamily,
    required this.displayWeight, required this.displayLetterSpacingEm,
    required this.shelfFamily, required this.shelfWeight,
    required this.serifFamily,
  });

  /// Dark cinema theme (`:root`).
  static const EvTheme cinema = EvTheme(
    isPaper: false, onImage: false,
    bg: Color(0xFF09090B), fg: Color(0xFFF5F5F7),
    ink: Color(0xFFF5F5F7), ink2: Color.fromRGBO(245, 245, 247, 0.76),
    ink3: Color.fromRGBO(245, 245, 247, 0.54), ink4: Color.fromRGBO(245, 245, 247, 0.30),
    line: Color.fromRGBO(245, 245, 247, 0.10), fill: Color.fromRGBO(245, 245, 247, 0.07),
    fill2: Color.fromRGBO(245, 245, 247, 0.13), fill3: Color.fromRGBO(245, 245, 247, 0.22),
    glass: Color.fromRGBO(40, 40, 46, 0.46), glassSolid: Color.fromRGBO(28, 28, 33, 0.92),
    glassEdge: Color.fromRGBO(255, 255, 255, 0.16), glassBorder: Color.fromRGBO(255, 255, 255, 0.07),
    glassShadow: [BoxShadow(offset: Offset(0, 8), blurRadius: 32, color: Color.fromRGBO(0, 0, 0, 0.28))],
    blurSigma: 36,
    priBg: Color(0xFFF5F5F7), priFg: Color(0xFF0B0B0D),
    indBg: Color(0xFFF5F5F7), indFg: Color(0xFF0B0B0D),
    focusColor: Color.fromRGBO(255, 255, 255, 0.62),
    cardBg: Color(0xFF18181D),
    cardShadow: [BoxShadow(offset: Offset(0, 4), blurRadius: 12, color: Color.fromRGBO(0, 0, 0, 0.25))],
    cardShadowHi: [BoxShadow(offset: Offset(0, 24), blurRadius: 48, color: Color.fromRGBO(0, 0, 0, 0.55))],
    radius: 0.75, posterRadius: 0.625,
    brand: Color(0xFFD97757), accent: Color(0xFFF5F5F7), ambient: Color(0xFF282830),
    zoneColors: [
      Color(0xFFFF8060), Color(0xFFE8C27A), Color(0xFF7FA7FF),
      Color(0xFF5FD3A6), Color(0xFFB7A6FF), Color(0xFFEC78AA), Color(0xFF50C8DC),
    ],
    sansFamily: 'SF Pro Display', displayFamily: 'SF Pro Display',
    displayWeight: FontWeight.w700, displayLetterSpacingEm: -0.02,
    shelfFamily: 'SF Pro Display', shelfWeight: FontWeight.w700,
    serifFamily: 'New York',
  );

  /// Warm paper theme (`[data-theme="anthropic"]`, displayed as 「纸面」).
  static const EvTheme paper = EvTheme(
    isPaper: true, onImage: false,
    bg: Color(0xFFFAF9F5), fg: Color(0xFF141413),
    ink: Color(0xFF141413), ink2: Color(0xFF3D3D3A),
    ink3: Color(0xFF66655F), ink4: Color(0xFFA3A29B),
    line: Color(0xFFE8E6DC), fill: Color.fromRGBO(20, 20, 19, 0.04),
    fill2: Color(0xFFF0EEE6), fill3: Color(0xFFE8E6DC),
    glass: Color.fromRGBO(255, 255, 255, 0.84), glassSolid: Color(0xFFFFFFFF),
    glassEdge: Color(0x00000000), glassBorder: Color(0xFFE8E6DC),
    glassShadow: [
      BoxShadow(offset: Offset(0, 4), blurRadius: 16, color: Color.fromRGBO(20, 20, 19, 0.08)),
      BoxShadow(offset: Offset(0, 1), blurRadius: 3, color: Color.fromRGBO(20, 20, 19, 0.06)),
    ],
    blurSigma: 20,
    priBg: Color(0xFFB5532F), priFg: Color(0xFFFFFFFF),
    indBg: Color(0xFF141413), indFg: Color(0xFFFAF9F5),
    focusColor: Color(0xFF141413),
    cardBg: Color(0xFFF0EEE6),
    cardShadow: [BoxShadow(offset: Offset(0, 1), blurRadius: 2, color: Color.fromRGBO(20, 20, 19, 0.05))],
    cardShadowHi: [],
    radius: 0.5, posterRadius: 0.375,
    brand: Color(0xFFD97757), accent: Color(0xFF141413), ambient: Color(0xFFFAF9F5),
    zoneColors: [
      Color(0xFFD97757), Color(0xFFD4A27F), Color(0xFF6A9BCC),
      Color(0xFF788C5D), Color(0xFFC46686), Color(0xFFC9638D), Color(0xFF5B99A0),
    ],
    sansFamily: 'Anthropic Sans', displayFamily: 'Anthropic Serif',
    displayWeight: FontWeight.w500, displayLetterSpacingEm: 0.0,
    shelfFamily: 'Anthropic Sans', shelfWeight: FontWeight.w600,
    serifFamily: 'Anthropic Serif',
  );

  final bool isPaper;
  final bool onImage;
  final Color bg, fg, ink, ink2, ink3, ink4;
  final Color line, fill, fill2, fill3;
  final Color glass, glassSolid, glassEdge, glassBorder;
  final List<BoxShadow> glassShadow;
  final double blurSigma;
  final Color priBg, priFg, indBg, indFg, focusColor, cardBg;
  final List<BoxShadow> cardShadow, cardShadowHi;

  /// Base (`--r`) and poster (`--r-poster`) corner radii in `rem`.
  final double radius, posterRadius;
  final Color brand, accent, ambient;
  final List<Color> zoneColors;
  final String sansFamily, displayFamily, shelfFamily, serifFamily;
  final FontWeight displayWeight, shelfWeight;
  final double displayLetterSpacingEm;

  Brightness get brightness => isPaper ? Brightness.light : Brightness.dark;
  String get displayName => isPaper ? '纸面' : '影院';

  List<String> get sansFallback => isPaper
      ? const ['PingFang SC', 'Hiragino Sans GB', 'SF Pro Text', 'Roboto']
      : const ['SF Pro Text', 'PingFang SC', 'Helvetica Neue', 'Roboto'];
  List<String> get serifFallback => isPaper
      ? const ['Songti SC', 'Noto Serif CJK SC', 'Georgia']
      : const ['Iowan Old Style', 'Songti SC', 'Noto Serif SC', 'Georgia'];
  List<String> get displayFallback => isPaper ? serifFallback : sansFallback;

  Color get anime => zoneColor(0);
  Color get movie => zoneColor(1);
  Color get tv => zoneColor(2);
  Color get doc => zoneColor(3);
  Color get box => zoneColor(4);

  /// Returns one of the 7 themed zone colors for [slot].
  Color zoneColor(int slot) {
    final len = zoneColors.length;
    return zoneColors[((slot % len) + len) % len];
  }

  /// Resolves a semantic zone key (`anime`, `movie`, `tv`, `doc`, `box`) to its color.
  Color zoneColorByKey(String key) => switch (key.toLowerCase()) {
    'anime' || 'nav_anime' => anime,
    'movie' || 'movies' || 'nav_movie' => movie,
    'tv' || 'series' || 'nav_tv' => tv,
    'doc' || 'documentary' || 'nav_doc' => doc,
    'box' || 'boxset' || 'collections' || 'nav_box' => box,
    _ => accent,
  };

  TextStyle displayStyle(double fontSize, {Color? color, double? height}) =>
      TextStyle(
        fontFamily: displayFamily, fontFamilyFallback: displayFallback,
        fontSize: fontSize, fontWeight: displayWeight,
        letterSpacing: fontSize * displayLetterSpacingEm,
        color: color ?? ink, height: height,
        decoration: TextDecoration.none,
      );

  TextStyle shelfStyle(double fontSize, {Color? color}) => TextStyle(
    fontFamily: shelfFamily, fontFamilyFallback: sansFallback,
    fontSize: fontSize, fontWeight: shelfWeight,
    letterSpacing: fontSize * -0.01, color: color ?? ink,
    decoration: TextDecoration.none,
  );

  TextStyle bodyStyle(
    double fontSize, {
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
  }) => TextStyle(
    fontFamily: sansFamily, fontFamilyFallback: sansFallback,
    fontSize: fontSize, fontWeight: fontWeight,
    color: color ?? ink, height: height,
    decoration: TextDecoration.none,
  );

  TextStyle serifStyle(
    double fontSize, {
    FontWeight fontWeight = FontWeight.w400,
    FontStyle fontStyle = FontStyle.normal,
    Color? color,
    double? height,
  }) => TextStyle(
    fontFamily: serifFamily, fontFamilyFallback: serifFallback,
    fontSize: fontSize, fontWeight: fontWeight, fontStyle: fontStyle,
    color: color ?? ink, height: height,
    decoration: TextDecoration.none,
  );

  static EvTheme of(BuildContext context) =>
      Theme.of(context).extension<EvTheme>() ?? cinema;

  /// Applies `.onimage` (and `[data-theme="anthropic"] .onimage` when paper).
  EvTheme toOnImage() {
    if (onImage) return this;
    return copyWith(
      onImage: true,
      fg: const Color(0xFFF5F5F7),
      ink: const Color(0xFFF5F5F7),
      ink2: const Color.fromRGBO(245, 245, 247, 0.84),
      ink3: const Color.fromRGBO(245, 245, 247, 0.62),
      ink4: const Color.fromRGBO(245, 245, 247, 0.34),
      fill: const Color.fromRGBO(255, 255, 255, 0.08),
      fill2: const Color.fromRGBO(255, 255, 255, 0.14),
      fill3: const Color.fromRGBO(255, 255, 255, 0.24),
      line: const Color.fromRGBO(255, 255, 255, 0.14),
      glass: isPaper ? const Color.fromRGBO(20, 20, 19, 0.40) : glass,
      glassSolid: isPaper ? const Color.fromRGBO(20, 20, 19, 0.86) : glassSolid,
      glassEdge: isPaper ? const Color(0x00000000) : glassEdge,
      glassBorder: isPaper ? const Color.fromRGBO(255, 255, 255, 0.16) : glassBorder,
      blurSigma: isPaper ? 24 : blurSigma,
      indBg: isPaper ? const Color(0xFFFAF9F5) : indBg,
      indFg: isPaper ? const Color(0xFF141413) : indFg,
    );
  }

  ThemeData toThemeData() => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme(
      brightness: brightness, primary: priBg, onPrimary: priFg,
      secondary: brand, onSecondary: Colors.white,
      error: const Color(0xFFFF5F57), onError: Colors.white,
      surface: bg, onSurface: ink,
    ),
    scaffoldBackgroundColor: bg, canvasColor: bg,
    fontFamily: sansFamily, fontFamilyFallback: sansFallback,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent, hoverColor: fill,
    focusColor: focusColor, dividerColor: line,
    iconTheme: IconThemeData(color: ink),
    textTheme: TextTheme(
      bodyLarge: bodyStyle(16), bodyMedium: bodyStyle(15),
      bodySmall: bodyStyle(13, color: ink3),
      titleLarge: shelfStyle(24), displayLarge: displayStyle(64),
    ),
    extensions: [this],
  );

  @override
  EvTheme copyWith({
    bool? isPaper, bool? onImage, Color? bg, Color? fg,
    Color? ink, Color? ink2, Color? ink3, Color? ink4,
    Color? line, Color? fill, Color? fill2, Color? fill3,
    Color? glass, Color? glassSolid, Color? glassEdge, Color? glassBorder,
    List<BoxShadow>? glassShadow, double? blurSigma,
    Color? priBg, Color? priFg, Color? indBg, Color? indFg,
    Color? focusColor, Color? cardBg,
    List<BoxShadow>? cardShadow, List<BoxShadow>? cardShadowHi,
    double? radius, double? posterRadius,
    Color? brand, Color? accent, Color? ambient, List<Color>? zoneColors,
    String? sansFamily, String? displayFamily, FontWeight? displayWeight,
    double? displayLetterSpacingEm, String? shelfFamily, FontWeight? shelfWeight,
    String? serifFamily,
  }) => EvTheme(
    isPaper: isPaper ?? this.isPaper, onImage: onImage ?? this.onImage,
    bg: bg ?? this.bg, fg: fg ?? this.fg,
    ink: ink ?? this.ink, ink2: ink2 ?? this.ink2, ink3: ink3 ?? this.ink3, ink4: ink4 ?? this.ink4,
    line: line ?? this.line, fill: fill ?? this.fill, fill2: fill2 ?? this.fill2, fill3: fill3 ?? this.fill3,
    glass: glass ?? this.glass, glassSolid: glassSolid ?? this.glassSolid,
    glassEdge: glassEdge ?? this.glassEdge, glassBorder: glassBorder ?? this.glassBorder,
    glassShadow: glassShadow ?? this.glassShadow, blurSigma: blurSigma ?? this.blurSigma,
    priBg: priBg ?? this.priBg, priFg: priFg ?? this.priFg,
    indBg: indBg ?? this.indBg, indFg: indFg ?? this.indFg,
    focusColor: focusColor ?? this.focusColor, cardBg: cardBg ?? this.cardBg,
    cardShadow: cardShadow ?? this.cardShadow, cardShadowHi: cardShadowHi ?? this.cardShadowHi,
    radius: radius ?? this.radius, posterRadius: posterRadius ?? this.posterRadius,
    brand: brand ?? this.brand, accent: accent ?? this.accent, ambient: ambient ?? this.ambient,
    zoneColors: zoneColors ?? this.zoneColors,
    sansFamily: sansFamily ?? this.sansFamily, displayFamily: displayFamily ?? this.displayFamily,
    displayWeight: displayWeight ?? this.displayWeight,
    displayLetterSpacingEm: displayLetterSpacingEm ?? this.displayLetterSpacingEm,
    shelfFamily: shelfFamily ?? this.shelfFamily, shelfWeight: shelfWeight ?? this.shelfWeight,
    serifFamily: serifFamily ?? this.serifFamily,
  );

  @override
  EvTheme lerp(ThemeExtension<EvTheme>? other, double t) {
    if (other is! EvTheme) return this;
    final target = t < 0.5 ? this : other;
    return EvTheme(
      isPaper: target.isPaper, onImage: target.onImage,
      bg: Color.lerp(bg, other.bg, t)!, fg: Color.lerp(fg, other.fg, t)!,
      ink: Color.lerp(ink, other.ink, t)!, ink2: Color.lerp(ink2, other.ink2, t)!,
      ink3: Color.lerp(ink3, other.ink3, t)!, ink4: Color.lerp(ink4, other.ink4, t)!,
      line: Color.lerp(line, other.line, t)!, fill: Color.lerp(fill, other.fill, t)!,
      fill2: Color.lerp(fill2, other.fill2, t)!, fill3: Color.lerp(fill3, other.fill3, t)!,
      glass: Color.lerp(glass, other.glass, t)!, glassSolid: Color.lerp(glassSolid, other.glassSolid, t)!,
      glassEdge: Color.lerp(glassEdge, other.glassEdge, t)!, glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      glassShadow: BoxShadow.lerpList(glassShadow, other.glassShadow, t) ?? const [],
      blurSigma: lerpDouble(blurSigma, other.blurSigma, t)!,
      priBg: Color.lerp(priBg, other.priBg, t)!, priFg: Color.lerp(priFg, other.priFg, t)!,
      indBg: Color.lerp(indBg, other.indBg, t)!, indFg: Color.lerp(indFg, other.indFg, t)!,
      focusColor: Color.lerp(focusColor, other.focusColor, t)!, cardBg: Color.lerp(cardBg, other.cardBg, t)!,
      cardShadow: BoxShadow.lerpList(cardShadow, other.cardShadow, t) ?? const [],
      cardShadowHi: BoxShadow.lerpList(cardShadowHi, other.cardShadowHi, t) ?? const [],
      radius: lerpDouble(radius, other.radius, t)!, posterRadius: lerpDouble(posterRadius, other.posterRadius, t)!,
      brand: Color.lerp(brand, other.brand, t)!, accent: Color.lerp(accent, other.accent, t)!,
      ambient: Color.lerp(ambient, other.ambient, t)!,
      zoneColors: List<Color>.generate(
        zoneColors.length,
        (i) => Color.lerp(zoneColors[i], other.zoneColors[i % other.zoneColors.length], t)!,
      ),
      sansFamily: target.sansFamily, displayFamily: target.displayFamily,
      displayWeight: target.displayWeight,
      displayLetterSpacingEm: lerpDouble(displayLetterSpacingEm, other.displayLetterSpacingEm, t)!,
      shelfFamily: target.shelfFamily, shelfWeight: target.shelfWeight,
      serifFamily: target.serifFamily,
    );
  }
}

/// Provides [EvTheme] down the widget tree, reacting immediately to
/// [EmbyViewPreferences.changes] and automatic 07:00 / 19:00 day-night shifts.
class EvThemeScope extends StatefulWidget {
  const EvThemeScope({
    super.key,
    this.preferences,
    this.themeMode,
    this.clock = DateTime.now,
    required this.child,
  }) : assert(preferences != null || themeMode != null,
            'Either preferences or themeMode must be provided.');

  final EmbyViewPreferences? preferences;
  final ThemeMode? themeMode;
  final DateTime Function() clock;
  final Widget child;

  /// Paper between 07:00 (inclusive) and 19:00 (exclusive) local time.
  static bool resolveIsPaper(ThemeMode mode, DateTime now) => switch (mode) {
    ThemeMode.cinema => false,
    ThemeMode.paper => true,
    ThemeMode.automatic => now.hour >= 7 && now.hour < 19,
  };

  static Brightness resolveBrightness(ThemeMode mode, DateTime now) =>
      resolveIsPaper(mode, now) ? Brightness.light : Brightness.dark;

  static EvTheme resolveTheme(ThemeMode mode, DateTime now) =>
      resolveIsPaper(mode, now) ? EvTheme.paper : EvTheme.cinema;

  /// Duration until the next 07:00 or 19:00 local-time transition boundary.
  static Duration timeUntilNextBoundary(DateTime now) {
    final next = now.hour < 7
        ? DateTime(now.year, now.month, now.day, 7)
        : now.hour < 19
        ? DateTime(now.year, now.month, now.day, 19)
        : DateTime(now.year, now.month, now.day + 1, 7);
    final diff = next.difference(now);
    return diff > Duration.zero ? diff : const Duration(seconds: 1);
  }

  @override
  State<EvThemeScope> createState() => _EvThemeScopeState();
}

class _EvThemeScopeState extends State<EvThemeScope> {
  StreamSubscription<LocalPreferences>? _sub;
  Timer? _boundaryTimer;
  late ThemeMode _mode;

  @override
  void initState() {
    super.initState();
    _syncSource();
  }

  @override
  void didUpdateWidget(EvThemeScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences != widget.preferences ||
        oldWidget.themeMode != widget.themeMode ||
        oldWidget.clock != widget.clock) {
      _sub?.cancel();
      _sub = null;
      _syncSource();
    }
  }

  void _syncSource() {
    _mode = widget.themeMode ?? widget.preferences!.current.theme;
    if (widget.themeMode == null && widget.preferences != null) {
      _sub = widget.preferences!.changes.listen((prefs) {
        if (!mounted || prefs.theme == _mode) return;
        setState(() {
          _mode = prefs.theme;
          _scheduleBoundary();
        });
      });
    }
    _scheduleBoundary();
  }

  void _scheduleBoundary() {
    _boundaryTimer?.cancel();
    _boundaryTimer = null;
    if (_mode != ThemeMode.automatic) return;
    _boundaryTimer = Timer(
      EvThemeScope.timeUntilNextBoundary(widget.clock()),
      () {
        if (mounted) setState(_scheduleBoundary);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _boundaryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final evTheme = EvThemeScope.resolveTheme(_mode, widget.clock());
    return Theme(
      data: evTheme.toThemeData(),
      child: DefaultTextStyle(style: evTheme.bodyStyle(15), child: widget.child),
    );
  }
}
