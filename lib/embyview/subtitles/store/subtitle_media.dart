import 'dart:io';

import 'package:path/path.dart' as p;

import '../../contracts/common.dart';
import '../../contracts/preferences.dart';
import '../../playback/playback_subtitle_input.dart';

final class SubtitleMedia {
  const SubtitleMedia({
    required this.itemId,
    required this.mediaSourceId,
    this.itemFilePath,
    this.mediaSourceFilePath,
    this.duration,
  });

  factory SubtitleMedia.fromPlayback(PlaybackSubtitleSource source, {Duration? duration}) => SubtitleMedia(
    itemId: source.target.itemId,
    mediaSourceId: source.mediaSourceId,
    itemFilePath: source.itemFilePath,
    mediaSourceFilePath: source.mediaSourceFilePath,
    duration: duration,
  );

  final String itemId;
  final String mediaSourceId;
  final String? itemFilePath;
  final String? mediaSourceFilePath;
  final Duration? duration;

  String? get embyFilePath {
    final item = itemFilePath;
    if (item != null && p.posix.extension(item).toLowerCase() == '.strm') return item;
    return mediaSourceFilePath ?? item;
  }
}

typedef MappedSubtitleMedia = ({String directory, String baseName, String embyDirectory});

Future<MappedSubtitleMedia> mapMedia(SubtitleMedia media, MediaFolderStatus status, {bool writing = false}) async {
  final localRoot = status.localRoot;
  if (status.state != MediaFolderState.authorized || localRoot == null) {
    throw EmbyViewFailure(status.reason ?? '媒体目录尚未授权或挂载。', retryable: true, code: 'subtitle_folder_unavailable');
  }
  if (writing && status.writable == false) {
    throw const EmbyViewFailure('已挂载的媒体目录当前不可写入。', retryable: true, code: 'subtitle_folder_read_only');
  }
  final filePath = media.embyFilePath;
  final embyRoot = p.posix.normalize(status.embyRoot);
  if (filePath == null ||
      !filePath.startsWith('/') ||
      filePath.startsWith('//') ||
      filePath.contains('\\') ||
      filePath.contains('\u0000') ||
      p.posix.split(filePath).contains('..') ||
      !p.posix.isWithin(embyRoot, p.posix.normalize(filePath))) {
    throw _outsideFolder;
  }
  final relative = p.posix.relative(filePath, from: embyRoot);
  final root = await Directory(localRoot).resolveSymbolicLinks();
  final realFile = await File(p.joinAll([root, ...p.posix.split(relative)])).resolveSymbolicLinks();
  if (!p.isWithin(root, realFile) || !await File(realFile).exists()) {
    throw _outsideFolder;
  }
  return (
    directory: p.dirname(realFile),
    baseName: p.basenameWithoutExtension(realFile),
    embyDirectory: p.posix.dirname(filePath),
  );
}

Future<void> verifyMappedDirectory(MappedSubtitleMedia media) async {
  if (await Directory(media.directory).resolveSymbolicLinks() != media.directory) {
    throw _outsideFolder;
  }
}

const _outsideFolder = EmbyViewFailure('该媒体源的文件路径不在已授权的媒体目录内。', code: 'subtitle_path_outside_root');
