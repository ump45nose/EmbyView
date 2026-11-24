import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../contracts/common.dart';
import '../../contracts/subtitles.dart';
import '../ai/subtitle_ai_types.dart';
import 'subtitle_job_files.dart';

final class SubtitleBudgetBlocked extends EmbyViewFailure {
  const SubtitleBudgetBlocked(super.reason, BudgetState state)
    : super(
        retryable: true,
        code: state == BudgetState.unknown ? 'subtitle_budget_unknown' : 'subtitle_budget_exceeded',
      );
}

final class SubtitleUsageLedger {
  SubtitleUsageLedger({
    required this.localDirectory,
    required this.sharedRoot,
    required this.machineName,
    required this.budgetMicros,
    required this.credentialsAvailable,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (machineName.isEmpty ||
        machineName == '.' ||
        machineName == '..' ||
        machineName.contains(RegExp(r'[/\\:\x00-\x1f]'))) {
      throw ArgumentError('Invalid usage ledger machine name');
    }
  }

  final Directory localDirectory;
  final FutureOr<Directory?> Function() sharedRoot;
  final String machineName;
  final int Function() budgetMicros;
  final FutureOr<bool> Function() credentialsAvailable;
  final DateTime Function() _clock;
  final _serial = SubtitleJobSerial();
  final _episodeZoneKey = Object();
  Set<String>? _dirtyMonths;

  String get _month {
    final date = _clock().toUtc();
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }

  Directory get _local => Directory(p.join(localDirectory.path, 'usage'));
  File _localFile(String month) => File(p.join(_local.path, '$month.json'));
  Future<AiUsage> usage() => _serial.run(() => _usage(_month));

  Future<(BudgetState, String?)> episodeBudget() async {
    if (!await credentialsAvailable()) {
      return (BudgetState.missingCredentials, '请先在设置中配置听写和翻译凭据。');
    }
    return _budget(await usage());
  }

  (BudgetState, String?) _budget(AiUsage current) {
    if (current.state != AiUsageState.available) {
      return (BudgetState.unknown, current.reason);
    }
    if (current.usedMicros! >= current.budgetMicros) {
      return (BudgetState.exceeded, '已达到本月 AI 字幕预算。');
    }
    return (BudgetState.available, null);
  }

  /// Associates requests with the episode for the completed-episode average.
  Future<T> duringEpisode<T>(String episode, Future<T> Function() run) =>
      runZoned(run, zoneValues: {_episodeZoneKey: episode});

  Future<T> charge<T>(int estimatedCostMicros, Future<SubtitleAiCharge<T>> Function() invoke) {
    if (estimatedCostMicros < 0) throw ArgumentError.value(estimatedCostMicros);
    final episode = Zone.current[_episodeZoneKey] as String?;
    return _serial.run(() async {
      final month = _month;
      final (state, reason) = _budget(await _usage(month));
      // This machine admits one request at a time while any budget remains.
      if (state != BudgetState.available) throw SubtitleBudgetBlocked(reason!, state);
      final own = await _readLocal(month);
      final response = await invoke();
      final requestId = response.requestId?.trim();
      final key = requestId == null || requestId.isEmpty ? const Uuid().v4() : requestId;
      own.calls.putIfAbsent(key, () => (response.costMicros >= 0 ? response.costMicros : estimatedCostMicros, episode));
      await _writeLocal(month, own);
      await _sync();
      return response.value;
    });
  }

  Future<void> completeEpisode(String episode) => _serial.run(() async {
    final month = _month;
    final own = await _readLocal(month);
    if (own.completed.add(episode)) await _writeLocal(month, own);
    await _sync();
  });

  Future<_UsageRecords> _readLocal(String month) async => _UsageRecords.fromJson(await readJobJson(_localFile(month)));
  Future<Set<String>> _dirty() async => _dirtyMonths ??= {
    if (await _local.exists())
      await for (final file in _local.list(followLinks: false))
        if (file is File && RegExp(r'^\d{4}-\d{2}\.json$').hasMatch(p.basename(file.path)))
          p.basenameWithoutExtension(file.path),
  };

  Future<void> _writeLocal(String month, _UsageRecords records) async {
    final dirty = await _dirty();
    await _local.create(recursive: true);
    await writeJobJson(_localFile(month), records.toJson());
    dirty.add(month);
  }

  Future<Directory> _sharedMonth(String month) async {
    final root = await sharedRoot();
    if (root == null) throw const FileSystemException('Subtitle usage share is unavailable');
    var path = await root.resolveSymbolicLinks();
    for (final part in ['.embyview', 'usage', month]) {
      path = p.join(path, part);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(path).create();
      } else if (type != FileSystemEntityType.directory) {
        throw FileSystemException('Invalid subtitle usage directory', path);
      }
    }
    return Directory(path);
  }

