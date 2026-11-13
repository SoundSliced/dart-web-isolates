import 'dart:async';

import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

/// Pausing and resuming dispatch (ADR-028).
Future<Object?> _slow(Object? input) async {
  await Future<void>.delayed(Duration(milliseconds: input! as int));
  return input;
}

Future<Object?> _echo(Object? input) async => input;

void main() {
  setUpAll(() {
    Dwi.registerTask('slow', _slow);
    Dwi.registerTask('echo', _echo);
  });

  setUp(() => Dwi.configure(const DwiConfig()));

  tearDown(() async {
    Dwi.resume();
    await Dwi.close();
  });

  test('held calls start only after resume, in order', () async {
    Dwi.pause();
    expect(Dwi.isPaused, isTrue);
    final order = <String>[];
    final first = Dwi.run<String>('echo', 'a').then((v) => order.add(v));
    final second = Dwi.runFresh<String>('echo', 'b').then((v) => order.add(v));
    final third = Dwi.runCancellable<String>('echo', 'c');
    unawaited(third.result.then((v) => order.add(v)));

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(order, isEmpty);

    Dwi.resume();
    expect(Dwi.isPaused, isFalse);
    await Future.wait<void>(<Future<void>>[first, second, third.result]);
    expect(order, containsAll(<String>['a', 'b', 'c']));
    expect(order, hasLength(3));
  });

  test('a call already running keeps running while paused', () async {
    final running = Dwi.run<int>('slow', 200);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    Dwi.pause();
    expect(await running, 200);
  });

  test('a held cancellable call can be cancelled without starting', () async {
    Dwi.pause();
    final task = Dwi.runCancellable<int>('slow', 10);
    expect(await task.cancel(), isTrue);
    await expectLater(task.result, throwsA(isA<DwiCancelledException>()));
    expect(await task.cancel(), isFalse);
    Dwi.resume();
    // Nothing is left to dispatch and later calls run normally.
    expect(await Dwi.run<int>('slow', 5), 5);
  });

  test('cancelling after resume reaches the running call', () async {
    Dwi.pause();
    final task = Dwi.runCancellable<int>('slow', 2000);
    Dwi.resume();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await task.cancel(), isTrue);
    await expectLater(task.result, throwsA(isA<DwiCancelledException>()));
  });

  test('the hold is bounded by maxQueuedTasks and queueTimeout', () async {
    await Dwi.configure(
      const DwiConfig(
        maxQueuedTasks: 2,
        queueTimeout: Duration(milliseconds: 100),
      ),
    );
    Dwi.pause();
    final a = expectLater(
      Dwi.run<int>('slow', 1),
      throwsA(isA<DwiTimeoutException>()),
    );
    final b = expectLater(
      Dwi.runCancellable<int>('slow', 1).result,
      throwsA(isA<DwiTimeoutException>()),
    );
    final refused = Dwi.run<int>('slow', 1);
    await expectLater(refused, throwsA(isA<DwiUnsupportedException>()));
    final refusedCancellable = Dwi.runCancellable<int>('slow', 1);
    await expectLater(
      refusedCancellable.result,
      throwsA(isA<DwiUnsupportedException>()),
    );
    await a;
    await b;
    // Timed-out calls left the hold: resuming dispatches nothing stale.
    Dwi.resume();
    expect(await Dwi.run<int>('slow', 1), 1);
  });

  test('close fails held calls; close(drain: true) runs them', () async {
    Dwi.pause();
    final failed = expectLater(
      Dwi.run<int>('slow', 1),
      throwsA(isA<DwiUnsupportedException>()),
    );
    final failedCancellable = expectLater(
      Dwi.runCancellable<int>('slow', 1).result,
      throwsA(isA<DwiUnsupportedException>()),
    );
    await Dwi.close();
    await failed;
    await failedCancellable;
    expect(Dwi.isPaused, isFalse);

    Dwi.pause();
    final drained = Dwi.run<int>('slow', 50);
    final drainedFresh = Dwi.runFresh<int>('slow', 30);
    await Dwi.close(drain: true);
    expect(await drained, 50);
    expect(await drainedFresh, 30);
    expect(Dwi.isPaused, isFalse);
  });

  test('pause and resume are idempotent', () async {
    Dwi.resume();
    Dwi.pause();
    Dwi.pause();
    final held = Dwi.run<String>('echo', 'x');
    Dwi.resume();
    Dwi.resume();
    expect(await held, 'x');
  });

  test('dedicated handles are not paused', () async {
    final worker = await DwiWorker.spawn();
    try {
      Dwi.pause();
      expect(await worker.run<String>('echo', 'h'), 'h');
    } finally {
      await worker.close();
    }
  });

  test('DwiWorker.ping reports a round trip (ADR-028)', () async {
    final worker = await DwiWorker.spawn();
    try {
      expect(await worker.ping(), lessThan(const Duration(seconds: 1)));
    } finally {
      await worker.close();
    }
    await expectLater(
      worker.ping(),
      throwsA(isA<DwiWorkerClosedException>()),
    );
  });
}
