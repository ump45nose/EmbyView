import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// Vector icon definition ported from `.spec/mockups/proto.js`.
/// Renders crisp duotone strokes in cinema theme and deterministic hand-wobbled
/// doodle strokes with an offset terracotta/accent fill block in paper theme.
/// Icons marked [solid] render identically across both themes.
@immutable
class EvIconData {
  const EvIconData(
    this.key,
    this.spec, {
    this.cinemaSpec,
    this.solid = false,
    this.viewBox = 24.0,
    this.cinemaStrokeWidth = 1.75,
    this.doodleStrokeWidth = 1.7,
  });

  final String key, spec;
  final String? cinemaSpec;
  final bool solid;
  final double viewBox, cinemaStrokeWidth, doodleStrokeWidth;
}

/// Complete EmbyView icon catalog ported from `.spec/mockups/proto.js`.
abstract final class EvIcons {
  // Navigation & default zones
  static const navHome = EvIconData('nav_home', 'p 3.4,11.8 12,4.2 20.6,11.8 | p 6,10.2 6,20 18,20 18,10.2 | R 10,14.2,4,5.8');
  static const navAnime = EvIconData('nav_anime', 'O 12,12,3.2 | c 12,6.6,3.3 | c 17.1,10.3,3.3 | c 15.2,16.4,3.3 | c 8.8,16.4,3.3 | c 6.9,10.3,3.3 | d 12,12', cinemaSpec: 'petals | d 12,12.4');
  static const navMovie = EvIconData('nav_movie', 'R 3.8,10,16.4,10.2 | P 3.4,9.6 19.5,5.4 18.8,2.9 2.8,7.1 | p 7.4,5.9 9,8.3 | p 11.8,4.7 13.4,7.1 | p 16.1,3.6 17.6,6');
  static const navTv = EvIconData('nav_tv', 'r 3,7.5,18,12.6 | p 8.4,3.4 12,7.3 15.6,3.4 | F 5.8,10.3 14,10.3 13.2,17.4 5.8,17.6 | d 18,11.2 | d 18,14.4');
  static const navDoc = EvIconData('nav_doc', 'p 2.8,19.6 9,10.4 13.4,16.2 15.8,13 21.2,19.6 | p 2.4,19.9 21.6,19.9 | C 16.6,6.4,2.5');
  static const navBox = EvIconData('nav_box', 'p 4,16.4 4,6.4 5.6,4.8 15.6,4.8 | R 7,8,13,12');
  static const navSearch = EvIconData('nav_search', 'O 9.6,9.6,2.6 | c 10.5,10.5,6.6 | p 15.4,15.4 20.6,20.6', cinemaSpec: 'O 10.5,10.5,6.6 | c 10.5,10.5,6.6 | p 15.4,15.4 20.6,20.6');

  // Solid icons (identical in cinema and paper)
  static const play = EvIconData('play', 'solid_play', solid: true);
  static const pause = EvIconData('pause', 'solid_pause', solid: true);
  static const next = EvIconData('next', 'solid_next', solid: true);
  static const more = EvIconData('more', 'solid_more', solid: true);
  static const star = EvIconData('star', 'solid_star', solid: true);

