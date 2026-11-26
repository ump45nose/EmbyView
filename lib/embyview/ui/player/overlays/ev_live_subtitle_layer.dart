import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

const _kWhite = Color(0xFFFFFFFF);

/// Renders live AI-generated subtitle cues directly over the video surface
/// only after the selected run has taken over from the native renderer.
class EvLiveSubtitleLayer extends StatelessWidget {
  const EvLiveSubtitleLayer({
    super.key, required this.snapshot, this.subtitleSnapshot,
    required this.controlsVisible, required this.panelOpen,
    this.scrubHovering = false, this.paused = false, this.creditsActive = false,
  });

  final PlaybackSnapshot snapshot;
  final SubtitleSnapshot? subtitleSnapshot;
  final bool controlsVisible, panelOpen, scrubHovering, paused, creditsActive;

  /// Resolves the active cue matching [position], or `null` when none matches.
  static SubtitleCue? activeCueAt(List<SubtitleCue> cues, Duration position) {
    for (final cue in cues) {
      if (cue.start <= position && position < cue.end) return cue;
    }
    return null;
  }

  SubtitleCue? _resolveCue() {
    final id = snapshot.subtitleOverlayId, subtitles = subtitleSnapshot;
    if (id == null || snapshot.selectedSubtitleId != id || subtitles == null ||
        subtitles.generation != snapshot.generation || subtitles.selectedTrackId != id) {
      return null;
    }
    return activeCueAt(subtitles.cues ?? const [], snapshot.position);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context);
    final cue = _resolveCue();
    final raw = cue == null ? null : (cue.translation?.trim().isNotEmpty == true ? cue.translation! : cue.text).trim();
    final text = raw != null && raw.isNotEmpty ? raw : null;
    final visible = text != null && !scrubHovering && !paused && !creditsActive;
    final shadows = [
      Shadow(blurRadius: scale.rem(0.5), color: const Color.fromRGBO(0, 0, 0, 0.9)),
      const Shadow(offset: Offset(0, 2), blurRadius: 2, color: Color.fromRGBO(0, 0, 0, 0.8)),
    ];
    final style = (theme.isPaper
            ? theme.serifStyle(scale.rem(2.0), fontWeight: FontWeight.w500, color: _kWhite, height: 1.35)
            : theme.bodyStyle(scale.rem(2.0), fontWeight: FontWeight.w600, color: _kWhite, height: 1.35))
        .copyWith(shadows: shadows);

    return AnimatedPositioned(
      key: const Key('ev_player_live_subtitle'),
      duration: const Duration(milliseconds: 500), curve: EvCurves.out,
      left: 0, right: panelOpen ? scale.rem(29.0) : 0, bottom: controlsVisible ? scale.rem(13.0) : scale.rem(7.0),
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0, duration: const Duration(milliseconds: 200), curve: EvCurves.soft,
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: scale.rem(1.5)),
              child: text == null
                  ? const SizedBox.shrink(key: ValueKey('ev_live_sub_empty'))
                  : Padding(
                      key: ValueKey('ev_live_sub_${cue!.id}_$text'),
                      padding: EdgeInsets.symmetric(horizontal: scale.rem(1.0)),
                      child: Text(text, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis, style: style),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
