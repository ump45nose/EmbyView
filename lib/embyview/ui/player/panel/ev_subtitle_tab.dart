import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/subtitles/model/subtitle_document.dart' show normalizeSubtitleFormat;
import 'package:moonfin/embyview/ui/player/controls/ev_track_language.dart';
import 'package:moonfin/embyview/ui/player/controls/ev_player_format.dart';
import 'package:moonfin/embyview/ui/player/panel/ev_player_panel.dart';

const _kWhite = Color(0xFFFFFFFF), _kPaperInk = Color(0xFF141413);
const _kTerracotta = Color(0xFFD97757), _kTerracottaDark = Color(0xFFB5532F), _kOlive = Color(0xFF5F7346);
const _kTabular = [FontFeature.tabularFigures()];

/// Subtitle tab inside [EvPlayerPanel]: track list, AI subtitle card, quick
/// actions (translate / align / season batch), and dialogue / online search.
class EvSubtitleTab extends StatefulWidget {
  const EvSubtitleTab({
    super.key, required this.snapshot, this.subtitleSnapshot, this.subtitlePanel,
    this.subtitles, this.initialLowerTab, required this.onSelectSubtitle, required this.onSeek, this.onToast,
  });

  final PlaybackSnapshot snapshot;
  final SubtitleSnapshot? subtitleSnapshot;
  final SubtitlePanel? subtitlePanel;
  final EmbyViewSubtitles? subtitles;
  final String? initialLowerTab;
  final ValueChanged<String?> onSelectSubtitle;
  final ValueChanged<Duration> onSeek;
  final void Function(String message, {EvIconData? icon})? onToast;

  @override State<EvSubtitleTab> createState() => _EvSubtitleTabState();
}

class _EvSubtitleTabState extends State<EvSubtitleTab> with TickerProviderStateMixin {
  late final AnimationController _borderCtrl, _waveCtrl, _pulseCtrl;
  late final TextEditingController _searchCtrl;
  final _searchFocus = FocusNode(debugLabel: 'ev_sub_search_focus');
  final _dlgScroll = ScrollController();

  late String _lowerTab;
  SubtitleSource? _sourceFilter;
  List<SubtitleSearchGroup> _searchGroups = const [];
  bool _searching = false, _autoSearched = false, _quotingSeason = false, _queuingSeason = false;
  String? _searchError, _seasonError;
  SeasonQuote? _seasonQuote;
  int _searchGen = -1, _searchToken = 0, _seasonToken = 0, _lastCueIdx = -1;

  bool get _hasCues => widget.subtitleSnapshot?.cues != null;
  String get _effectiveLowerTab => _hasCues ? _lowerTab : 'search';
  bool get _aiAnimating {
    final s = widget.subtitleSnapshot?.ai?.state;
    return s == AiRunState.preparing || s == AiRunState.generating || s == AiRunState.catchingUp;
  }

