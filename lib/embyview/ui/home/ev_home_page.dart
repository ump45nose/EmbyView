import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/home/ev_feature_spread.dart';
import 'package:moonfin/embyview/ui/home/ev_hero.dart';
import 'package:moonfin/embyview/ui/home/ev_zone_strip.dart';
import 'package:moonfin/embyview/ui/kit.dart';

/// Optional forced state for tests and the demo screenshot launcher.
enum EvHomeForcedState { empty, error }

/// Complete EmbyView home page following `.spec/mockups/proto.js` section order
/// and coordinating with [EvStageController], [Immersion], and [EvShellController].
class EvHomePage extends StatefulWidget {
  const EvHomePage({
    super.key,
    this.enableAnimations = true,
    this.enableAutoRetry = true,
    this.autoRetryInterval = const Duration(seconds: 10),
    this.forcedState,
  });

  final bool enableAnimations;
  final bool enableAutoRetry;
  final Duration autoRetryInterval;
  final EvHomeForcedState? forcedState;

  @override
  State<EvHomePage> createState() => _EvHomePageState();
}

class _EvHomePageState extends State<EvHomePage> {
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<MediaCard?> _previewCard = ValueNotifier<MediaCard?>(null);
  final ValueNotifier<bool> _hoverPaused = ValueNotifier<bool>(false);

  EvScope? _scope;
  StreamSubscription<EvPlaybackEnded>? _playbackEndedSub;
  bool _pendingPlaybackRefresh = false;
  EmbyViewData? _attachedData;
  String? _attachedSessionId;
  StreamSubscription<LocalPreferences>? _prefsSub;
  StreamSubscription<AccountSnapshot>? _accountsSub;
  StreamSubscription<ConnectionNoticeEvent>? _noticeSub;
  Timer? _autoRetryTimer;
  AccountSnapshot _account = const AccountSnapshot(phase: AccountPhase.signedOut);
  ShelfSort _seriesSort = ShelfSort.added;
  String _zonesSig = '';

