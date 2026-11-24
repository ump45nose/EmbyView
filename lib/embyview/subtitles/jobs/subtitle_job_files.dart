import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

Future<Map<String, dynamic>?> readJobJson(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file) throw FileSystemException('Expected a regular file', file.path);
  final data = jsonDecode(await file.readAsString());
  if (data is! Map<String, dynamic>) throw const FormatException('Invalid subtitle job record');
  return data;
}

Future<void> writeJobJson(File file, Map<String, dynamic> data) async {
  final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
  try {
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

class SubtitleJobSerial {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
