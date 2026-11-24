import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/shelf/ev_artwork.dart';
import 'package:moonfin/embyview/ui/shelf/ev_card.dart';
import 'package:moonfin/embyview/ui/shelf/ev_shelf.dart';
import 'package:moonfin/embyview/ui/shelf/ev_skeleton.dart';
import 'package:moonfin/embyview/ui/theme/ev_scale.dart';
import 'package:moonfin/embyview/ui/theme/ev_theme.dart';

// 1x1 valid PNG pixel for offline widget tests.
final Uint8List _kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _MemoryArtworkRef implements ArtworkRef {
  _MemoryArtworkRef(this.id, {ImageProvider<Object>? image})
    : image = image ?? MemoryImage(_kPngBytes);

  @override
  final String id;

  @override
  String get cacheKey => 'test_$id';

  @override
  final ImageProvider<Object> image;

  @override
  double? get aspectRatio => null;

  @override
  int? get width => 1;

  @override
  int? get height => 1;
}

class _FailingImageProvider extends ImageProvider<_FailingImageProvider> {
  const _FailingImageProvider(this.tag);
  final String tag;

  @override
  Future<_FailingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FailingImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FailingImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      Future<ImageInfo>.error(StateError('decode failed: $tag')),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _FailingImageProvider && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;
}

MediaCard _card(
  String id, {
  String title = '测试影片',
  String? libraryId = 'movie',
  MediaKind kind = MediaKind.movie,
  int? year = 2024,
  List<String> genres = const ['科幻'],
  bool? played,
  int? childCount,
  CardArtwork? art,
}) {
  final thumb = _MemoryArtworkRef('thumb_$id');
  final primary = _MemoryArtworkRef('primary_$id');
  return MediaCard(
    id: id,
    kind: kind,
    libraryId: libraryId,
    title: title,
    year: year,
    genres: genres,
    played: played,
    childCount: childCount,
    art:
        art ??
        CardArtwork(
          landscape: ArtworkPlan(
            layers: [ArtworkLayer(source: thumb)],
            fallbackTitle: title,
          ),
          poster: ArtworkPlan(
            layers: [ArtworkLayer(source: primary)],
            fallbackTitle: title,
            stack: kind == MediaKind.collection
                ? [
                    _MemoryArtworkRef('stack1_$id'),
                    _MemoryArtworkRef('stack2_$id'),
                  ]
                : const [],
          ),
        ),
  );
}

Widget _harness({
  required Widget child,
  Size size = const Size(1440, 900),
  ThemeMode mode = ThemeMode.cinema,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: EvThemeScope(
        themeMode: mode,
        child: Scaffold(body: child),
      ),
    ),
  );
}

double _rotationDegrees(Matrix4 m) =>
    math.atan2(m.entry(1, 0), m.entry(0, 0)) * 180.0 / math.pi;

