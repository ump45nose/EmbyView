import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Target payload opened inside [EvQuickLookHost].
@immutable
class EvQuickLookTarget {
  const EvQuickLookTarget({required this.card, this.resume, this.origin});
  final MediaCard card;
  final ResumeCard? resume;
  final Rect? origin;
}

/// Imperative controller for opening and closing the global QuickLook overlay.
class EvQuickLookController extends ChangeNotifier {
  EvQuickLookTarget? _current;
  bool get isOpen => _current != null;
  EvQuickLookTarget? get current => _current;
  void open(EvQuickLookTarget target) { _current = target; notifyListeners(); }
  void close() { if (_current == null) return; _current = null; notifyListeners(); }
}

/// Global Space-bar QuickLook host wrapping app content inside [EvThemeScope] + [EvScope].
class EvQuickLookHost extends StatefulWidget {
  const EvQuickLookHost({
    super.key, required this.child, this.controller, this.isSuppressed,
    this.resolveFocusTarget, this.onOpenDetail, this.onPlayTarget,
  });

  final Widget child;
  final EvQuickLookController? controller;
  final bool Function()? isSuppressed;
  final EvQuickLookTarget? Function(BuildContext focusContext)? resolveFocusTarget;
  final ValueChanged<String>? onOpenDetail;
  final void Function(PlayTarget target, CardArtwork art, Rect? origin)? onPlayTarget;

  @override State<EvQuickLookHost> createState() => _EvQuickLookHostState();
}

class _EvQuickLookHostState extends State<EvQuickLookHost> with SingleTickerProviderStateMixin {
  late EvQuickLookController _controller;
  late bool _ownsController;
  late final AnimationController _anim;
  late final CurvedAnimation _fadeAnim, _scaleCurve;
  late final Animation<double> _scaleAnim;
  late final _ChainedKeyInterceptor _keyInterceptor;