  // Actions, player & settings
  static const plus = EvIconData('plus', 'p 12,4.5 12,19.5 | p 4.5,12 19.5,12', cinemaStrokeWidth: 2.3);
  static const check = EvIconData('check', 'p 4.6,12.6 9.6,17.4 19.4,6.6', cinemaStrokeWidth: 2.3);
  static const left = EvIconData('left', 'p 15,4.6 7.6,12 15,19.4', cinemaStrokeWidth: 2.3);
  static const right = EvIconData('right', 'p 9,4.6 16.4,12 9,19.4', cinemaStrokeWidth: 2.3);
  static const down = EvIconData('down', 'p 5.6,9 12,15.4 18.4,9', cinemaStrokeWidth: 2.3);
  static const x = EvIconData('x', 'p 6,6 18,18 | p 18,6 6,18', cinemaStrokeWidth: 2.3);
  static const search = EvIconData('search', 'O 9.6,9.6,2.6 | c 10.5,10.5,6.6 | p 15.4,15.4 20.6,20.6', cinemaSpec: 'O 10.5,10.5,6.6 | c 10.5,10.5,6.6 | p 15.4,15.4 20.6,20.6');
  static const sort = EvIconData('sort', 'p 4,7 20,7 | p 7,12 17,12 | p 10,17 14,17');
  static const filter = EvIconData('filter', 'p 4,6.5 20,6.5 | p 7.5,12 16.5,12 | p 10.5,17.5 13.5,17.5');
  static const spark = EvIconData('spark', 'B 12,3 13.9,10.1 21,12 13.9,13.9 12,21 10.1,13.9 3,12 10.1,10.1');
  static const aisub = EvIconData('aisub', 'r 2.4,7,14.6,11.8 | p 5.4,11.6 12.4,11.6 | p 5.4,15 8.8,15 | p 11,15 14,15 | B 19.6,1.4 20.4,3.8 22.8,4.6 20.4,5.4 19.6,7.8 18.8,5.4 16.4,4.6 18.8,3.8');
  static const cc = EvIconData('cc', 'r 3,5,18,14 | a 9.6,12,2.6,40,320 | a 15.8,12,2.6,40,320');
  static const audio = EvIconData('audio', 'p 4,10 4,14 | p 8,7 8,17 | p 12,4 12,20 | p 16,8 16,16 | p 20,10.5 20,13.5');
  static const image = EvIconData('image', 'r 3,5,18,14 | C 9,10,1.8 | B 3.4,17.6 9,12.6 12.6,15.6 15.4,13 20.6,17.6');
  static const vol = EvIconData('vol', 'B 3.8,9.4 7.4,9.4 12,5.4 12,18.6 7.4,14.6 3.8,14.6 | a 12.5,12,4,-45,45 | a 12.5,12,7.6,-48,48');
  static const mute = EvIconData('mute', 'B 3.8,9.4 7.4,9.4 12,5.4 12,18.6 7.4,14.6 3.8,14.6 | p 16.2,9.4 21,14.6 | p 21,9.4 16.2,14.6');
  static const back10 = EvIconData('back10', 'a 12,12,7.8,180,-130 | p 4.2,4.4 4.2,9.2 9,9.2 | lbl 12.4,15.4,6.6,10');
  static const fwd10 = EvIconData('fwd10', 'a 12,12,7.8,0,310 | p 19.8,4.4 19.8,9.2 15,9.2 | lbl 11.6,15.4,6.6,10');
  static const pip = EvIconData('pip', 'r 3,5,18,14 | R 12,11,6,5');
  static const full = EvIconData('full', 'p 4,9 4,4 9,4 | p 15,4 20,4 20,9 | p 4,15 4,20 9,20 | p 15,20 20,20 20,15');
  static const gear = EvIconData('gear', 'O 12,12,6.6 | c 12,12,3 | c 12,12,6.6 | p 19,12 21.4,12 | p 16.9,16.9 18.6,18.6 | p 12,19 12,21.4 | p 7.1,16.9 5.4,18.6 | p 5,12 2.6,12 | p 7.1,7.1 5.4,5.4 | p 12,5 12,2.6 | p 16.9,7.1 18.6,5.4');
  static const users = EvIconData('users', 'C 9,8,3.4 | a 9,21.5,6.6,195,345 | c 16.8,8.6,2.7 | a 16.8,20.2,5,235,335');
  static const film = EvIconData('film', 'F 8.5,6 15.5,6 15.5,18 8.5,18 | r 3,4,18,16 | p 7,4 7,20 | p 17,4 17,20 | p 3,9 7,9 | p 3,15 7,15 | p 17,9 21,9 | p 17,15 21,15');
  static const wave = EvIconData('wave', 'p 3,12 5,12 7,7 10,17 13,3.6 16,15 18,12 21,12');
  static const key = EvIconData('key', 'C 8,15.5,4 | p 11,12.5 20,3.5 | p 17,6.5 20,9.5 | p 14.6,8.9 16.6,10.9');
  static const info = EvIconData('info', 'c 12,12,9 | p 12,11 12,17 | d 12,7.6');
  static const shuffle = EvIconData('shuffle', 'p 16,4 20,4 20,8 | p 4,20 20,4 | p 20,16 20,20 16,20 | p 14.6,14.6 20,20 | p 4,4 9.4,9.4');
  static const grid = EvIconData('grid', 'R 4,4,6.5,6.5 | r 13.5,4,6.5,6.5 | r 4,13.5,6.5,6.5 | R 13.5,13.5,6.5,6.5');
  static const ok = EvIconData('ok', 'O 12,12,9 | c 12,12,9 | p 7.6,12.4 10.6,15.4 16.6,9');
  static const a4k = EvIconData('a4k', 'p 3.6,19 8.8,6 14,19 | p 5.6,14.6 12,14.6 | B 17.5,3 18.4,5.6 21,6.5 18.4,7.4 17.5,10 16.6,7.4 14,6.5 16.6,5.6');
  static const cmp = EvIconData('cmp', 'p 9,6.5 4,12 9,17.5 | p 15,6.5 20,12 15,17.5');
  static const palette = EvIconData('palette', 'O 15.4,15,2.2 | c 12,12,8.8 | d 8,9.4 | d 12,6.8 | d 16,9.2 | d 7.6,14', cinemaSpec: 'palette_shape | d 7.5,11 | d 10.5,7.2 | d 15,7.5');
  static const lang = EvIconData('lang', 'p 3.4,6.4 12.6,6.4 | p 8,4 8,6.4 | p 10.8,6.4 6,15 | p 5.4,9.6 11,15 | B 12.4,20 16.4,10.4 20.6,20 | p 13.8,16.8 19.2,16.8');
  static const stack = EvIconData('stack', 'R 4,9,16,11 | p 6,6.2 18,6.2 | p 8.4,3.6 15.6,3.6');
  static const edit = EvIconData('edit', 'B 4,20 4.6,16 16,4.6 19.4,8 8,19.4 | p 13.8,6.8 17.2,10.2');
  static const zones = EvIconData('zones', 'R 3.5,3.5,7.5,7.5 | r 13,3.5,7.5,7.5 | r 3.5,13,7.5,7.5 | p 16.75,13.4 16.75,20.1 | p 13.4,16.75 20.1,16.75');

