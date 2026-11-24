// Internal adapters import this file directly. Never export it from the barrel.
import 'package:flutter/painting.dart';

import '../media.dart';

final class AuthorizedArtworkRef implements ArtworkRef {
  const AuthorizedArtworkRef({
    required this.id,
    required this.cacheKey,
    required this.image,
    this.aspectRatio,
    this.width,
    this.height,
  });

  @override
  final String id;
  @override
  final String cacheKey;
  @override
  final ImageProvider<Object> image;
  @override
  final double? aspectRatio;
  @override
  final int? width;
  @override
  final int? height;
}

final class AuthorizedPreviewRef implements PreviewRef {
  AuthorizedPreviewRef({
    required this.id,
    required this.name,
    required this.uri,
    Map<String, String> headers = const {},
    this.duration,
  }) : headers = Map.unmodifiable(headers);

  @override
  final String id;
  @override
  final String name;
  @override
  final Duration? duration;
  final Uri uri;
  final Map<String, String> headers;
}
