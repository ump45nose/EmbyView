import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/player/panel/ev_player_panel.dart';

/// Audio track selection tab inside [EvPlayerPanel].
class EvAudioTab extends StatelessWidget {
  const EvAudioTab({super.key, required this.snapshot, required this.onSelectAudio});

  final PlaybackSnapshot snapshot;
  final ValueChanged<String> onSelectAudio;

  static bool _isCommentary(PlaybackTrack track) {
    final nameLower = track.name.toLowerCase();
    return track.name.contains('评论') ||
        nameLower.contains('commentary') ||
        track.id.toLowerCase() == 'cm';
  }

  static String? _langBadgeForRaw(String? input) {
    final s = input?.trim().toLowerCase() ?? '';
    if (s.isEmpty) return null;
    final tokens = s.split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toSet();
    if (s.contains('中') || s.contains('简') || s.contains('繁') || s.contains('国语') || s.contains('粤语') ||
        tokens.any((w) => w == 'zh' || w == 'chi' || w == 'zho' || w == 'zhi' || w == 'cmn' || w == 'yue' || w == 'chinese')) {
      return '中';
    }
    if (s.contains('日') || tokens.any((w) => w == 'ja' || w == 'jpn' || w == 'jp' || w == 'japanese')) return '日';
    if (s.contains('英') || tokens.any((w) => w == 'en' || w == 'eng' || w == 'english')) return 'EN';
    if (s.contains('韩') || s.contains('韓') || tokens.any((w) => w == 'ko' || w == 'kor' || w == 'korean')) return '韩';
    if (s.contains('法') || tokens.any((w) => w == 'fr' || w == 'fre' || w == 'fra' || w == 'french')) return 'FR';
    if (s.contains('德') || tokens.any((w) => w == 'de' || w == 'ger' || w == 'deu' || w == 'german')) return 'DE';
    if (s.contains('西班牙') || tokens.any((w) => w == 'es' || w == 'spa' || w == 'spanish')) return 'ES';
    if (s.contains('俄') || tokens.any((w) => w == 'ru' || w == 'rus' || w == 'russian')) return 'RU';
    if (s.contains('意') || tokens.any((w) => w == 'it' || w == 'ita' || w == 'italian')) return 'IT';
    if (s.contains('泰') || tokens.any((w) => w == 'th' || w == 'tha' || w == 'thai')) return 'TH';
    return null;
  }

  static String _langBadge(PlaybackTrack track, {required bool isOriginal}) {
    if (_isCommentary(track)) return '评';
    if (isOriginal) return '原';
    final matched = _langBadgeForRaw(track.language) ?? _langBadgeForRaw(track.name);
    if (matched != null) return matched;
    final lang = track.language?.trim() ?? '';
    if (RegExp(r'^[A-Za-z]{2,3}$').hasMatch(lang) && lang.toLowerCase() != 'und') {
      return lang.substring(0, 2).toUpperCase();
    }
    return '音';
  }

  static String _trackSubtitle(PlaybackTrack t, {required bool isOriginal}) {
    final tech = [
      for (final v in [t.format, t.layout]) if (v != null && v.trim().isNotEmpty) v.trim(),
    ].join(' ');
    if (isOriginal) {
      return tech.isNotEmpty ? '原声 · $tech' : '原声';
    }
    return tech;
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = EvPanelPalette.of(t);
    final tracks = snapshot.audioTracks;
    String? firstNonCommentaryId;
    for (final tr in tracks) {
      if (!_isCommentary(tr)) {
        firstNonCommentaryId = tr.id;
        break;
      }
    }
    return Column(
      key: const Key('ev_panel_audio_tab'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
      children: [
        const EvPanelHeading('音轨', topMargin: 0.5),
        Container(
          padding: EdgeInsets.all(s.rem(0.25)),
          decoration: BoxDecoration(color: pal.cardBg, borderRadius: BorderRadius.circular(s.rem(1.0)), border: Border.all(color: pal.cardBorder)),
          child: tracks.isEmpty
              ? Padding(padding: EdgeInsets.all(s.rem(0.875)), child: Text('无可选音轨', style: t.bodyStyle(s.rem(0.875), color: pal.subInk)))
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final track in tracks) ...[
                    Builder(builder: (_) {
                      final isOriginal = !_isCommentary(track) && (track.id == firstNonCommentaryId || track.name.contains('原声'));
                      return EvPanelTrackRow(
                        key: Key('ev_audio_track_${track.id}'),
                        selected: track.id == snapshot.selectedAudioId, title: track.name, subtitle: _trackSubtitle(track, isOriginal: isOriginal),
                        onTap: () => onSelectAudio(track.id),
                        badge: Container(
                          width: s.rem(2.25), height: s.rem(2.25), alignment: Alignment.center,
                          decoration: BoxDecoration(color: pal.badgeBg, borderRadius: BorderRadius.circular(s.rem(0.625))),
                          child: Text(_langBadge(track, isOriginal: isOriginal), style: t.bodyStyle(s.rem(0.8125), fontWeight: FontWeight.w700, color: pal.badgeFg)),
                        ),
                      );
                    }),
                  ],
                ]),
        ),
      ],
    );
  }
}

/// Video enhancement (Anime4K) tab inside [EvPlayerPanel].
class EvVideoTab extends StatelessWidget {
  const EvVideoTab({super.key, required this.snapshot, required this.onToggleAnime4k, required this.onStartCompare});

  final PlaybackSnapshot snapshot;
  final VoidCallback onToggleAnime4k, onStartCompare;

