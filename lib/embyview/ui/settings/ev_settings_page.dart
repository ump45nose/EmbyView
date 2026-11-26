import 'dart:async';

import 'package:flutter/widgets.dart' hide ConnectionState, Page;
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/kit.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_sections.dart';
import 'package:moonfin/embyview/ui/settings/ev_settings_widgets.dart';
import 'package:moonfin/embyview/ui/settings/ev_zone_editor.dart';

/// All 10 settings navigation sections aligned with `.spec/mockups/proto.js`.
enum EvSettingsSection { account, look, zones, play, immerse, subs, ai, video, keys, about }

/// Full EmbyView settings page with sidebar navigation, 10 live-bound panes,
/// and inline custom zone editor overlay.
class EvSettingsPage extends StatefulWidget {
  const EvSettingsPage({
    super.key,
    this.initialSection = EvSettingsSection.account,
    this.openZoneEditorOnMount = false,
    this.editZoneId,
    this.onOpenUsers,
  });

  final EvSettingsSection initialSection;
  final bool openZoneEditorOnMount;
  final String? editZoneId;
  final VoidCallback? onOpenUsers;

  @override State<EvSettingsPage> createState() => _EvSettingsPageState();
}

class _EvSettingsPageState extends State<EvSettingsPage> {
  late EvSettingsSection _section = (widget.openZoneEditorOnMount || widget.editZoneId != null)
      ? EvSettingsSection.zones : widget.initialSection;
  EmbyViewServices? _boundServices;
  StreamSubscription<LocalPreferences>? _prefsSub;
  StreamSubscription<AccountSnapshot>? _accountsSub;
  StreamSubscription<List<SeasonJob>>? _jobsSub;

  LocalPreferences _prefs = const LocalPreferences();
  AccountSnapshot _account = const AccountSnapshot(phase: AccountPhase.signedOut);
  List<ZoneTile> _zoneTiles = const [];
  Map<String, ZoneTile> _tilesById = const {};
  ZoneFacets? _zoneFacets;
  Set<SecretKind> _configuredSecrets = const {};
  bool _loadingSecrets = true, _secretsLoaded = false, _loadingAiUsage = false;
  AiUsage? _aiUsage;
  List<SeasonJob> _aiJobs = const [];
  bool _zoneEditorOpen = false, _didHandleMountEditor = false;
  ZonePreference? _editingZone;
  String? _bannerError;
  int _loadToken = 0;

  bool get _hasMissingSecrets => _secretsLoaded && _configuredSecrets.length < SecretKind.values.length;

  List<ZonePreference> get _displayedZones => _prefs.zones.isNotEmpty ? _prefs.zones : [
    for (final t in _zoneTiles)
      ZonePreference(id: t.id, name: t.name, iconKey: t.iconKey, colorSlot: t.colorSlot, rule: ZoneRule.library(t.id), custom: false),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = EvScope.of(context);
    if (!identical(_boundServices, scope.services)) _bindServices(scope);
  }

  void _cancelSubs() { unawaited(_prefsSub?.cancel()); unawaited(_accountsSub?.cancel()); unawaited(_jobsSub?.cancel()); }