  // Additional custom zone icons (20 total in zoneIcons)
  static const heart = EvIconData('heart', 'S 12,20 6.6,15.4 3.6,10.8 4.2,6.8 7.6,4.6 10.6,5.4 12,7.6 13.4,5.4 16.4,4.6 19.8,6.8 20.4,10.8 17.4,15.4');
  static const rocket = EvIconData('rocket', 'S 12,2.6 15,6.8 15.6,13.6 14,17.2 10,17.2 8.4,13.6 9,6.8 | c 12,9.8,1.8 | p 8.6,12.8 5.6,15.6 5.6,18.6 9.2,17.2 | p 15.4,12.8 18.4,15.6 18.4,18.6 14.8,17.2 | p 10.8,19.4 12,21.6 13.2,19.4');
  static const ghost = EvIconData('ghost', 'S 6,19.6 5.8,10.6 7.4,5.6 12,3.6 16.6,5.6 18.2,10.6 18,19.6 15.6,18 13.8,20 12,18.2 10.2,20 8.4,18 | d 9.6,10.6 | d 14.4,10.6');
  static const music = EvIconData('music', 'C 7.6,17.6,2.6 | C 16.6,15.6,2.6 | p 10.2,17.6 10.2,5.6 19.2,3.6 19.2,15.6 | p 10.2,9 19.2,7');
  static const balloon = EvIconData('balloon', 'S 12,3 16.6,5.2 17.6,9.8 15,14.4 12,15.8 9,14.4 6.4,9.8 7.4,5.2 | P 11,16.2 13,16.2 12,17.6 | p 12,17.6 10.8,19.4 12.6,21.4');
  static const ball = EvIconData('ball', 'C 12,12,8.6 | p 3.4,12 20.6,12 | p 12,3.4 12,20.6 | a 4.4,12,6.2,-62,62 | a 19.6,12,6.2,118,242');
  static const book = EvIconData('book', 'B 12,6.6 7.6,4.8 3.4,5.4 3.4,18.4 7.6,17.8 12,19.6 | P 12,6.6 16.4,4.8 20.6,5.4 20.6,18.4 16.4,17.8 12,19.6');
  static const globe = EvIconData('globe', 'C 12,12,8.6 | s 12,3.4 15.4,7.6 15.4,16.4 12,20.6 8.6,16.4 8.6,7.6 | p 3.8,9.2 20.2,9.2 | p 3.8,14.8 20.2,14.8');
  static const crown = EvIconData('crown', 'B 3.6,8 8,12 12,5 16,12 20.4,8 18.6,18 5.4,18 | p 5.4,20.8 18.6,20.8');
  static const clock = EvIconData('clock', 'C 12,12,8.6 | p 12,7 12,12 15.4,14.2');
  static const leaf = EvIconData('leaf', 'S 4.8,19.2 5,11.6 9.4,6.2 19.2,4.8 18,13.4 12.4,18.4 | p 4.8,19.2 14.4,9.6');
  static const flame = EvIconData('flame', 'S 12,2.8 16.4,8.8 17.6,14.2 15.6,19 12,20.8 8.4,19 6.4,14.2 8.2,10.2 10.4,11.8 10.8,7.2 | P 12,20.6 10.2,17.4 12,14.2 13.8,17.4');
  static const cat = EvIconData('cat', 'S 4.8,19.6 4.8,10.6 5.8,4 9.6,7.6 14.4,7.6 18.2,4 19.2,10.6 19.2,19.6 | d 9.4,13 | d 14.6,13 | p 11.2,15.8 12,16.6 12.8,15.8');

  // 48x48 editorial illustrations (ISPEC)
  static const illClock = EvIconData('ill_clock', 'O 24,27,14 | c 24,27,14 | p 24,18 24,27 30.5,31 | p 19,6.5 29,6.5 | p 24,6.5 24,12.5 | p 35,13.5 38.5,10', viewBox: 48, cinemaStrokeWidth: 2.1, doodleStrokeWidth: 2.1);
  static const illTv = EvIconData('ill_tv', 'F 10,16 31,16 29.5,32 10,32 | r 6,12,36,24.5 | p 17,5.5 24,12 31,5.5 | p 14,41 34,41 | B 38,2.5 39.2,6.8 43.5,8 39.2,9.2 38,13.5 36.8,9.2 32.5,8 36.8,6.8', viewBox: 48, cinemaStrokeWidth: 2.1, doodleStrokeWidth: 2.1);
  static const illEmpty = EvIconData('ill_empty', 'O 19,19,8.5 | c 20,20,12.5 | p 29.5,29.5 42,42 | p 14,21 17.5,16.5 21,23 25,17.5', viewBox: 48, cinemaStrokeWidth: 2.1, doodleStrokeWidth: 2.1);
  static const illSofa = EvIconData('ill_sofa', 'R 8,20,32,12 | p 4,32 4,22 8,20 | p 44,32 44,22 40,20 | p 4,32 44,32 | p 8,32 8,38 | p 40,32 40,38 | p 12,20 12,12 36,12 36,20', viewBox: 48, cinemaStrokeWidth: 2.1, doodleStrokeWidth: 2.1);

  // Paper theme smiley avatars (FSPEC)
  static const faceSfw = EvIconData('face_sfw', 'd 9,10.6 | d 15,10.6 | a 12,12.6,4.6,25,155', cinemaStrokeWidth: 1.5, doodleStrokeWidth: 1.5);
  static const faceFamily = EvIconData('face_family', 'd 9,11.4 | d 15,11.4 | p 9.6,16.2 14.4,16.2 | a 12,13,8.2,205,335', cinemaStrokeWidth: 1.5, doodleStrokeWidth: 1.5);
  static const faceGuest = EvIconData('face_guest', 'a 9,11.6,1.6,200,340 | a 15,11.6,1.6,200,340 | a 12,13.4,3.8,25,155 | p 4.6,7.6 19.4,7.6 | p 7.6,7.6 8.8,3.6 15.2,3.6 16.4,7.6', cinemaStrokeWidth: 1.5, doodleStrokeWidth: 1.5);

