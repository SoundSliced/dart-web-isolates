import 'dart:async';

import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

Future<Object?> _slow(Object? input) async {
  await Future<void>.delayed(Duration(milliseconds: input! as int));
  return input;
}

void main() {
  setUpAll(() async {
    Dwi.registerTask('slow', _slow);
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  test('close(drain: true) lets started calls finish and refuses new ones',
      () async {
    final running = Dwi.run<int>('slow', 300);
    final cancellable = Dwi.runCancellable<int>('slow', 200);
    final fresh = Dwi.runFresh<int>('slow', 250);
    // Give the calls a moment to be started before draining.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final watch = Stopwatch()..start();
    final closing = Dwi.close(drain: true);

    await expectLater(
      Dwi.run<int>('slow', 1),
      throwsA(isA<DwiUnsupportedException>()),
    );
    await expectLater(
      Dwi.runCancellable<int>('slow', 1).result,
      throwsA(isA<DwiUnsupportedException>()),
    );
    await expectLater(
      Dwi.runFresh<int>('slow', 1),
      throwsA(isA<DwiUnsupportedException>()),
    );

    expect(await running, 300);
    expect(await cancellable.result, 200);
    expect(await fresh, 250);
    await closing;
    // The drain waited for the slowest call.
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(200));

    // A drained close keeps the configuration and accepts work again.
    expect(await Dwi.run<int>('slow', 5), 5);
  });

  test('a failing call does not block the drain', () async {
    Dwi.registerTask('fail', (Object? input) => throw StateError('nope'));
    final failing = expectLater(
      Dwi.run<Object?>('fail'),
      throwsA(isA<DwiRemoteException>()),
    );
    final ok = Dwi.run<int>('slow', 100);
    await Dwi.close(drain: true);
    await failing;
    expect(await ok, 100);
  });

  test('close without drain does not wait for pooled calls', () async {
    final running = Dwi.run<int>('slow', 400);
    running.ignore();
    final watch = Stopwatch()..start();
    await Dwi.close();
    expect(watch.elapsedMilliseconds, lessThan(300));
  });
}
