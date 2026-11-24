import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../contracts/common.dart';
import '../../contracts/subtitles.dart';
import '../audio/subtitle_audio.dart';
import '../model/subtitle_document.dart';
import 'subtitle_ai_types.dart';

/// Estimate a shift and a small playback-rate difference from audible speech
/// onsets. Keep the source script when the onsets do not give a consistent fit.
Future<SubtitleDocument> alignSubtitle(
  SubtitleDocument document,
  Stream<SubtitleAudioSegment> audio, {
  required SubtitleAiCancellation cancellation,
}) async {
  final cues = document.cues;
  if (cues == null || cues.isEmpty) {
    throw const EmbyViewFailure('没有可用于校正的文本字幕原文。', code: 'subtitle_text_unavailable');
  }
  cancellation.check();
  final speech = <TimeRange>[];
  final input = StreamIterator(audio);
  void stop() => unawaited(input.cancel());
  cancellation.addListener(stop);
  try {
    while (await input.moveNext()) {
      cancellation.check();
      speech.addAll(await _analyze(input.current));
      cancellation.check();
    }
    cancellation.check();
  } finally {
    cancellation.removeListener(stop);
    await input.cancel();
  }
  final onsets = [for (final range in mergeSubtitleAiCoverage(speech)) range.start.inMicroseconds / 1000000];
  final result = await _fitInBackground(cues, onsets, document.format);
  cancellation.check();
  return result == null ? document : document.withTimings(result);
}

Future<List<TimeRange>> _analyze(SubtitleAudioSegment segment) => Isolate.run(() => _speechSpans(segment));

List<TimeRange> _speechSpans(SubtitleAudioSegment segment) {
  const frameTime = Duration(milliseconds: 20);
  final width = segment.sampleRate ~/ 50;
  final sampleCount = segment.pcm.length ~/ 4;
  final pcm = ByteData.sublistView(segment.pcm);
  final energy = <double>[];
  var previous = 0.0;
  for (var frame = 0; frame + width <= sampleCount; frame += width) {
    var sum = 0.0;
    for (var index = frame; index < frame + width; index++) {
      final pcmValue = pcm.getFloat32(index * 4, Endian.little);
      final sample = pcmValue.isFinite ? pcmValue : 0.0;
      // Suppress DC and low-frequency rumble before measuring the envelope.
      final filtered = sample - 0.96 * previous;
      previous = sample;
      sum += filtered * filtered;
    }
    energy.add(math.sqrt(sum / width));
  }
  if (energy.length < 6) return const [];
  final sorted = energy.toList()..sort();
  final floor = sorted[sorted.length ~/ 5];
  final peak = sorted[sorted.length * 98 ~/ 100];
  if (peak < 0.0008 || peak < 1.6 * floor) return const [];
  final threshold = math.max(0.0008, math.max(2.2 * floor, 0.15 * peak));
  final result = <TimeRange>[];
  int? start;
  var stop = 0;
  void append() {
    final first = start;
    if (first != null && stop - first >= 6) {
      result.add(TimeRange(start: segment.start + frameTime * first, end: segment.start + frameTime * stop));
    }
    start = null;
  }

  for (final (index, level) in energy.indexed) {
    if (level < threshold) continue;
    if (start != null && index - stop > 6) append();
    start ??= index;
    stop = index + 1;
  }
  append();
  return result;
}

Future<List<SubtitleCue>?> _fitInBackground(List<SubtitleCue> cues, List<double> onsets, String format) =>
    Isolate.run(() => _fit(cues, onsets, format == 'ass' || format == 'ssa' ? 10000 : 1000));

const _maxOffset = 25.0;
const _maxDrift = 0.045;
const _voteWidth = 0.25;
const _tolerance = 0.4;

typedef _Anchor = ({String id, double time});
typedef _Shift = ({double offset, double drift});
typedef _Match = ({_Anchor anchor, double onset});