  // Stage 7 supplement dual-theme icons (proto.js DSPEC L1469-1480)
  static const server = EvIconData('server', 'R 4,4,16,6.5 | R 4,13.5,16,6.5 | d 7.5,7.2 | d 7.5,16.7 | p 11,7.2 16.5,7.2 | p 11,16.7 16.5,16.7');
  static const folder = EvIconData('folder', 'B 3,6 9.5,6 11.5,8.5 21,8.5 21,19 3,19');
  static const download = EvIconData('download', 'p 12,3.5 12,14.5 | p 7.5,10.5 12,15 16.5,10.5 | p 4,15.5 4,20 20,20 20,15.5');
  static const lock = EvIconData('lock', 'R 5,10.5,14,10 | a 12,10.5,4.2,180,360 | d 12,15.4');
  static const logout = EvIconData('logout', 'p 13,4 5,4 5,20 13,20 | p 10,12 20.5,12 | p 17,8.5 20.5,12 17,15.5');
  static const keyboard = EvIconData('keyboard', 'R 2.5,6,19,12 | d 6.2,9.6 | d 9.8,9.6 | d 13.4,9.6 | d 17,9.6 | p 7,14.4 17,14.4');
  static const nowifi = EvIconData('nowifi', 'a 12,19,13,228,312 | a 12,19,8.5,226,314 | a 12,19,4,222,318 | d 12,19 | p 4,4 20,20');
  static const hourglass = EvIconData('hourglass', 'p 6,3 18,3 | p 6,21 18,21 | p 7.5,3 7.5,6.5 12,12 7.5,17.5 7.5,21 | p 16.5,3 16.5,6.5 12,12 16.5,17.5 16.5,21 | F 9,19.8 15,19.8 12,15.8');
  static const shield = EvIconData('shield', 'B 12,2.8 19.5,5.5 19,13.5 12,21 5,13.5 4.5,5.5 | p 12,8 12,12.6 | d 12,16');
  static const refresh = EvIconData('refresh', 'a 12,12,7.5,40,320 | p 18.6,3.4 17.8,7.3 13.9,6.6');

  /// The 20 selectable icons for custom zones (`ZICONS` in `proto.js`).
  static const List<EvIconData> zoneIcons = [
    navAnime, navMovie, navTv, navDoc, navBox, star, heart, rocket, ghost, music,
    balloon, ball, book, globe, crown, clock, leaf, flame, cat, spark,
  ];

  /// Complete catalog of every defined icon.
  static const List<EvIconData> all = [
    navHome, navAnime, navMovie, navTv, navDoc, navBox, navSearch,
    play, pause, next, more, star, plus, check, left, right, down, x,
    search, sort, filter, spark, aisub, cc, audio, image, vol, mute,
    back10, fwd10, pip, full, gear, users, film, wave, key, info,
    shuffle, grid, ok, a4k, cmp, palette, lang, stack, edit, zones,
    heart, rocket, ghost, music, balloon, ball, book, globe, crown,
    clock, leaf, flame, cat,
    server, folder, download, lock, logout, keyboard, nowifi, hourglass, shield, refresh,
    illClock, illTv, illEmpty, illSofa, faceSfw, faceFamily, faceGuest,
  ];

  static final Map<String, EvIconData> _byKey = {
    for (final i in all) i.key: i,
    'no_wifi': nowifi,
    'series': navTv,
    'tvshows': navTv,
    'tv': navTv,
    'movies': navMovie,
    'movie': navMovie,
    'anime': navAnime,
    'boxsets': navBox,
    'collections': navBox,
    'box': navBox,
    'documentaries': navDoc,
    'doc': navDoc,
  };

  /// Looks up an icon by its prototype or contract key, falling back to [film].
  static EvIconData byKey(String key) => _byKey[key] ?? film;

  /// Picks a deterministic smiley avatar face for a profile id.
  static EvIconData faceFor(String id) {
    final direct = _byKey['face_$id'];
    if (direct != null) return direct;
    const faces = [faceSfw, faceFamily, faceGuest];
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return faces[h % faces.length];
  }
}

/// Dual-style vector icon widget driven by [EvTheme.isPaper].
class EvIcon extends StatelessWidget {
  const EvIcon(
    this.icon, {
    super.key,
    this.size = 24,
    this.color,
    this.fillOpacity,
    this.active = true,
    this.accentColor,
    this.forcePaper,
  });

  final EvIconData icon;
  final double size;
  final Color? color, accentColor;
  final double? fillOpacity;
  final bool active;
  final bool? forcePaper;

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final isPaper = forcePaper ?? theme.isPaper;
    final strokeColor = color ?? IconTheme.of(context).color ?? theme.ink;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: EvIconPainter(
          icon: icon,
          isPaper: isPaper,
          strokeColor: strokeColor,
          accentColor: accentColor ?? theme.brand,
          fillOpacity: fillOpacity ?? (active ? (isPaper ? 1.0 : 0.2) : 0.0),
        ),
      ),
    );
  }
}

class EvIconPainter extends CustomPainter {
  EvIconPainter({
    required this.icon,
    required this.isPaper,
    required this.strokeColor,
    required this.accentColor,
    required this.fillOpacity,
  });

  final EvIconData icon;
  final bool isPaper;
  final Color strokeColor, accentColor;
  final double fillOpacity;

  bool get isSolid => icon.solid;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    if (side <= 0) return;
    final scale = side / icon.viewBox;
    canvas.save();
    canvas.translate(
      (size.width - icon.viewBox * scale) / 2,
      (size.height - icon.viewBox * scale) / 2,
    );
    canvas.scale(scale, scale);

    if (icon.solid) {
      _paintSolid(canvas);
      canvas.restore();
      return;
    }

    final compiled = _IconCompiler.compile(icon, isPaper: isPaper);
    if (fillOpacity > 0 && compiled.fills.isNotEmpty) {
      final base = isPaper ? accentColor : strokeColor;
      final fillPaint = Paint()
        ..color = base.withValues(alpha: (base.a * fillOpacity).clamp(0.0, 1.0))
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
      for (final path in compiled.fills) {
        canvas.drawPath(path, fillPaint);
      }
    }

    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = isPaper ? icon.doodleStrokeWidth : icon.cinemaStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (final path in compiled.strokes) {
      canvas.drawPath(path, strokePaint);
    }