  HomeData? _home;
  HomeRecommendation? _activeHero;
  MediaCard? _hoveredCard;
  MediaCard? _focusedCard;
  String? _activeInteractionCardId;
  bool _wasHeroVisible = true;
  bool _loading = true;
  bool _emptyLibraries = false;
  bool _probingFailover = false;
  Object? _error;
  EvHomeForcedState? _activeForcedState;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _activeForcedState = widget.forcedState;
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(EvHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.forcedState != widget.forcedState) {
      _activeForcedState = widget.forcedState;
      _applyForcedOrLoad();
    } else if (oldWidget.enableAutoRetry != widget.enableAutoRetry ||
        oldWidget.autoRetryInterval != widget.autoRetryInterval) {
      if (_isShowingErrorCard) {
        _restartAutoRetryTimer();
      } else {
        _cancelAutoRetryTimer();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context);
    final changed =
        _scope == null ||
        !identical(_attachedData, scope.services.data) ||
        _attachedSessionId != scope.services.sessionId;
    if (!identical(_scope?.shell, scope.shell)) {
      if (identical(_scope?.shell.onRetryHome, _handleNoticeRetry)) {
        _scope!.shell.onRetryHome = null;
      }
      scope.shell.onRetryHome = _handleNoticeRetry;
    }
    if (!identical(_scope?.shell, scope.shell)) {
      unawaited(_playbackEndedSub?.cancel());
      _playbackEndedSub = scope.shell.playbackEnded.listen((event) {
        final services = _scope?.services;
        if (!mounted || services == null || !event.matches(services)) return;
        if (_activeForcedState != null) return;
        if (TickerMode.valuesOf(context).enabled) {
          unawaited(_loadHome());
        } else {
          // A detail/search overlay owns the shared stage and chrome.
          _pendingPlaybackRefresh = true;
        }
      });
    }
    _scope = scope;
    final visible = TickerMode.valuesOf(context).enabled;
    if (!changed) {
      if (_pendingPlaybackRefresh && visible) {
        _pendingPlaybackRefresh = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _activeForcedState == null) unawaited(_loadHome());
        });
      }
      return;
    }
    _pendingPlaybackRefresh = false;

    final sessionChanged = _attachedSessionId != null && _attachedSessionId != scope.services.sessionId;
    if (sessionChanged) {
      scope.shell.clearHomeCache();
    }

    if (_activeInteractionCardId != null) {
      scope.immersion.onCardHoverEnd(cardId: _activeInteractionCardId);
      _activeInteractionCardId = null;
    }
    _cancelAutoRetryTimer();
    _hoveredCard = null;
    _focusedCard = null;
    _wasHeroVisible = true;
    _hoverPaused.value = false;
    _previewCard.value = null;
    _attachedData = scope.services.data;
    _attachedSessionId = scope.services.sessionId;
    _attachAccounts(scope.services.accounts);
    _attachPreferences(scope.services.preferences);

    final cached = scope.shell.cachedHomeFor(scope.services.sessionId, scope.services.data);
    _home = cached;
    _activeHero = cached?.recommendations.firstOrNull;
    _emptyLibraries = false;
    _error = null;
    _loading = _activeForcedState == null && cached == null && scope.services.data != null;

    _applyForcedOrLoad(initial: true);
  }

  void _applyForcedOrLoad({bool initial = false}) {
    final scope = _scope;
    if (scope == null) return;
    _cancelAutoRetryTimer();
    if (_activeForcedState == EvHomeForcedState.empty) {
      _loading = false;
      _error = null;
      _emptyLibraries = true;
      _setHasVisibleLibraries(scope.shell, false);
      _enterCalmStage(scope);
      return;
    }
    if (_activeForcedState == EvHomeForcedState.error) {
      _loading = false;
      _emptyLibraries = false;
      _error = const EmbyViewFailure('连不上服务器', retryable: true);
      _setHasVisibleLibraries(scope.shell, true);
      _enterCalmStage(scope);
      _restartAutoRetryTimer();
      return;
    }
    if (initial) {
      final cachedBackdrop = _activeHero?.card.art.stage;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || scope.shell.current is! EvHomeDestination) return;
        if (_home != null && cachedBackdrop == null) return;
        scope.stage
          ..clearPreviewBackdrop()
          ..setAmbientColor(null)
          ..setVeilLifted(false)
          ..setMode(EvStageMode.hero)
          ..setBaseBackdrop(cachedBackdrop)
          ..setScrollProgress(0.0);
        scope.shell.setScrollOffset(0.0);
      });
    }
    unawaited(_loadHome());
  }

  void _enterCalmStage(EvScope scope) {
    void apply() {
      if (!mounted) return;
      scope.stage
        ..setMode(EvStageMode.ambient)
        ..setBaseBackdrop(null)
        ..setScrollProgress(0.0)
        ..setVeilLifted(false);
      scope.shell.setScrollOffset(0.0);
    }
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _setHasVisibleLibraries(EvShellController shell, bool visible) {
    if (shell.hasVisibleLibraries == visible) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) shell.hasVisibleLibraries = visible;
      });
    } else {
      shell.hasVisibleLibraries = visible;
    }
  }

  void _attachAccounts(EmbyViewAccounts accounts) {
    unawaited(_accountsSub?.cancel());
    unawaited(_noticeSub?.cancel());
    _noticeSub = null;
    _account = accounts.snapshot;
    _accountsSub = accounts.changes.listen((next) {
      if (!mounted) return;
      setState(() => _account = next);
    });
    _noticeSub = accounts.connectionNotices.listen((event) {
      if (!mounted || _activeForcedState != null || _probingFailover) return;
      if ((event.kind == ConnectionNoticeKind.recovered ||
              event.kind == ConnectionNoticeKind.switched) &&
          (_error != null || _home == null)) {
        unawaited(_loadHome(allowFailover: false));
      }
    });
  }

  void _attachPreferences(EmbyViewPreferences prefs) {
    unawaited(_prefsSub?.cancel());
    _seriesSort = prefs.current.seriesSort;
    _zonesSig = _zonesSignature(prefs.current.zones);
    _prefsSub = prefs.changes.listen((next) {
      if (!mounted) return;
      final nextSig = _zonesSignature(next.zones);
      final reload = next.seriesSort != _seriesSort || nextSig != _zonesSig;
      _seriesSort = next.seriesSort;
      _zonesSig = nextSig;
      if (reload && _activeForcedState == null) unawaited(_loadHome());
    });
  }

  static String _zonesSignature(List<ZonePreference> zones) => [
    for (final z in zones)
      '${z.id}:${z.name}:${z.iconKey}:${z.colorSlot}:${switch (z.rule) {
        LibraryZoneRule(:final libraryId) => 'l:$libraryId',
        GenreZoneRule(:final genreId) => 'g:$genreId',
        TechnologyZoneRule(:final technology) => 't:${technology.name}',
      }}',
  ].join('|');

  static bool _hasHomeContent(HomeData home) =>
      home.zones.isNotEmpty ||
      home.recommendations.isNotEmpty ||
      home.continueWatching.isNotEmpty ||
      (home.recentMovies?.items.isNotEmpty ?? false) ||
      (home.anime?.items.isNotEmpty ?? false) ||
      (home.series?.items.isNotEmpty ?? false) ||
      (home.collections?.items.isNotEmpty ?? false) ||
      (home.documentaries?.items.isNotEmpty ?? false) ||
      (home.shortHighRated != null && home.shortHighRated!.total > 0) ||
      (home.uhdDolbyVision != null && home.uhdDolbyVision!.total > 0);

  bool _isEmptyLibraries(HomeData home) =>
      !_hasHomeContent(home) ||
      (_account.current?.visibleLibraryCount == 0 && home.zones.isEmpty);

  int _triedAddressCount() {
    if (_account.triedAddressCount > 0) return _account.triedAddressCount;
    if (_account.addresses.isNotEmpty) return _account.addresses.length;
    return 1;
  }

  bool get _isShowingEmptyCard =>
      _activeForcedState == EvHomeForcedState.empty ||
      (_activeForcedState == null &&
          !_loading &&
          _error == null &&
          (_emptyLibraries || _home == null));

  bool get _isShowingErrorCard =>
      _activeForcedState == EvHomeForcedState.error ||
      (_activeForcedState == null && _error != null && (_home == null || _emptyLibraries));

  void _cancelAutoRetryTimer() {
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
  }

  bool _isConnectionFailure(Object error) {
    if (error is EmbyViewFailure) {
      if (error.code == 'network') return true;
      const nonConnectionCodes = {
        'unauthorized',
        'forbidden',
        'session_changed',
        'wall_changed',
        'zone_missing',
        'season_missing',
        'invalid_page',
        'unsupported_filter',
      };
      if (error.code != null && nonConnectionCodes.contains(error.code)) {
        return false;
      }
      return error.retryable;
    }
    return true;
  }

  Future<void> _retryConnectionAndLoadHome() async {
    final accounts = _scope?.services.accounts;
    if (accounts != null) {
      _probingFailover = true;
      try {
        await accounts.retryConnection();
      } catch (_) {
      } finally {
        _probingFailover = false;
      }
    }
    if (!mounted) return;
    await _loadHome(allowFailover: false);
  }

  void _restartAutoRetryTimer() {
    _cancelAutoRetryTimer();
    if (!widget.enableAutoRetry) return;
    final interval = widget.autoRetryInterval > Duration.zero
        ? widget.autoRetryInterval
        : const Duration(seconds: 10);
    _autoRetryTimer = Timer.periodic(interval, (_) {
      if (!mounted || !_isShowingErrorCard) {
        _cancelAutoRetryTimer();
        return;
      }
      unawaited(_retryConnectionAndLoadHome());
    });
  }

  void _handleNoticeRetry() {
    if (!mounted) return;
    _activeForcedState = null;
    unawaited(_loadHome(allowFailover: false));
  }

  void _handleRecheck() {
    _activeForcedState = null;
    unawaited(_loadHome(refreshZones: true));
  }

  void _handleRetryError() {
    _cancelAutoRetryTimer();
    _activeForcedState = null;
    unawaited(_retryConnectionAndLoadHome());
  }

  void _openServerSettings() {
    final shell = _scope?.shell;
    (shell?.onOpenServerSettings ?? shell?.onOpenSettings)?.call();
  }

  void _openUsers() => _scope?.shell.onOpenUsers?.call();

  Future<void> _loadHome({
    bool refreshZones = false,
    bool allowFailover = true,
  }) async {
    final scope = _scope, data = scope?.services.data;
    final token = ++_loadToken;
    if (scope == null || data == null) {
      _cancelAutoRetryTimer();
      if (scope != null) {
        _setHasVisibleLibraries(scope.shell, false);
        _enterCalmStage(scope);
      }
      if (mounted) {
        _previewCard.value = null;
        setState(() {
          _loading = false;
          _home = null;
          _activeHero = null;
          _emptyLibraries = true;
          _error = null;
        });
      }
      return;
    }
    if (_home == null && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final result = await data.home(seriesSort: _seriesSort);
      if (!mounted || token != _loadToken) return;
      _cancelAutoRetryTimer();
      if (_isEmptyLibraries(result)) {
        _previewCard.value = null;
        scope.shell.clearHomeCache();
        _setHasVisibleLibraries(scope.shell, false);
        _enterCalmStage(scope);
        if (scope.shell.notice?.kind == EvNoticeKind.offline) {
          scope.shell.dismissNotice();
        }
        setState(() {
          _home = result;
          _activeHero = null;
          _loading = false;
          _emptyLibraries = true;
          _error = null;
        });
        return;
      }

      final activeId = _activeHero?.card.id;
      final nextHero = (activeId != null
              ? result.recommendations.where((r) => r.card.id == activeId).firstOrNull
              : null) ??
          result.recommendations.firstOrNull;
      _previewCard.value = null;
      scope.shell.cacheHome(scope.services.sessionId, data, result);
      _setHasVisibleLibraries(scope.shell, true);
      if (refreshZones) {
        if (result.zones.isNotEmpty) {
          scope.shell.setZones(result.zones);
        } else {
          unawaited(() async {
            try {
              final loaded = await data.zones();
              if (mounted && loaded.isNotEmpty) scope.shell.setZones(loaded);
            } catch (_) {}
          }());
        }
      }
      if (scope.shell.notice?.kind == EvNoticeKind.offline) {
        scope.shell.dismissNotice();
      }
      setState(() {
        _home = result;
        _activeHero = nextHero;
        _loading = false;
        _emptyLibraries = false;
        _error = null;
      });
      if (scope.shell.current is EvHomeDestination && TickerMode.valuesOf(context).enabled) {
        scope.stage
          ..setMode(nextHero != null ? EvStageMode.hero : EvStageMode.ambient)
          ..setBaseBackdrop(nextHero?.card.art.stage);
      }
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      if (allowFailover &&
          _isConnectionFailure(e) &&
          scope.services.preferences.current.autoSwitchServerAddress) {
        Uri? nextAddress;
        _probingFailover = true;
        try {
          nextAddress = await scope.services.accounts.probeAndFailover();
        } catch (_) {
          nextAddress = null;
        } finally {
          _probingFailover = false;
        }
        if (!mounted || token != _loadToken) return;
        if (nextAddress != null) {
          return _loadHome(refreshZones: refreshZones, allowFailover: false);
        }
      }
      final hasCachedContent = _home != null && !_emptyLibraries;
      if (hasCachedContent) {
        _cancelAutoRetryTimer();
        if (scope.shell.notice?.kind != EvNoticeKind.offline) {
          scope.shell.showOfflineNotice(
            serverName: _account.serverName,
            triedAddressCount: _triedAddressCount(),
            autoTick: widget.enableAutoRetry,
          );
        }
        setState(() {
          _error = e;
          _loading = false;
        });
      } else {
        _enterCalmStage(scope);
        setState(() {
          _error = e;
          _loading = false;
        });
        _restartAutoRetryTimer();
      }
    }
  }

  bool get _isHeroVisible {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    final vh = pos.hasViewportDimension && pos.viewportDimension > 0
        ? pos.viewportDimension
        : MediaQuery.sizeOf(context).height;
    return pos.pixels < vh * 0.2;
  }

  void _onScroll() {
    final scope = _scope;
    if (scope == null || !_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final vh = pos.hasViewportDimension && pos.viewportDimension > 0 ? pos.viewportDimension : 900.0;
    scope.shell.setScrollOffset(pos.pixels);
    scope.stage.setScrollProgress((pos.pixels / (vh * 0.5)).clamp(0.0, 1.0));
    final heroVisible = _isHeroVisible;
    if (!heroVisible && _previewCard.value != null) _previewCard.value = null;
    if (!_wasHeroVisible && heroVisible) {
      final active = _hoveredCard ?? _focusedCard;
      if (active != null) {
        _activeInteractionCardId = null;
        _activateInteraction(active);
      }
    }
    _wasHeroVisible = heroVisible;
  }

  void _activateInteraction(MediaCard card) {
    final scope = _scope;
    if (scope == null || _activeInteractionCardId == card.id) return;
    _activeInteractionCardId = card.id;
    _hoverPaused.value = true;
    final scrolledDown = !_isHeroVisible;
    scope.immersion.onCardHoverStart(
      card,
      scrolledDown: scrolledDown,
      allowVideo: !(scrolledDown && EvTheme.of(context).isPaper),
      onBackdropReady: () {
        if (mounted && _activeInteractionCardId == card.id && _isHeroVisible) _previewCard.value = card;
      },
    );
  }

  void _clearInteraction(String cardId) {
    final scope = _scope;
    if (scope == null || _activeInteractionCardId != cardId) return;
    _activeInteractionCardId = null;
    _hoverPaused.value = false;
    scope.immersion.onCardHoverEnd(cardId: cardId);
    if (_previewCard.value != null) _previewCard.value = null;
  }

  void _onCardHover(MediaCard card, bool active) {
    if (active) {
      _hoveredCard = card;
      _activateInteraction(card);
    } else if (_hoveredCard?.id == card.id) {
      _hoveredCard = null;
      if (_focusedCard != null) {
        _activateInteraction(_focusedCard!);
      } else {
        _clearInteraction(card.id);
      }
    }
  }

  void _onCardFocus(MediaCard card, bool active) {
    if (active) {
      _focusedCard = card;
      _activateInteraction(card);
    } else if (_focusedCard?.id == card.id) {
      _focusedCard = null;
      if (_hoveredCard != null) {
        _activateInteraction(_hoveredCard!);
      } else {
        _clearInteraction(card.id);
      }
    }
  }

  void _openDetail(MediaCard card) => _scope?.shell.onOpenDetail?.call(card.id);

  void _play(PlayTarget target, CardArtwork art, {Rect? origin}) =>
      unawaited(EvPlayer.open(context, target, origin: origin, art: art));

  @override
  void dispose() {
    unawaited(_playbackEndedSub?.cancel());
    _cancelAutoRetryTimer();
    if (identical(_scope?.shell.onRetryHome, _handleNoticeRetry)) {
      _scope!.shell.onRetryHome = null;
    }
    unawaited(_prefsSub?.cancel());
    unawaited(_accountsSub?.cancel());
    unawaited(_noticeSub?.cancel());
    if (_activeInteractionCardId != null) _scope?.immersion.onCardHoverEnd(cardId: _activeInteractionCardId);
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _previewCard.dispose();
    _hoverPaused.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EvTheme.of(context), scale = EvScale.of(context), home = _home;

    if (_isShowingErrorCard) {
      return EvHomeStateCard.error(
        serverName: _account.serverName,
        triedAddressCount: _triedAddressCount(),
        retryIntervalSeconds: math.max(1, widget.autoRetryInterval.inSeconds),
        onRetry: _handleRetryError,
        onServerSettings: _openServerSettings,
        onSwitchUser: _openUsers,
        animate: widget.enableAnimations,
      );
    }

    if (_isShowingEmptyCard) {
      return EvHomeStateCard.empty(
        username: _account.current?.displayName ?? '',
        onRecheck: _handleRecheck,
        onSwitchUser: _openUsers,
        animate: widget.enableAnimations,
      );
    }

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        key: const Key('ev_home_scroller'),
        controller: _scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading && home == null)
              SizedBox(height: math.max(0.0, scale.vh(100) - scale.peek))
            else
              ValueListenableBuilder<MediaCard?>(
                valueListenable: _previewCard,
                builder: (_, preview, _) => EvHero(
                  recommendations: home?.recommendations ?? const [],
                  previewCard: preview,
                  defaultReasonLabel: '今日推荐',
                  enableAutoRotate: widget.enableAnimations,
                  pauseAutoRotate: _hoverPaused,
                  onActiveChanged: (rec) {
                    _activeHero = rec;
                    final scope = _scope;
                    if (scope != null && scope.shell.current is EvHomeDestination) {
                      scope.stage.setBaseBackdrop(rec.card.art.stage);
                    }
                  },
                  onDetail: () {
                    final card = _previewCard.value ?? _activeHero?.card;
                    if (card != null) _openDetail(card);
                  },
                  onPlay: (rec, origin) =>
                      _play(rec.resume?.target ?? PlayTarget(itemId: rec.card.id), rec.card.art, origin: origin),
                ),
              ),
            Padding(
              padding: EdgeInsets.only(bottom: scale.rem(6.0)),
              child: _loading && home == null
                  ? const Column(
                      key: Key('ev_home_skeletons'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        EvShelfSkeleton(style: EvCardStyle.landscape, count: 5),
                        EvShelfSkeleton(style: EvCardStyle.poster, count: 9),
                        EvShelfSkeleton(style: EvCardStyle.poster, count: 9),
                      ],
                    )
                  : home != null
                  ? _buildSections(theme, home)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSections(EvTheme theme, HomeData home) {
    final sortLabel = switch (_seriesSort) {
      ShelfSort.added => '最近添加',
      ShelfSort.score => '评分最高',
      ShelfSort.title => '按标题',
    };
    final resumeById = {for (final r in home.continueWatching) r.card.id: r};

    Widget shelf(Key key, HomeShelf s, EvCardStyle style, {String? title, String? badge}) {
      final resolvedTitle = title ?? (s.title.isNotEmpty ? s.title : '');
      return EvShelf(
        key: key,
        title: resolvedTitle,
        badge: badge,
        items: s.items,
        style: style,
        onMoreTap: s.more != null
            ? () => _scope?.shell.openWall(s.more!, title: s.title.isNotEmpty ? s.title : resolvedTitle)
            : null,
        onCardTap: _openDetail,
        onCardPlay: (c) => _play(PlayTarget(itemId: c.id), c.art),
        onCardHoverChanged: _onCardHover,
        onCardFocusChanged: _onCardFocus,
      );
    }

    Widget feature(Key key, FeatureSpread sp, String title, Color accent, EvIconData doodle) => EvFeatureSpread(
      key: key,
      spread: sp,
      title: title,
      accentColor: accent,
      doodleIcon: doodle,
      enableAnimations: widget.enableAnimations,
      onTap: () => _scope?.shell.openWall(sp.query, title: title.replaceAll('\n', '')),
    );

    return Column(
      key: const Key('ev_home_sections'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (home.continueWatching.isNotEmpty)
          EvShelf(
            key: const Key('ev_home_section_continue'),
            title: '继续观看',
            resumeItems: home.continueWatching,
            style: EvCardStyle.landscape,
            onCardTap: _openDetail,
            onCardPlay: (c) => _play(resumeById[c.id]?.target ?? PlayTarget(itemId: c.id), c.art),
            onCardHoverChanged: _onCardHover,
            onCardFocusChanged: _onCardFocus,
          ),
        if (home.zones.isNotEmpty)
          EvZoneStrip(
            key: const Key('ev_home_section_zones'),
            zones: home.zones,
            onZoneTap: (z) => _scope?.shell.openZone(z.id),
            onManageZones: () => _scope?.shell.onManageZones?.call(),
          ),
        if (home.shortHighRated != null && home.shortHighRated!.total > 0)
          feature(
            const Key('ev_home_section_short_feature'),
            home.shortHighRated!,
            '100 分钟以内\n的高分电影',
            theme.movie,
            EvIcons.illClock,
          ),
        if (home.recentMovies != null && home.recentMovies!.items.isNotEmpty)
          shelf(
            const Key('ev_home_section_recent'),
            home.recentMovies!,
            EvCardStyle.poster,
            title: '最近添加',
            badge: home.recentMovies!.title.isNotEmpty && home.recentMovies!.title != '最近添加'
                ? home.recentMovies!.title
                : '电影',
          ),
        if (home.anime != null && home.anime!.items.isNotEmpty)
          shelf(
            const Key('ev_home_section_anime'),
            home.anime!,
            EvCardStyle.poster,
            title: home.anime!.title.isNotEmpty ? home.anime!.title : '番剧',
            badge: sortLabel,
          ),
        if (home.uhdDolbyVision != null && home.uhdDolbyVision!.total > 0)
          feature(
            const Key('ev_home_section_dv_feature'),
            home.uhdDolbyVision!,
            '4K 杜比视界',
            theme.tv,
            EvIcons.illTv,
          ),
        if (home.series != null && home.series!.items.isNotEmpty)
          shelf(
            const Key('ev_home_section_series'),
            home.series!,
            EvCardStyle.poster,
            title: home.series!.title.isNotEmpty ? home.series!.title : '剧集',
            badge: sortLabel,
          ),
        if (home.collections != null && home.collections!.items.isNotEmpty)
          shelf(
            const Key('ev_home_section_collections'),
            home.collections!,
            EvCardStyle.collection,
            title: home.collections!.title.isNotEmpty ? home.collections!.title : '合集',
          ),
        if (home.documentaries != null && home.documentaries!.items.isNotEmpty)
          shelf(
            const Key('ev_home_section_docs'),
            home.documentaries!,
            EvCardStyle.landscape,
            title: home.documentaries!.title.isNotEmpty ? home.documentaries!.title : '纪录片',
          ),
      ],
    );
  }
}
