import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:get_it/get_it.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/services/log_service.dart';
import 'build_info.dart';

/// Lightweight daily-rolling local diagnostic logger for EmbyView.
///
/// Writes sanitized structured summaries (never credentials, passwords, tokens,
/// or raw server addresses) to
/// `Application Support/<bundleId>/embyview_logs/diag-YYYY-MM-DD.log` and
/// automatically prunes log files older than [retention] (7 days by default).
class EvDiagnosticsLog {
  EvDiagnosticsLog({
    this.directoryLoader,
    DateTime Function()? now,
    this.retention = EvDiagnosticsExporter.defaultWindow,
    this.maxDailyFileBytes = defaultMaxDailyFileBytes,
  }) : _customNow = now != null,
       _now = now ?? DateTime.now;

  /// Process-wide diagnostic logger shared by EmbyView runtime modules.
  static final EvDiagnosticsLog instance = EvDiagnosticsLog();

  static const String directoryName = 'embyview_logs';
  static const int defaultMaxDailyFileBytes = 4 * 1024 * 1024;
  static final RegExp _dailyFileRe = RegExp(r'^diag-(\d{4})-(\d{2})-(\d{2})\.log$');

  final Future<Directory?> Function()? directoryLoader;
  final bool _customNow;
  final DateTime Function() _now;
  final Duration retention;
  final int maxDailyFileBytes;

  Future<void> _queue = Future<void>.value();
  String? _lastPrunedDay;

  /// Formats a daily log filename (`diag-YYYY-MM-DD.log`) for [timestamp] in UTC.
  static String dailyFileName(DateTime timestamp) {
    final utc = timestamp.toUtc();
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return 'diag-$y-$m-$d.log';
  }

  /// Parses the UTC end-of-day boundary of a `diag-YYYY-MM-DD.log` filename, or
  /// returns null if [fileName] does not match the rolling naming pattern.
  static DateTime? parseDailyFileEndUtc(String fileName) {
    final match = _dailyFileRe.firstMatch(fileName);
    if (match == null) return null;
    final y = int.tryParse(match.group(1)!);
    final m = int.tryParse(match.group(2)!);
    final d = int.tryParse(match.group(3)!);
    if (y == null || m == null || d == null) return null;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    return DateTime.utc(y, m, d, 23, 59, 59, 999);
  }

  /// Resolves the primary `embyview_logs` directory under Application Support.
  Future<Directory?> resolveDirectory() async {
    if (directoryLoader != null) {
      try {
        return await directoryLoader!();
      } catch (_) {
        return null;
      }
    }
    try {
      final support = await getApplicationSupportDirectory();
      return Directory(p.join(support.path, directoryName));
    } catch (_) {
      return null;
    }
  }

  /// Appends a structured diagnostic event asynchronously without blocking UI.
  /// All fields are sanitized before persisting to disk.
  void record(
    String category,
    String event, {
    String level = 'INFO',
    Map<String, Object?>? details,
    Object? error,
  }) {
    final ts = _now().toUtc();
    final buf = StringBuffer()
      ..write(ts.toIso8601String())
      ..write(' ')
      ..write(level.toUpperCase().padRight(5))
      ..write(' [')
      ..write(category)
      ..write('] ')
      ..write(event);
    if (details != null && details.isNotEmpty) {
      for (final entry in details.entries) {
        final v = entry.value;
        if (v == null) continue;
        final text = v.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
        if (text.isEmpty) continue;
        buf
          ..write(' ')
          ..write(entry.key)
          ..write('=')
          ..write(text);
      }
    }
    if (error != null) {
      final errText = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
      if (errText.isNotEmpty) {
        buf
          ..write(' error=')
          ..write(errText);
      }
    }
    final sanitized = EvDiagnosticsExporter.sanitizeDiagnosticText(buf.toString());
    _enqueue(() => _writeLine(ts, sanitized));
  }

  /// Triggers an immediate retention sweep for logs older than [retention].
  Future<void> pruneExpiredLogs({DateTime? now}) {
    final reference = (now ?? _now()).toUtc();
    return _enqueue(() async {
      final dir = await resolveDirectory();
      if (dir == null) return;
      await _pruneDirectory(dir, reference);
    });
  }