    if (compiled.dots.isNotEmpty) {
      final dotPaint = Paint()..color = strokeColor..style = PaintingStyle.fill..isAntiAlias = true;
      for (final (center, radius) in compiled.dots) {
        canvas.drawCircle(center, radius, dotPaint);
      }
    }

    for (final (x, y, fs, text) in compiled.labels) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: strokeColor, fontSize: fs, fontWeight: FontWeight.w700, fontFamily: 'SF Pro Rounded', height: 1.0),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height * 0.85));
      tp.dispose();
    }
    canvas.restore();
  }

  void _paintSolid(Canvas canvas) {
    final p = Paint()..color = strokeColor..style = PaintingStyle.fill..isAntiAlias = true;
    switch (icon.spec) {
      case 'solid_play':
        canvas.drawPath(_solidPlayPath, p);
      case 'solid_pause':
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(6, 4.5, 4, 15), const Radius.circular(1.2)), p);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(14, 4.5, 4, 15), const Radius.circular(1.2)), p);
      case 'solid_next':
        canvas.drawPath(_solidNextPath, p);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(16.5, 5, 2.5, 14), const Radius.circular(1)), p);
      case 'solid_more':
        for (final cx in const [5.0, 12.0, 19.0]) {
          canvas.drawCircle(Offset(cx, 12), 2, p);
        }
      case 'solid_star':
        canvas.drawPath(_solidStarPath, p);
    }
  }

  static final Path _solidPlayPath = Path()
    ..moveTo(7, 4.8)..lineTo(7, 19.2)..cubicTo(7, 20.0, 7.9, 20.5, 8.6, 20.1)
    ..lineTo(19.9, 12.9)..cubicTo(20.5, 12.5, 20.5, 11.5, 19.9, 11.1)
    ..lineTo(8.6, 3.9)..cubicTo(7.9, 3.5, 7, 4.0, 7, 4.8)..close();

  static final Path _solidNextPath = Path()
    ..moveTo(5, 6.2)..lineTo(5, 17.8)..cubicTo(5, 18.6, 5.9, 19.0, 6.5, 18.6)
    ..lineTo(14.8, 12.8)..cubicTo(15.3, 12.4, 15.3, 11.6, 14.8, 11.2)
    ..lineTo(6.5, 5.4)..cubicTo(5.9, 5.0, 5, 5.4, 5, 6.2)..close();

  static final Path _solidStarPath = Path()
    ..moveTo(12, 2.8)..lineTo(14.7, 8.6)..lineTo(21.0, 9.3)..lineTo(16.3, 13.6)
    ..lineTo(17.6, 19.9)..lineTo(12.0, 16.7)..lineTo(6.4, 19.9)..lineTo(7.7, 13.6)
    ..lineTo(3.0, 9.3)..lineTo(9.3, 8.6)..close();

  @override
  bool shouldRepaint(EvIconPainter oldDelegate) =>
      oldDelegate.icon.key != icon.key ||
      oldDelegate.isPaper != isPaper ||
      oldDelegate.strokeColor != strokeColor ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.fillOpacity != fillOpacity;
}

typedef _DotRec = (Offset, double);
typedef _LblRec = (double, double, double, String);

class _CompiledIcon {
  const _CompiledIcon(this.fills, this.strokes, this.dots, this.labels);
  final List<Path> fills, strokes;
  final List<_DotRec> dots;
  final List<_LblRec> labels;
}

abstract final class _IconCompiler {
  static final Map<(String, bool), _CompiledIcon> _cache = {};

  static _CompiledIcon compile(EvIconData icon, {required bool isPaper}) =>
      _cache.putIfAbsent(
        (icon.key, isPaper),
        () => isPaper
            ? _compileDoodle(icon.key, icon.spec, icon.viewBox)
            : _compileClean(icon.cinemaSpec ?? icon.spec),
      );

