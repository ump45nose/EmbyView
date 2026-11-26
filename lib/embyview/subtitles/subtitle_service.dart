import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:server_emby/server_emby.dart';

import '../../auth/repositories/server_repository.dart';
import '../../auth/store/authentication_store.dart';
import '../../util/server_url.dart';
import '../embyview.dart';
import '../playback/playback_subtitle_input.dart';
import '../prefs/machine_preferences.dart';
import 'ai/subtitle_ai.dart';
import 'emby_subtitle_library.dart';
import 'jobs/subtitle_jobs.dart';
import 'sources/subtitle_sources.dart';
import 'store/subtitle_media.dart' show mapMedia;
import 'store/subtitle_store.dart';
import 'subtitle_panel.dart';

const _authorization = EmbyViewFailure('原 Emby 账户或媒体目录授权已变更。', retryable: true);
const _expired = EmbyViewFailure('Emby 账户已变更。', retryable: true);

/// Device-owned transport, budget and job queue. Each authenticated session
/// gets a separate Emby client whose token cannot change under requests.
class SubtitleRuntime {
  SubtitleRuntime(this.preferences, this.accounts, this.servers, this.device, PlaybackManager playback) {
    void observe(bool _) {
      final state = playback.state;
      final active = state.isPlaying || state.isBuffering;
      var strm = false;
      if (active) {
        final item = playback.queueService.currentItem;
        final sourceId = playback.currentResolution?.mediaSourceId;
        final sources = (playbackItemData(item)['MediaSources'] as List? ?? []).whereType<Map>();
        final mediaPath = sources.where((source) => source['Id'] == sourceId).firstOrNull?['Path'];
        strm = [
          playbackItemPath(item),
          mediaPath,
        ].whereType<String>().any((path) => path.toLowerCase().endsWith('.strm'));
      }
      if (strm == _foregroundStrm) return;
      _foregroundStrm = strm;
      unawaited(queue.then<void>((queue) => queue.setForegroundStrm(_foregroundStrm), onError: (Object _) {}));
    }

    _playback = [playback.state.playingStream.listen(observe), playback.state.bufferingStream.listen(observe)];
    observe(false);
    unawaited(queue.then<void>((_) {}, onError: (Object _) {}));
  }

  final MachinePreferences preferences;
  final AuthenticationStore accounts;
  final ServerRepository servers;
  final DeviceInfo device;
  late final local = getApplicationSupportDirectory().then(
    (root) => Directory(p.join(root.path, 'EmbyView', 'subtitles')),
  );
  late final sources = SubtitleSources(readSecret: preferences.readSecret);
  late final _cache = local.then((root) => Directory(p.join(root.path, 'tracks')));
  late final List<StreamSubscription<bool>> _playback;
  bool _foregroundStrm = false;

  Future<SubtitleUsageLedger> _openLedger() async => SubtitleUsageLedger(
    localDirectory: await local,
    sharedRoot: () async {
      final folder = await preferences.mediaFolderStatus();
      return folder.state == MediaFolderState.authorized && folder.localRoot != null
          ? Directory(folder.localRoot!)
          : null;
    },
    machineName: Platform.localHostname.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_'),
    budgetMicros: () => preferences.current.monthlyBudgetMicros,
    checkGeneration: processor.checkGeneration,
    translationMetered: () => isSubtitleTranslationMetered(preferences.current),
  );
  late final ledger = _openLedger();
  late final processor = SubtitleAiProcessor(
    readSecret: preferences.readSecret,
    preferences: () => preferences.current,
    meter: <T>(cost, invoke) async => (await ledger).charge<T>(cost, invoke),
  );
  late final queue = _openQueue();
  Future<SubtitleSeasonQueue> _openQueue() async => SubtitleSeasonQueue.open(
    localDirectory: await local,
    ledger: await ledger,
    resolve: _resolve,
    generate: SubtitleSeasonGenerator(processor: processor).generate,
    preferences: () => preferences.current,
  );

