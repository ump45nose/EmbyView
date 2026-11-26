/// A failure that can be shown directly to the user.
class EmbyViewFailure implements Exception {
  const EmbyViewFailure(
    this.reason, {
    this.retryable = false,
    this.code,
    this.httpStatus,
    this.sourceLabel,
    this.isRateLimited = false,
  });

  const EmbyViewFailure.rateLimited115({
    String reason = '115 暂时限制了播放',
    int httpStatus = 403,
    String sourceLabel = '115 网盘',
    String code = 'rateLimited115',
  }) : this(
         reason,
         retryable: true,
         code: code,
         httpStatus: httpStatus,
         sourceLabel: sourceLabel,
         isRateLimited: true,
       );

  final String reason;
  final bool retryable;
  final String? code;
  final int? httpStatus;
  final String? sourceLabel;
  final bool isRateLimited;

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