  final GlobalKey _mediaKey = GlobalKey();
  EvScope? _scope;
  FocusNode? _restoreFocus;
  String? _activeCardId, _failedLogoKey;
  int _loadToken = 0;
  bool _videoActive = false;
  MediaQuality? _loadedQuality;
  SubtitleAvailability? _availability;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = (widget.controller ?? EvQuickLookController())..addListener(_onControllerChanged);
    _anim = AnimationController(vsync: this, duration: EvDurations.medium);
    _fadeAnim = CurvedAnimation(parent: _anim, curve: const Interval(0.0, 0.55, curve: EvCurves.soft));
    _scaleCurve = CurvedAnimation(parent: _anim, curve: EvCurves.spring);
    _scaleAnim = Tween<double>(begin: 0.6, end: 1.0).animate(_scaleCurve);
    _keyInterceptor = _ChainedKeyInterceptor(_handleKeyMessage)..attach();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = EvScope.maybeOf(context);
    if (_controller.isOpen && _activeCardId != _controller.current!.card.id) _onTargetOpened(_controller.current!);
  }

  @override
  void didUpdateWidget(EvQuickLookHost old) {
    super.didUpdateWidget(old);
    if (old.controller == widget.controller) return;
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    _ownsController = widget.controller == null;
    _controller = (widget.controller ?? EvQuickLookController())..addListener(_onControllerChanged);
    _onControllerChanged();
  }

  @override
  void dispose() {
    _keyInterceptor.detach();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    _fadeAnim.dispose(); _scaleCurve.dispose(); _anim.dispose();
    ++_loadToken;
    if (_videoActive) { _videoActive = false; unawaited(_scope?.immersion.stopVideo()); }
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final target = _controller.current;
    target == null ? _onTargetClosed() : _onTargetOpened(target);
    setState(() {});
  }

  void _onTargetOpened(EvQuickLookTarget target) {
    final prevId = _activeCardId, card = target.card, token = ++_loadToken;
    if (_videoActive && prevId != card.id) { _videoActive = false; unawaited(_scope?.immersion.stopVideo()); }
    _activeCardId = card.id; _failedLogoKey = null; _loadedQuality = null; _availability = null;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) { _anim.value = 1.0; } else { _anim.forward(from: 0.0); }

    final services = _scope?.services, data = services?.data, subtitles = services?.subtitles;
    if (data != null) {
      unawaited(_safe(() => data.quality(card.id)).then((q) {
        if (mounted && token == _loadToken && _controller.current?.card.id == card.id && q != null) setState(() => _loadedQuality = q);
      }));
      unawaited(_safe(() => data.themeMedia(card.id)).then((media) {
        if (!mounted || token != _loadToken || _controller.current?.card.id != card.id) return;
        final video = media?.backgroundVideo ?? media?.trailer, scope = _scope;
        if (video == null || scope == null || !scope.services.preferences.current.backgroundVideo) return;
        _videoActive = true;
        unawaited(scope.immersion.showMutedVideo(video, label: ''));
        setState(() {});
      }));
    }
    if (subtitles != null) {
      unawaited(_safe(() => subtitles.availability(card.id)).then((av) {
        if (mounted && token == _loadToken && _controller.current?.card.id == card.id && av != null) setState(() => _availability = av);
      }));
    }
  }

  void _onTargetClosed() {
    ++_loadToken;
    _activeCardId = _failedLogoKey = null; _loadedQuality = null; _availability = null;
    _anim.stop();
    if (_videoActive) { _videoActive = false; unawaited(_scope?.immersion.stopVideo()); }
    final restore = _restoreFocus; _restoreFocus = null;
    if (restore != null && restore.canRequestFocus && restore.context != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_controller.isOpen && restore.canRequestFocus && restore.context != null) restore.requestFocus();
      });
    }
  }

  // ignore: deprecated_member_use
  bool _handleKeyMessage(KeyMessage message) {
    if (!mounted || widget.isSuppressed?.call() == true || (_scope?.immersion.isPlayerActive ?? false)) return false;

    if (_controller.isOpen) {
      for (final e in message.events) {
        final k = e.logicalKey;
        final isClose = k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.escape;
        final isPlay = k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
        if (!isClose && !isPlay) continue;
        if (e is KeyDownEvent) isClose ? _controller.close() : _playCurrent();
        return true;
      }
      return false;
    }

    if (_scope?.services.preferences.current.quickLook == false) return false;
    final hw = HardwareKeyboard.instance;
    if (hw.isMetaPressed || hw.isControlPressed || hw.isAltPressed) return false;
    if (!message.events.any((e) => e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.space)) return false;

    final primary = FocusManager.instance.primaryFocus, focusCtx = primary?.context;
    if (focusCtx == null || !focusCtx.mounted || !_isInSubtree(focusCtx) || _isEditableText(focusCtx)) return false;

    final target = widget.resolveFocusTarget?.call(focusCtx) ?? _resolveEvCard(focusCtx);
    if (target == null) return false;
    _restoreFocus = primary;
    _controller.open(target);
    return true;
  }

  bool _isInSubtree(BuildContext target) {
    if (identical(target, context)) return true;
    var found = false;
    target.visitAncestorElements((el) { if (!identical(el, context)) return true; found = true; return false; });
    return found;
  }

  static bool _isEditableText(BuildContext ctx) =>
      ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;

  EvQuickLookTarget? _resolveEvCard(BuildContext focusCtx) {
    EvCard? evCard;
    BuildContext? cardCtx;
    if (focusCtx.widget is EvCard) {
      evCard = focusCtx.widget as EvCard; cardCtx = focusCtx;
    } else {
      focusCtx.visitAncestorElements((el) {
        if (el.widget is EvCard) { evCard = el.widget as EvCard; cardCtx = el; return false; }
        return !identical(el, context);
      });
    }
    if (evCard == null) return null;
    final ro = (cardCtx ?? focusCtx).findRenderObject();
    return EvQuickLookTarget(
      card: evCard!.card, resume: evCard!.resume,
      origin: ro is RenderBox && ro.hasSize ? (ro.localToGlobal(Offset.zero) & ro.size) : null,
    );
  }

  Rect? _mediaRect() {
    final ro = _mediaKey.currentContext?.findRenderObject();
    return ro is RenderBox && ro.hasSize ? (ro.localToGlobal(Offset.zero) & ro.size) : null;
  }

  void _playCurrent() {
    final target = _controller.current;
    if (target == null) return;
    final origin = _mediaRect(), playTarget = target.resume?.target ?? PlayTarget(itemId: target.card.id);
    _restoreFocus = null;
    _controller.close();
    if (widget.onPlayTarget != null) { widget.onPlayTarget!(playTarget, target.card.art, origin); }
    else { unawaited(EvPlayer.open(context, playTarget, origin: origin, art: target.card.art)); }
  }

  void _openDetail() {
    final target = _controller.current;
    if (target == null) return;
    _restoreFocus = null;
    _controller.close();
    (widget.onOpenDetail ?? _scope?.shell.onOpenDetail)?.call(target.card.id);
  }

  static Future<T?> _safe<T>(Future<T> Function() fn) async { try { return await fn(); } catch (_) { return null; } }

  static MediaQuality? _mergeQuality(MediaQuality? fetched, MediaQuality? base) {
    if (fetched == null) return base;
    if (base == null) return fetched;
    return MediaQuality(
      resolution: fetched.resolution ?? base.resolution, videoRange: fetched.videoRange ?? base.videoRange,
      audioLabel: fetched.audioLabel ?? base.audioLabel, origin: fetched.origin ?? base.origin,
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = _controller.current;
    return Stack(
      fit: StackFit.passthrough,
      children: [widget.child, if (target != null) Positioned.fill(child: _buildOverlay(context, target))],
    );
  }

  Widget _buildOverlay(BuildContext context, EvQuickLookTarget target) {
    final t = EvTheme.of(context), s = EvScale.of(context);
    final quality = _mergeQuality(_loadedQuality, target.card.quality);
    final showSubtitles = _scope?.services.subtitles != null;

    return LayoutBuilder(builder: (_, c) {
      final vw = c.hasBoundedWidth && c.maxWidth > 0 ? c.maxWidth : s.size.width;
      final vh = c.hasBoundedHeight && c.maxHeight > 0 ? c.maxHeight : s.size.height;
      final winW = math.min(s.rem(46.0), math.max(0.0, vw - s.rem(3.0)));
      final maxH = math.max(0.0, vh - s.rem(3.0));
      final align = _originAlignment(target.origin, vw, vh, winW, math.min(maxH, s.rem(44.0)));
      final radius = BorderRadius.circular(s.rem(1.5));

      return Stack(key: const Key('ev_quicklook_overlay'), fit: StackFit.expand, children: [
        FadeTransition(
          opacity: _fadeAnim,
          child: GestureDetector(
            key: const Key('ev_quicklook_backdrop'), behavior: HitTestBehavior.opaque, onTap: _controller.close,
            child: ColoredBox(color: t.isPaper ? const Color.fromRGBO(250, 249, 245, 0.60) : const Color.fromRGBO(0, 0, 0, 0.40)),
          ),
        ),
        Center(child: FadeTransition(opacity: _fadeAnim, child: ScaleTransition(
          scale: _scaleAnim, alignment: align,
          child: Semantics(
            scopesRoute: true, explicitChildNodes: true, label: '空格一瞥：${target.card.title}',
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: winW, minWidth: winW, maxHeight: maxH),
              child: DecoratedBox(
                key: const Key('ev_quicklook_window'),
                decoration: BoxDecoration(
                  color: t.glassSolid, borderRadius: radius, border: Border.all(color: t.glassBorder),
                  boxShadow: [...t.glassShadow, BoxShadow(offset: Offset(0, s.rem(2.0)), blurRadius: s.rem(5.0), color: Color.fromRGBO(0, 0, 0, t.isPaper ? 0.16 : 0.50))],
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: SingleChildScrollView(child: Column(
                    mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [_buildMedia(s, target.card), _buildBody(t, s, target, quality, showSubtitles)],
                  )),
                ),
              ),
            ),
          ),
        ))),
      ]);
    });
  }

  static Alignment _originAlignment(Rect? origin, double vw, double vh, double winW, double winH) {
    if (origin == null || winW <= 0 || winH <= 0) return Alignment.center;
    return Alignment(
      ((origin.center.dx - (vw - winW) / 2) / winW * 2 - 1).clamp(-1.5, 1.5),
      ((origin.center.dy - (vh - winH) / 2) / winH * 2 - 1).clamp(-1.5, 1.5),
    );
  }

  Widget _buildMedia(EvScale s, MediaCard card) {
    final immersion = _scope?.immersion, logo = card.art.logo;
    return AspectRatio(
      key: _mediaKey, aspectRatio: 16 / 9,
      child: ColoredBox(color: const Color(0xFF000000), child: Stack(fit: StackFit.expand, children: [
        EvArtwork(key: const Key('ev_quicklook_artwork'), plan: card.art.stage, overrideFit: BoxFit.cover, showFallbackTitle: false),
        if (immersion != null)
          ListenableBuilder(listenable: immersion, builder: (ctx, _) {
            final show = _videoActive && immersion.isVideoVisible && immersion.videoSurfaceBuilder != null;
            return AnimatedOpacity(
              key: const Key('ev_quicklook_video'), opacity: show ? 1.0 : 0.0,
              duration: EvDurations.normal, curve: EvCurves.soft,
              child: show ? immersion.videoSurfaceBuilder!(ctx) : const SizedBox.shrink(),
            );
          }),
        const IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.bottomCenter, end: Alignment(0.0, -0.2),
          colors: [Color.fromRGBO(0, 0, 0, 0.65), Color.fromRGBO(0, 0, 0, 0.0)],
        )))),
        Positioned(left: s.rem(1.75), right: s.rem(1.75), bottom: s.rem(1.25), child: EvOnImage(child: Builder(builder: (ctx) {
          final onImg = EvTheme.of(ctx);
          Widget fallback() => Text(
            card.title, key: const Key('ev_quicklook_title'), maxLines: 2, overflow: TextOverflow.ellipsis,
            style: onImg.displayStyle(s.font(2.25), color: onImg.ink, height: 1.12).copyWith(
              fontWeight: FontWeight.w700, shadows: const [Shadow(offset: Offset(0, 2), blurRadius: 12, color: Color.fromRGBO(0, 0, 0, 0.5))],
            ),
          );
          if (logo == null || _failedLogoKey == logo.cacheKey) return fallback();
          return Align(alignment: Alignment.bottomLeft, child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: s.rem(4.5), maxWidth: s.rem(20.0)),
            child: Image(
              key: ValueKey<String>('ev_quicklook_logo_${logo.cacheKey}'), image: logo.image,
              fit: BoxFit.contain, alignment: Alignment.bottomLeft, gaplessPlayback: true, filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) {
                WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _failedLogoKey != logo.cacheKey) setState(() => _failedLogoKey = logo.cacheKey); });
                return fallback();
              },
            ),
          ));
        }))),
      ])),
    );
  }

  Widget _buildBody(EvTheme t, EvScale s, EvQuickLookTarget target, MediaQuality? quality, bool showSubtitles) {
    final overview = target.card.overview?.trim() ?? '';
    final subPill = showSubtitles ? _buildSubtitlePill(t, s, _availability) : null;
    final originPill = quality?.origin != null ? _pill(
      key: const Key('ev_quicklook_origin_pill'), t: t, s: s,
      label: quality!.origin == MediaOrigin.direct115 ? '115 直连 · 首帧约 1.7 秒' : 'NAS 本地 · 直接播放', bg: t.fill2, fg: t.ink2,
    ) : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(s.rem(1.75), s.rem(1.25), s.rem(1.75), s.rem(1.5)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildMetaLine(t, s, target.card, quality),
        if (overview.isNotEmpty) ...[
          SizedBox(height: s.rem(0.75)),
          Text(overview, key: const Key('ev_quicklook_overview'), maxLines: 3, overflow: TextOverflow.ellipsis,
              style: t.bodyStyle(s.font(1.0), color: t.ink2, height: 1.6)),
        ],
        if (subPill != null || originPill != null) ...[
          SizedBox(height: s.rem(0.875)),
          Wrap(key: const Key('ev_quicklook_pills'), spacing: s.rem(0.5), runSpacing: s.rem(0.5), children: [?subPill, ?originPill]),
        ],
        SizedBox(height: s.rem(1.25)),
        _buildActions(t, s, target),
      ]),
    );
  }

  Widget _buildMetaLine(EvTheme t, EvScale s, MediaCard card, MediaQuality? q) {
    final ts = t.bodyStyle(s.font(1.0), fontWeight: FontWeight.w500, color: t.ink2);
    final bits = <Widget>[];
    void add(Widget w) { if (bits.isNotEmpty) bits.add(SizedBox(width: 1, height: s.rem(0.875), child: ColoredBox(color: t.fill3))); bits.add(w); }

    if (card.score != null && card.score! > 0) add(EvScoreBadge(score: card.score!));
    if (card.year != null) add(Text('${card.year}', style: ts));
    if (card.genres.isNotEmpty) add(Text(card.genres.take(2).join(' / '), style: ts));
    if ((card.kind == MediaKind.movie || card.kind == MediaKind.episode) && (card.duration ?? Duration.zero) > Duration.zero) {
      final m = math.max(1, card.duration!.inMinutes);
      add(Text(m < 60 ? '$m 分钟' : (m % 60 == 0 ? '${m ~/ 60} 小时' : '${m ~/ 60} 小时 ${m % 60} 分'), style: ts));
    } else if (card.kind == MediaKind.series && (card.childCount ?? 0) > 0) { add(Text('${card.childCount} 季', style: ts)); }
    else if (card.kind == MediaKind.collection && (card.childCount ?? 0) > 0) { add(Text('${card.childCount} 部', style: ts)); }
    if (card.rating?.trim().isNotEmpty ?? false) add(Text(card.rating!.trim(), style: ts));

    final res = q?.resolution?.trim(), rng = q?.videoRange?.trim(), aud = q?.audioLabel?.trim();
    final badges = <Widget>[
      if (res != null && res.isNotEmpty && res.toLowerCase() != '1080p' && res.toLowerCase() != '720p') EvQualityBadge(label: res),
      if (rng != null && rng.isNotEmpty) EvQualityBadge(label: rng, kind: (rng.toLowerCase().contains('dolby') || rng.contains('杜比')) ? EvQualityBadgeKind.dolbyVision : EvQualityBadgeKind.standard),
      if (aud != null && aud.isNotEmpty) EvQualityBadge(label: aud),
      if (q?.origin != null) EvQualityBadge(label: q!.origin == MediaOrigin.direct115 ? '115 直连' : 'NAS 本地', kind: EvQualityBadgeKind.source),
    ];
    return Wrap(
      key: const Key('ev_quicklook_meta'), spacing: s.rem(0.75), runSpacing: s.rem(0.5), crossAxisAlignment: WrapCrossAlignment.center,
      children: [...bits, if (badges.isNotEmpty) Wrap(spacing: s.rem(0.375), runSpacing: s.rem(0.375), crossAxisAlignment: WrapCrossAlignment.center, children: badges)],
    );
  }

  Widget? _buildSubtitlePill(EvTheme t, EvScale s, SubtitleAvailability? av) {
    if (av == null || av.chinese == ChineseSubtitleState.unknown) return null;
    final src = (av.nasTrackCount ?? 0) > 0 ? 'NAS 外挂' : av.hasAiChinese == true ? 'AI 中字' : av.hasEmbeddedChinese == true ? '内嵌' : null;
    final (icon, label, bg, fg) = switch (av.chinese) {
      ChineseSubtitleState.complete => (EvIcons.check, src == null ? '中字已就绪' : '中字已就绪 · $src', t.isPaper ? const Color.fromRGBO(95, 115, 70, 0.14) : const Color.fromRGBO(79, 191, 127, 0.16), t.isPaper ? const Color(0xFF5F7346) : const Color(0xFF4FBF7F)),
      ChineseSubtitleState.partial => (EvIcons.cc, '部分中字 · 可补全', t.isPaper ? const Color.fromRGBO(181, 125, 47, 0.14) : const Color.fromRGBO(255, 181, 71, 0.16), t.isPaper ? const Color(0xFF9E6418) : const Color(0xFFFFC86B)),
      ChineseSubtitleState.canGenerate => (EvIcons.spark, '没有中字 · 可一键 AI 生成', t.isPaper ? const Color.fromRGBO(217, 119, 87, 0.14) : const Color.fromRGBO(178, 140, 255, 0.18), t.isPaper ? const Color(0xFFB5532F) : const Color(0xFFB9A0FF)),
      ChineseSubtitleState.unknown => (EvIcons.cc, '', t.fill2, t.ink2),
    };
    return _pill(key: const Key('ev_quicklook_sub_pill'), t: t, s: s, icon: icon, label: label, bg: bg, fg: fg);
  }

  Widget _pill({required Key key, required EvTheme t, required EvScale s, EvIconData? icon, required String label, required Color bg, required Color fg}) =>
      Container(
        key: key, height: s.rem(1.875), padding: EdgeInsets.symmetric(horizontal: s.rem(0.75)),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[EvIcon(icon, size: s.rem(1.0), color: fg), SizedBox(width: s.rem(0.375))],
          Text(label, style: t.bodyStyle(s.font(0.875), fontWeight: FontWeight.w600, color: fg, height: 1.0)),
        ]),
      );

  Widget _buildActions(EvTheme t, EvScale s, EvQuickLookTarget target) {
    final btnFont = s.rem(1.0625);
    Widget kbd(String text, Color c) => Container(
      padding: EdgeInsets.symmetric(horizontal: s.rem(0.45), vertical: s.rem(0.15)),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(s.rem(0.375)), border: Border.all(color: c.withValues(alpha: 0.45))),
      child: Text(text, style: t.bodyStyle(s.font(0.8125), fontWeight: FontWeight.w500, color: c.withValues(alpha: 0.72), height: 1.0)),
    );
    return Wrap(
      key: const Key('ev_quicklook_actions'), spacing: s.rem(0.75), runSpacing: s.rem(0.5), crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        EvButton.primary(
          key: const Key('ev_quicklook_play_btn'), onPressed: _playCurrent,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            EvIcon(EvIcons.play, size: s.rem(1.125), color: t.priFg), SizedBox(width: s.rem(0.5)),
            Text(target.resume != null ? '继续' : '播放', style: t.bodyStyle(btnFont, fontWeight: FontWeight.w600, color: t.priFg)),
            SizedBox(width: s.rem(0.625)), kbd('⏎', t.priFg),
          ]),
        ),
        EvButton.ghost(key: const Key('ev_quicklook_detail_btn'), label: '详情', glass: true, onPressed: _openDetail),
        EvButton.ghost(
          key: const Key('ev_quicklook_close_btn'), glass: true, onPressed: _controller.close,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('关闭', style: t.bodyStyle(btnFont, fontWeight: FontWeight.w600, color: t.ink)),
            SizedBox(width: s.rem(0.5)), kbd('空格', t.ink),
          ]),
        ),
      ],
    );
  }
}

