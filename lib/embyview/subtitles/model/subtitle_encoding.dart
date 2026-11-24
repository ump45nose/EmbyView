import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

({String text, bool unchanged}) decodeSubtitle(Uint8List bytes, {String? encoding, String? language}) {
  final utf16Bom =
      bytes.length >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff));
  if (utf16Bom) return (text: _convert(bytes, 'UTF-16'), unchanged: false);
  try {
    final text = utf8.decode(bytes);
    if (!text.contains('\u0000')) return (text: text, unchanged: true);
  } on FormatException {
    // Legacy encodings are tried below.
  }
  if (encoding != null && encoding.trim().isNotEmpty) {
    return (text: _convert(bytes, encoding.trim()), unchanged: false);
  }
  final locales = language?.toLowerCase().replaceAll('_', '-').split('-') ?? const <String>[];
  final likely = switch (locales.firstOrNull) {
    'ja' || 'jpn' => ['CP932', 'EUC-JP'],
    'ko' || 'kor' => ['CP949'],
    'zh' || 'zho' || 'chi' when locales.any((part) => const {'hant', 'tw', 'hk'}.contains(part)) => ['BIG5', 'GB18030'],
    'zh' || 'zho' || 'chi' || null => ['GB18030', 'BIG5'],
    'ru' || 'rus' => ['WINDOWS-1251'],
    _ => <String>[],
  };
  for (final name in [...likely, 'WINDOWS-1252']) {
    try {
      return (text: _convert(bytes, name), unchanged: false);
    } on FormatException {
      // Try the next encoding without silently dropping invalid bytes.
    }
  }
  throw const FormatException('Unsupported subtitle character encoding');
}

typedef _Open = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _ConvertNative = Size Function(
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<Size>,
  Pointer<Pointer<Uint8>>,
  Pointer<Size>,
);
typedef _Convert = int Function(
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<Size>,
  Pointer<Pointer<Uint8>>,
  Pointer<Size>,
);

final _iconv = switch (Platform.operatingSystem) {
  'macos' => DynamicLibrary.open('/usr/lib/libiconv.2.dylib'),
  'linux' => DynamicLibrary.process(),
  _ => throw const FormatException('Unsupported subtitle character encoding'),
};

String _convert(Uint8List bytes, String name) {
  final open = _iconv.lookupFunction<_Open, _Open>('iconv_open');
  final convert = _iconv.lookupFunction<_ConvertNative, _Convert>('iconv');
  final close = _iconv.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('iconv_close');
  return using((arena) {
    final descriptor = open('UTF-8'.toNativeUtf8(allocator: arena), name.toNativeUtf8(allocator: arena));
    if (descriptor == Pointer<Void>.fromAddress(-1)) throw FormatException('Unknown subtitle character encoding', name);
    try {
      final input = arena<Uint8>(bytes.length + 1);
      input.asTypedList(bytes.length).setAll(0, bytes);
      final inputPointer = arena<Pointer<Uint8>>()..value = input;
      final inputLeft = arena<Size>()..value = bytes.length;
      final capacity = bytes.length * 4 + 4;
      final output = arena<Uint8>(capacity);
      final outputPointer = arena<Pointer<Uint8>>()..value = output;
      final outputLeft = arena<Size>()..value = capacity;
      convert(descriptor, inputPointer, inputLeft, outputPointer, outputLeft);
      final text = utf8.decode(output.asTypedList(capacity - outputLeft.value));
      if (inputLeft.value != 0 || text.contains('\u0000')) {
        throw FormatException('Invalid subtitle character encoding', name);
      }
      return text;
    } finally {
      close(descriptor);
    }
  });
}
