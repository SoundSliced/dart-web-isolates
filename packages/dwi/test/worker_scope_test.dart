import 'dart:async';

import 'package:dwi/dwi.dart';
import 'package:dwi/src/worker_scope.dart' show runScopedWorker;
import 'package:test/test.dart';

var counter = 0;

void main() {
  setUpAll(() async {
    Dwi.registerTask('counter', (Object? input) => ++counter);
    Dwi.registerTask('failingTask', (Object? input) {
      throw StateError('task failed');
    });
    Dwi.registerTask('slowWorker', (Object? input) async {
      await Future<void>.delayed(Duration(milliseconds: input! as int));
      return 'slow';
    });
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  test('using runs several calls and retains worker-local state', () async {
    late DwiWorker captured;
    final values = await DwiWorker.using((worker) async {
      captured = worker;
      final first = await worker.run<int>('counter', null);
      final second = await worker.run<int>('counter', null);
      return (first, second);
    });

    expect(values, (1, 2));
    expect(captured.state, DwiWorkerState.closed);
    await expectLater(
      captured.run<int>('counter', null),
      throwsA(isA<DwiWorkerClosedException>()),
    );
  });

  test('using supports void, synchronous and typed returns', () async {
    var ran = false;
    await DwiWorker.using<void>((worker) async {
      ran = true;
      await worker.run<int>('counter', null);
    });
    expect(ran, isTrue);

    expect(await DwiWorker.using((worker) => 21 * 2), 42);
  });

  test('a task failure propagates and the handle is closed', () async {
    late DwiWorker captured;
    await expectLater(
      DwiWorker.using<void>((worker) {
        captured = worker;
        return worker.run<int>('failingTask', null);
      }),
      throwsA(isA<DwiRemoteException>()),
    );
    expect(captured.state, DwiWorkerState.closed);
  });

  test('a callback failure is rethrown unchanged and the handle is closed',
      () async {
    final error = StateError('callback failed');
    late DwiWorker captured;
    Object? caught;
    try {
      await DwiWorker.using<void>((worker) {
        captured = worker;
        throw error;
      });
      fail('expected the callback error');
    } catch (e) {
      caught = e;
    }
    expect(identical(caught, error), isTrue);
    expect(captured.state, DwiWorkerState.closed);
  });

  test('a spawn failure never enters the callback or attempts cleanup',
      () async {
    final spawnError = DwiStartupException('no worker');
    var bodyRan = false;
    var closes = 0;

    await expectLater(
      runScopedWorker<void>(
        open: () async => throw spawnError,
        close: (_) async {
          closes++;
        },
        body: (_) {
          bodyRan = true;
        },
      ),
      throwsA(same(spawnError)),
    );
    expect(bodyRan, isFalse);
    expect(closes, 0);
  });

  test('closing the handle inside the callback is allowed', () async {
    late DwiWorker captured;
    final value = await DwiWorker.using((worker) async {
      captured = worker;
      expect(await worker.run<int>('counter', null), 1);
      await worker.close();
      return 'done';
    });

    expect(value, 'done');
    expect(captured.state, DwiWorkerState.closed);
    await expectLater(
      captured.run<int>('counter', null),
      throwsA(isA<DwiWorkerClosedException>()),
    );
  });

  test('a timeout during the callback closes the failed handle', () async {
    await Dwi.configure(
      const DwiConfig(taskTimeout: Duration(milliseconds: 50)),
    );
    late DwiWorker captured;
    try {
      await expectLater(
        DwiWorker.using<void>((worker) {
          captured = worker;
          return worker.run<String>('slowWorker', 5000);
        }),
        throwsA(isA<DwiTimeoutException>()),
      );
      expect(captured.state, DwiWorkerState.closed);
    } finally {
      await Dwi.configure(const DwiConfig());
    }
  });

  test('cancelling a running call propagates and closes the handle', () async {
    late DwiWorker captured;
    await expectLater(
      DwiWorker.using<void>((worker) async {
        captured = worker;
        final task = worker.runCancellable<String>('slowWorker', 5000);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await task.cancel();
        await task.result;
      }),
      throwsA(isA<DwiCancelledException>()),
    );
    expect(captured.state, DwiWorkerState.closed);
  });

  test('channels opened in the scope are failed at scope exit', () async {
    late DwiChannel channel;
    await DwiWorker.using<void>((worker) async {
      channel = await worker.openChannel('progress');
      channel.messages.listen(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      );
    });

    await expectLater(
      channel.send('after'),
      throwsA(isA<DwiChannelClosedException>()),
    );
  });

  test('close runs exactly once and no live handle remains', () async {
    final worker = await DwiWorker.spawn();
    var closes = 0;

    await runScopedWorker<void>(
      open: () async => worker,
      close: (handle) async {
        closes++;
        await handle.close();
      },
      body: (handle) async {
        expect(await handle.run<int>('counter', null), 1);
      },
    );

    expect(closes, 1);
    expect(worker.state, DwiWorkerState.closed);
  });

  test('a cleanup failure is the scope error when the callback succeeded',
      () async {
    final cleanupError = StateError('cleanup failed');
    await expectLater(
      runScopedWorker<void>(
        open: DwiWorker.spawn,
        close: (_) async => throw cleanupError,
        body: (_) {},
      ),
      throwsA(same(cleanupError)),
    );
  });

  test('a callback error wins and the cleanup failure rides in its stack',
      () async {
    // Deliberately no runZonedGuarded: an ordinary caller (and package:test's
    // own zone) must neither lose the cleanup failure nor treat it as an
    // uncaught error. The callback error stays the future's error.
    final bodyError = StateError('body failed');
    final cleanupError = StateError('cleanup failed');
    Object? caught;
    StackTrace? caughtStack;

    try {
      await runScopedWorker<void>(
        open: DwiWorker.spawn,
        close: (_) async => throw cleanupError,
        body: (_) => throw bodyError,
      );
      fail('expected the callback error');
    } catch (error, stack) {
      caught = error;
      caughtStack = stack;
    }

    expect(identical(caught, bodyError), isTrue);
    expect(caughtStack.toString(), contains(cleanupError.toString()));
  });

  test('an asynchronous cleanup failure also rides in the callback stack',
      () async {
    final bodyError = StateError('body failed');
    final cleanupError = StateError('async cleanup failed');
    Object? caught;
    StackTrace? caughtStack;

    try {
      await runScopedWorker<void>(
        open: DwiWorker.spawn,
        close: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw cleanupError;
        },
        body: (_) => throw bodyError,
      );
      fail('expected the callback error');
    } catch (error, stack) {
      caught = error;
      caughtStack = stack;
    }

    expect(identical(caught, bodyError), isTrue);
    expect(caughtStack.toString(), contains(cleanupError.toString()));
  });
}