  static _CompiledIcon _compileClean(String spec) {
    final fills = <Path>[], strokes = <Path>[];
    final dots = <_DotRec>[];
    final labels = <_LblRec>[];
    for (final raw in spec.split('|')) {
      final parts = raw.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first.isEmpty) continue;
      final op = parts.first;
      if (op == 'petals') {
        for (final deg in const [0, 72, 144, 216, 288]) {
          final p = _rotatedPetal(deg * math.pi / 180);
          fills.add(p);
          strokes.add(p);
        }
        continue;
      }
      if (op == 'palette_shape') {
        final p = _palettePath();
        fills.add(p);
        strokes.add(p);
        continue;
      }
      if (op == 'lbl') {
        final a = parts[1].split(',');
        labels.add((double.parse(a[0]), double.parse(a[1]), double.parse(a[2]), a[3]));
        continue;
      }
      final nums = [for (final t in parts.skip(1)) t.split(',').map(double.parse).toList()];
      if ('pPFB'.contains(op)) {
        final p = _polyline([for (final n in nums) Offset(n[0], n[1])], closed: op != 'p');
        if (op == 'F' || op == 'B') fills.add(p);
        if (op != 'F') strokes.add(p);
      } else if (op == 's' || op == 'S') {
        final p = _smoothClosed([for (final n in nums) Offset(n[0], n[1])]);
        if (op == 'S') fills.add(p);
        strokes.add(p);
      } else if ('cCO'.contains(op)) {
        final n = nums.first;
        final p = Path()..addOval(Rect.fromCircle(center: Offset(n[0], n[1]), radius: n[2]));
        if (op != 'c') fills.add(p);
        if (op != 'O') strokes.add(p);
      } else if (op == 'a') {
        final n = nums.first;
        strokes.add(Path()..addArc(Rect.fromCircle(center: Offset(n[0], n[1]), radius: n[2]), n[3] * math.pi / 180, (n[4] - n[3]) * math.pi / 180));
      } else if (op == 'r' || op == 'R') {
        final n = nums.first;
        final rx = math.min(2.4, math.min(n[2] / 4, n[3] / 4));
        final p = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(n[0], n[1], n[2], n[3]), Radius.circular(rx)));
        if (op == 'R') fills.add(p);
        strokes.add(p);
      } else if (op == 'd') {
        dots.add((Offset(nums.first[0], nums.first[1]), 1.2));
      }
    }
    return _CompiledIcon(fills, strokes, dots, labels);
  }

  static _CompiledIcon _compileDoodle(String name, String spec, double size) {
    var seed = 7;
    for (final ch in name.codeUnits) {
      seed = (seed * 31 + ch) % 2147483647;
    }
    double rnd() {
      seed = (seed * 16807) % 2147483647;
      return seed / 2147483647 - 0.5;
    }

    final k = size / 24.0, amp = 0.95 * k;
    Path poly(List<Offset> pts, {required bool closed, bool fill = false}) {
      final pp = closed ? [...pts, pts.first] : pts;
      var last = Offset(pp.first.dx + rnd() * amp * 0.5, pp.first.dy + rnd() * amp * 0.5);
      final path = Path()..moveTo(last.dx, last.dy);
      for (var i = 1; i < pp.length; i++) {
        final p = pp[i], dx = p.dx - last.dx, dy = p.dy - last.dy;
        final len = math.sqrt(dx * dx + dy * dy), sl = len == 0 ? 1.0 : len;
        final nx = -dy / sl, ny = dx / sl;
        final w = amp * math.min(1.0, sl / (7 * k)) * (fill ? 1.4 : 1.0);
        var end = Offset(p.dx + rnd() * amp * 0.35, p.dy + rnd() * amp * 0.35);
        if (closed && !fill && i == pp.length - 1) {
          end = Offset(p.dx + dx / sl * 1.4 * k, p.dy + dy / sl * 1.4 * k);
        }
        final o1 = rnd() * w, o2 = rnd() * w;
        path.cubicTo(
          last.dx + dx / 3 + nx * o1, last.dy + dy / 3 + ny * o1,
          last.dx + dx * 2 / 3 + nx * o2, last.dy + dy * 2 / 3 + ny * o2,
          end.dx, end.dy,
        );
        last = end;
      }
      if (fill) path.close();
      return path;
    }

    List<Offset> arcPts(double cx, double cy, double r, double a0, double a1, double jit) {
      final n = math.max(3, ((a1 - a0).abs() / 45).round());
      return List<Offset>.generate(n + 1, (i) {
        final a = (a0 + (a1 - a0) * i / n) * math.pi / 180;
        final rr = r * (1 + rnd() * jit);
        return Offset(cx + rr * math.cos(a), cy + rr * math.sin(a));
      });
    }

    List<Offset> rectPts(double x, double y, double w, double h) {
      final c = math.min(1.6 * k, math.min(w / 4, h / 4));
      return [
        Offset(x + c, y), Offset(x + w - c, y), Offset(x + w, y + c), Offset(x + w, y + h - c),
        Offset(x + w - c, y + h), Offset(x + c, y + h), Offset(x, y + h - c), Offset(x, y + c),
      ];
    }

    List<Offset> off(List<Offset> pts) => [for (final p in pts) Offset(p.dx + 0.75 * k, p.dy + 0.65 * k)];
    List<Offset> jit(List<Offset> pts) => [for (final p in pts) Offset(p.dx + rnd() * amp * 0.45, p.dy + rnd() * amp * 0.45)];

    final fills = <Path>[], strokes = <Path>[];
    final dots = <_DotRec>[];
    final labels = <_LblRec>[];
    for (final raw in spec.split('|')) {
      final parts = raw.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first.isEmpty) continue;
      final op = parts.first;
      if (op == 'lbl') {
        final a = parts[1].split(',');
        labels.add((double.parse(a[0]), double.parse(a[1]), double.parse(a[2]), a[3]));
        continue;
      }
      final nums = [for (final t in parts.skip(1)) t.split(',').map(double.parse).toList()];
      if ('pPFB'.contains(op)) {
        final pts = [for (final n in nums) Offset(n[0], n[1])];
        if (op == 'F' || op == 'B') fills.add(poly(off(pts), closed: true, fill: true));
        if (op != 'F') strokes.add(poly(pts, closed: op != 'p'));
      } else if (op == 's' || op == 'S') {
        final pts = [for (final n in nums) Offset(n[0], n[1])];
        if (op == 'S') fills.add(_smoothClosed(off(jit(pts))));
        strokes.add(_smoothClosed(jit(pts)));
      } else if ('cCO'.contains(op)) {
        final n = nums.first;
        if (op != 'c') fills.add(_smoothOpen(arcPts(n[0] + 0.7 * k, n[1] + 0.6 * k, n[2], 0, 360, 0.1), close: true));
        if (op != 'O') {
          final st = rnd() * 360;
          strokes.add(_smoothOpen(arcPts(n[0], n[1], n[2], st, st + 385, 0.08)));
        }
      } else if (op == 'a') {
        final n = nums.first;
        strokes.add(_smoothOpen(arcPts(n[0], n[1], n[2], n[3], n[4], 0.06)));
      } else if (op == 'r' || op == 'R') {
        final n = nums.first;
        final rp = rectPts(n[0], n[1], n[2], n[3]);
        if (op == 'R') fills.add(poly(off(rp), closed: true, fill: true));
        strokes.add(poly(rp, closed: true));
      } else if (op == 'd') {
        final n = nums.first;
        dots.add((Offset(n[0] + rnd() * 0.3, n[1] + rnd() * 0.3), 1.15 * k));
      }
    }
    return _CompiledIcon(fills, strokes, dots, labels);
  }

  static Path _polyline(List<Offset> pts, {required bool closed}) {
    final p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      p.lineTo(pts[i].dx, pts[i].dy);
    }
    return closed ? (p..close()) : p;
  }

  static Path _smoothClosed(List<Offset> pts) {
    final n = pts.length, p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < n; i++) {
      final p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
      p.cubicTo(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6, p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6, p2.dx, p2.dy);
    }
    return p..close();
  }

  static Path _smoothOpen(List<Offset> pts, {bool close = false}) {
    final p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = i > 0 ? pts[i - 1] : pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = i + 2 < pts.length ? pts[i + 2] : p2;
      p.cubicTo(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6, p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6, p2.dx, p2.dy);
    }
    return close ? (p..close()) : p;
  }

  static Path _rotatedPetal(double rad) {
    final base = Path()
      ..moveTo(12, 12.2)..cubicTo(9.5, 10.2, 9.1, 7.0, 10.6, 4.7)
      ..lineTo(12, 6)..lineTo(13.4, 4.7)..cubicTo(14.9, 7.0, 14.5, 10.2, 12, 12.2)..close();
    final m = Matrix4.identity()
      ..multiply(Matrix4.translationValues(12, 12.4, 0))
      ..multiply(Matrix4.rotationZ(rad))
      ..multiply(Matrix4.translationValues(-12, -12.4, 0));
    return base.transform(m.storage);
  }

  static Path _palettePath() => Path()
    ..moveTo(12, 3)
    ..arcToPoint(const Offset(12, 21), radius: const Radius.circular(9), largeArc: true, clockwise: false)
    ..cubicTo(13.2, 21, 13.8, 20.2, 13.8, 19.2)..cubicTo(13.8, 18.7, 13.6, 18.3, 13.3, 18.0)
    ..cubicTo(13.0, 17.7, 12.8, 17.3, 12.8, 16.8)..cubicTo(12.8, 15.8, 13.6, 15.0, 14.6, 15.0)
    ..lineTo(16.7, 15.0)
    ..arcToPoint(const Offset(21, 10.7), radius: const Radius.circular(4.3), clockwise: false)
    ..cubicTo(21, 6.4, 17, 3, 12, 3)..close();
}

