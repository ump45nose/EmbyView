// dart format width=120
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef Transliterate = String Function(String text);

/// macOS uses its bundled ICU transliterator; tests inject the same operation.
/// No downloaded dictionary or application-visible Chinese-only subset.
class TitleKey {
  TitleKey(String title, Transliterate transliterate) : latin = transliterate(title).toLowerCase().trim() {
    final words = latin.split(RegExp(r'[^a-z0-9]+')).where((e) => e.isNotEmpty);
    initials = words.map((e) => e[0]).join();
    sort = words.join();
    letter = sort.isNotEmpty && RegExp('[a-z]').hasMatch(sort[0]) ? sort[0].toUpperCase() : '#';
  }
  final String latin;
  late final String initials;
  late final String sort;
  late final String letter;
}

typedef _CreateNative = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32);
typedef _Create = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _CopyNative = Pointer<Void> Function(Pointer<Void>, IntPtr, Pointer<Void>);
typedef _Copy = Pointer<Void> Function(Pointer<Void>, int, Pointer<Void>);
typedef _TransformNative = Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint8);
typedef _Transform = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int);
typedef _LengthNative = IntPtr Function(Pointer<Void>);
typedef _Length = int Function(Pointer<Void>);
typedef _GetNative = Uint8 Function(Pointer<Void>, Pointer<Utf8>, IntPtr, Uint32);
typedef _Get = int Function(Pointer<Void>, Pointer<Utf8>, int, int);
typedef _ReleaseNative = Void Function(Pointer<Void>);
typedef _Release = void Function(Pointer<Void>);

class MacPinyin {
  MacPinyin._(this._library);
  final DynamicLibrary _library;
  static final MacPinyin? _instance = Platform.isMacOS
      ? MacPinyin._(DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'))
      : null;
  static String transliterate(String text) => _instance?._convert(text) ?? text;
  late final _create = _library.lookupFunction<_CreateNative, _Create>('CFStringCreateWithCString');
  late final _copy = _library.lookupFunction<_CopyNative, _Copy>('CFStringCreateMutableCopy');
  late final _transform = _library.lookupFunction<_TransformNative, _Transform>('CFStringTransform');
  late final _length = _library.lookupFunction<_LengthNative, _Length>('CFStringGetLength');
  late final _get = _library.lookupFunction<_GetNative, _Get>('CFStringGetCString');
  late final _release = _library.lookupFunction<_ReleaseNative, _Release>('CFRelease');
  late final _latin = _library.lookup<Pointer<Void>>('kCFStringTransformToLatin').value;
  late final _strip = _library.lookup<Pointer<Void>>('kCFStringTransformStripCombiningMarks').value;

  String _convert(String text) {
    const utf8 = 0x08000100;
    final input = text.toNativeUtf8();
    final source = _create(nullptr, input, utf8);
    calloc.free(input);
    if (source == nullptr) return text;
    final mutable = _copy(nullptr, 0, source);
    _release(source);
    if (mutable == nullptr) return text;
    Pointer<Utf8>? output;
    try {
      _transform(mutable, nullptr, _latin, 0);
      _transform(mutable, nullptr, _strip, 0);
      final size = _length(mutable) * 4 + 1;
      output = calloc<Uint8>(size).cast<Utf8>();
      return _get(mutable, output, size, utf8) != 0 ? output.toDartString() : text;
    } finally {
      if (output != null) calloc.free(output);
      _release(mutable);
    }
  }
}