List<SubtitleCue>? _fit(List<SubtitleCue> cues, List<double> onsets, int minLengthUs) {
  final anchors = <_Anchor>[];
  var previousEnd = Duration.zero;
  for (final cue in cues) {
    if (cue.start >= previousEnd + const Duration(milliseconds: 160) &&
        cue.end - cue.start >= const Duration(milliseconds: 180)) {
      anchors.add((id: cue.id, time: cue.start.inMicroseconds / 1000000));
    }
    if (cue.end > previousEnd) previousEnd = cue.end;
  }
  if (anchors.length < 4 || onsets.length < 4) return null;

  final step = (anchors.length / 180).ceil();
  final votes = [for (var i = 0; i < anchors.length; i += step) anchors[i]];
  final span = (votes.last.time - votes.first.time).clamp(10.0, 1500.0);
  final driftSteps = (_maxDrift * span / _voteWidth).ceil();
  final offsets = (2 * _maxOffset / _voteWidth).round() + 1;
  var bestVotes = 0;
  _Shift? best;
  final contenders = <(_Shift, int)>[];
  for (var slope = -driftSteps; slope <= driftSteps; slope++) {
    final drift = slope * _maxDrift / driftSteps;
    final histogram = List<int>.filled(offsets, 0);
    for (final anchor in votes) {
      final predicted = anchor.time * (1 + drift);
      var i = _lowerBound(onsets, predicted - _maxOffset - _voteWidth);
      var previousBin = -1;
      while (i < onsets.length && onsets[i] <= predicted + _maxOffset + _voteWidth) {
        final bin = ((onsets[i++] - predicted + _maxOffset) / _voteWidth).round();
        if (bin == previousBin || bin < 0 || bin >= offsets) continue;
        histogram[bin]++;
        previousBin = bin;
      }
    }
    for (var index = 0; index < offsets; index++) {
      final center = histogram[index];
      final left = index == 0 ? 0 : histogram[index - 1];
      final right = index == offsets - 1 ? 0 : histogram[index + 1];
      final count = 2 * center + left + right;
      if (count * 2 < votes.length) continue;
      final candidate = (offset: index * _voteWidth - _maxOffset, drift: drift);
      contenders.add((candidate, count));
      if (count > bestVotes) {
        bestVotes = count;
        best = candidate;
      }
    }
  }
  if (best == null) return null;
  // Repetitive sounds can support several different shifts equally well.
  final middle = anchors[anchors.length ~/ 2].time;
  double prediction(_Shift shift) => shift.offset + middle * shift.drift;
  final center = prediction(best);
  if (contenders.any((other) => other.$2 >= bestVotes * 0.96 && (prediction(other.$1) - center).abs() > 0.7)) {
    return null;
  }
  final initial = _match(anchors, onsets, best);
  if (initial.length < math.max(4, (anchors.length * 0.6).ceil())) return null;
  final fitted = _regression(initial);
  if (fitted.offset.abs() > _maxOffset + _tolerance || fitted.drift.abs() > _maxDrift) {
    return null;
  }

  final matched = _match(anchors, onsets, fitted).map((match) => match.anchor.id).toSet();
  if (matched.length < math.max(4, (anchors.length * 0.6).ceil())) return null;
  return [for (final cue in cues) _shiftCue(cue, fitted, matched.contains(cue.id), minLengthUs)];
}

int _lowerBound(List<double> values, double target) {
  var start = 0;
  var end = values.length;
  while (start < end) {
    final middle = (start + end) ~/ 2;
    if (values[middle] < target) {
      start = middle + 1;
    } else {
      end = middle;
    }
  }
  return start;
}

List<_Match> _match(List<_Anchor> anchors, List<double> onsets, _Shift shift) {
  final result = <_Match>[];
  var last = -1;
  for (final anchor in anchors) {
    final predicted = anchor.time * (1 + shift.drift) + shift.offset;
    final index = math.max(last + 1, _lowerBound(onsets, predicted));
    final before = index - 1;
    final right = index < onsets.length ? onsets[index] - predicted : double.infinity;
    final left = before > last ? predicted - onsets[before] : double.infinity;
    final nearest = left <= right ? before : index;
    if (nearest > last && math.min(left, right) <= _tolerance) {
      result.add((anchor: anchor, onset: onsets[nearest]));
      last = nearest;
    }
  }
  return result;
}

_Shift _regression(List<_Match> matches) {
  var sumTime = 0.0;
  var sumShift = 0.0;
  for (final match in matches) {
    sumTime += match.anchor.time;
    sumShift += match.onset - match.anchor.time;
  }
  final meanTime = sumTime / matches.length;
  final meanShift = sumShift / matches.length;
  var variance = 0.0;
  var covariance = 0.0;
  for (final match in matches) {
    final centered = match.anchor.time - meanTime;
    variance += centered * centered;
    covariance += centered * (match.onset - match.anchor.time - meanShift);
  }
  final drift = matches.last.anchor.time - matches.first.anchor.time >= 8 ? covariance / variance : 0.0;
  return (offset: meanShift - drift * meanTime, drift: drift);
}

SubtitleCue _shiftCue(SubtitleCue cue, _Shift shift, bool matched, int minLengthUs) {
  Duration shifted(Duration time) {
    final us = time.inMicroseconds * (matched ? 1 + shift.drift : 1.0) + shift.offset * 1000000;
    return Duration(microseconds: math.max(0, us.round()));
  }

  final start = shifted(cue.start);
  final end = shifted(cue.end);
  final minimum = start + Duration(microseconds: minLengthUs);
  return SubtitleCue(id: cue.id, start: start, end: end < minimum ? minimum : end, text: cue.text);
}
