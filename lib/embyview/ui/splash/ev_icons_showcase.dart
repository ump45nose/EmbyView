import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/ui/icons/ev_icons.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

/// App icon showcase page ported from `vIcons` in `.spec/mockups/proto.js` and
/// `.icons` / `.docks` in `.spec/mockups/proto.css` for the demo launcher.
class EvIconsShowcase extends StatelessWidget {
  const EvIconsShowcase({super.key});

  static const List<int> _previewSizes = [128, 64, 32, 16];
  static const List<Color?> _dockSlots = [
    Color(0xFF5AA0F2),
    Color(0xFF6BD46B),
    Color(0xFFF2C14E),
    null, // EmbyView
    Color(0xFFEF6F6C),
    Color(0xFF9A8CF0),
    Color(0xFF8E8E93),
  ];

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context);
    final s = EvScale.of(context);

    return EvBrandBackground(
      showFloaters: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(s.gutter, s.rem(6.0), s.gutter, s.rem(4.0)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('应用图标', style: t.displayStyle(s.font(2.75))),
            SizedBox(height: s.rem(0.75)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: s.rem(50.0)),
              child: Text(
                '定稿：手绘播放。陶土色底上一个手绘圆圈框住纸白播放键，右上一颗小星点，和纸面主题的简笔画图标同一套笔触。按 Apple 图标模板出 16–1024 全套尺寸，另出深色外观（系统深色模式下 Dock 用）。',
                style: t.bodyStyle(s.font(1.0), color: t.ink3, height: 1.6),
              ),
            ),
            SizedBox(height: s.rem(2.25)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: s.rem(56.0)),
              child: Row(
                children: [
                  Expanded(child: _variantCard(t, s, dark: false)),
                  SizedBox(width: s.rem(1.5)),
                  Expanded(child: _variantCard(t, s, dark: true)),
                ],
              ),
            ),
            SizedBox(height: s.rem(2.5)),
            Text(
              'Dock 里的样子',
              style: t.bodyStyle(s.font(1.0), fontWeight: FontWeight.w600, color: t.ink3),
            ),
            SizedBox(height: s.rem(1.0)),
            Row(
              children: [
                Expanded(child: _dockPreview(s, dark: true)),
                SizedBox(width: s.rem(1.5)),
                Expanded(child: _dockPreview(s, dark: false)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _variantCard(EvTheme t, EvScale s, {required bool dark}) {
    return Container(
      key: Key(dark ? 'ev_icons_showcase_dark' : 'ev_icons_showcase_light'),
      padding: EdgeInsets.all(s.rem(1.75)),
      decoration: BoxDecoration(
        color: t.isPaper ? const Color(0xFFFFFFFF) : t.fill,
        borderRadius: BorderRadius.circular(s.rem(1.5)),
        border: Border.all(color: t.line, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: s.rem(0.75)),
              child: EvAppIcon(size: s.rem(13.0), dark: dark),
            ),
          ),
          Text(
            dark ? '深色外观' : '默认外观',
            style: t.bodyStyle(s.font(1.25), fontWeight: FontWeight.w600, color: t.ink),
          ),
          SizedBox(height: s.rem(1.25)),
          Wrap(
            spacing: s.rem(1.25),
            runSpacing: s.rem(0.75),
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              for (final px in _previewSizes)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EvAppIcon(size: px.toDouble(), dark: dark, showShadow: false),
                    SizedBox(height: s.rem(0.375)),
                    Text('$px', style: t.bodyStyle(s.font(0.8125), color: t.ink3)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dockPreview(EvScale s, {required bool dark}) {
    final dotColor = dark ? const Color(0xFFFFFFFF) : const Color(0xFF141413);
    final dockBg = dark
        ? const Color.fromRGBO(255, 255, 255, 0.16)
        : const Color.fromRGBO(255, 255, 255, 0.45);
    return Container(
      key: Key(dark ? 'ev_icons_dock_dark' : 'ev_icons_dock_light'),
      height: s.rem(10.0),
      alignment: Alignment.bottomCenter,
      padding: EdgeInsets.only(bottom: s.rem(1.25)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(s.rem(1.25)),
        gradient: RadialGradient(
          center: dark ? const Alignment(-0.4, -1.0) : const Alignment(0.4, -1.0),
          radius: 1.2,
          colors: dark
              ? const [Color(0xFF40375E), Color(0xFF14131F)]
              : const [Color(0xFFF4DCCB), Color(0xFFD8E0EE)],
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: s.rem(0.5), vertical: s.rem(0.375)),
          decoration: BoxDecoration(
            color: dockBg,
            borderRadius: BorderRadius.circular(s.rem(1.25)),
            border: Border.all(color: const Color.fromRGBO(255, 255, 255, 0.22), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _dockSlots.length; i++) ...[
                if (i > 0) SizedBox(width: s.rem(0.375)),
                SizedBox(
                  width: s.rem(3.5),
                  height: s.rem(3.5),
                  child: _dockSlots[i] != null
                      ? Center(
                          child: Container(
                            width: s.rem(2.8),
                            height: s.rem(2.8),
                            decoration: BoxDecoration(
                              color: _dockSlots[i]!.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(s.rem(0.7)),
                            ),
                          ),
                        )
                      : Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.center,
                          children: [
                            EvAppIcon(size: s.rem(3.5), dark: dark),
                            Positioned(
                              bottom: -s.rem(0.3),
                              child: Container(
                                width: s.rem(0.25),
                                height: s.rem(0.25),
                                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
