import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moonfin/embyview/embyview.dart';
import 'package:moonfin/embyview/ui/shell/ev_player.dart';
import 'package:moonfin/playback/mpv_player_registry.dart';
import 'package:moonfin/util/app_exit.dart';

class _FakePlayer extends Fake implements Player {
  _FakePlayer(this._dispose);

  final Future<void> Function() _dispose;
  int disposeCalls = 0;

  @override
  Future<void> dispose() {
    disposeCalls++;
    return _dispose();
  }
}

class _BlockedSession extends Fake implements PlaybackSession {
  final gate = Completer<void>();
  int closeCalls = 0;

  @override
  PlaybackSnapshot get snapshot => const PlaybackSnapshot(
    generation: 1, target: PlayTarget(itemId: 'episode'),
  );

  @override
  Future<void> close() {
    closeCalls++;
    return gate.future;
  }
}

class _BlockedPlayback extends Fake implements EmbyViewPlayback {
  final session = _BlockedSession();

  @override
  PlaybackSession open(PlayTarget target) => session;
}

void main() {
  late MpvPlayerRegistry registry;
  setUp(() => registry = MpvPlayerRegistry());

  _FakePlayer track(Future<void> Function() dispose) =>
      registry.track(_FakePlayer(dispose)) as _FakePlayer;

  test('disposeAll disposes every tracked player once', () async {
    final a = track(() async {});
    final b = track(() async {});

    await registry.disposeAll();
    await registry.disposeAll();

    expect(a.disposeCalls, 1);
    expect(b.disposeCalls, 1);
  });

  test('disposeAll survives a player that throws or never finishes', () async {
    track(() async => throw StateError('already disposed'));
    track(() => Future<void>.delayed(const Duration(days: 1)));
    final ok = track(() async {});

    await registry.disposeAll();

    expect(ok.disposeCalls, 1);
  });

  test('disposeAll waits for a dispose already in flight', () async {
    final gate = Completer<void>();
    final player = track(() => gate.future);

    final first = registry.dispose(player);
    final all = registry.disposeAll();
    var allDone = false;
    unawaited(all.then((_) => allDone = true));
    await Future<void>.delayed(Duration.zero);
    expect(allDone, isFalse);

    gate.complete();
    await Future.wait([first, all]);

    expect(player.disposeCalls, 1);
  });

  test('disposing a player again after exit released it does nothing', () async {
    final player = track(() async {});

    await registry.disposeAll();
    await registry.dispose(player);

    expect(player.disposeCalls, 1);
  });

  test('creating a player after shutdown starts is rejected', () async {
    await registry.disposeAll();

    expect(() => registry.create(), throwsStateError);
  });

  testWidgets('prepareForExit caps the stop wait and shares teardown across calls', (tester) async {
    final playback = _BlockedPlayback();
    final player = MpvPlayerRegistry.instance.track(_FakePlayer(() async {})) as _FakePlayer;
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Navigator(key: nav, onGenerateRoute: (_) => PageRouteBuilder<void>(
        pageBuilder: (ctx, _, _) => GestureDetector(
          onTap: () => unawaited(EvPlayer.open(ctx, const PlayTarget(itemId: 'episode'),
            playback: playback, builder: (_, _, {origin, art}) => const SizedBox.expand())),
          child: const Text('play'),
        ),
      )),
    ));
    await tester.tap(find.text('play'));
    await tester.pumpAndSettle();
    final exit = AppExit.prepareForExit();
    expect(identical(exit, AppExit.prepareForExit()), isTrue);
    await tester.pump(const Duration(milliseconds: 2499));
    expect(player.disposeCalls, 0);
    expect(playback.session.closeCalls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await exit;
    expect(player.disposeCalls, 1);

    nav.currentState!.pop();
    playback.session.gate.complete();
    await tester.pumpAndSettle();
    expect(playback.session.closeCalls, 1);
    expect(EvPlayer.isOpening, isFalse);
  });
}
