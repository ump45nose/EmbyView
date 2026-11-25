import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_format.dart';

/// Darkened pause info overlay mirroring `.pausecard` and `.player.paused`.
class EvPauseOverlay extends StatelessWidget {
  const EvPauseOverlay({
    super.key, required this.visible, required this.snapshot,
    this.art, this.onResume, this.clock = DateTime.now,
  });

  final bool visible;
  final PlaybackSnapshot snapshot;
  final CardArtwork? art;
  final VoidCallback? onResume;
  final DateTime Function() clock;

  String? _resolveTitle(ArtworkRef? logo) {
    final epTitle = evFormatPauseEpisodeTitle(snapshot.item, snapshot.target);
    if (epTitle != null) return epTitle;
    final raw = snapshot.item?.title.trim() ?? '';
    return logo == null && raw.isNotEmpty ? raw : null;
  }

  String? _formatRemainingMeta() {
    final dur = snapshot.duration ?? snapshot.item?.duration;
    if (dur == null || dur <= Duration.zero) return null;
    final rem = dur > snapshot.position ? dur - snapshot.position : Duration.zero;
    return evFormatPauseRemainingLine(rem, clock());
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context);
    final scale = EvScale.of(context);
    final logo = art?.logo ?? snapshot.item?.art.logo;
    final title = _resolveTitle(logo);
    final overview = snapshot.item?.overview?.trim();
    final meta = _formatRemainingMeta();
    final eyebrowSize = scale.font(0.875);

    Widget card = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (logo != null)
          Padding(
            padding: EdgeInsets.only(bottom: scale.rem(1.5)),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: scale.rem(4.75), maxWidth: scale.rem(19)),
              child: Image(
                image: logo.image, fit: BoxFit.contain, alignment: Alignment.bottomLeft,
                gaplessPlayback: true, filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(bottom: scale.rem(0.875)),
          child: Text(
            '已暂停',
            style: theme.bodyStyle(eyebrowSize, fontWeight: FontWeight.w600, color: const Color.fromRGBO(255, 255, 255, 0.62))
                .copyWith(letterSpacing: eyebrowSize * 0.12),
          ),
        ),
        if (title != null)
          Text(
            title, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: theme.bodyStyle(scale.rem(2.125), fontWeight: FontWeight.w700, color: const Color(0xFFFFFFFF), height: 1.2),
          ),
        if (overview != null && overview.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: scale.rem(0.75)),
            child: Text(
              overview, maxLines: 3, overflow: TextOverflow.ellipsis,
              style: theme.bodyStyle(scale.rem(1.0625), color: const Color.fromRGBO(255, 255, 255, 0.78), height: 1.62),
            ),
          ),
        if (meta != null)
          Padding(
            padding: EdgeInsets.only(top: scale.rem(1.0)),
            child: Text(
              meta,
              style: theme.bodyStyle(scale.rem(0.9375), color: const Color.fromRGBO(255, 255, 255, 0.62))
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
      ],
    );

    if (onResume != null) {
      card = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: onResume,
          child: Semantics(button: true, label: '恢复播放', child: card),
        ),
      );
    }

    return IgnorePointer(
      ignoring: !visible,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: visible ? 1.0 : 0.0, duration: const Duration(milliseconds: 800), curve: EvCurves.soft,
              child: const ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.58)),
            ),
          ),
          Positioned(
            left: scale.gutter, bottom: scale.rem(13.5),
            width: math.min(scale.rem(38), scale.size.width * 0.46),
            child: AnimatedOpacity(
              opacity: visible ? 1.0 : 0.0, duration: const Duration(milliseconds: 600), curve: EvCurves.soft,
              child: AnimatedContainer(
                key: const Key('ev_player_pause_card'),
                duration: const Duration(milliseconds: 800), curve: EvCurves.out,
                transform: Matrix4.translationValues(0.0, visible ? 0.0 : scale.rem(1.0), 0.0),
                child: card,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