  (String, String, String) _credentials(String account) {
    final ids = account.split('/').map(Uri.decodeComponent).toList();
    if (ids.length != 2) throw _authorization;
    final server = servers.getServer(ids.first), user = accounts.getUser(ids.first, ids.last);
    if (server?.serverType != ServerType.emby || user == null || user.accessToken.isEmpty) {
      throw _authorization;
    }
    return (normalizeServerBaseUrl(server!.address), user.id, user.accessToken);
  }

  Future<SubtitleEpisodeContext> _resolve(String account, SubtitleEpisodeRequest request) async {
    final (url, user, token) = _credentials(account);
    EmbyMediaServerClient client() => EmbyMediaServerClient(baseUrl: url, deviceInfo: device)
      ..accessToken = token
      ..userId = user;
    final library = EmbySubtitleLibrary(client());
    try {
      final item = await library.item(request.episodeId, request.mediaSourceId);
      final media = SubtitleMedia.fromPlayback(item.source, duration: item.duration);
      Future<(MediaFolderStatus, String)> authorization(String? expectedId) async {
        if (_credentials(account) != (url, user, token)) throw _authorization;
        final folder = await preferences.mediaFolderStatus();
        final mapped = await mapMedia(media, folder);
        final identity = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  account,
                  url,
                  folder.embyRoot,
                  await Directory(folder.localRoot!).resolveSymbolicLinks(),
                  media.embyFilePath,
                  mapped.directory,
                  mapped.baseName,
                ]),
              ),
            )
            .toString();
        if (expectedId != null && identity != expectedId) throw _authorization;
        return (folder, identity);
      }

      final (_, identity) = await authorization(request.authorizationId);
      final store = SubtitleStore(
        folderStatus: () async => (await authorization(identity)).$1,
        localDirectory: () => _cache,
      );
      return SubtitleEpisodeContext(
        source: item.source,
        store: store,
        duration: item.duration ?? Duration.zero,
        authorizationId: identity,
        checkAuthorization: () async {
          if (_credentials(account) != (url, user, token)) throw _authorization;
          // A fresh connection uses the current mTLS configuration. Item metadata
          // confirms visibility without negotiating or opening another 115 stream.
          final verification = client();
          try {
            final current = await verification.itemsApi.getItem(
              request.episodeId,
              mediaSourceId: media.mediaSourceId,
              fields: 'Path,MediaSources',
            );
            final source = (current['MediaSources'] as List? ?? [])
                .whereType<Map>()
                .where((row) => row['Id'] == media.mediaSourceId)
                .firstOrNull;
            final fresh = SubtitleMedia(
              itemId: request.episodeId,
              mediaSourceId: media.mediaSourceId,
              itemFilePath: playbackItemPath(current),
              mediaSourceFilePath: source?['Path'] as String?,
            );
            if (current['Id'] != request.episodeId ||
                (source == null && media.mediaSourceFilePath != null) ||
                fresh.embyFilePath != media.embyFilePath) {
              throw _authorization;
            }
          } catch (_) {
            throw _authorization;
          } finally {
            verification.dispose();
          }
          await authorization(identity);
        },
        availability: await library.availability(item, store),
        mediaContext: subtitleTranslationContext(item.item),
        streamIndex: item.audioIndex,
        language:
            item.streams
                    .where((row) => row['Type'] == 'Audio' && row['Index'] == item.audioIndex)
                    .firstOrNull?['Language']
                as String?,
      );
    } finally {
      library.close();
    }
  }

  AccountSubtitles bind(String account, EmbyViewData data, EmbyMediaServerClient active) => AccountSubtitles(
    this,
    account,
    data,
    EmbySubtitleLibrary(
      EmbyMediaServerClient(baseUrl: active.baseUrl, deviceInfo: active.deviceInfo)
        ..userId = active.userId
        ..accessToken = active.accessToken,
    ),
  );

  Future<void> close() async {
    await Future.wait(_playback.map((subscription) => subscription.cancel()));
    sources.close();
    final jobs = await queue.then<SubtitleSeasonQueue?>((value) => value, onError: (Object _) => null);
    await jobs?.close();
  }
}