  void _bindServices(EvScope scope) {
    final services = scope.services;
    _boundServices = services;
    _cancelSubs();
    _prefs = services.preferences.current;
    _account = services.accounts.snapshot;
    _zoneTiles = const []; _tilesById = const {}; _zoneFacets = null; _aiUsage = null; _aiJobs = const []; _loadingAiUsage = false;

    _prefsSub = services.preferences.changes.listen((next) {
      final zc = _zonesSig(_prefs.zones) != _zonesSig(next.zones);
      final bc = _prefs.monthlyBudgetMicros != next.monthlyBudgetMicros;
      if (!mounted || !identical(_boundServices, services)) return;
      setState(() => _prefs = next);
      if (zc) unawaited(_refreshZones(services));
      if (bc && services.subtitles != null) unawaited(_refreshAiUsage(services));
    });
    _accountsSub = services.accounts.changes.listen((next) { if (mounted && identical(_boundServices, services)) setState(() => _account = next); });

    final subs = services.subtitles;
    if (subs != null) {
      _jobsSub = subs.jobs.listen((j) { if (mounted && identical(_boundServices, services)) setState(() => _aiJobs = List.unmodifiable(j)); }, onError: (_) {});
      unawaited(_refreshAiUsage(services, notify: false));
    }
    unawaited(_refreshSecrets(services));
    unawaited(_refreshZones(services));
    unawaited(_refreshFacets(services));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_boundServices, services)) return;
      scope.immersion.onCardHoverEnd();
      scope.stage..setMode(EvStageMode.ambient)..setScrollProgress(1.0)..setVeilLifted(false);
      scope.shell..updateChrome(clearTitlePlate: true, rightActions: const [], hideTabs: false, hideAvatar: false)..setScrollOffset(0.0);
      if (!_didHandleMountEditor && (widget.openZoneEditorOnMount || widget.editZoneId != null)) {
        _didHandleMountEditor = true;
        final target = widget.editZoneId != null ? _displayedZones.where((z) => z.id == widget.editZoneId).firstOrNull : null;
        setState(() { _editingZone = target; _zoneEditorOpen = true; });
      }
    });
  }

  String _zonesSig(List<ZonePreference> zs) => zs.map((z) => '${z.id}:${z.name}:${z.iconKey}:${z.colorSlot}').join('|');

  Future<void> _refreshSecrets(EmbyViewServices services) async {
    try {
      final s = await services.preferences.configuredSecrets();
      if (mounted && identical(_boundServices, services)) setState(() { _configuredSecrets = s; _loadingSecrets = false; _secretsLoaded = true; });
    } catch (_) {
      if (mounted && identical(_boundServices, services)) setState(() { _loadingSecrets = false; _secretsLoaded = true; });
    }
  }

  Future<void> _refreshZones(EmbyViewServices services) async {
    final data = services.data;
    if (data == null) return;
    final token = ++_loadToken;
    try {
      final tiles = await data.zones();
      if (mounted && token == _loadToken && identical(_boundServices, services)) {
        setState(() { _zoneTiles = List.unmodifiable(tiles); _tilesById = {for (final t in tiles) t.id: t}; });
      }
    } catch (_) {}
  }

  Future<void> _refreshFacets(EmbyViewServices services) async {
    final data = services.data;
    if (data == null) return;
    try { final f = await data.customZoneFacets(); if (mounted && identical(_boundServices, services)) setState(() => _zoneFacets = f); } catch (_) {}
  }

  Future<void> _refreshAiUsage(EmbyViewServices services, {bool notify = true}) async {
    final subs = services.subtitles;
    if (subs == null) return;
    if (notify && mounted) { setState(() => _loadingAiUsage = true); } else { _loadingAiUsage = true; }
    try { final u = await subs.usage(); if (mounted && identical(_boundServices, services)) setState(() { _aiUsage = u; _loadingAiUsage = false; }); }
    catch (_) { if (mounted && identical(_boundServices, services)) setState(() => _loadingAiUsage = false); }
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_bannerError != null) setState(() => _bannerError = null);
    try { await action(); } catch (e) {
      if (mounted) setState(() => _bannerError = e is EmbyViewFailure ? e.reason : '操作失败，请重试。');
    }
  }

  void _moveZone(int index, int delta) {
    final services = _boundServices, zones = _displayedZones, target = index + delta;
    if (services == null || index < 0 || index >= zones.length || target < 0 || target >= zones.length) return;
    final ids = [for (final z in zones) z.id];
    ids.insert(target, ids.removeAt(index));
    unawaited(_guard(() => services.preferences.reorderZones(ids)));
  }

  @override void dispose() { _cancelSubs(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final scope = EvScope.of(context), t = EvTheme.of(context), s = EvScale.of(context), services = _boundServices ?? scope.services;
    final editTile = _editingZone != null ? _tilesById[_editingZone!.id] : null;
    return Stack(fit: StackFit.expand, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(s.gutter, s.rem(6.0), s.gutter, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: s.rem(15.5), child: _sidebar(scope, t, s)),
          SizedBox(width: s.rem(2.5)),
          Expanded(child: Align(alignment: Alignment.topLeft, child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: s.rem(48.0)),
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.depth == 0 && n.metrics.axis == Axis.vertical) scope.shell.setScrollOffset(n.metrics.pixels);
                return false;
              },
              child: SingleChildScrollView(
                key: ValueKey<EvSettingsSection>(_section), padding: EdgeInsets.only(bottom: s.rem(4.0)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_bannerError != null) _errorBanner(t, s, _bannerError!),
                  _buildPane(services),
                ]),
              ),
            ),
          ))),
        ]),
      ),
      if (_zoneEditorOpen)
        Positioned.fill(child: EvZoneEditorOverlay(
          initialZone: _editingZone, facets: _zoneFacets, loadFacets: services.data?.customZoneFacets,
          zoneTotal: editTile?.total, zoneUnit: editTile?.unit ?? '部',
          onSave: (z) async { await services.preferences.saveZone(z); await _refreshZones(services); },
          onDelete: (id) async { await services.preferences.removeCustomZone(id); await _refreshZones(services); },
          onClose: () => setState(() { _zoneEditorOpen = false; _editingZone = null; }),
        )),
    ]);
  }

  Widget _sidebar(EvScope scope, EvTheme t, EvScale s) {
    final cur = _account.current;
    const navItems = [
      (EvSettingsSection.account, '用户与服务器', EvIcons.users), (EvSettingsSection.look, '外观', EvIcons.palette),
      (EvSettingsSection.zones, '分区', EvIcons.zones), (EvSettingsSection.play, '播放', EvIcons.play),
      (EvSettingsSection.immerse, '沉浸', EvIcons.film), (EvSettingsSection.subs, '字幕', EvIcons.cc),
      (EvSettingsSection.ai, 'AI 字幕', EvIcons.spark), (EvSettingsSection.video, '画面增强', EvIcons.a4k),
      (EvSettingsSection.keys, '密钥', EvIcons.key), (EvSettingsSection.about, '关于', EvIcons.info),
    ];
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: s.rem(3.0)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: EdgeInsets.only(bottom: s.rem(1.0)), child: EvGlass(
          key: const Key('ev_settings_user_card'), borderRadius: BorderRadius.circular(s.rem(1.0)), padding: EdgeInsets.all(s.rem(0.75)),
          child: Row(children: [
            EvAvatarButton(profile: cur, size: s.rem(3.0)),
            SizedBox(width: s.rem(0.875)),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(cur?.displayName ?? '未登录', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: t.bodyStyle(s.font(1.0625), fontWeight: FontWeight.w600, color: t.ink)),
              SizedBox(height: s.rem(0.125)),
              Text(cur != null ? 'Emby 用户' : '尚未连接账号', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyStyle(s.font(0.875), color: t.ink3)),
            ])),
          ]),
        )),
        for (final (sec, label, icon) in navItems) ...[
          EvInteractive(
            key: Key('ev_settings_nav_${sec.name}'), selected: _section == sec, label: label,
            onTap: () {
              if (_section == sec) return;
              scope.shell.setScrollOffset(0.0);
              setState(() { _section = sec; _bannerError = null; });
              if (sec == EvSettingsSection.ai && _boundServices?.subtitles != null) unawaited(_refreshAiUsage(_boundServices!));
              if ((sec == EvSettingsSection.keys || sec == EvSettingsSection.ai) && _boundServices != null) unawaited(_refreshSecrets(_boundServices!));
            },
            builder: (_, hovered, focused) {
              final sel = _section == sec, fg = (sel || hovered || focused) ? t.ink : t.ink2;
              return AnimatedContainer(
                duration: EvDurations.fast, curve: EvCurves.soft, height: s.rem(2.875), padding: EdgeInsets.symmetric(horizontal: s.rem(0.875)),
                decoration: BoxDecoration(color: sel ? t.fill2 : hovered ? t.fill : evTransparent, borderRadius: BorderRadius.circular(s.rem(0.75)),
                  border: focused ? Border.all(color: t.focusColor, width: 1.5) : null),
                child: Row(children: [
                  EvIcon(icon, size: s.rem(1.25), color: fg, active: sel || hovered),
                  SizedBox(width: s.rem(0.75)),
                  Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: t.bodyStyle(s.font(1.0), fontWeight: sel ? FontWeight.w500 : FontWeight.w400, color: fg))),
                  if (sec == EvSettingsSection.keys && _hasMissingSecrets)
                    Container(key: const Key('ev_settings_keys_badge'), width: s.rem(0.5), height: s.rem(0.5),
                      decoration: const BoxDecoration(color: Color(0xFFFF5F57), shape: BoxShape.circle)),
                ]),
              );
            },
          ),
          SizedBox(height: s.rem(0.125)),
        ],
      ]),
    );
  }

  Widget _errorBanner(EvTheme t, EvScale s, String msg) => Container(
    key: const Key('ev_settings_error_banner'), margin: EdgeInsets.only(bottom: s.rem(1.0)),
    padding: EdgeInsets.symmetric(horizontal: s.rem(1.0), vertical: s.rem(0.75)),
    decoration: BoxDecoration(color: const Color.fromRGBO(229, 72, 77, 0.14), borderRadius: BorderRadius.circular(s.rem(0.75)),
      border: Border.all(color: const Color.fromRGBO(229, 72, 77, 0.45), width: 1)),
    child: Row(children: [
      Expanded(child: Text(msg, style: t.bodyStyle(s.font(0.875), color: evDangerColor))),
      GestureDetector(onTap: () => setState(() => _bannerError = null), child: EvIcon(EvIcons.x, size: s.rem(0.875), color: evDangerColor)),
    ]),
  );

  Widget _buildPane(EmbyViewServices services) {
    final openUsers = widget.onOpenUsers ?? EvScope.maybeOf(context)?.shell.onOpenUsers;
    void update(LocalPreferences next) => unawaited(_guard(() => services.preferences.update(next)));
    Future<void> saveSecret(SecretKind kind, String? value) => _guard(() async {
      await services.preferences.setSecret(kind, value);
      await _refreshSecrets(services);
    });
    return switch (_section) {
      EvSettingsSection.account => EvAccountSettingsPane(
        snapshot: _account, prefs: _prefs, visibleZoneCount: _displayedZones.length,
        onSwitchProfile: (id) { if (_account.current?.id != id) unawaited(_guard(() => services.accounts.switchTo(id))); },
        onOpenUsers: openUsers, onUpdatePrefs: update),
      EvSettingsSection.look => EvLookSettingsPane(prefs: _prefs, onUpdatePrefs: update),
      EvSettingsSection.zones => EvZonesSettingsPane(
        zones: _displayedZones, tilesById: _tilesById, facets: _zoneFacets, onMoveZone: _moveZone,
        onEditZone: (z) => setState(() { _editingZone = z; _zoneEditorOpen = true; }),
        onAddZone: () => setState(() { _editingZone = null; _zoneEditorOpen = true; }),
        onResetZones: () => unawaited(_guard(() => services.preferences.resetZones()))),
      EvSettingsSection.play => EvPlaySettingsPane(prefs: _prefs, onUpdatePrefs: update),
      EvSettingsSection.immerse => EvImmerseSettingsPane(prefs: _prefs, onUpdatePrefs: update),
      EvSettingsSection.subs => EvSubtitlesSettingsPane(
        prefs: _prefs, onUpdatePrefs: update,
        onAuthorizeFolder: (root) => _guard(() async => services.preferences.authorizeMediaFolder(embyRoot: root)),
        onRecheckFolder: () => _guard(() async { await services.preferences.mediaFolderStatus(); })),
      EvSettingsSection.ai => EvAiSettingsPane(
        prefs: _prefs, subtitlesAvailable: services.subtitles != null, usage: _aiUsage,
        loadingUsage: _loadingAiUsage, jobs: _aiJobs, onUpdatePrefs: update,
        configuredSecrets: _configuredSecrets, loadingSecrets: _loadingSecrets, onSaveSecret: saveSecret,
        onCancelJob: (id) => _guard(() async { await services.subtitles?.cancelJob(id); })),
      EvSettingsSection.video => EvVideoSettingsPane(prefs: _prefs, onUpdatePrefs: update),
      EvSettingsSection.keys => EvKeysSettingsPane(
        configuredSecrets: _configuredSecrets, loadingSecrets: _loadingSecrets,
        onSaveSecret: saveSecret),
      EvSettingsSection.about => const EvAboutSettingsPane(),
    };
  }
}