void main() {
  group('C3.7 shelf card width, 0.25 peek, scrollbar, collection & resume', () {
    test('EvShelfLayout satisfies N + 0.25 peek at 1440x900 and 2560x1440', () {
      for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
        final scale = EvScale.fromSize(size);
        final gap = EvShelfLayout.gap(scale);
        final avail = size.width - scale.gutter;

        for (final style in EvCardStyle.values) {
          final n = EvShelfLayout.visibleFullCards(
            viewportWidth: size.width,
            scale: scale,
            style: style,
          );
          final w = EvShelfLayout.cardWidth(
            viewportWidth: size.width,
            scale: scale,
            style: style,
          );
          expect(n, greaterThanOrEqualTo(1));
          expect(n * w + n * gap + 0.25 * w, closeTo(avail, 1e-6));
        }
      }
    });

    testWidgets(
      'rendered EvShelf exposes exactly 0.25 of the (N+1)th card at 1440x900 and 2560x1440',
      (tester) async {
        for (final size in const [Size(1440, 900), Size(2560, 1440)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final scale = EvScale.fromSize(size);
          for (final style in EvCardStyle.values) {
            final expectedN = EvShelfLayout.visibleFullCards(
              viewportWidth: size.width,
              scale: scale,
              style: style,
            );
            final expectedW = EvShelfLayout.cardWidth(
              viewportWidth: size.width,
              scale: scale,
              style: style,
            );
            final items = List.generate(
              expectedN + 4,
              (i) => _card(
                'item_${style.name}_$i',
                title: '影片 $i',
                kind: style == EvCardStyle.collection
                    ? MediaKind.collection
                    : MediaKind.movie,
              ),
            );

            await tester.pumpWidget(
              _harness(
                size: size,
                child: EvShelf(
                  title: '测试货架',
                  items: items,
                  style: style,
                ),
              ),
            );
            await tester.pumpAndSettle();

            final cardFinders = find.byType(EvCard);
            final firstRect = tester.getRect(cardFinders.at(0));
            expect(firstRect.left, closeTo(scale.gutter, 0.5));
            expect(firstRect.width, closeTo(expectedW, 0.5));

            final peekingRect = tester.getRect(cardFinders.at(expectedN));
            final exposedFraction =
                (size.width - peekingRect.left) / peekingRect.width;
            expect(exposedFraction, closeTo(0.25, 0.01));
          }
        }
      },
    );

    testWidgets(
      'EvShelfScrollbar hides when fitting, reveals on hover/scroll, and supports track click + thumb drag',
      (tester) async {
        const size = Size(1440, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // 1. Fits completely -> no scrollbar rendered.
        final fitController = ScrollController();
        addTearDown(fitController.dispose);
        await tester.pumpWidget(
          _harness(
            size: size,
            child: EvShelf(
              title: '少量内容',
              items: [_card('a'), _card('b')],
              style: EvCardStyle.landscape,
              controller: fitController,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ev_shelf_scrollbar_track')), findsNothing);

        // 2. Overflows -> hidden at rest, appears on hover and scroll, click & drag move offset.
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final many = List.generate(12, (i) => _card('m$i', title: '大片 $i'));
        await tester.pumpWidget(
          _harness(
            size: size,
            child: EvShelf(
              title: '热门电影',
              badge: '12 部',
              moreLabel: '看看这 12 部',
              onMoreTap: () {},
              items: many,
              style: EvCardStyle.landscape,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final opacityFinder = find.byKey(
          const ValueKey('ev_shelf_scrollbar_opacity'),
        );
        expect(opacityFinder, findsOneWidget);
        expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 0.0);

        // Scroll programmatically -> scrollbar shows transiently, then fades out after 900ms.
        controller.jumpTo(120);
        await tester.pump();
        expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 1.0);
        await tester.pump(const Duration(milliseconds: 950));
        await tester.pumpAndSettle();
        expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 0.0);

        // Hover shelf -> scrollbar becomes visible.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(find.byType(EvShelf)));
        await tester.pumpAndSettle();
        expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 1.0);

        // Click near right end of scrollbar track -> scrolls further right.
        final trackRect = tester.getRect(
          find.byKey(const ValueKey('ev_shelf_scrollbar_track')),
        );
        final beforeClick = controller.offset;
        await tester.tapAt(
          Offset(trackRect.left + trackRect.width * 0.85, trackRect.center.dy),
        );
        await tester.pumpAndSettle();
        expect(controller.offset, greaterThan(beforeClick));

        // Drag thumb left -> scrolls back toward start.
        final thumbFinder = find.byKey(
          const ValueKey('ev_shelf_scrollbar_thumb'),
        );
        final beforeDrag = controller.offset;
        await tester.drag(thumbFinder, const Offset(-260, 0));
        await tester.pumpAndSettle();
        expect(controller.offset, lessThan(beforeDrag));
      },
    );

    testWidgets(
      'collection EvCard fans two back posters ±3° on hover and focus',
      (tester) async {
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        final boxCard = _card(
          'box1',
          title: '指环王三部曲',
          kind: MediaKind.collection,
          childCount: 3,
        );

        await tester.pumpWidget(
          _harness(
            child: Center(
              child: EvCard(
                card: boxCard,
                style: EvCardStyle.collection,
                width: 180,
                focusNode: focusNode,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        Transform midTransform() => tester.widget<Transform>(
          find.byKey(const ValueKey('ev_collection_stack_mid')),
        );
        Transform backTransform() => tester.widget<Transform>(
          find.byKey(const ValueKey('ev_collection_stack_back')),
        );

        // Idle: 0 degrees.
        expect(_rotationDegrees(midTransform().transform), closeTo(0.0, 0.01));
        expect(_rotationDegrees(backTransform().transform), closeTo(0.0, 0.01));

        // Hover -> mid -3°, back +3°.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(find.byType(EvCard)));
        await tester.pumpAndSettle();

        expect(_rotationDegrees(midTransform().transform), closeTo(-3.0, 0.05));
        expect(_rotationDegrees(backTransform().transform), closeTo(3.0, 0.05));

        // Leave hover -> returns to 0°.
        await mouse.moveTo(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(_rotationDegrees(midTransform().transform), closeTo(0.0, 0.05));
        expect(_rotationDegrees(backTransform().transform), closeTo(0.0, 0.05));

        // Keyboard focus -> fans ±3°.
        focusNode.requestFocus();
        await tester.pumpAndSettle();
        expect(_rotationDegrees(midTransform().transform), closeTo(-3.0, 0.05));
        expect(_rotationDegrees(backTransform().transform), closeTo(3.0, 0.05));
      },
    );

    testWidgets(
      'continue watching card renders progress bar, remaining time, and watched badge',
      (tester) async {
        expect(
          EvCard.formatRemaining(const Duration(minutes: 9)),
          '剩 9 分钟',
        );
        expect(
          EvCard.formatRemaining(const Duration(hours: 1, minutes: 15)),
          '剩 1 小时 15 分',
        );

        final epCard = _card('ep9', title: '葬送的芙莉莲', played: true);
        final resume = ResumeCard(
          card: epCard,
          target: const PlayTarget(itemId: 'ep9', episodeNumber: 9),
          position: const Duration(minutes: 15),
          duration: const Duration(minutes: 24),
        );

        final movieCard = _card('mov1', title: '沙丘 2');
        final longResume = ResumeCard(
          card: movieCard,
          target: const PlayTarget(itemId: 'mov1'),
          position: const Duration(minutes: 45),
          duration: const Duration(hours: 2, minutes: 10),
        );

        await tester.pumpWidget(
          _harness(
            mode: ThemeMode.paper,
            child: EvShelf(
              title: '继续观看',
              resumeItems: [resume, longResume],
              style: EvCardStyle.landscape,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('第 9 集 · 剩 9 分钟'), findsOneWidget);
        expect(find.text('剩 1 小时 25 分'), findsOneWidget);

        final progressBoxes = tester
            .widgetList<FractionallySizedBox>(
              find.descendant(
                of: find.byKey(const ValueKey('ev_card_progress')),
                matching: find.byType(FractionallySizedBox),
              ),
            )
            .toList();
        expect(progressBoxes.length, 2);
        expect(progressBoxes[0].widthFactor, closeTo(15 / 24, 0.01));
        expect(progressBoxes[1].widthFactor, closeTo(45 / 130, 0.01));

        // Paper theme played badge is terracotta solid circle with ink border.
        final playedBadge = tester.widget<Container>(
          find.byKey(const ValueKey('ev_card_played')),
        );
        final dec = playedBadge.decoration! as BoxDecoration;
        expect(dec.color, EvTheme.paper.brand);
        expect(dec.shape, BoxShape.circle);
      },
    );

    testWidgets(
      'focused EvCard switches between cinema scale+glow and paper offset+hard shadow',
      (tester) async {
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        final card = _card('f1', title: '千与千寻', libraryId: 'anime');

        // Cinema mode
        await tester.pumpWidget(
          _harness(
            mode: ThemeMode.cinema,
            child: Center(
              child: EvCard(
                card: card,
                style: EvCardStyle.landscape,
                width: 300,
                focusNode: focusNode,
              ),
            ),
          ),
        );
        focusNode.requestFocus();
        await tester.pumpAndSettle();

        final cinemaTransform = tester.widget<Transform>(
          find.byKey(const ValueKey('ev_card_art_transform')),
        );
        expect(cinemaTransform.transform.entry(0, 0), closeTo(1.07, 0.01));
        expect(cinemaTransform.transform.entry(0, 3), closeTo(0.0, 0.01));

        final cinemaBorder = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('ev_card_border')),
        );
        expect(
          ((cinemaBorder.decoration! as BoxDecoration).border! as Border)
              .top
              .color,
          EvTheme.cinema.focusColor,
        );

        // Paper mode
        await tester.pumpWidget(
          _harness(
            mode: ThemeMode.paper,
            child: Center(
              child: EvCard(
                card: card,
                style: EvCardStyle.landscape,
                width: 300,
                focusNode: focusNode,
              ),
            ),
          ),
        );
        focusNode.requestFocus();
        await tester.pumpAndSettle();

        final paperTransform = tester.widget<Transform>(
          find.byKey(const ValueKey('ev_card_art_transform')),
        );
        expect(paperTransform.transform.entry(0, 0), closeTo(1.0, 0.01));
        expect(paperTransform.transform.entry(0, 3), closeTo(-5.0, 0.1));
        expect(paperTransform.transform.entry(1, 3), closeTo(-5.0, 0.1));

        final paperBorder = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('ev_card_border')),
        );
        expect(
          ((paperBorder.decoration! as BoxDecoration).border! as Border)
              .top
              .color,
          const Color(0xFF141413),
        );

        // Title gets terracotta underline in paper focused state.
        final titleText = tester.widget<Text>(find.text('千与千寻'));
        expect(titleText.style?.decoration, TextDecoration.underline);
        expect(titleText.style?.decorationColor, EvTheme.paper.brand);
      },
    );

    testWidgets(
      'EvShelf auto-scrolls keyboard-focused card into view and renders skeleton when loading',
      (tester) async {
        const size = Size(1440, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final controller = ScrollController();
        addTearDown(controller.dispose);
        final targetNode = FocusNode();
        addTearDown(targetNode.dispose);

        await tester.pumpWidget(
          _harness(
            size: size,
            child: EvShelf(
              title: '横向焦点测试',
              style: EvCardStyle.landscape,
              controller: controller,
              itemCount: 10,
              itemBuilder: (context, index) => EvCard(
                card: _card('k$index', title: '条目 $index'),
                style: EvCardStyle.landscape,
                focusNode: index == 8 ? targetNode : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.offset, 0.0);

        targetNode.requestFocus();
        await tester.pumpAndSettle();
        expect(controller.offset, greaterThan(0.0));

        // Loading skeleton
        await tester.pumpWidget(
          _harness(
            size: size,
            child: const EvShelf(
              title: '加载中',
              loading: true,
              skeletonCount: 5,
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(EvShelfSkeleton), findsOneWidget);
        expect(find.byType(EvCardSkeleton), findsNWidgets(5));
      },
    );
  });

  group('C3.8 EvArtwork four fallback states and error degradation', () {
    testWidgets('1. Backdrop + small Logo renders both image and logo overlay', (
      tester,
    ) async {
      final bd = _MemoryArtworkRef('bd_1');
      final logo = _MemoryArtworkRef('logo_1');
      await tester.pumpWidget(
        _harness(
          child: Center(
            child: SizedBox(
              width: 320,
              child: EvArtwork(
                aspectRatio: 16 / 9,
                plan: ArtworkPlan(
                  layers: [
                    ArtworkLayer(
                      source: bd,
                      fit: ArtworkFit.cover,
                      logo: logo,
                    ),
                  ],
                  fallbackTitle: '星际穿越',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('ev_art_layer_0_${bd.cacheKey}')), findsOneWidget);
      expect(find.byKey(ValueKey('ev_art_logo_0_${logo.cacheKey}')), findsOneWidget);
      expect(find.text('星际穿越'), findsNothing);
    });

    testWidgets('2. Backdrop + title text renders image with title overlay', (
      tester,
    ) async {
      final bd = _MemoryArtworkRef('bd_2');
      await tester.pumpWidget(
        _harness(
          child: Center(
            child: SizedBox(
              width: 320,
              child: EvArtwork(
                aspectRatio: 16 / 9,
                plan: ArtworkPlan(
                  layers: [
                    ArtworkLayer(
                      source: bd,
                      fit: ArtworkFit.cover,
                      text: '银翼杀手 2049',
                    ),
                  ],
                  fallbackTitle: '银翼杀手 2049',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final img = tester.widget<Image>(
        find.byKey(ValueKey('ev_art_layer_0_${bd.cacheKey}')),
      );
      expect(img.fit, BoxFit.cover);
      expect(img.alignment, Alignment.center);
      expect(find.text('银翼杀手 2049'), findsOneWidget);
    });

    testWidgets(
      '3. Portrait cropped Backdrop + title text aligns to 30% horizontal crop',
      (tester) async {
        final bd = _MemoryArtworkRef('bd_3');
        await tester.pumpWidget(
          _harness(
            child: Center(
              child: SizedBox(
                width: 180,
                child: EvArtwork(
                  aspectRatio: 2 / 3,
                  plan: ArtworkPlan(
                    layers: [
                      ArtworkLayer(
                        source: bd,
                        fit: ArtworkFit.cover,
                        text: '千与千寻',
                      ),
                    ],
                    fallbackTitle: '千与千寻',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final img = tester.widget<Image>(
          find.byKey(ValueKey('ev_art_layer_0_${bd.cacheKey}')),
        );
        expect(img.fit, BoxFit.cover);
        expect(img.alignment, const Alignment(-0.4, 0.0));
        expect(find.text('千与千寻'), findsOneWidget);
      },
    );

    testWidgets(
      '4. Fallback color block + title renders when layers are empty',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            child: const Center(
              child: SizedBox(
                width: 180,
                child: EvArtwork(
                  aspectRatio: 2 / 3,
                  plan: ArtworkPlan(
                    layers: [],
                    fallbackColor: 0xFFFF8060,
                    fallbackTitle: '无图影片',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ev_artwork_fallback')), findsOneWidget);
        expect(find.text('无图影片'), findsOneWidget);
      },
    );

    testWidgets(
      'decoding error on upper layer degrades automatically to lower layer and fallback block',
      (tester) async {
        final brokenThumb = _MemoryArtworkRef(
          'broken_thumb',
          image: const _FailingImageProvider('thumb'),
        );
        final brokenLogo = _MemoryArtworkRef(
          'broken_logo',
          image: const _FailingImageProvider('logo'),
        );
        final goodBackdrop = _MemoryArtworkRef('good_bd');

        // Upper layer fails -> degrades to layer 1 (Backdrop + brokenLogo) -> logo fails -> degrades to layer 2 (Backdrop + title).
        await tester.pumpWidget(
          _harness(
            child: Center(
              child: SizedBox(
                width: 320,
                child: EvArtwork(
                  aspectRatio: 16 / 9,
                  plan: ArtworkPlan(
                    layers: [
                      ArtworkLayer(source: brokenThumb),
                      ArtworkLayer(
                        source: goodBackdrop,
                        fit: ArtworkFit.cover,
                        logo: brokenLogo,
                      ),
                      ArtworkLayer(
                        source: goodBackdrop,
                        fit: ArtworkFit.cover,
                        text: '降级片名',
                      ),
                    ],
                    fallbackColor: 0xFF7FA7FF,
                    fallbackTitle: '降级片名',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(ValueKey('ev_art_layer_2_${goodBackdrop.cacheKey}')),
          findsOneWidget,
        );
        expect(find.text('降级片名'), findsOneWidget);

        // When all layers fail -> degrades all the way to fallback color block + title.
        final brokenOnly = _MemoryArtworkRef(
          'broken_only',
          image: const _FailingImageProvider('only'),
        );
        await tester.pumpWidget(
          _harness(
            mode: ThemeMode.paper,
            child: Center(
              child: SizedBox(
                width: 180,
                child: EvArtwork(
                  aspectRatio: 2 / 3,
                  plan: ArtworkPlan(
                    layers: [ArtworkLayer(source: brokenOnly)],
                    fallbackColor: 0xFFD97757,
                    fallbackTitle: '终极兜底',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ev_artwork_fallback')), findsOneWidget);
        expect(find.text('终极兜底'), findsOneWidget);
      },
    );

    testWidgets(
      'idle EvCard mounts zero implicit animation controllers and EvShelf more button supports keyboard activation',
      (tester) async {
        var moreHits = 0;
        await tester.pumpWidget(
          _harness(
            child: EvShelf(
              title: '轻量化测试',
              items: [_card('idle1', libraryId: 'real-emby-guid-1', kind: MediaKind.series)],
              moreLabel: '查看全部',
              onMoreTap: () => moreHits++,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final cardFinder = find.byType(EvCard);
        expect(find.descendant(of: cardFinder, matching: find.byType(AnimatedContainer)), findsNothing);
        expect(find.descendant(of: cardFinder, matching: find.byType(AnimatedOpacity)), findsNothing);
        expect(find.descendant(of: cardFinder, matching: find.byType(TweenAnimationBuilder<double>)), findsNothing);
        expect(find.descendant(of: cardFinder, matching: find.byType(TweenAnimationBuilder<Offset>)), findsNothing);

        // Hover enables animations; leave demotes back to zero animation controllers.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(cardFinder));
        await tester.pump();
        expect(find.descendant(of: cardFinder, matching: find.byType(AnimatedContainer)), findsWidgets);

        await mouse.moveTo(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(find.descendant(of: cardFinder, matching: find.byType(AnimatedContainer)), findsNothing);

        // EvShelf "more" button activates on Enter/Space.
        Focus.of(tester.element(find.text('查看全部'))).requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        expect(moreHits, 2);
      },
    );
  });
}