class AccountSubtitles implements EmbyViewSubtitles {
  AccountSubtitles(this.runtime, this.account, this.data, this.library);
  final SubtitleRuntime runtime;
  final String account;
  final EmbyViewData data;
  final EmbySubtitleLibrary library;
  late final store = SubtitleStore(
    folderStatus: runtime.preferences.mediaFolderStatus,
    localDirectory: () => runtime._cache,
    index: library,
  );
  final _closed = Completer<void>();
  final _panels = <PlaybackSession, BoundSubtitlePanel>{};

  Future<T> _guard<T>(Future<T> Function() work) {
    if (_closed.isCompleted) return Future.error(_expired);
    return Future.any([
      Future.sync(work).onError(
        (Object error, _) =>
            throw error is EmbyViewFailure ? error : const EmbyViewFailure('暂时无法读取字幕资料，请重试。', retryable: true),
      ),
      _closed.future.then<T>((_) => throw _expired),
    ]);
  }

  @override
  Future<SubtitleAvailability> availability(String itemId) =>
      _guard(() async => library.availability(await library.item(itemId), store));

  @override
  SubtitlePanel bind(PlaybackSession session) {
    if (_closed.isCompleted) throw _expired;
    if (session is! PlaybackSubtitleInput) {
      throw const EmbyViewFailure('当前播放器未提供字幕输入。');
    }
    final input = session as PlaybackSubtitleInput;
    return _panels.putIfAbsent(
      session,
      () => BoundSubtitlePanel(
        session: session,
        input: input,
        store: store,
        loadItem: library.item,
        loadDocument: library.document,
        sources: runtime.sources,
        processor: runtime.processor,
        preferences: () => runtime.preferences.current,
        checkAi: () async {
          final (budget, reason) = await (await runtime.ledger).episodeBudget();
          if (budget != BudgetState.available) {
            throw EmbyViewFailure(reason ?? '暂时无法启动 AI 字幕。', retryable: true, code: budget.name);
          }
        },
        onClosed: () => _panels.remove(session),
      ),
    );
  }

  @override
  Future<SeasonQuote> quoteSeason(String seriesId, String seasonId) =>
      _guard(() async => (await runtime.queue).quoteSeason(await _season(seriesId, seasonId)));
  @override
  Future<String> queueSeason(SeasonQuote quote) => _guard(() async {
    final request = await _season(quote.seriesId, quote.seasonId);
    if (_closed.isCompleted) throw _expired;
    return (await runtime.queue).queueSeason(request, quote);
  });

  Future<SubtitleSeasonRequest> _season(String seriesId, String seasonId) async {
    final season = await data.episodes(seriesId, seasonId);
    return SubtitleSeasonRequest(
      accountId: account,
      seriesId: seriesId,
      seasonId: seasonId,
      seasonName: season.season.name,
      episodes: [
        for (final episode in season.episodes)
          SubtitleEpisodeRequest(
            episodeId: episode.card.id,
            name: episode.card.title,
            episodeNumber: episode.episodeNumber,
          ),
      ],
    );
  }

  @override
  Future<AiUsage> usage() => _guard(() async => (await runtime.ledger).usage());
  @override
  Stream<List<SeasonJob>> get jobs async* {
    yield* (await runtime.queue).jobs;
  }

  @override
  Future<void> cancelJob(String jobId, {String? episodeId}) =>
      _guard(() async => (await runtime.queue).cancelJob(jobId, episodeId: episodeId));

  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    library.close();
    await Future.wait(_panels.values.toList().map((panel) => panel.close()));
  }
}
