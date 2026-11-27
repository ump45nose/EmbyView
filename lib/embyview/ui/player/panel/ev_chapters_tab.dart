import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_format.dart';
import 'package:moonfin/embyview/ui/player/panel/ev_player_panel.dart';

const _kTabular = [FontFeature.tabularFigures()];

/// Chapter list tab inside [EvPlayerPanel].
class EvChaptersTab extends StatelessWidget {
  const EvChaptersTab({
    super.key,
    required this.snapshot,
    required this.onSeek,
  });

  final PlaybackSnapshot snapshot;
  final ValueChanged<Duration> onSeek;

  /// Returns the index of the chapter containing [position], or `-1` when
  /// [chapters] is empty or [position] precedes every chapter start.
  static int activeChapterIndex(List<ChapterMark> chapters, Duration position) {
    var activeIdx = -1;
    Duration? bestStart;
    for (var i = 0; i < chapters.length; i++) {
      final start = chapters[i].start;
      if (start <= position && (bestStart == null || start >= bestStart)) {
        bestStart = start;
        activeIdx = i;
      }
    }
    return activeIdx;
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = EvPanelPalette.of(t);
    final chapters = snapshot.chapters;
    final activeIdx = activeChapterIndex(chapters, snapshot.position);

    return Column(
      key: const Key('ev_panel_chapters_tab'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        EvPanelHeading(
          '章节',
          trailing: chapters.isNotEmpty ? '${chapters.length} 章' : null,
          topMargin: 0.5,
        ),
        Container(
          padding: EdgeInsets.all(s.rem(0.25)),
          decoration: BoxDecoration(
            color: pal.cardBg,
            borderRadius: BorderRadius.circular(s.rem(1.0)),
            border: Border.all(color: pal.cardBorder),
          ),
          child: chapters.isEmpty
              ? Padding(
                  key: const Key('ev_chapters_empty'),
                  padding: EdgeInsets.symmetric(
                    horizontal: s.rem(0.875),
                    vertical: s.rem(1.5),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      EvIcon(EvIcons.chapters, size: s.rem(1.75), color: pal.subInk, active: false),
                      SizedBox(height: s.rem(0.625)),
                      Text(
                        '当前影片没有章节信息',
                        textAlign: TextAlign.center,
                        style: t.bodyStyle(s.rem(0.875), color: pal.subInk),
                      ),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < chapters.length; i++) ...[
                      Builder(builder: (_) {
                        final chapter = chapters[i];
                        final selected = i == activeIdx;
                        final label = evFormatChapterLabel(chapter.name, index: i) ?? '第 ${i + 1} 章';
                        final badgeBg = selected
                            ? (pal.isPaper ? const Color.fromRGBO(181, 83, 47, 0.14) : const Color.fromRGBO(255, 255, 255, 0.18))
                            : pal.badgeBg;
                        final badgeFg = selected ? pal.checkColor : pal.badgeFg;
                        return EvPanelTrackRow(
                          key: Key('ev_chapter_row_$i'),
                          selected: selected,
                          title: label,
                          subtitle: evFormatPlayerTime(chapter.start),
                          onTap: () => onSeek(chapter.start),
                          badge: Container(
                            width: s.rem(2.25),
                            height: s.rem(2.25),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: badgeBg,
                              borderRadius: BorderRadius.circular(s.rem(0.625)),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: t
                                  .bodyStyle(s.rem(0.8125), fontWeight: FontWeight.w700, color: badgeFg)
                                  .copyWith(fontFeatures: _kTabular),
                            ),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}