  /// Waits for all queued writes and pruning operations to reach disk.
  Future<void> flush() => _queue;

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _queue.then((_) => task()).catchError((Object _) {});
    _queue = next;
    return next;
  }

  Future<void> _writeLine(DateTime ts, String line) async {
    final dir = await resolveDirectory();
    if (dir == null) return;
    try {
      await dir.create(recursive: true);
      final dayFile = dailyFileName(ts);
      if (_lastPrunedDay != dayFile) {
        _lastPrunedDay = dayFile;
        await _pruneDirectory(dir, ts);
      }
      final file = File(p.join(dir.path, dayFile));
      if (await file.exists()) {
        final len = await file.length();
        if (len >= maxDailyFileBytes) return;
      }
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      if (_customNow) {
        try {
          await file.setLastModified(ts);
        } catch (_) {}
      }
    } catch (_) {
      // Never propagate disk I/O errors into user flows or tests.
    }
  }

  Future<void> _pruneDirectory(Directory dir, DateTime reference) async {
    try {
      if (!await dir.exists()) return;
      final cutoff = reference.subtract(retention);
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        final dayEnd = parseDailyFileEndUtc(name);
        if (dayEnd == null) continue;
        final expiredByName = dayEnd.isBefore(cutoff);
        var expiredByMtime = false;
        if (!expiredByName) {
          try {
            final stat = await entity.stat();
            expiredByMtime = stat.modified.toUtc().isBefore(cutoff);
          } catch (_) {}
        }
        if (expiredByName || expiredByMtime) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}

/// Prompts for a save location and exports sanitized diagnostic logs via
/// [EvDiagnosticsExporter]. Shared by the macOS menu item and Settings → About.
Future<EvDiagnosticsExportResult?> evExportDiagnosticsViaDialog({
  EvDiagnosticsExporter exporter = const EvDiagnosticsExporter(),
  EvBuildInfo? buildInfo,
}) async {
  final ts = DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
  String? path;
  try {
    path = await FilePicker.saveFile(
      dialogTitle: '导出诊断日志',
      fileName: 'EmbyView-diagnostics-$ts.log',
      type: FileType.custom,
      allowedExtensions: const ['log', 'txt'],
    );
  } catch (_) {
    return null;
  }
  if (path == null || path.isEmpty) return null;
  return exporter.exportSanitizedBundle(
    destinationPath: path,
    buildInfo: buildInfo,
  );
}

/// Result metadata returned by [EvDiagnosticsExporter.exportSanitizedBundle].
@immutable
class EvDiagnosticsExportResult {
  const EvDiagnosticsExportResult({
    required this.path,
    required this.byteCount,
    required this.fileCount,
    required this.entryCount,
  });

  final String path;
  final int byteCount;
  final int fileCount;
  final int entryCount;
}

/// Collects recent diagnostic logs (7-day window by default), strips credentials
/// and private server/network identifiers, estimates log volume, and exports a
/// sanitized diagnostic bundle for troubleshooting.
class EvDiagnosticsExporter {
  const EvDiagnosticsExporter({
    this.buildInfo = EvBuildInfo.current,
    this.logDirectoriesLoader,
    this.recentInMemoryEntriesLoader,
    this.diagnosticsLog,
    this.now = DateTime.now,
  });

  static const Duration defaultWindow = Duration(days: 7);
  static const List<String> _logExtensions = ['.log', '.txt', '.jsonl'];

  final EvBuildInfo buildInfo;
  final Future<List<Directory>> Function()? logDirectoriesLoader;
  final List<({DateTime time, String line})> Function()? recentInMemoryEntriesLoader;
  final EvDiagnosticsLog? diagnosticsLog;
  final DateTime Function() now;

  // --- Pure sanitization patterns ---

  // 1. Authorization & Cookie headers (quoted JSON value or full unquoted header line).
  static final RegExp _authHeaderRe = RegExp(
    r'''\b(authorization|x-emby-authorization|set-cookie|cookie)\s*[:=]\s*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^\r\n]+))''',
    caseSensitive: false,
  );

  // 2. Standalone Bearer tokens anywhere in log output.
  static final RegExp _bearerRe = RegExp(
    r'\bBearer\s+[A-Za-z0-9\-._~+/=]{6,}',
    caseSensitive: false,
  );

  // 3. OpenAI / Anthropic / Google style secret API keys (e.g. sk-..., AIza...).
  static final RegExp _apiKeyLiteralRe = RegExp(
    r'\b(?:sk-[A-Za-z0-9_-]{8,}|AIza[0-9A-Za-z_-]{16,})\b',
  );

  // 4. Query parameters carrying credentials or signatures (including prefixed names).
  static final RegExp _querySecretRe = RegExp(
    r'([?&](?:[A-Za-z0-9_-]*(?:api[_-]?key|token|password|passwd|secret)|'
    r'pwd|pass|sig|signature)=)'
    r'[^&\s"\x27<>)}\]]*',
    caseSensitive: false,
  );

  // 5. Key/value credentials (JSON, HTTP headers, key=value, key: value),
  //    covering prefixed names like translationApiKey, gateway_api_key,
  //    emby_token, streamToken, x-goog-api-key, cookie, set-cookie.
  static final RegExp _kvCredentialRe = RegExp(
    r'''(["']?\b(?:[A-Za-z0-9_-]*(?:api[_-]?key|token|password|passwd|secret|cookie)|'''
    r'''pwd|pass|pw|signature)\b["']?\s*[:=]\s*["']?)'''
    r'''(?:(?:Bearer|Basic|MediaBrowser)\s+)?([^\s&"',;<>{}\[\]\r\n]+)''',
    caseSensitive: false,
  );

  // 6. Full URLs: keep scheme & path/query structure (credentials already stripped)
  //    while replacing userinfo + host + port with [REDACTED_HOST].
  static final RegExp _urlAuthorityRe = RegExp(
    r'''((?:https?|wss?|smb|ftp)://)[^\s/<>"',;()\]}]+''',
    caseSensitive: false,
  );

  // 7. Local / private / Tailscale hostnames (with optional :port).
  static final RegExp _localOrTailscaleHostRe = RegExp(
    r'\b[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*'
    r'\.(?:local|lan|home|internal|ts\.net)(?::\d{1,5})?\b',
    caseSensitive: false,
  );

  // 7b. Bare domain:port references (excluding source/log filenames like foo.dart:42).
  static final RegExp _bareDomainPortRe = RegExp(
    r'\b(?!(?:https?|wss?|smb|ftp)\b)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*'
    r'\.(?!(?:dart|swift|log|txt|json|jsonl|yaml|yml|xml|plist|kt|java|cpp|hpp|cc|mm|py|js|ts|css|html|md|srt|ass|vtt)\b)'
    r'[A-Za-z]{2,24}:\d{1,5}\b',
    caseSensitive: false,
  );

  // 8. Key/value server/host/address/domain/origin fields.
  static final RegExp _kvHostRe = RegExp(
    r'''(\b(?:host(?:name)?|address|server(?:_?url|_?addr|_?address)?|ip|domain|origin|url|uri)\b'''
    r'''\s*["']?\s*[:=]\s*["']?)(?!(?:https?|wss?|smb|ftp)://|\[REDACTED)'''
    r'''([^\s,;()<>"{}\[\]\x27\r\n]*[.0-9:][^\s,;()<>"{}\[\]\x27\r\n]*)''',
    caseSensitive: false,
  );

  // 9. Host lookup errors ("Failed host lookup: 'emby.example.com'").
  static final RegExp _hostLookupRe = RegExp(
    r'''((?:Failed host lookup|Unable to resolve host):?\s*['"])[^'"]+''',
    caseSensitive: false,
  );

  // 10. Bracketed IPv6 with optional port (e.g. [::1]:8096, [fe80::1]).
  static final RegExp _bracketIpv6Re = RegExp(
    r'\[(?:[A-Fa-f0-9:]+::[A-Fa-f0-9:]*|(?:[A-Fa-f0-9]{1,4}:){7}[A-Fa-f0-9]{1,4})\](?::\d{1,5})?',
  );

  // 11. Bare IPv4 with optional :port.
  static final RegExp _ipv4Re = RegExp(
    r'\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?::\d{1,5})?\b',
  );

  // 12. Bare IPv6.
  static final RegExp _ipv6Re = RegExp(
    r'(?<![:.\w])(?:'
    r'(?:[A-Fa-f0-9]{1,4}:){7}[A-Fa-f0-9]{1,4}'
    r'|(?:[A-Fa-f0-9]{1,4}:){1,6}:[A-Fa-f0-9:]*'
    r'|::[A-Fa-f0-9:]+'
    r')(?![:.\w])',
  );

  // 13. Email addresses.
  static final RegExp _emailRe = RegExp(
    r'\b[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}\b',
  );

  // 14. OS user home directories (keeps Emby 32/36-char hex user IDs and API paths like /emby/Users/...).
  static final RegExp _homeDirRe = RegExp(
    r'''(?<=^|[\s"'(=:])(/Users/|/home/|\\Users\\)(?![0-9a-fA-F]{32}\b|[0-9a-fA-F-]{36}\b)[^/\\\s"']+''',
  );

  /// Pure sanitization function removing passwords, API keys, Bearer/Emby tokens,
  /// credential query parameters, URLs, IP addresses, and `.local`/`.ts.net` hostnames.
  static String sanitizeDiagnosticText(String raw) {
    if (raw.isEmpty) return raw;
    var out = raw;

    // Preserve Authorization / Cookie header key while redacting the full value.
    out = out.replaceAllMapped(_authHeaderRe, (m) {
      final key = m.group(1)!;
      final dq = m.group(2);
      final sq = m.group(3);
      final bare = m.group(4);
      if (dq != null) {
        return dq.isEmpty ? m.group(0)! : '$key: "[REDACTED]"';
      }
      if (sq != null) {
        return sq.isEmpty ? m.group(0)! : "$key: '[REDACTED]'";
      }
      if (bare == null || bare.trim().isEmpty) return m.group(0)!;
      return '$key: [REDACTED]';
    });

    // Redact query-string credentials before authority redaction so query keys stay legible.
    out = out.replaceAllMapped(_querySecretRe, (m) => '${m.group(1)}[REDACTED]');

    // Redact standalone Bearer tokens and API key literals (sk-*, AIza*).
    out = out.replaceAll(_bearerRe, 'Bearer [REDACTED]');
    out = out.replaceAll(_apiKeyLiteralRe, '[REDACTED_KEY]');

    // Redact key-value credentials (password, token, api_key, X-Emby-Token, etc.).
    out = out.replaceAllMapped(_kvCredentialRe, (m) => '${m.group(1)}[REDACTED]');

    // Redact scheme://[user:pass@]host[:port] while retaining path structure.
    out = out.replaceAllMapped(_urlAuthorityRe, (m) => '${m.group(1)}[REDACTED_HOST]');

    // Redact host lookup errors and explicit server/host/address key-value fields.
    out = out.replaceAllMapped(_hostLookupRe, (m) => '${m.group(1)}[REDACTED_HOST]');
    out = out.replaceAllMapped(_kvHostRe, (m) => '${m.group(1)}[REDACTED_HOST]');

    // Redact bare .local, .lan, .home, .internal, .ts.net hostnames and bare domain:port.
    out = out.replaceAll(_localOrTailscaleHostRe, '[REDACTED_HOST]');
    out = out.replaceAll(_bareDomainPortRe, '[REDACTED_HOST]');

    // Redact IPv4 / IPv6 addresses.
    out = out.replaceAll(_bracketIpv6Re, '[REDACTED_IP]');
    out = out.replaceAll(_ipv4Re, '[REDACTED_IP]');
    out = out.replaceAll(_ipv6Re, '[REDACTED_IP]');

    // Redact emails and local OS usernames in file paths.
    out = out.replaceAll(_emailRe, '[REDACTED_EMAIL]');
    out = out.replaceAllMapped(_homeDirRe, (m) => '${m.group(1)}[REDACTED]');

    return out;
  }

  /// Formats a byte count cleanly for the About page (e.g. `2.4 MB`, `12 KB`, `0 B`).
  static String formatByteSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      final kb = bytes / 1024;
      return kb >= 100 ? '${kb.round()} KB' : '${kb.toStringAsFixed(1)} KB';
    }
    final mb = bytes / (1024 * 1024);
    return mb >= 100 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }

  Future<void> _flushActiveLog(List<Directory>? override) async {
    if (diagnosticsLog != null) {
      await diagnosticsLog!.flush();
    } else if (override == null && logDirectoriesLoader == null) {
      await EvDiagnosticsLog.instance.flush();
    }
  }

  Future<List<Directory>> _resolveLogDirectories(List<Directory>? override) async {
    if (override != null) return override;
    if (logDirectoriesLoader != null) return logDirectoriesLoader!();
    if (diagnosticsLog != null) {
      final dir = await diagnosticsLog!.resolveDirectory();
      return dir == null ? const [] : [dir];
    }
    try {
      final support = await getApplicationSupportDirectory();
      return [
        Directory(p.join(support.path, EvDiagnosticsLog.directoryName)),
        Directory(p.join(support.path, 'EmbyView', 'logs')),
        Directory(p.join(support.path, 'logs')),
      ];
    } catch (_) {
      return const [];
    }
  }

  List<({DateTime time, String line})> _loadInMemoryEntries() {
    if (recentInMemoryEntriesLoader != null) {
      return recentInMemoryEntriesLoader!();
    }
    if (GetIt.instance.isRegistered<LogService>()) {
      final service = GetIt.instance<LogService>();
      return [
        for (final entry in service.entries) (time: entry.time, line: entry.format()),
      ];
    }
    return const [];
  }

  Future<List<({File file, int length, DateTime modified})>> _collectRecentFiles(
    List<Directory> dirs,
    DateTime cutoff,
  ) async {
    final seen = <String>{};
    final files = <({File file, int length, DateTime modified})>[];
    for (final dir in dirs) {
      try {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final ext = p.extension(entity.path).toLowerCase();
          if (ext.isNotEmpty && !_logExtensions.contains(ext)) continue;
          final canonical = p.normalize(entity.path);
          if (!seen.add(canonical)) continue;
          final dayEnd = EvDiagnosticsLog.parseDailyFileEndUtc(p.basename(entity.path));
          if (dayEnd != null && dayEnd.isBefore(cutoff)) continue;
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) continue;
          files.add((file: entity, length: stat.size, modified: stat.modified));
        }
      } catch (_) {
        // Ignore unreadable directories so partial logs can still be collected.
      }
    }
    files.sort((a, b) => a.modified.compareTo(b.modified));
    return files;
  }

  /// Estimates total bytes of recent diagnostic logs within [window] (default 7 days).
  Future<int> estimateRecentLogsBytes({
    DateTime? now,
    Duration window = defaultWindow,
    List<Directory>? logDirectories,
  }) async {
    await _flushActiveLog(logDirectories);
    final reference = now ?? this.now();
    final cutoff = reference.subtract(window);
    final dirs = await _resolveLogDirectories(logDirectories);
    final files = await _collectRecentFiles(dirs, cutoff);
    var total = 0;
    for (final f in files) {
      total += f.length;
    }
    for (final entry in _loadInMemoryEntries()) {
      if (!entry.time.isBefore(cutoff)) {
        total += utf8.encode(entry.line).length + 1;
      }
    }
    return total;
  }

  /// Collects all logs within [window], sanitizes them with [sanitizeDiagnosticText],
  /// and writes the bundle to [destinationPath] (or a timestamped file in system temp).
  Future<EvDiagnosticsExportResult> exportSanitizedBundle({
    String? destinationPath,
    DateTime? now,
    Duration window = defaultWindow,
    List<Directory>? logDirectories,
    EvBuildInfo? buildInfo,
  }) async {
    await _flushActiveLog(logDirectories);
    final reference = now ?? this.now();
    final cutoff = reference.subtract(window);
    final info = buildInfo ?? this.buildInfo;
    final dirs = await _resolveLogDirectories(logDirectories);
    final files = await _collectRecentFiles(dirs, cutoff);
    final memEntries = _loadInMemoryEntries()
        .where((e) => !e.time.isBefore(cutoff))
        .toList(growable: false);

    final buf = StringBuffer()
      ..writeln('EmbyView Diagnostic Bundle')
      ..writeln('Generated: ${reference.toUtc().toIso8601String()}')
      ..writeln('Version: ${info.formattedVersion}')
      ..writeln('Upstream: ${info.upstreamBase} (${info.license})')
      ..writeln('Window: last ${window.inDays} days (since ${cutoff.toUtc().toIso8601String()})')
      ..writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('Files: ${files.length}, In-memory entries: ${memEntries.length}')
      ..writeln('=' * 60);

    if (memEntries.isNotEmpty) {
      buf.writeln('\n--- In-Memory Diagnostic Log ---');
      for (final entry in memEntries) {
        buf.writeln(sanitizeDiagnosticText(entry.line));
      }
    }

    for (final item in files) {
      buf.writeln('\n--- File: ${p.basename(item.file.path)} (${item.modified.toUtc().toIso8601String()}) ---');
      try {
        final raw = await item.file.readAsString();
        buf.writeln(sanitizeDiagnosticText(raw));
      } catch (e) {
        buf.writeln('[Unreadable log file: ${sanitizeDiagnosticText(e.toString())}]');
      }
    }

    if (memEntries.isEmpty && files.isEmpty) {
      buf.writeln('\n(No diagnostic logs recorded in the last ${window.inDays} days.)');
    }

    final outputPath = destinationPath ?? _defaultOutputPath(reference);
    final outFile = File(outputPath);
    await outFile.parent.create(recursive: true);
    final encoded = utf8.encode(buf.toString());
    await outFile.writeAsBytes(encoded, flush: true);

    return EvDiagnosticsExportResult(
      path: outFile.path,
      byteCount: encoded.length,
      fileCount: files.length,
      entryCount: memEntries.length,
    );
  }

  static String _defaultOutputPath(DateTime reference) {
    final ts = reference
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    return p.join(Directory.systemTemp.path, 'EmbyView-diagnostics-$ts.log');
  }
}