/// Chainable, safely-detachable wrapper around [KeyEventManager.keyMessageHandler].
class _ChainedKeyInterceptor {
  // ignore: deprecated_member_use
  _ChainedKeyInterceptor(bool Function(KeyMessage message) handler) : _handler = handler;
  // ignore: deprecated_member_use
  bool Function(KeyMessage message)? _handler;
  // ignore: deprecated_member_use
  KeyMessageHandler? _previous;
  // ignore: deprecated_member_use
  late final KeyMessageHandler _fn = _dispatch;
  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    // ignore: deprecated_member_use
    final manager = ServicesBinding.instance.keyEventManager;
    // ignore: deprecated_member_use
    _previous = manager.keyMessageHandler;
    // ignore: deprecated_member_use
    manager.keyMessageHandler = _fn;
  }

  // ignore: deprecated_member_use
  bool _dispatch(KeyMessage message) => (_handler?.call(message) ?? false) || (_previous?.call(message) ?? false);

  void detach() {
    if (!_attached) return;
    _attached = false;
    _handler = null;
    // ignore: deprecated_member_use
    final manager = ServicesBinding.instance.keyEventManager;
    // ignore: deprecated_member_use
    if (identical(manager.keyMessageHandler, _fn)) {
      // ignore: deprecated_member_use
      manager.keyMessageHandler = _previous;
      _previous = null;
    }
  }
}