/// Code-drawn EmbyView app icon (Final E · Hand-drawn Play) ported from
/// `appIcon()` / `ICON_SPEC` in `.spec/mockups/proto.js`.
class EvAppIcon extends StatelessWidget {
  const EvAppIcon({
    super.key,
    this.size = 96,
    this.dark = false,
    this.showShadow = true,
  });

  final double size;
  final bool dark;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: EvAppIconPainter(dark: dark, showShadow: showShadow),
      ),
    );
  }
}

/// Painter for [EvAppIcon] matching the 1024x1024 Apple icon template canvas
/// (`rect(100, 100, 824, 824, rx: 186)` + `doodle('iconE', ICON_SPEC, 24, 1.3)`).
class EvAppIconPainter extends CustomPainter {
  const EvAppIconPainter({this.dark = false, this.showShadow = true});

  final bool dark;
  final bool showShadow;

  static const EvIconData iconSpec = EvIconData(
    'iconE',
    'c 12,12.4,8.4 | B 9.7,8 16.4,12.4 9.7,16.8 | p 19.8,2.6 19.8,5.4 | p 18.4,4 21.2,4',
    doodleStrokeWidth: 1.3,
  );

  static const Color lightBg = Color(0xFFD97757);
  static const Color lightEdge = Color(0xFFC4643F);
  static const Color lightInk = Color(0xFF141413);
  static const Color lightFill = Color(0xFFFAF9F5);

  static const Color darkBg = Color(0xFF1F1E1C);
  static const Color darkEdge = Color(0xFF33312D);
  static const Color darkInk = Color(0xFFFAF9F5);
  static const Color darkFill = Color(0xFFD97757);

