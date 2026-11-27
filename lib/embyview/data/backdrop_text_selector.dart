// dart format width=120
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/utils/bounded_concurrency.dart';
import 'diagnostics_exporter.dart';

/// A single Emby backdrop candidate identified by owning item ID, Emby index, and image tag.
typedef BackdropCandidate = ({String itemId, int index, String tag});

/// Returns `true` when the backdrop contains prominent baked-in text, `false` when clean,
/// or `null` when detection failed or is unavailable on the current platform.
typedef BackdropTextDetector = Future<bool?> Function(Uri uri, Map<String, String> headers);

/// Default macOS Vision channel bridge (`macos/Runner/EmbyViewBackdropTextChannel.swift`).
class MacBackdropTextDetector {
  static const MethodChannel _channel = MethodChannel('embyview/backdrop_text');
  static bool _missingPlugin = false;

  static Future<bool?> detect(Uri uri, Map<String, String> headers) async {
    if (kIsWeb || !Platform.isMacOS || _missingPlugin) return null;
    try {
      return await _channel.invokeMethod<bool>('hasLargeText', {
        'url': uri.toString(),
        'headers': headers,
      });
    } on MissingPluginException {
      _missingPlugin = true;
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Detects prominent title text on Emby backdrops and caches per-tag verdicts locally.
///
/// Cover selection rules stay single-sourced in [MediaMapper]: callers await [prepare]
/// for stage-visible items before constructing cards, and [MediaMapper.artwork] reads
/// [order] synchronously with zero UI flicker.
class BackdropTextSelector {
  BackdropTextSelector({
    required Future<SharedPreferences> Function() storage,
    required String cacheKey,
    BackdropTextDetector? detector,
    int maxEntries = defaultMaxEntries,
  }) : _storage = storage,
       _cacheKey = cacheKey,
       _detector = detector ?? MacBackdropTextDetector.detect,
       _maxEntries = maxEntries;

  static const int defaultMaxEntries = 2000;

  final Future<SharedPreferences> Function() _storage;
  final String _cacheKey;
  final BackdropTextDetector _detector;
  final int _maxEntries;

  final Map<String, bool> _cache = {};
  final Map<String, Future<bool?>> _inFlight = {};
  Future<void>? _loadFuture;
  bool _loaded = false;
  bool _dirty = false;
  bool _disposed = false;

  static String tagKey(BackdropCandidate candidate) => '${candidate.itemId}:${candidate.tag}';

  void dispose() {
    _disposed = true;
    _inFlight.clear();
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _readCache();
  }

  Future<void> _readCache() async {
    try {
      final prefs = await _storage();
      if (_disposed) return;
      final saved = prefs.getString(_cacheKey);
      if (saved != null && saved.isNotEmpty) {
        final decoded = jsonDecode(saved);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is bool) {
              _cache.putIfAbsent(entry.key as String, () => entry.value as bool);
            }
          }
        }
      }
    } catch (_) {
      // Ignore corrupt cache payloads and rebuild incrementally.
    } finally {
      _loaded = true;
    }
  }

  Future<void> _saveCache() async {
    if (!_dirty || _disposed) return;
    _dirty = false;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    try {
      final prefs = await _storage();
      if (_disposed) return;
      await prefs.setString(_cacheKey, jsonEncode(_cache));
    } catch (_) {
      // Local persistence is best-effort; in-memory verdicts remain valid.
    }
  }

  Future<void> clearPersistedCache() async {
    _cache.clear();
    _dirty = false;
    try {
      final prefs = await _storage();
      await prefs.remove(_cacheKey);
    } catch (_) {}
  }

  Future<bool?> _detect(BackdropCandidate candidate, Uri uri, Map<String, String> headers) {
    final key = tagKey(candidate);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = () async {
      try {
        final sw = Stopwatch()..start();
        final verdict = await _detector(uri, headers);
        sw.stop();
        if (verdict != null && !_disposed) {
          _cache[key] = verdict;
          _dirty = true;
          EvDiagnosticsLog.instance.record(
            'backdrop',
            'detect',
            details: {
              'itemId': candidate.itemId,
              'index': candidate.index,
              'tag': candidate.tag,
              'hasText': verdict,
              'ms': sw.elapsedMilliseconds,
            },
          );
        }
        return verdict;
      } catch (_) {
        return null;
      } finally {
        _inFlight.remove(key);
      }
    }();
    _inFlight[key] = future;
    return future;
  }

  /// Resolves backdrop text verdicts for every multi-backdrop candidate group,
  /// stopping early per item as soon as a clean (text-free) backdrop is confirmed.
  Future<void> prepare(
    Iterable<List<BackdropCandidate>> groups, {
    required Uri Function(BackdropCandidate candidate) uriFor,
    required Map<String, String> headers,
    int concurrency = 4,
  }) async {
    if (_disposed) return;
    final multi = <List<BackdropCandidate>>[];
    final seenGroups = <String>{};
    for (final group in groups) {
      if (group.length <= 1) continue;
      final sig = group.map(tagKey).join('|');
      if (seenGroups.add(sig)) multi.add(group);
    }
    if (multi.isEmpty) return;

    await _ensureLoaded();
    if (_disposed) return;

    await mapBounded(multi, concurrency, (group) async {
      for (final candidate in group) {
        if (_disposed) return;
        final verdict = _cache[tagKey(candidate)] ?? await _detect(candidate, uriFor(candidate), headers);
        if (verdict == false) return;
      }
    });

    if (_dirty && !_disposed) {
      await _saveCache();
    }
  }

  /// Synchronously orders [candidates] using cached verdicts:
  /// prefers clean backdrops first; keeps original order when only one exists,
  /// all backdrops contain text, or no clean alternative is confirmed.
  List<BackdropCandidate> order(List<BackdropCandidate> candidates) {
    if (candidates.length <= 1) return candidates;
    final clean = <BackdropCandidate>[];
    final unknown = <BackdropCandidate>[];
    final withText = <BackdropCandidate>[];
    for (final candidate in candidates) {
      final verdict = _cache[tagKey(candidate)];
      if (verdict == false) {
        clean.add(candidate);
      } else if (verdict == true) {
        withText.add(candidate);
      } else {
        unknown.add(candidate);
      }
    }
    if (withText.isEmpty || clean.isEmpty) return candidates;
    if (_cache[tagKey(candidates.first)] == null) return candidates;
    return [...clean, ...unknown, ...withText];
  }
}
