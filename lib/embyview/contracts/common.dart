/// A failure that can be shown directly to the user.
class EmbyViewFailure implements Exception {
  const EmbyViewFailure(this.reason, {this.retryable = false, this.code});

  final String reason;
  final bool retryable;
  final String? code;

  @override
  String toString() => reason;
}

class Page<T> {
  const Page({required this.items, required this.total, this.nextOffset});

  final List<T> items;
  final int total;
  final int? nextOffset;
}

class TimeRange {
  const TimeRange({required this.start, required this.end});

  final Duration start;
  final Duration end;
}