  static String stateLabel(Anime4kState state) => switch (state) {
    Anime4kState.active => '已生效',
    Anime4kState.pending => '启用中',
    Anime4kState.degraded => '已降级',
    Anime4kState.failed => '启用失败',
    Anime4kState.unsupported => '不支持',
    Anime4kState.off => '已关闭',
  };

  static String _sizeText(VideoSize? sz, String? fallback) =>
      sz != null && sz.height > 0 ? '${sz.height}p' : (fallback?.trim().isNotEmpty == true ? fallback!.trim() : '—');

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = EvPanelPalette.of(t);
    final a4k = snapshot.anime4k;
    final canCompare = a4k.state == Anime4kState.active && a4k.comparison == ComparisonState.available;
    final showReason = (a4k.requested && a4k.state != Anime4kState.active && a4k.state != Anime4kState.pending) ||
        ((a4k.state == Anime4kState.failed || a4k.state == Anime4kState.degraded || a4k.state == Anime4kState.unsupported) &&
            a4k.reason?.trim().isNotEmpty == true);
    final reasonText = a4k.reason?.trim().isNotEmpty == true ? a4k.reason!.trim() : stateLabel(a4k.state);
    final inputText = _sizeText(a4k.originalSize, snapshot.quality?.resolution ?? snapshot.item?.quality?.resolution);
    final outputText = _sizeText(a4k.enhancedSize, '—');

    Widget stat(String label, String val) => Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: s.rem(0.75), vertical: s.rem(0.625)),
        decoration: BoxDecoration(color: pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.06), borderRadius: BorderRadius.circular(s.rem(0.75))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.8125), color: pal.subInk)),
          SizedBox(height: s.rem(0.125)),
          Text(val, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.9375), fontWeight: FontWeight.w700, color: pal.ink).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      ),
    );

    return Column(
      key: const Key('ev_panel_video_tab'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
      children: [
        const EvPanelHeading('画面增强', topMargin: 0.5),
        Container(
          key: const Key('ev_video_a4k_card'), padding: EdgeInsets.all(s.rem(1.125)),
          decoration: BoxDecoration(color: pal.cardBg, borderRadius: BorderRadius.circular(s.rem(1.25)), border: Border.all(color: pal.cardBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Container(
                width: s.rem(2.625), height: s.rem(2.625), padding: EdgeInsets.all(s.rem(0.5)),
                decoration: BoxDecoration(color: pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.10), borderRadius: BorderRadius.circular(s.rem(0.75))),
                child: EvIcon(EvIcons.a4k, size: s.rem(1.625), color: pal.ink),
              ),
              SizedBox(width: s.rem(0.75)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Anime4K', style: t.bodyStyle(s.rem(1.0625), fontWeight: FontWeight.w700, color: pal.ink)),
                  Text(stateLabel(a4k.state), style: t.bodyStyle(s.rem(0.8125), color: pal.subInk)),
                ]),
              ),
              _PanelToggle(key: const Key('ev_video_a4k_toggle'), value: a4k.requested, onTap: onToggleAnime4k, pal: pal),
            ]),
            SizedBox(height: s.rem(0.75)),
            Text('线条重建放大，1080p 番剧在 4K 显示器上更清晰。只在 Mac 上提供。', style: t.bodyStyle(s.rem(0.875), color: pal.subInk, height: 1.5)),
            if (showReason) ...[
              SizedBox(height: s.rem(0.75)),
              Container(
                key: const Key('ev_video_a4k_reason'),
                padding: EdgeInsets.symmetric(horizontal: s.rem(0.75), vertical: s.rem(0.625)),
                decoration: BoxDecoration(
                  color: pal.isPaper ? const Color.fromRGBO(217, 119, 87, 0.14) : const Color.fromRGBO(255, 159, 10, 0.16),
                  borderRadius: BorderRadius.circular(s.rem(0.75)),
                  border: Border.all(color: pal.isPaper ? const Color.fromRGBO(181, 83, 47, 0.28) : const Color.fromRGBO(255, 159, 10, 0.35)),
                ),
                child: Text(reasonText, style: t.bodyStyle(s.rem(0.8125), fontWeight: FontWeight.w500, color: pal.isPaper ? const Color(0xFFB5532F) : const Color(0xFFFFD57E), height: 1.45)),
              ),
            ],
            SizedBox(height: s.rem(0.875)),
            Row(spacing: s.rem(0.5), children: [stat('输入', inputText), stat('输出', outputText), stat('状态', stateLabel(a4k.state))]),
            SizedBox(height: s.rem(0.875)),
            EvPanelButton(key: const Key('ev_video_compare_btn'), icon: EvIcons.cmp, label: '拖动中线对比原画', enabled: canCompare, onPressed: canCompare ? onStartCompare : null),
          ]),
        ),
      ],
    );
  }
}

class _PanelToggle extends StatelessWidget {
  const _PanelToggle({super.key, required this.value, required this.onTap, required this.pal});
  final bool value;
  final VoidCallback onTap;
  final EvPanelPalette pal;

  @override
  Widget build(BuildContext context) {
    final s = EvScale.of(context), w = s.rem(2.875), h = s.rem(1.6875), knob = s.rem(1.3125);
    return Semantics(
      toggled: value, button: true, label: value ? '关闭 Anime4K' : '开启 Anime4K',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220), width: w, height: h, padding: EdgeInsets.all((h - knob) / 2),
            decoration: BoxDecoration(color: value ? pal.toggleOn : pal.toggleOff, borderRadius: BorderRadius.circular(999)),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 280), curve: EvCurves.spring,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: knob, height: knob,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFFFFFFF), boxShadow: [BoxShadow(offset: Offset(0, 1), blurRadius: 3, color: Color.fromRGBO(0, 0, 0, 0.25))]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
