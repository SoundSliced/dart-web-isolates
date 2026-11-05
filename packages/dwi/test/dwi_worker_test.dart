import 'dart:async';

import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

var counter = 0;

void main() {
  setUpAll(() async {
    Dwi.registerTask('counter', (Object? input) => ++counter);
    Dwi.registerTask('echoWorker', (Object? input) => input);
    Dwi.registerTask('slowWorker', (Object? input) async {
      await Future<void>.delayed(
        Duration(milliseconds: input! as int),
      );
      return 'slow';
    });
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  test('Dwi.run keeps working before and after a handle exists', () async {
    expect(await Dwi.run<String>('echoWorker', 'before'), 'before');
    final worker = await DwiWorker.spawn();
    try {
      expect(await Dwi.run<String>('echoWorker', 'during'), 'during');
      expect(await worker.run<int>('counter', null), 1);
      expect(await Dwi.run<String>('echoWorker', 'still'), 'still');
    } finally {
      await worker.close();
    }
    // The pool still runs new work after the dedicated context is closed.
    expect(await Dwi.run<String>('echoWorker', 'after'), 'after');
  });

  test('repeated calls on one handle retain worker-local state', () async {
    final worker = await DwiWorker.spawn();
    try {
      expect(worker.isUsable, isTrue);
      expect(worker.state, DwiWorkerState.ready);
      expect(await worker.run<int>('counter', null), 1);
      expect(await worker.run<int>('counter', null), 2);
      expect(await worker.run<int>('counter', null), 3);
    } finally {
      await worker.close();
    }
  });

  test('separate handles have separate state', () async {
    final first = await DwiWorker.spawn();
    final second = await DwiWorker.spawn();
    try {
      expect(await first.run<int>('counter', null), 1);
      expect(await first.run<int>('counter', null), 2);
      expect(await second.run<int>('counter', null), 1);
    } finally {
      await first.close();
      await second.close();
    }
  });

  test('runCancellable reuses the DwiCancellableTask contract', () async {
    final worker = await DwiWorker.spawn();
    try {
      final running = worker.run<String>('slowWorker', 100);
      final queued = worker.runCancellable<int>('counter', null);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await queued.cancel(), isTrue);
      await expectLater(queued.result, throwsA(isA<DwiCancelledException>()));
      expect(worker.state, DwiWorkerState.ready);
      expect(await running, 'slow');

      final done = worker.runCancellable<int>('counter', null);
      expect(await done.result, 1);
      expect(await done.cancel(), isFalse);
    } finally {
      await worker.close();
    }
  });

  test('run after close throws a typed error', () async {
    final worker = await DwiWorker.spawn();
    await worker.close();
    await worker.close();
    expect(worker.state, DwiWorkerState.closed);
    expect(worker.isUsable, isFalse);
    await expectLater(
      worker.run<int>('counter', null),
      throwsA(isA<DwiWorkerClosedException>()),
    );
  });

  test('Dwi.close closes live handles', () async {
    final worker = await DwiWorker.spawn();
    expect(await worker.run<int>('counter', null), 1);
    await Dwi.close();
    expect(worker.state, DwiWorkerState.closed);
    await expectLater(
      worker.run<int>('counter', null),
      throwsA(isA<DwiWorkerClosedException>()),
    );
    await Dwi.configure(const DwiConfig());
  });

  test('restart replaces state after a failure', () async {
    await Dwi.configure(
      const DwiConfig(taskTimeout: Duration(milliseconds: 50)),
    );
    final worker = await DwiWorker.spawn();
    try {
      await expectLater(
        worker.run<String>('slowWorker', 5000),
        throwsA(isA<DwiTimeoutException>()),
      );
      expect(worker.state, DwiWorkerState.failed);
      await expectLater(
        worker.run<int>('counter', null),
        throwsA(isA<DwiWorkerFailedException>()),
      );

      await worker.restart();
      expect(worker.state, DwiWorkerState.ready);
      expect(await worker.run<int>('counter', null), 1);
    } finally {
      await worker.close();
      await Dwi.configure(const DwiConfig());
    }
  });
}
