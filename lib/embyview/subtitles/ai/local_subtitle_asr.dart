import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../contracts/common.dart';
import '../../contracts/subtitles.dart';
import '../audio/subtitle_audio.dart';
import 'subtitle_ai_types.dart';

enum AsrModelState { notDownloaded, downloading, ready, failed }

class AsrModelStatus {
  const AsrModelStatus({required this.state, required this.receivedBytes, required this.totalBytes, this.error});

  final AsrModelState state;
  final int receivedBytes, totalBytes;
  final String? error;

  String? get unavailableReason => switch (state) {
    AsrModelState.ready => null,
    AsrModelState.notDownloaded => '请到设置的 AI 字幕中下载本机听写模型。',
    AsrModelState.downloading => '本机听写模型正在下载，请在设置中查看进度。',
    AsrModelState.failed => '本机听写模型不可用，请在设置中重新下载。${error ?? ''}',
  };
}

class LocalSubtitleAsr {
  const LocalSubtitleAsr({this.channel = const MethodChannel('embyview/asr')});

  final MethodChannel channel;

  Future<AsrModelStatus> modelStatus() async {
    final data = await _invoke<Map>('modelStatus');
    final state = AsrModelState.values.where((state) => state.name == data?['state']).firstOrNull;
    if (state == null || data?['receivedBytes'] is! int || data?['totalBytes'] is! int) {
      throw const EmbyViewFailure('无法读取本机听写模型状态。', retryable: true, code: 'subtitle_asr_status');
    }
    return AsrModelStatus(
      state: state,
      receivedBytes: data!['receivedBytes'],
      totalBytes: data['totalBytes'],
      error: data['error'] as String?,
    );
  }

  Future<void> downloadModel() => _invoke<void>('downloadModel');
  Future<void> cancelDownload() => _invoke<void>('cancelDownload');
  Future<void> deleteModel() => _invoke<void>('deleteModel');

  Future<({String language, List<SubtitleCue> cues})> transcribe(
    SubtitleAudioSegment segment,
    SubtitleAiCancellation cancellation,
  ) async {
    cancellation.check();
    final id = const Uuid().v4();
    void cancel() {
      unawaited(_invoke<void>('cancelTranscription', {'requestId': id}).catchError((Object _) {}));
    }

    cancellation.addListener(cancel);
    try {
      final data = await _invoke<Map>('transcribe', {
        'requestId': id,
        'pcm': segment.pcm,
        'sampleRate': segment.sampleRate,
      });
      cancellation.check();
      final rows = data?['segments'];
      final language = data?['language'];
      if (rows is! List || language is! String) throw _invalid;
      final cues = <SubtitleCue>[];
      final limit = segment.duration.inMicroseconds;
      for (final (index, row) in rows.indexed) {
        if (row is! Map || row['startUs'] is! int || row['endUs'] is! int || row['text'] is! String) throw _invalid;
        final start = (row['startUs'] as int).clamp(0, limit);
        final end = (row['endUs'] as int).clamp(0, limit);
        final text = (row['text'] as String).trim();
        if (end - start < 1000 || text.isEmpty) continue;
        cues.add(
          SubtitleCue(
            id: '${segment.start.inMicroseconds}:$index',
            start: segment.start + Duration(microseconds: start),
            end: segment.start + Duration(microseconds: end),
            text: text,
          ),
        );
      }
      return (language: language, cues: cues);
    } on EmbyViewFailure {
      cancellation.check();
      rethrow;
    } finally {
      cancellation.removeListener(cancel);
    }
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const EmbyViewFailure('此设备未提供本机听写服务。', code: 'subtitle_asr_unavailable');
    } on PlatformException catch (error) {
      throw EmbyViewFailure(error.message ?? '本机听写失败，请在设置中检查模型。', retryable: true, code: error.code);
    }
  }
}

const _invalid = EmbyViewFailure('本机听写返回的句子或时间不可用。', retryable: true, code: 'subtitle_asr_response');