  Future<void> _sync() async {
    try {
      final dirty = await _dirty();
      for (final month in dirty.toList()) {
        final directory = await _sharedMonth(month);
        final file = File(p.join(directory.path, '$machineName.json'));
        final own = await _readLocal(month);
        final remote = _UsageRecords.fromJson(await readJobJson(file));
        if (remote.merge(own)) await writeJobJson(file, remote.toJson());
        dirty.remove(month);
      }
    } on Exception {
      // The local copy remains queued for the next successful refresh.
    }
  }

  Future<AiUsage> _usage(String month) async {
    AiUsage result(AiUsageState state, _UsageRecords? records, [String? reason]) {
      final completed = records?.completed ?? const <String>{};
      final calls = records?.calls.values;
      int sum(Iterable<(int, String?)> rows) => rows.fold(0, (total, call) => total + call.$1);
      return AiUsage(
        month: month,
        state: state,
        budgetMicros: budgetMicros(),
        usedMicros: calls == null ? null : sum(calls),
        completedEpisodes: completed.length,
        averageEpisodeMicros: completed.isEmpty
            ? null
            : sum(calls!.where((call) => completed.contains(call.$2))) ~/ completed.length,
        reason: reason,
      );
    }

    final _UsageRecords local;
    try {
      local = await _readLocal(month);
    } on Exception {
      return result(AiUsageState.unavailable, null, '无法读取本机 AI 用量。');
    }
    await _sync();
    try {
      final total = _UsageRecords()..merge(local);
      final directory = await _sharedMonth(month);
      await for (final entry in directory.list(followLinks: false)) {
        if (p.extension(entry.path) != '.json') continue;
        if (entry is! File) throw const FormatException('Invalid subtitle usage file');
        total.merge(_UsageRecords.fromJson(await readJobJson(entry)));
      }
      return result(AiUsageState.available, total);
    } on Exception {
      return result(AiUsageState.localOnly, local, '暂时无法读取 NAS 共享用量。');
    }
  }
}

final class _UsageRecords {
  _UsageRecords();
  factory _UsageRecords.fromJson(Map<String, dynamic>? data) {
    final result = _UsageRecords();
    if (data == null) return result;
    if (data['calls'] case final Map<String, dynamic> calls) {
      for (final row in calls.entries) {
        if (row.value case [final int cost, final String? episode] when cost >= 0) {
          result.calls[row.key] = (cost, episode);
        } else {
          throw const FormatException('Invalid AI usage call');
        }
      }
      if (data['completed'] case final List rows when rows.every((row) => row is String)) {
        result.completed.addAll(rows.cast<String>());
        return result;
      }
    }
    throw const FormatException('Invalid AI usage ledger');
  }

  final calls = <String, (int, String?)>{};
  final completed = <String>{};
  bool merge(_UsageRecords other) {
    var changed = false;
    for (final row in other.calls.entries) {
      final original = calls[row.key];
      if (original == null || row.value.$1 > original.$1 || original.$2 == null && row.value.$2 != null) {
        final cost = original == null || row.value.$1 >= original.$1 ? row.value.$1 : original.$1;
        calls[row.key] = (cost, original?.$2 ?? row.value.$2);
        changed = true;
      }
    }
    for (final episode in other.completed) {
      if (completed.add(episode)) changed = true;
    }
    return changed;
  }

  Map<String, dynamic> toJson() => {
    'calls': {
      for (final row in calls.entries) row.key: [row.value.$1, row.value.$2],
    },
    'completed': completed.toList(),
  };
}