  static final RRect _baseRRect = RRect.fromRectAndRadius(
    const Rect.fromLTWH(100, 100, 824, 824),
    const Radius.circular(186),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    if (side <= 0) return;
    final scale = side / 1024.0;
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(scale, scale);

    final bg = dark ? darkBg : lightBg;
    final edge = dark ? darkEdge : lightEdge;
    final ink = dark ? darkInk : lightInk;
    final fill = dark ? darkFill : lightFill;

    if (showShadow) {
      final shadowPaint = Paint()
        ..color = const Color.fromRGBO(0, 0, 0, 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 42);
      canvas.drawRRect(_baseRRect.shift(const Offset(0, 32)), shadowPaint);
    }

    canvas.drawRRect(
      _baseRRect,
      Paint()
        ..color = bg
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    canvas.drawRRect(
      _baseRRect,
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..isAntiAlias = true,
    );

    final compiled = _IconCompiler.compile(iconSpec, isPaper: true);
    canvas.save();
    canvas.translate(212, 206);
    canvas.scale(25.0, 25.0);

    final fillPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final path in compiled.fills) {
      canvas.drawPath(path, fillPaint);
    }

    final strokePaint = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = iconSpec.doodleStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (final path in compiled.strokes) {
      canvas.drawPath(path, strokePaint);
    }

    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(EvAppIconPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.showShadow != showShadow;
}

class _FloaterSpec {
  const _FloaterSpec(this.icon, this.left, this.top, this.sizeRem, this.deg);
  final EvIconData icon;
  final double left, top, sizeRem, deg;
}

/// Brand radial glow background with gently floating library icons, ported from
/// `.brandbg`, `.brandbg.calm`, and `floaters()` in `.spec/mockups/proto.css`.
class EvBrandBackground extends StatefulWidget {
  const EvBrandBackground({
    super.key,
    this.calm = false,
    this.showFloaters,
    this.child,
  });

  /// Calm mode omits colorful glows and floating icons (used by empty/error states).
  final bool calm;

  /// Explicit override for floating icons; defaults to `!calm`.
  final bool? showFloaters;

  final Widget? child;

  static const List<_FloaterSpec> _floaters = [
    _FloaterSpec(EvIcons.navAnime, 0.05, 0.13, 6.0, -12),
    _FloaterSpec(EvIcons.navMovie, 0.14, 0.56, 4.5, 8),
    _FloaterSpec(EvIcons.navTv, 0.22, 0.84, 5.5, -6),
    _FloaterSpec(EvIcons.navDoc, 0.24, 0.30, 3.5, 14),
    _FloaterSpec(EvIcons.navBox, 0.79, 0.12, 5.5, 10),
    _FloaterSpec(EvIcons.star, 0.89, 0.42, 4.0, -10),
    _FloaterSpec(EvIcons.music, 0.74, 0.72, 6.0, 6),
    _FloaterSpec(EvIcons.ghost, 0.91, 0.83, 3.5, -14),
    _FloaterSpec(EvIcons.rocket, 0.62, 0.05, 3.5, -4),
    _FloaterSpec(EvIcons.heart, 0.36, 0.90, 3.5, 12),
  ];

  @override
  State<EvBrandBackground> createState() => _EvBrandBackgroundState();
}

class _EvBrandBackgroundState extends State<EvBrandBackground>
    with TickerProviderStateMixin {
  AnimationController? _ctrl;

  bool get _hasFloaters => widget.showFloaters ?? !widget.calm;

  void _syncController(bool disableAnimations) {
    if (_hasFloaters && !disableAnimations) {
      _ctrl ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 32),
      )..repeat();
    } else {
      _ctrl?.dispose();
      _ctrl = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncController(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void didUpdateWidget(EvBrandBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);
    final hasFloaters = _hasFloaters;

    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _BrandGlowPainter(isPaper: t.isPaper, calm: widget.calm, bg: t.bg, fg: t.fg),
                ),
                if (hasFloaters)
                  LayoutBuilder(
                    builder: (_, constraints) {
                      final w = constraints.maxWidth;
                      final h = constraints.maxHeight;
                      final drift = s.rem(1.5);
                      final opacity = t.isPaper ? 0.17 : 0.07;
                      return Stack(
                        children: [
                          for (var i = 0; i < EvBrandBackground._floaters.length; i++)
                            _buildFloater(EvBrandBackground._floaters[i], i, w, h, drift, opacity, t, s),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }

  Widget _buildFloater(
    _FloaterSpec spec,
    int index,
    double width,
    double height,
    double drift,
    double opacity,
    EvTheme t,
    EvScale s,
  ) {
    final iconSize = s.rem(spec.sizeRem);
    final iconChild = Opacity(
      opacity: opacity,
      child: Transform.rotate(
        angle: spec.deg * math.pi / 180,
        child: EvIcon(spec.icon, size: iconSize, color: t.ink, active: false),
      ),
    );
    final ctrl = _ctrl;
    return Positioned(
      left: width * spec.left,
      top: height * spec.top,
      child: ctrl == null
          ? iconChild
          : AnimatedBuilder(
              animation: ctrl,
              child: iconChild,
              builder: (_, child) {
                // 32s full cycle = 16s up + 16s down, staggered by -2.3s per icon.
                final phase = (ctrl.value + (index * 2.3 / 32.0)) % 1.0;
                final wave = 0.5 - 0.5 * math.cos(phase * math.pi * 2);
                return Transform.translate(
                  offset: Offset(0, -drift * wave),
                  child: child,
                );
              },
            ),
    );
  }
}

class _BrandGlowPainter extends CustomPainter {
  const _BrandGlowPainter({
    required this.isPaper,
    required this.calm,
    required this.bg,
    required this.fg,
  });

  final bool isPaper, calm;
  final Color bg, fg;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = bg);

    void drawGlow(double cxFrac, double cyFrac, double rxFrac, double ryFrac, Color color) {
      final cx = size.width * cxFrac;
      final cy = size.height * cyFrac;
      final rx = size.width * rxFrac;
      final ry = size.height * ryFrac;
      if (rx <= 0 || ry <= 0) return;
      canvas.save();
      canvas.translate(cx, cy);
      canvas.scale(1.0, ry / rx);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: const [0.0, 0.70],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: rx));
      canvas.drawCircle(Offset.zero, rx, paint);
      canvas.restore();
    }

    if (calm) {
      if (!isPaper) {
        drawGlow(0.50, 0.30, 0.70, 0.70, fg.withValues(alpha: 0.05));
      }
      return;
    }

    if (isPaper) {
      drawGlow(0.16, 0.20, 0.60, 0.70, const Color.fromRGBO(217, 119, 87, 0.13));
      drawGlow(0.86, 0.82, 0.55, 0.65, const Color.fromRGBO(106, 155, 204, 0.10));
    } else {
      drawGlow(0.16, 0.20, 0.60, 0.70, const Color.fromRGBO(217, 119, 87, 0.24));
      drawGlow(0.86, 0.82, 0.55, 0.65, const Color.fromRGBO(127, 167, 255, 0.16));
      drawGlow(0.72, 0.08, 0.40, 0.50, const Color.fromRGBO(183, 166, 255, 0.10));
    }
  }

  @override
  bool shouldRepaint(_BrandGlowPainter oldDelegate) =>
      oldDelegate.isPaper != isPaper ||
      oldDelegate.calm != calm ||
      oldDelegate.bg != bg ||
      oldDelegate.fg != fg;
}