  @override
  void initState() {
    super.initState();
    _lowerTab = widget.initialLowerTab == 'search' ? 'search' : 'dlg';
    _borderCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4));
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
    _searchCtrl = TextEditingController(text: _defaultQuery());
    _searchGen = widget.snapshot.generation;
    _syncAnimations();
    if (widget.subtitlePanel != null && _effectiveLowerTab == 'search') _ensureAutoSearch();
  }

  @override
  void didUpdateWidget(EvSubtitleTab old) {
    super.didUpdateWidget(old);
    if (widget.snapshot.generation != _searchGen) {
      _searchGen = widget.snapshot.generation;
      _searchToken++;
      _seasonToken++;
      _quotingSeason = false;
      _queuingSeason = false;
      _searchGroups = const []; _sourceFilter = null; _searching = false; _autoSearched = false;
      _searchError = null; _seasonQuote = null; _seasonError = null; _lastCueIdx = -1;
      _searchCtrl.text = _defaultQuery();
    }
    if (widget.initialLowerTab != old.initialLowerTab && widget.initialLowerTab != null) {
      _lowerTab = widget.initialLowerTab!;
      if (_lowerTab == 'dlg') _lastCueIdx = -1;
    }
    _syncAnimations();
    if (widget.subtitlePanel != null && _effectiveLowerTab == 'search' && !_autoSearched) _ensureAutoSearch();
  }

  void _syncAnimations() {
    if (_aiAnimating) {
      if (!_borderCtrl.isAnimating) _borderCtrl.repeat();
      if (!_waveCtrl.isAnimating) _waveCtrl.repeat(reverse: true);
      if (!_pulseCtrl.isAnimating) _pulseCtrl.repeat();
    } else {
      if (_borderCtrl.isAnimating) _borderCtrl.stop();
      if (_waveCtrl.isAnimating) _waveCtrl.stop();
      if (_pulseCtrl.isAnimating) _pulseCtrl.stop();
    }
  }

  @override
  void dispose() {
    _borderCtrl.dispose(); _waveCtrl.dispose(); _pulseCtrl.dispose();
    _searchCtrl.dispose(); _searchFocus.dispose(); _dlgScroll.dispose();
    super.dispose();
  }

  String _defaultQuery() {
    final item = widget.snapshot.item;
    final title = item?.title.trim().isNotEmpty == true ? item!.title.trim() : widget.snapshot.target.itemId;
    final ep = item?.episodeNumber ?? widget.snapshot.target.episodeNumber;
    if (ep != null) {
      final m = RegExp(r'(\d+)').firstMatch(item?.seasonId ?? widget.snapshot.target.seasonId ?? '');
      final sNum = m != null ? int.tryParse(m.group(1)!) ?? 1 : 1;
      return '$title S${sNum.toString().padLeft(2, '0')}E${ep.toString().padLeft(2, '0')}';
    }
    return item?.year != null ? '$title ${item!.year}' : title;
  }

  void _ensureAutoSearch() {
    if (_autoSearched || widget.subtitlePanel == null) return;
    _autoSearched = true;
    unawaited(_runSearch(_searchCtrl.text));
  }

  Future<void> _runSearch(String raw) async {
    final panel = widget.subtitlePanel;
    if (panel == null) return;
    final token = ++_searchToken, q = raw.trim();
    setState(() { _searching = true; _searchError = null; });
    try {
      final res = await panel.search(q.isEmpty ? null : q);
      if (mounted && token == _searchToken) setState(() { _searchGroups = res; _searching = false; });
    } catch (e) {
      if (mounted && token == _searchToken) setState(() { _searching = false; _searchError = e is EmbyViewFailure ? e.reason : '搜索字幕失败'; });
    }
  }

  static bool _isCommentaryAudio(PlaybackTrack track) {
    final nameLower = track.name.toLowerCase();
    return track.name.contains('评论') ||
        nameLower.contains('commentary') ||
        track.id.toLowerCase() == 'cm';
  }

  String _sourceAudioLanguage() {
    final tracks = widget.snapshot.audioTracks;
    PlaybackTrack? target;
    for (final t in tracks) {
      if (t.id == widget.snapshot.selectedAudioId && !_isCommentaryAudio(t)) {
        target = t;
        break;
      }
    }
    if (target == null) {
      for (final t in tracks) {
        if (!_isCommentaryAudio(t)) {
          target = t;
          break;
        }
      }
    }
    if (target == null) return '外语';
    final lang = evTrackLanguage(target.language, target.name);
    return lang.code == 'en' ? '英语' : lang.code == null ? '外语' : lang.title;
  }

  PlaybackTrack? _pickTranslateTarget() {
    final tracks = widget.snapshot.subtitleTracks;
    bool isForeignSub(PlaybackTrack t) {
      if (t.source == PlaybackTrackSource.ai) return false;
      final code = evTrackLanguage(t.language, t.name).code;
      return code != 'zh' && code != 'yue';
    }

    final selectedId = widget.snapshot.selectedSubtitleId;
    if (selectedId != null) {
      for (final t in tracks) {
        if (t.id == selectedId && isForeignSub(t)) return t;
      }
    }
    for (final t in tracks) {
      if (isForeignSub(t)) return t;
    }
    return null;
  }

  String _translateSourceLabel() {
    final target = _pickTranslateTarget();
    if (target == null) return '外语';
    final lang = evTrackLanguage(target.language, target.name);
    return lang.code == null ? '外语' : lang.title;
  }

  String? _pickTrack({bool preferForeign = false}) {
    final tracks = widget.snapshot.subtitleTracks;
    if (preferForeign) {
      final foreign = _pickTranslateTarget();
      if (foreign != null) return foreign.id;
    }
    return widget.snapshot.selectedSubtitleId ?? (tracks.isNotEmpty ? tracks.first.id : null);
  }

  Future<void> _runTrackAction(bool isTranslate) async {
    final panel = widget.subtitlePanel;
    if (panel == null) return;
    final id = _pickTrack(preferForeign: isTranslate);
    if (id == null) { widget.onToast?.call(isTranslate ? '当前没有可翻译的字幕轨' : '当前没有可校正的字幕轨', icon: EvIcons.info); return; }
    try {
      await (isTranslate ? panel.translate(id) : panel.align(id));
      widget.onToast?.call(isTranslate ? '正在翻译字幕…' : '正在按对白校正时间轴…', icon: isTranslate ? EvIcons.aisub : EvIcons.clock);
    } catch (e) {
      widget.onToast?.call(e is EmbyViewFailure ? e.reason : (isTranslate ? '翻译失败' : '时间轴校正失败'), icon: EvIcons.info);
    }
  }

  Future<void> _runPanelAction(Future<void> Function() action, String fallbackError) async {
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      widget.onToast?.call(e is EmbyViewFailure ? e.reason : fallbackError, icon: EvIcons.info);
    }
  }

  Future<void> _runSeasonAction({required bool confirm}) async {
    final subs = widget.subtitles;
    if (confirm) {
      final quote = _seasonQuote;
      if (subs == null || quote == null || _queuingSeason) return;
      final token = ++_seasonToken, gen = widget.snapshot.generation;
      setState(() => _queuingSeason = true);
      try {
        await subs.queueSeason(quote);
        if (!mounted || token != _seasonToken || widget.snapshot.generation != gen) return;
        setState(() { _queuingSeason = false; _seasonQuote = null; });
        widget.onToast?.call('已加入整季队列 · ${quote.seasonName}', icon: EvIcons.ok);
      } catch (e) {
        if (!mounted || token != _seasonToken || widget.snapshot.generation != gen) return;
        final msg = e is EmbyViewFailure ? e.reason : '加入队列失败';
        setState(() { _queuingSeason = false; _seasonError = msg; });
        widget.onToast?.call(msg, icon: EvIcons.info);
      }
      return;
    }
    final seriesId = widget.snapshot.item?.seriesId ?? widget.snapshot.target.seriesId;
    final seasonId = widget.snapshot.item?.seasonId ?? widget.snapshot.target.seasonId;
    if (subs == null || seriesId?.isNotEmpty != true || seasonId?.isNotEmpty != true) {
      widget.onToast?.call('仅剧集支持整季批量生成', icon: EvIcons.info);
      return;
    }
    final token = ++_seasonToken, gen = widget.snapshot.generation;
    setState(() { _quotingSeason = true; _seasonError = null; });
    try {
      final quote = await subs.quoteSeason(seriesId!, seasonId!);
      if (!mounted || token != _seasonToken || widget.snapshot.generation != gen) return;
      setState(() { _seasonQuote = quote; _quotingSeason = false; });
    } catch (e) {
      if (!mounted || token != _seasonToken || widget.snapshot.generation != gen) return;
      final msg = e is EmbyViewFailure ? e.reason : '获取整季估算失败';
      setState(() { _quotingSeason = false; _seasonError = msg; });
      widget.onToast?.call(msg, icon: EvIcons.info);
    }
  }

  static PlaybackTrackSource _trackSourceFromOrigin(SubtitleOrigin origin) => switch (origin) {
    SubtitleOrigin.embedded => PlaybackTrackSource.embedded,
    SubtitleOrigin.embyExternal => PlaybackTrackSource.embyExternal,
    SubtitleOrigin.nas => PlaybackTrackSource.nas,
    SubtitleOrigin.online => PlaybackTrackSource.online,
    SubtitleOrigin.ai => PlaybackTrackSource.ai,
  };

  static String _saveLabel(SubtitleSaveState s) => const {SubtitleSaveState.saved: '已存 NAS', SubtitleSaveState.saving: '保存中…', SubtitleSaveState.failed: '保存失败'}[s] ?? '';
  static String _indexLabel(SubtitleIndexState s) => const {SubtitleIndexState.recognized: 'Emby 已识别', SubtitleIndexState.unrecognized: 'Emby 未识别', SubtitleIndexState.checking: 'Emby 识别中…'}[s] ?? '';
  static String _sourceShort(PlaybackTrackSource s) => const {PlaybackTrackSource.embedded: '内嵌', PlaybackTrackSource.embyExternal: '外挂', PlaybackTrackSource.nas: 'NAS', PlaybackTrackSource.online: '在线下载', PlaybackTrackSource.ai: 'AI 生成'}[s]!;
  Widget _retryChip(EvTheme t, EvScale s, EvPanelPalette pal, Key key, String trackId) => evPanelTap(
    key: key,
    onTap: () {
      final panel = widget.subtitlePanel;
      if (panel != null) unawaited(_runPanelAction(() => panel.retrySave(trackId), '重试保存失败'));
    },
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: s.rem(0.55), vertical: s.rem(0.2)),
      decoration: BoxDecoration(color: pal.isPaper ? const Color.fromRGBO(181, 83, 47, 0.14) : const Color.fromRGBO(255, 110, 110, 0.2), borderRadius: BorderRadius.circular(999)),
      child: Text('重试', style: t.bodyStyle(s.rem(0.75), fontWeight: FontWeight.w600, color: pal.isPaper ? _kTerracottaDark : const Color(0xFFFF9B9B))),
    ),
  );

  Widget _trackBadge(EvTheme t, EvScale s, EvPanelPalette pal, {bool isAi = false, bool isNas = false, String? text}) {
    final sz = s.rem(2.25), r = BorderRadius.circular(s.rem(0.625));
    if (isAi) {
      return Container(
        width: sz, height: sz, alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: r, color: pal.isPaper ? _kTerracotta : null, gradient: pal.isPaper ? null : const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0x66B28CFF), Color(0x4D6FB8FF)])),
        child: EvIcon(EvIcons.aisub, size: s.rem(1.25), color: pal.isPaper ? _kPaperInk : _kWhite),
      );
    }
    if (isNas) {
      return Container(
        width: sz, height: sz, alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: r, color: pal.isPaper ? const Color.fromRGBO(95, 115, 70, 0.16) : const Color.fromRGBO(95, 211, 166, 0.22)),
        child: EvIcon(EvIcons.check, size: s.rem(1.25), color: pal.isPaper ? _kOlive : const Color(0xFF9FF0CC)),
      );
    }
    return Container(width: sz, height: sz, alignment: Alignment.center, decoration: BoxDecoration(color: pal.badgeBg, borderRadius: r), child: Text(text ?? '—', style: t.bodyStyle(s.rem(0.8125), fontWeight: FontWeight.w700, color: pal.badgeFg)));
  }

  Widget _buildTrackList(EvTheme t, EvScale s, EvPanelPalette pal) {
    final stateById = {for (final st in widget.subtitleSnapshot?.tracks ?? const <SubtitleTrackState>[]) st.trackId: st};
    final selectedId = widget.snapshot.selectedSubtitleId, seen = <String>{};
    final rows = <Widget>[
      EvPanelTrackRow(key: const Key('ev_sub_track_off'), badge: _trackBadge(t, s, pal, text: '—'), title: '关闭字幕', selected: selectedId == null, onTap: () => widget.onSelectSubtitle(null)),
    ];

    void addTrack(String id, String name, PlaybackTrackSource src, String? lang, String? fmt, SubtitleTrackState? st) {
      seen.add(id);
      final isAi = src == PlaybackTrackSource.ai || st?.origin == SubtitleOrigin.ai;
      final isNas = !isAi && (src == PlaybackTrackSource.nas || src == PlaybackTrackSource.online || st?.origin == SubtitleOrigin.nas || st?.origin == SubtitleOrigin.online);
      final language = evTrackLanguage(lang, name);
      final codec = normalizeSubtitleFormat(fmt ?? '');
      final format = codec == 'sup' ? 'PGS' : codec.toUpperCase();
      final title = isAi || isNas ? name : language.title;
      final meta = [_sourceShort(src), if (format.isNotEmpty) format, if (st != null && _saveLabel(st.save).isNotEmpty) _saveLabel(st.save), if (st != null && _indexLabel(st.index).isNotEmpty) _indexLabel(st.index)].join(' · ');
      rows.add(EvPanelTrackRow(
        key: Key('ev_sub_track_$id'), selected: selectedId == id, title: title, subtitle: meta, onTap: () => widget.onSelectSubtitle(id),
        badge: _trackBadge(t, s, pal, isAi: isAi, isNas: isNas, text: language.badge),
        trailingAction: st?.save == SubtitleSaveState.failed && widget.subtitlePanel != null ? _retryChip(t, s, pal, Key('ev_sub_retry_$id'), id) : null,
      ));
    }

    for (final tr in widget.snapshot.subtitleTracks) { addTrack(tr.id, tr.name, tr.source, tr.language, tr.format, stateById[tr.id]); }
    for (final st in widget.subtitleSnapshot?.tracks ?? const <SubtitleTrackState>[]) {
      if (seen.contains(st.trackId)) continue;
      final src = _trackSourceFromOrigin(st.origin);
      addTrack(st.trackId, st.origin == SubtitleOrigin.ai ? '简体中文 · AI 生成' : '外挂字幕', src, 'zh', null, st);
    }

    return Container(padding: EdgeInsets.all(s.rem(0.25)), decoration: BoxDecoration(color: pal.cardBg, borderRadius: BorderRadius.circular(s.rem(1.0)), border: Border.all(color: pal.cardBorder)), child: Column(mainAxisSize: MainAxisSize.min, children: rows));
  }

  Widget _buildAiCard(EvTheme t, EvScale s, EvPanelPalette pal) {
    final ai = widget.subtitleSnapshot?.ai, state = ai?.state, pos = widget.snapshot.position;
    final durMs = widget.snapshot.duration?.inMilliseconds ?? 0;
    final lead = ai?.coverageEnd != null ? (ai!.coverageEnd! - pos) : null;

    final (subline, badge, pulse, badgeOn) = switch (state) {
      null || AiRunState.cancelled => ('从 ${evFormatPlayerTime(pos)} 开始听写、翻译', '未开启', false, false),
      AiRunState.preparing => ('正在听写第一段对白', '准备中', true, false),
      AiRunState.generating => (
        ai?.coverageEnd != null ? '已生成到 ${evFormatPlayerTime(ai!.coverageEnd!)}' : '正在生成字幕',
        lead != null && lead > Duration.zero ? '领先 ${evFormatLeadDuration(lead)}' : '生成中', true, true,
      ),
      AiRunState.catchingUp => ('音频追赶中，即将同步', '追赶中', true, false),
      AiRunState.completed => (
        (ai?.coverageStart != null && ai?.coverageEnd != null) ? '已覆盖 ${evFormatPlayerTime(ai!.coverageStart!)} – ${evFormatPlayerTime(ai.coverageEnd!)}' : '本集字幕已生成完成',
        '已完成', false, true,
      ),
      AiRunState.failed => ('生成中断', '失败', false, false),
    };

    final posF = durMs > 0 ? (pos.inMilliseconds / durMs).clamp(0.0, 1.0) : 0.0;
    final laneSegments = _computeLaneSegments(ai, durMs);
    final radius = s.rem(1.25);

    return AnimatedBuilder(
      animation: _borderCtrl,
      builder: (_, child) => CustomPaint(painter: _ConicBorderPainter(angle: _aiAnimating ? _borderCtrl.value * 2 * math.pi : 0.0, radius: radius, isPaper: pal.isPaper), child: child),
      child: Container(
        key: const Key('ev_ai_card'), padding: EdgeInsets.all(s.rem(1.125)),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), color: pal.isPaper ? _kWhite : null, gradient: pal.isPaper ? null : const LinearGradient(begin: Alignment(-0.8, -1.0), end: Alignment(0.8, 1.0), colors: [Color(0x29B28CFF), Color(0x0F6FB8FF)])),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            width: s.rem(2.625), height: s.rem(2.625), padding: EdgeInsets.all(s.rem(0.5)),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(s.rem(0.75)), color: pal.isPaper ? _kTerracotta : null, gradient: pal.isPaper ? null : const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF9F7BFF), Color(0xFF5FB8FF)])),
            child: EvIcon(EvIcons.aisub, size: s.rem(1.625), color: pal.isPaper ? _kPaperInk : _kWhite),
          ),
          SizedBox(width: s.rem(0.75)),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('AI 中字', style: t.bodyStyle(s.rem(1.0625), fontWeight: FontWeight.w700, color: pal.ink)),
            SizedBox(height: s.rem(0.125)),
            Text(subline, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.8125), color: pal.subInk).copyWith(fontFeatures: _kTabular)),
          ])),
          SizedBox(width: s.rem(0.5)),
          Container(
            key: const Key('ev_ai_status_badge'), height: s.rem(1.625), padding: EdgeInsets.symmetric(horizontal: s.rem(0.625)),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), color: badgeOn ? (pal.isPaper ? const Color.fromRGBO(95, 115, 70, 0.16) : const Color.fromRGBO(95, 224, 192, 0.18)) : (pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.10))),
            child: Row(mainAxisSize: MainAxisSize.min, spacing: s.rem(0.375), children: [
              if (pulse) _buildPulseDot(s, pal),
              Text(badge, style: t.bodyStyle(s.rem(0.8125), fontWeight: FontWeight.w600, color: badgeOn ? (pal.isPaper ? _kOlive : const Color(0xFF8FF0D2)) : (pal.isPaper ? const Color(0xFF66655F) : const Color.fromRGBO(255, 255, 255, 0.78))).copyWith(fontFeatures: _kTabular)),
            ]),
          ),
        ]),
        if (state == null || state == AiRunState.cancelled) ...[
          SizedBox(height: s.rem(0.75)),
          Text('把${_sourceAudioLanguage()}对白听写成文字，再译成简体中文。约 40 秒后开始出字，之后一直领先播放进度。', style: t.bodyStyle(s.rem(0.875), color: pal.isPaper ? pal.subInk : const Color.fromRGBO(255, 255, 255, 0.72), height: 1.55)),
          SizedBox(height: s.rem(1.0)),
          EvPanelButton(
            key: const Key('ev_ai_start'), primary: true, icon: EvIcons.aisub, label: '开始生成',
            onPressed: () {
              final panel = widget.subtitlePanel;
              if (panel != null) unawaited(_runPanelAction(panel.startAi, '启动 AI 字幕失败'));
            },
          ),
        ] else if (state == AiRunState.preparing || state == AiRunState.generating || state == AiRunState.catchingUp) ...[
          SizedBox(height: s.rem(1.0)),
          SizedBox(height: s.rem(2.25), child: AnimatedBuilder(animation: _waveCtrl, builder: (_, _) => Row(crossAxisAlignment: CrossAxisAlignment.center, spacing: 3, children: [
            for (var k = 0; k < 28; k++) Expanded(child: FractionallySizedBox(heightFactor: 0.2 + 0.8 * (0.5 + 0.5 * math.sin((_waveCtrl.value * 2 * math.pi) - k * 0.45)), child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: pal.isPaper ? _kTerracotta : null, gradient: pal.isPaper ? null : const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFB9A0FF), Color(0xFF6FB8FF)]))))),
          ]))),
          SizedBox(height: s.rem(1.0)),
          _buildLane(s, pal, posF, laneSegments),
          SizedBox(height: s.rem(0.5)),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('播放到 ${evFormatPlayerTime(pos)}', style: t.bodyStyle(s.rem(0.8125), color: pal.subInk).copyWith(fontFeatures: _kTabular)),
            Text(state == AiRunState.preparing ? '约 40 秒后出字' : state == AiRunState.catchingUp ? '正在追赶进度' : '字幕已到 ${ai?.coverageEnd != null ? evFormatPlayerTime(ai!.coverageEnd!) : '--:--'}', style: t.bodyStyle(s.rem(0.8125), color: pal.subInk).copyWith(fontFeatures: _kTabular)),
          ]),
          SizedBox(height: s.rem(0.875)),
          EvPanelButton(
            key: const Key('ev_ai_cancel'), label: '取消生成',
            onPressed: () {
              final panel = widget.subtitlePanel;
              if (panel != null) unawaited(_runPanelAction(panel.cancelAi, '取消 AI 字幕失败'));
            },
          ),
        ] else if (state == AiRunState.failed) ...[
          SizedBox(height: s.rem(0.75)),
          Text(ai?.failure?.reason.trim().isNotEmpty == true ? ai!.failure!.reason : 'AI 字幕生成失败，请稍后重试。', style: t.bodyStyle(s.rem(0.875), color: pal.isPaper ? _kTerracottaDark : const Color(0xFFFFB4B4), height: 1.5)),
          SizedBox(height: s.rem(0.875)),
          EvPanelButton(
            key: const Key('ev_ai_start'), primary: true, icon: EvIcons.aisub, label: '重新生成',
            onPressed: () {
              final panel = widget.subtitlePanel;
              if (panel != null) unawaited(_runPanelAction(panel.startAi, '重新生成 AI 字幕失败'));
            },
          ),
        ] else if (state == AiRunState.completed) ...[
          SizedBox(height: s.rem(0.625)),
          Text(subline, style: t.bodyStyle(s.rem(0.875), color: pal.subInk)),
        ],
      ]),
      ),
    );
  }

  Widget _buildPulseDot(EvScale s, EvPanelPalette pal) {
    final base = pal.isPaper ? _kTerracotta : const Color(0xFFB28CFF);
    final sz = s.rem(0.5);
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, _) {
        final t = (_pulseCtrl.value / 0.7).clamp(0.0, 1.0);
        final alpha = _pulseCtrl.value <= 0.7 ? 0.6 * (1.0 - t) : 0.0;
        final spread = _pulseCtrl.value <= 0.7 ? t * s.rem(0.5) : 0.0;
        return Container(
          width: sz, height: sz,
          decoration: BoxDecoration(
            shape: BoxShape.circle, color: base,
            boxShadow: [BoxShadow(color: base.withValues(alpha: alpha), spreadRadius: spread)],
          ),
        );
      },
    );
  }

  static List<(double, double)> _computeLaneSegments(AiRun? ai, int durMs) {
    if (ai == null || durMs <= 0) return const [];
    if (ai.coverage.isNotEmpty) {
      return [
        for (final r in ai.coverage)
          if (r.end > r.start)
            ((r.start.inMilliseconds / durMs).clamp(0.0, 1.0), (r.end.inMilliseconds / durMs).clamp(0.0, 1.0)),
      ];
    }
    final end = ai.coverageEnd;
    if (end == null) return const [];
    final startMs = (ai.coverageStart?.inMilliseconds ?? 0).clamp(0, durMs);
    final endMs = end.inMilliseconds.clamp(0, durMs);
    return endMs > startMs ? [(startMs / durMs, endMs / durMs)] : const [];
  }

  Widget _buildLane(EvScale s, EvPanelPalette pal, double posF, List<(double, double)> segments) {
    final h = s.rem(0.375), dot = s.rem(0.75);
    return LayoutBuilder(builder: (_, c) {
      final w = c.maxWidth;
      return SizedBox(
        height: dot,
        child: Stack(clipBehavior: Clip.none, alignment: Alignment.centerLeft, children: [
          Container(
            height: h, width: w,
            decoration: BoxDecoration(color: pal.isPaper ? const Color(0xFFE8E6DC) : const Color.fromRGBO(255, 255, 255, 0.10), borderRadius: BorderRadius.circular(3)),
          ),
          for (final (segS, segE) in segments)
            if (w > 0 && segE > segS)
              Positioned(
                left: w * segS,
                width: math.min(w - w * segS, math.max(2.0, w * (segE - segS))),
                top: (dot - h) / 2,
                height: h,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: pal.isPaper ? _kTerracotta : null,
                    gradient: pal.isPaper ? null : const LinearGradient(colors: [Color(0xFF9F7BFF), Color(0xFF5FE0C0)]),
                  ),
                ),
              ),
          Positioned(
            left: (w * posF - dot / 2).clamp(0.0, math.max(0.0, w - dot)),
            child: Container(width: dot, height: dot, decoration: BoxDecoration(shape: BoxShape.circle, color: pal.isPaper ? _kPaperInk : _kWhite, border: Border.all(color: pal.isPaper ? _kWhite : const Color.fromRGBO(0, 0, 0, 0.35), width: 2))),
          ),
        ]),
      );
    });
  }

  Widget _buildQuickActions(EvTheme t, EvScale s, EvPanelPalette pal) {
    final hasSeries = (widget.snapshot.item?.seriesId ?? widget.snapshot.target.seriesId)?.isNotEmpty == true;
    Widget tile(Key key, EvIconData icon, String title, String sub, VoidCallback onTap) => Expanded(
      child: _QuickActionTile(
        key: key, icon: icon, title: title, subtitle: sub, pal: pal, onTap: onTap,
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(spacing: s.rem(0.5), children: [
        tile(const Key('ev_ai_translate'), EvIcons.lang, '翻译字幕', '${_translateSourceLabel()} → 中文', () => unawaited(_runTrackAction(true))),
        tile(const Key('ev_ai_align'), EvIcons.clock, '校正时间轴', '按对白对齐', () => unawaited(_runTrackAction(false))),
        tile(const Key('ev_ai_season'), EvIcons.stack, '整季生成', hasSeries ? '后台排队' : '仅剧集可用', () => unawaited(_runSeasonAction(confirm: false))),
      ]),
      if (_quotingSeason) Padding(padding: EdgeInsets.only(top: s.rem(0.625)), child: Text('正在估算整季费用…', style: t.bodyStyle(s.rem(0.8125), color: pal.subInk))),
      if (_seasonQuote != null) _buildSeasonQuoteBox(t, s, pal, _seasonQuote!),
      if (_seasonError != null && _seasonQuote == null) Padding(padding: EdgeInsets.only(top: s.rem(0.5)), child: Text(_seasonError!, style: t.bodyStyle(s.rem(0.8125), color: pal.isPaper ? _kTerracottaDark : const Color(0xFFFFB4B4)))),
    ]);
  }

  Widget _buildSeasonQuoteBox(EvTheme t, EvScale s, EvPanelPalette pal, SeasonQuote q) {
    final usd = (q.estimatedCostMicros / 1e6).toStringAsFixed(2);
    final blocked = q.budget == BudgetState.exceeded || q.budget == BudgetState.missingCredentials;
    final budgetText = const {BudgetState.available: '预算充足', BudgetState.exceeded: '超出本月预算', BudgetState.missingCredentials: '缺少 AI 凭据', BudgetState.unknown: '预算状态未知'}[q.budget]!;
    return Container(
      key: const Key('ev_ai_season_quote'), margin: EdgeInsets.only(top: s.rem(0.625)), padding: EdgeInsets.all(s.rem(0.875)),
      decoration: BoxDecoration(color: pal.cardBg, borderRadius: BorderRadius.circular(s.rem(1.0)), border: Border.all(color: pal.cardBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('${q.seasonName} · 待生成 ${q.pendingCount} 集（已完成 ${q.completedCount} 集）', style: t.bodyStyle(s.rem(0.875), fontWeight: FontWeight.w600, color: pal.ink)),
        SizedBox(height: s.rem(0.25)),
        Text('预估费用 \$$usd · $budgetText${q.reason?.trim().isNotEmpty == true ? '（${q.reason!.trim()}）' : ''}', style: t.bodyStyle(s.rem(0.8125), color: pal.subInk)),
        SizedBox(height: s.rem(0.75)),
        Row(spacing: s.rem(0.5), children: [
          Expanded(child: EvPanelButton(key: const Key('ev_ai_season_confirm'), primary: true, enabled: !blocked && !_queuingSeason, label: _queuingSeason ? '提交中…' : '确认生成', onPressed: () => unawaited(_runSeasonAction(confirm: true)))),
          Expanded(child: EvPanelButton(label: '取消', onPressed: () => setState(() => _seasonQuote = null))),
        ]),
      ]),
    );
  }

  Widget _buildLowerSection(EvTheme t, EvScale s, EvPanelPalette pal) {
    final tab = _effectiveLowerTab;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (_hasCues)
        Container(
          margin: EdgeInsets.only(top: s.rem(1.375), bottom: s.rem(0.75)), padding: EdgeInsets.all(s.rem(0.25)),
          decoration: BoxDecoration(color: pal.segBg, borderRadius: BorderRadius.circular(s.rem(0.75))),
          child: Row(children: [
            for (final (id, label, icon, key) in const [('dlg', '对白', EvIcons.cc, Key('ev_sub_lower_dlg')), ('search', '在线搜索', EvIcons.search, Key('ev_sub_lower_search'))])
              Expanded(
                child: evPanelTap(
                  key: key,
                  onTap: () {
                    setState(() {
                      if (id == 'dlg' && _lowerTab != 'dlg') _lastCueIdx = -1;
                      _lowerTab = id;
                    });
                    if (id == 'search') _ensureAutoSearch();
                  },
                  child: Container(
                    height: s.rem(2.125),
                    decoration: BoxDecoration(color: tab == id ? pal.segActiveBg : const Color(0x00000000), borderRadius: BorderRadius.circular(s.rem(0.55))),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, spacing: s.rem(0.375), children: [
                      EvIcon(icon, size: s.rem(1.0), color: tab == id ? pal.segActiveFg : pal.segInactiveFg),
                      Text(label, style: t.bodyStyle(s.rem(0.875), fontWeight: FontWeight.w600, color: tab == id ? pal.segActiveFg : pal.segInactiveFg)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      if (tab == 'dlg' && _hasCues) _buildDialogueList(t, s, pal, widget.subtitleSnapshot!.cues!) else _buildOnlineSearch(t, s, pal),
    ]);
  }

  Widget _buildDialogueList(EvTheme t, EvScale s, EvPanelPalette pal, List<SubtitleCue> cues) {
    if (cues.isEmpty) {
      return Container(height: s.rem(8.0), alignment: Alignment.center, decoration: BoxDecoration(color: pal.cardBg, borderRadius: BorderRadius.circular(s.rem(1.0)), border: Border.all(color: pal.cardBorder)), child: Text('暂无对白字幕', style: t.bodyStyle(s.rem(0.875), color: pal.subInk)));
    }
    final pos = widget.snapshot.position;
    var curIdx = 0;
    for (var i = 0; i < cues.length; i++) {
      if (cues[i].start <= pos && pos < cues[i].end) { curIdx = i; break; }
      if (cues[i].start <= pos) curIdx = i;
    }
    final startIdx = math.max(0, curIdx - 8), window = cues.sublist(startIdx, math.min(cues.length, curIdx + 9)), localCur = curIdx - startIdx, rowH = s.rem(2.75);
    if (curIdx != _lastCueIdx) {
      _lastCueIdx = curIdx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_dlgScroll.hasClients) return;
        _dlgScroll.jumpTo((localCur * rowH - _dlgScroll.position.viewportDimension / 2 + rowH / 2).clamp(0.0, _dlgScroll.position.maxScrollExtent));
      });
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Container(
        key: const Key('ev_sub_dialogue_list'), height: s.rem(19.0), padding: EdgeInsets.all(s.rem(0.375)),
        decoration: BoxDecoration(color: pal.isPaper ? _kWhite : const Color.fromRGBO(255, 255, 255, 0.04), borderRadius: BorderRadius.circular(s.rem(1.0)), border: pal.isPaper ? Border.all(color: const Color(0xFFE8E6DC)) : null),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            stops: [0.0, 0.18, 0.82, 1.0],
            colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          ).createShader(bounds),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: ListView.builder(
              controller: _dlgScroll, itemCount: window.length,
              itemBuilder: (_, i) {
                final cue = window[i], isOn = i == localCur;
                final line = cue.translation?.trim().isNotEmpty == true ? cue.translation!.trim() : cue.text.trim();
                final tCol = isOn ? (pal.isPaper ? _kTerracottaDark : const Color.fromRGBO(255, 255, 255, 0.85)) : (pal.isPaper ? const Color(0xFF87867F) : const Color.fromRGBO(255, 255, 255, 0.4));
                final xCol = isOn ? pal.ink : (pal.isPaper ? const Color(0xFF87867F) : const Color.fromRGBO(255, 255, 255, 0.55));
                return evPanelTap(
                  key: Key('ev_dlg_cue_${cue.id}'),
                  onTap: () { widget.onSeek(cue.start); widget.onToast?.call('跳到 ${evFormatPlayerTime(cue.start)} · $line', icon: EvIcons.back10); },
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: s.rem(0.75), vertical: s.rem(0.5)),
                    decoration: BoxDecoration(color: isOn ? pal.rowSelected : const Color(0x00000000), borderRadius: BorderRadius.circular(s.rem(0.75))),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: s.rem(3.25), child: Text(evFormatPlayerTime(cue.start), style: t.bodyStyle(s.rem(0.8125), color: tCol).copyWith(fontFeatures: _kTabular))),
                      SizedBox(width: s.rem(0.5)),
                      Expanded(child: Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.9375), fontWeight: isOn ? FontWeight.w600 : FontWeight.w400, color: xCol, height: 1.45))),
                    ]),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      Padding(padding: EdgeInsets.fromLTRB(s.rem(0.25), s.rem(0.625), s.rem(0.25), 0), child: Text('没听清就点那一句，直接跳回去重听', style: t.bodyStyle(s.rem(0.8125), color: pal.subInk))),
    ]);
  }

  static (String, String, Color, Color, Color, Color) _srcStyle(SubtitleSource src) => switch (src) {
    SubtitleSource.xunlei => ('迅雷', '迅', const Color(0x3D4096FF), const Color(0xFF9CC8FF), const Color(0x294096FF), const Color(0xFF1D6FD1)),
    SubtitleSource.assrt => ('射手', '射', const Color(0x38FFAA50), const Color(0xFFFFC98F), const Color(0x2EFFAA50), const Color(0xFFB2620A)),
    SubtitleSource.openSubtitles => ('OpenSubtitles', 'O', const Color(0x3378DC78), const Color(0xFFA6EBA6), const Color(0x3378DC78), const Color(0xFF3E7A3E)),
    SubtitleSource.anime => ('字幕组', '字', const Color(0x38FF6E96), const Color(0xFFFFADC4), const Color(0x2EFF6E96), const Color(0xFFB83B63)),
  };

  Widget _buildOnlineSearch(EvTheme t, EvScale s, EvPanelPalette pal) {
    final counts = {for (final src in SubtitleSource.values) src: 0}, failures = <SubtitleSource, String>{};
    var total = 0;
    for (final g in _searchGroups) {
      counts[g.source] = (counts[g.source] ?? 0) + g.candidates.length;
      total += g.candidates.length;
      if (g.failure != null) failures[g.source] = g.failure!.reason;
    }
    final filtered = [for (final g in _searchGroups) if (_sourceFilter == null || g.source == _sourceFilter) ...g.candidates];
    final trackByCand = {for (final st in widget.subtitleSnapshot?.tracks ?? const <SubtitleTrackState>[]) if (st.candidateId != null) st.candidateId!: st};

    Widget chip(Key key, String label, bool selected, VoidCallback onTap) => evPanelTap(
      key: key, onTap: onTap,
      child: Container(
        height: s.rem(2.0), padding: EdgeInsets.symmetric(horizontal: s.rem(0.75)), alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), color: selected ? (pal.isPaper ? _kPaperInk : const Color(0xFFF5F5F7)) : (pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.08))),
        child: Text(label, style: t.bodyStyle(s.rem(0.8125), fontWeight: FontWeight.w600, color: selected ? (pal.isPaper ? const Color(0xFFFAF9F5) : const Color(0xFF111111)) : (pal.isPaper ? _kPaperInk : const Color.fromRGBO(255, 255, 255, 0.78)))),
      ),
    );

    return Column(key: const Key('ev_sub_online_search'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      EvPanelHeading('在线搜索', trailing: _searching ? '搜索中…' : '四个来源 · $total 条', topMargin: _hasCues ? 0.25 : 1.125),
      evPanelTap(
        onTap: () => _searchFocus.requestFocus(),
        child: Container(
          height: s.rem(2.75), padding: EdgeInsets.symmetric(horizontal: s.rem(0.875)),
          decoration: BoxDecoration(color: pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.08), borderRadius: BorderRadius.circular(s.rem(0.875))),
          child: Row(children: [
            EvIcon(EvIcons.search, size: s.rem(1.0), color: pal.subInk),
            SizedBox(width: s.rem(0.5)),
            Expanded(
              child: EditableText(
                key: const Key('ev_sub_search_input'), controller: _searchCtrl, focusNode: _searchFocus,
                style: t.bodyStyle(s.rem(0.9375), color: pal.ink), cursorColor: pal.isPaper ? _kTerracottaDark : _kWhite,
                backgroundCursorColor: pal.subInk, textInputAction: TextInputAction.search, onSubmitted: (v) => unawaited(_runSearch(v)),
              ),
            ),
          ]),
        ),
      ),
      SizedBox(height: s.rem(0.75)),
      Wrap(spacing: s.rem(0.375), runSpacing: s.rem(0.375), children: [
        chip(const Key('ev_sub_src_all'), '全部', _sourceFilter == null, () => setState(() => _sourceFilter = null)),
        for (final src in SubtitleSource.values)
          chip(Key('ev_sub_src_${src.name}'), '${_srcStyle(src).$1} ${counts[src] ?? 0}', _sourceFilter == src, () => setState(() => _sourceFilter = _sourceFilter == src ? null : src)),
      ]),
      if (_searchError != null) Padding(padding: EdgeInsets.only(top: s.rem(0.5)), child: Text(_searchError!, style: t.bodyStyle(s.rem(0.8125), color: pal.isPaper ? _kTerracottaDark : const Color(0xFFFFB4B4)))),
      for (final e in failures.entries)
        if (_sourceFilter == null || _sourceFilter == e.key)
          Padding(padding: EdgeInsets.only(top: s.rem(0.375)), child: Text('${_srcStyle(e.key).$1}：${e.value}', style: t.bodyStyle(s.rem(0.75), color: pal.subInk))),
      SizedBox(height: s.rem(0.375)),
      if (!_searching && filtered.isEmpty) Padding(padding: EdgeInsets.symmetric(vertical: s.rem(1.0)), child: Text('未找到匹配字幕', style: t.bodyStyle(s.rem(0.875), color: pal.subInk))),
      for (final cand in filtered) _buildCandidateRow(t, s, pal, cand, trackByCand[cand.id]),
    ]);
  }

  Widget _buildCandidateRow(EvTheme t, EvScale s, EvPanelPalette pal, SubtitleCandidate cand, SubtitleTrackState? st) {
    final (srcName, letter, bg, fg, pBg, pFg) = _srcStyle(cand.source);
    final isUsed = st != null && (st.active || st.trackId == widget.snapshot.selectedSubtitleId);
    final saveText = st != null ? _saveLabel(st.save) : '';
    final sub = [srcName, if (cand.language?.trim().isNotEmpty == true) cand.language!.trim(), if (cand.format?.trim().isNotEmpty == true) cand.format!.trim(), if (cand.releaseGroup?.trim().isNotEmpty == true) cand.releaseGroup!.trim(), if (saveText.isNotEmpty) saveText].join(' · ');
    return _CandidateHitRow(
      pal: pal,
      badgeBg: pal.isPaper ? pBg : bg,
      badgeFg: pal.isPaper ? pFg : fg,
      letter: letter,
      name: cand.name,
      sub: sub,
      isUsed: isUsed,
      useKey: Key('ev_sub_use_${cand.id}'),
      retryChip: st?.save == SubtitleSaveState.failed ? _retryChip(t, s, pal, Key('ev_sub_cand_retry_${cand.id}'), st!.trackId) : null,
      onUse: () {
        final panel = widget.subtitlePanel;
        if (panel != null) unawaited(_runPanelAction(() => panel.useCandidate(cand), '应用字幕失败'));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = EvPanelPalette.of(t);
    return Column(
      key: const Key('ev_panel_subs_tab'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
      children: [
        const EvPanelHeading('字幕轨', topMargin: 0.5),
        _buildTrackList(t, s, pal),
        if (widget.subtitlePanel != null) ...[
          const EvPanelHeading('AI'),
          _buildAiCard(t, s, pal),
          SizedBox(height: s.rem(0.625)),
          _buildQuickActions(t, s, pal),
          _buildLowerSection(t, s, pal),
        ],
      ],
    );
  }
}

class _QuickActionTile extends StatefulWidget {
  const _QuickActionTile({
    super.key, required this.icon, required this.title, required this.subtitle,
    required this.pal, required this.onTap,
  });
  final EvIconData icon;
  final String title, subtitle;
  final EvPanelPalette pal;
  final VoidCallback onTap;
  @override State<_QuickActionTile> createState() => _QuickActionTileState();
}

class _QuickActionTileState extends State<_QuickActionTile> {
  bool _hov = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = widget.pal;
    final bg = _hov
        ? (pal.isPaper ? const Color(0xFFE8E6DC) : const Color.fromRGBO(255, 255, 255, 0.11))
        : (pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.06));
    return Semantics(
      button: true, label: widget.title,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hov = true),
        onExit: (_) => setState(() { _hov = false; _down = false; }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _down ? 0.95 : 1.0, duration: const Duration(milliseconds: 250), curve: EvCurves.spring,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200), curve: EvCurves.out,
              transform: Matrix4.translationValues(0, _hov ? -2.0 : 0.0, 0),
              padding: EdgeInsets.fromLTRB(s.rem(0.5), s.rem(0.875), s.rem(0.5), s.rem(0.75)),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(s.rem(1.0))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(width: s.rem(2.25), height: s.rem(2.25), padding: EdgeInsets.all(s.rem(0.4375)), decoration: BoxDecoration(color: pal.isPaper ? _kWhite : const Color.fromRGBO(255, 255, 255, 0.08), borderRadius: BorderRadius.circular(s.rem(0.75))), child: EvIcon(widget.icon, size: s.rem(1.375), color: pal.ink)),
                SizedBox(height: s.rem(0.5)),
                Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.9375), fontWeight: FontWeight.w600, color: pal.ink)),
                SizedBox(height: s.rem(0.2)),
                Text(widget.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: t.bodyStyle(s.rem(0.75), color: pal.subInk)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _CandidateHitRow extends StatefulWidget {
  const _CandidateHitRow({
    required this.pal, required this.badgeBg, required this.badgeFg,
    required this.letter, required this.name, required this.sub,
    required this.isUsed, required this.useKey, this.retryChip, required this.onUse,
  });
  final EvPanelPalette pal;
  final Color badgeBg, badgeFg;
  final String letter, name, sub;
  final bool isUsed;
  final Key useKey;
  final Widget? retryChip;
  final VoidCallback onUse;
  @override State<_CandidateHitRow> createState() => _CandidateHitRowState();
}

class _CandidateHitRowState extends State<_CandidateHitRow> {
  bool _rowHov = false, _useHov = false, _useDown = false;

  @override
  Widget build(BuildContext context) {
    final t = EvTheme.of(context), s = EvScale.of(context), pal = widget.pal;
    final useBg = widget.isUsed
        ? (pal.isPaper ? _kOlive : const Color(0xFF34C759))
        : _useHov
            ? (pal.isPaper ? _kPaperInk : const Color(0xFFF5F5F7))
            : (pal.isPaper ? const Color(0xFFF0EEE6) : const Color.fromRGBO(255, 255, 255, 0.12));
    final useFg = widget.isUsed
        ? (pal.isPaper ? _kWhite : const Color(0xFF06210F))
        : _useHov
            ? (pal.isPaper ? const Color(0xFFFAF9F5) : const Color(0xFF111111))
            : pal.ink;

    return MouseRegion(
      onEnter: (_) => setState(() => _rowHov = true),
      onExit: (_) => setState(() => _rowHov = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(vertical: s.rem(0.375), horizontal: s.rem(0.375)),
        decoration: BoxDecoration(
          color: _rowHov ? pal.rowHover : const Color(0x00000000),
          borderRadius: BorderRadius.circular(s.rem(0.875)),
        ),
        child: Row(children: [
          Container(width: s.rem(2.25), height: s.rem(2.25), alignment: Alignment.center, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.badgeBg), child: Text(widget.letter, style: t.bodyStyle(s.rem(0.875), fontWeight: FontWeight.w700, color: widget.badgeFg))),
          SizedBox(width: s.rem(0.75)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.9375), fontWeight: FontWeight.w500, color: pal.ink)),
              SizedBox(height: s.rem(0.15)),
              Row(children: [
                Flexible(child: Text(widget.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.rem(0.8125), color: pal.subInk))),
                if (widget.retryChip != null) ...[SizedBox(width: s.rem(0.375)), widget.retryChip!],
              ]),
            ]),
          ),
          SizedBox(width: s.rem(0.5)),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _useHov = true),
            onExit: (_) => setState(() { _useHov = false; _useDown = false; }),
            child: GestureDetector(
              key: widget.useKey, behavior: HitTestBehavior.opaque,
              onTapDown: (_) => setState(() => _useDown = true),
              onTapUp: (_) => setState(() => _useDown = false),
              onTapCancel: () => setState(() => _useDown = false),
              onTap: widget.onUse,
              child: AnimatedScale(
                scale: _useDown ? 0.92 : 1.0, duration: const Duration(milliseconds: 250), curve: EvCurves.spring,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  height: s.rem(2.125), padding: EdgeInsets.symmetric(horizontal: s.rem(0.875)),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), color: useBg),
                  child: Row(mainAxisSize: MainAxisSize.min, spacing: s.rem(0.25), children: [
                    if (widget.isUsed) EvIcon(EvIcons.check, size: s.rem(0.9375), color: useFg),
                    Text(widget.isUsed ? '使用中' : '使用', style: t.bodyStyle(s.rem(0.875), fontWeight: FontWeight.w600, color: useFg)),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ConicBorderPainter extends CustomPainter {
  const _ConicBorderPainter({required this.angle, required this.radius, required this.isPaper});
  final double angle, radius;
  final bool isPaper;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.75), Radius.circular(math.max(0.0, radius - 0.75)));
    final colors = isPaper
        ? const [_kTerracotta, Color(0xFFE8E6DC), _kTerracotta, Color(0xFFE8E6DC), _kTerracotta]
        : const [Color(0xBFB28CFF), Color(0x336FB8FF), Color(0x995FE0C0), Color(0xBFB28CFF)];
    canvas.drawRRect(rrect, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..shader = SweepGradient(colors: colors, transform: GradientRotation(angle)).createShader(rect));
  }

  @override
  bool shouldRepaint(_ConicBorderPainter o) => o.angle != angle || o.radius != radius || o.isPaper != isPaper;
}
