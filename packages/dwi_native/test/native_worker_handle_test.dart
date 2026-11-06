import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';
import 'package:test/test.dart';

void main() {
  late DwiTaskRegistry registry;
  var counter = 0;

  setUp(() {
    counter = 0;
    registry = DwiTaskRegistry()
      ..register('count', (Object? input) => ++counter)
      ..register('slow', (Object? input) async {
        await Future<void>.delayed(
          Duration(milliseconds: input! as int),
        );
        return 'slow';
      })
      ..register('spin', (Object? input) {
        final until = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(until)) {}
        return 'spun';
      })
      ..register('boom', (Object? input) => throw StateError('boom'))
      ..register('die', (Object? input) => Isolate.exit())
      ..register('unsendable', (Object? input) => ReceivePort())
      ..register('startEcho', (Object? input) {
        final channel = DwiWorkerChannels.find(input! as String);
        if (channel == null) return 'missing';
        channel.messages.listen(
          (message) => channel.send('echo:$message'),
          onError: (Object error, StackTrace stack) {},
        );
        return 'listening';
      })
      ..register('announce', (Object? input) {
        final channel = DwiWorkerChannels.find(input! as String);
        if (channel == null) return 'missing';
        channel.send('hello');
        return 'sent';
      })
      ..register('closeChannel', (Object? input) {
        final channel = DwiWorkerChannels.find(input! as String);
        channel?.close();
        return 'closed';
      })
      ..register('startBytesEcho', (Object? input) {
        final channel = DwiWorkerChannels.find(input! as String);
        if (channel == null) return 'missing';
        channel.messages.listen(
          (message) {
            if (message is DwiTransferableBytes) channel.sendBytes(message);
          },
          onError: (Object error, StackTrace stack) {},
        );
        return 'listening';
      })
      ..register('echoTransferable', (Object? input) => input)
      ..register('makeTransferable', (Object? input) {
        final length = input! as int;
        final data = Uint8List(length)..fillRange(0, length, 7);
        return DwiTransferableBytes(data);
      });
  });

  Future<NativeWorkerHandle> spawn([DwiConfig config = const DwiConfig()]) =>
      NativeWorkerHandle.spawn(registry, config);

  test('retains isolate-local state across successive calls', () async {
    final handle = await spawn();
    try {
      expect(handle.isUsable, isTrue);
      expect(await handle.run('count', null), 1);
      expect(await handle.run('count', null), 2);
      expect(await handle.run('count', null), 3);
    } finally {
      await handle.close();
    }
  });

  test('separate handles have separate state', () async {
    final first = await spawn();
    final second = await spawn();
    try {
      expect(await first.run('count', null), 1);
      expect(await first.run('count', null), 2);
      expect(await second.run('count', null), 1);
      expect(await first.run('count', null), 3);
    } finally {
      await first.close();
      await second.close();
    }
  });

  test('runs queued calls in FIFO order, one at a time', () async {
    final handle = await spawn();
    try {
      final first = handle.run('count', null);
      final second = handle.run('count', null);
      final third = handle.run('count', null);
      expect(await Future.wait(<Future<Object?>>[first, second, third]), <int>[
        1,
        2,
        3,
      ]);
    } finally {
      await handle.close();
    }
  });

  test('a full queue rejects new calls with a typed error', () async {
    final handle = await spawn(const DwiConfig(maxQueuedTasks: 1));
    try {
      final running = handle.run('slow', 300);
      final queued = handle.run('count', null);
      await expectLater(
        handle.run('count', null),
        throwsA(isA<DwiUnsupportedException>()),
      );
      expect(handle.state, DwiWorkerState.ready);
      expect(await running, 'slow');
      expect(await queued, 1);
    } finally {
      await handle.close();
    }
  });

  test('a queued call fails when its queue deadline passes', () async {
    final handle = await spawn(
      const DwiConfig(
        queueTimeout: Duration(milliseconds: 50),
        taskTimeout: Duration(seconds: 5),
      ),
    );
    try {
      final running = handle.run('slow', 300);
      final queued = handle.run('count', null);
      await expectLater(queued, throwsA(isA<DwiTimeoutException>()));
      // A queue deadline is caller-local: the context is still healthy.
      expect(handle.state, DwiWorkerState.ready);
      expect(await running, 'slow');
      expect(await handle.run('count', null), 1);
    } finally {
      await handle.close();
    }
  });

  test('a result that cannot cross the boundary fails only that call', () async {
    final handle = await spawn();
    try {
      await expectLater(
        handle.run('unsendable', null),
        throwsA(isA<DwiSerializationException>()),
      );
      expect(handle.state, DwiWorkerState.ready);
      expect(await handle.run('count', null), 1);
    } finally {
      await handle.close();
    }
  });

  test('unknown task fails only that call', () async {
    final handle = await spawn();
    try {
      await expectLater(
        handle.run('missing', null),
        throwsA(isA<DwiUnknownTaskException>()),
      );
      expect(handle.state, DwiWorkerState.ready);
      expect(await handle.run('count', null), 1);
    } finally {
      await handle.close();
    }
  });

  test('delivers a typed remote error with type and stack', () async {
    final handle = await spawn();
    try {
      await expectLater(
        handle.run('boom', null),
        throwsA(
          isA<DwiRemoteException>()
              .having((error) => error.remoteType, 'remoteType', 'StateError')
              .having((error) => error.message, 'message', contains('boom'))
              .having((error) => error.remoteStack, 'remoteStack', isNotEmpty),
        ),
      );
      expect(handle.state, DwiWorkerState.ready);
    } finally {
      await handle.close();
    }
  });

  test('an isolate crash settles the running and queued calls once', () async {
    final handle = await spawn();
    final crashed = handle.run('die', null);
    final queued = handle.run('count', null);

    final runningError = await crashed.then<Object?>(
      (value) => value,
      onError: (Object error) => error,
    );
    expect(runningError, isA<DwiWorkerFailedException>());
    await expectLater(queued, throwsA(isA<DwiWorkerFailedException>()));
    expect(handle.state, DwiWorkerState.failed);
    await handle.close();
  });

  test('close before the first call settles and rejects later work', () async {
    final handle = await spawn();
    await handle.close();
    expect(handle.state, DwiWorkerState.closed);
    await expectLater(
      handle.run('count', null),
      throwsA(isA<DwiWorkerClosedException>()),
    );
    // Idempotent.
    await handle.close();
    expect(handle.state, DwiWorkerState.closed);
  });

  test('close settles a queued call and the running call once', () async {
    final handle = await spawn();
    final running = handle.run('slow', 5000);
    final queued = handle.run('count', null);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await handle.close();
    await expectLater(running, throwsA(isA<DwiWorkerClosedException>()));
    await expectLater(queued, throwsA(isA<DwiWorkerClosedException>()));
    expect(handle.state, DwiWorkerState.closed);
  });

  test('close during a running CPU task does not wait for it', () async {
    final handle = await spawn();
    final running = handle.run('spin', null);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final watch = Stopwatch()..start();
    await handle.close();
    await expectLater(running, throwsA(isA<DwiWorkerClosedException>()));
    expect(watch.elapsedMilliseconds, lessThan(2000));
  });

  test('a task timeout fails the handle and settles queued callers', () async {
    final handle = await spawn(
      const DwiConfig(taskTimeout: Duration(milliseconds: 100)),
    );
    final timedOut = handle.run('spin', null);
    final queued = handle.run('count', null);

    await expectLater(timedOut, throwsA(isA<DwiTimeoutException>()));
    await expectLater(queued, throwsA(isA<DwiWorkerFailedException>()));
    expect(handle.state, DwiWorkerState.failed);
    await expectLater(
      handle.run('count', null),
      throwsA(isA<DwiWorkerFailedException>()),
    );
    await handle.close();
  });

  test('queued cancellation removes the call and keeps the handle', () async {
    final handle = await spawn();
    final running = handle.run('slow', 150);
    final queued = handle.start('count', null);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(await queued.cancel(), isTrue);
    await expectLater(queued.result, throwsA(isA<DwiCancelledException>()));
    expect(handle.state, DwiWorkerState.ready);
    expect(await running, 'slow');
    expect(await handle.run('count', null), 1);
    await handle.close();
  });

  test('running cancellation terminates the isolate and fails the handle',
      () async {
    final handle = await spawn();
    final task = handle.start('spin', null);
    final queued = handle.run('count', null);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final watch = Stopwatch()..start();
    expect(await task.cancel(), isTrue);
    await expectLater(task.result, throwsA(isA<DwiCancelledException>()));
    await expectLater(queued, throwsA(isA<DwiWorkerFailedException>()));
    expect(handle.state, DwiWorkerState.failed);
    expect(watch.elapsedMilliseconds, lessThan(2000));
    // Cancel after completion changes nothing.
    expect(await task.cancel(), isFalse);
    await handle.close();
  });

  test('cancel and completion race settles exactly once', () async {
    final handle = await spawn();
    final task = handle.start('count', null);
    final cancelled = await task.cancel();
    final settleWatch = Stopwatch()..start();
    try {
      expect(await task.result, 1);
      expect(cancelled, isFalse);
    } on DwiCancelledException {
      expect(cancelled, isTrue);
    }
    expect(settleWatch.elapsedMilliseconds, lessThan(2000));
    await handle.close();
  });

  test('transfers an argument and a result', () async {
    final handle = await spawn();
    try {
      final bytes = DwiTransferableBytes(
        Uint8List.fromList(<int>[1, 2, 3]),
      );
      final echoed = await handle.run('echoTransferable', bytes);
      expect(echoed, isA<DwiTransferableBytes>());
      expect((echoed! as DwiTransferableBytes).bytes, <int>[1, 2, 3]);
      expect(bytes.isDetached, isTrue);

      final made = await handle.run('makeTransferable', 4);
      expect((made! as DwiTransferableBytes).bytes, <int>[7, 7, 7, 7]);
    } finally {
      await handle.close();
    }
  });

  test('transfer that succeeds before a failure stays detached', () async {
    final handle = await spawn(
      const DwiConfig(taskTimeout: Duration(milliseconds: 100)),
    );
    final bytes = DwiTransferableBytes(Uint8List(8));
    final task = handle.run('spin', bytes);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await expectLater(task, throwsA(isA<DwiTimeoutException>()));
    expect(bytes.isDetached, isTrue);
    expect(() => bytes.bytes, throwsA(isA<DwiSerializationException>()));
    await handle.close();
  });

  test('restart replaces the context with fresh state', () async {
    final handle = await spawn();
    expect(await handle.run('count', null), 1);
    expect(await handle.run('count', null), 2);

    await expectLater(handle.run('die', null), throwsA(isA<DwiException>()));
    expect(handle.state, DwiWorkerState.failed);
    await handle.restart();
    expect(handle.state, DwiWorkerState.ready);
    expect(await handle.run('count', null), 1);
    await handle.close();
  });

  test('restart on a healthy handle is rejected', () async {
    final handle = await spawn();
    try {
      await expectLater(
        handle.restart(),
        throwsA(isA<DwiWorkerStateException>()),
      );
    } finally {
      await handle.close();
    }
    await expectLater(
      handle.restart(),
      throwsA(isA<DwiWorkerStateException>()),
    );
  });

  test('repeated spawn/close cycles leave no live handle behind', () async {
    for (var i = 0; i < 5; i++) {
      final handle = await spawn();
      expect(await handle.run('count', null), 1);
      await handle.close();
      expect(handle.state, DwiWorkerState.closed);
    }
  });

  test('backend close closes dedicated handles', () async {
    final backend = NativeBackend(registry);
    final handle = await backend.spawnHandle();
    expect(await handle.run('count', null), 1);
    await backend.close();
    expect(handle.state, DwiWorkerState.closed);
    await expectLater(
      handle.run('count', null),
      throwsA(isA<DwiWorkerClosedException>()),
    );
    await expectLater(
      backend.spawnHandle(),
      throwsA(isA<DwiUnsupportedException>()),
    );
  });

  test('opens a channel and exchanges messages in both directions', () async {
    final handle = await spawn();
    try {
      final channel = await handle.openChannel('chat');
      expect(channel.name, 'chat');
      expect(await handle.run('startEcho', 'chat'), 'listening');

      final received = <Object?>[];
      final subscription = channel.messages.listen(
        received.add,
        onError: (Object error, StackTrace stack) {},
      );
      await channel.send('ping');
      await _waitFor(() => received.contains('echo:ping'));
      expect(received, <Object?>['echo:ping']);

      expect(await handle.run('announce', 'chat'), 'sent');
      await _waitFor(() => received.contains('hello'));
      expect(received, <Object?>['echo:ping', 'hello']);

      await subscription.cancel();
    } finally {
      await handle.close();
    }
  });

  test('rejects a duplicate name and allows reopening after close', () async {
    final handle = await spawn();
    try {
      final channel = await handle.openChannel('chat');
      channel.messages.listen(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      );
      await expectLater(
        handle.openChannel('chat'),
        throwsA(isA<DwiChannelStateException>()),
      );
      await channel.close();
      final again = await handle.openChannel('chat');
      expect(again.name, 'chat');
      expect(await handle.run('startEcho', 'chat'), 'listening');
      await again.close();
    } finally {
      await handle.close();
    }
  });

  test('bounds the unacknowledged window and recovers after an ack', () async {
    final handle = await spawn(const DwiConfig(channelBufferSize: 1));
    try {
      final channel = await handle.openChannel('chat');
      final received = <Object?>[];
      channel.messages.listen(
        received.add,
        onError: (Object error, StackTrace stack) {},
      );

      await channel.send('a');
      await expectLater(
        channel.send('b'),
        throwsA(isA<DwiChannelBufferException>()),
      );

      expect(await handle.run('startEcho', 'chat'), 'listening');
      await _waitFor(() => received.contains('echo:a'));
      await channel.send('c');
    } finally {
      await handle.close();
    }
  });

  test('a worker-initiated channel close ends the stream normally', () async {
    final handle = await spawn();
    try {
      final channel = await handle.openChannel('chat');
      final done = Completer<void>();
      channel.messages.listen(
        (_) {},
        onError: (Object error, StackTrace stack) {},
        onDone: done.complete,
      );
      expect(await handle.run('closeChannel', 'chat'), 'closed');
      await done.future.timeout(const Duration(seconds: 5));
      await expectLater(
        channel.send('after'),
        throwsA(isA<DwiChannelClosedException>()),
      );
    } finally {
      await handle.close();
    }
  });

  test('a handle failure errors every open channel', () async {
    final handle = await spawn();
    final channel = await handle.openChannel('chat');
    Object? caught;
    final done = Completer<void>();
    channel.messages.listen(
      (_) {},
      onError: (Object error, StackTrace stack) {
        caught = error;
      },
      onDone: done.complete,
    );

    await expectLater(handle.run('die', null), throwsA(isA<DwiException>()));
    await done.future.timeout(const Duration(seconds: 5));
    expect(caught, isA<DwiWorkerFailedException>());
    expect(handle.state, DwiWorkerState.failed);
    await expectLater(
      channel.send('after'),
      throwsA(isA<DwiChannelClosedException>()),
    );
    await handle.close();
  });

  test('channels do not survive restart', () async {
    final handle = await spawn();
    final channel = await handle.openChannel('chat');
    channel.messages.listen(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    await expectLater(handle.run('die', null), throwsA(isA<DwiException>()));
    await handle.restart();
    await expectLater(
      channel.send('stale'),
      throwsA(isA<DwiChannelClosedException>()),
    );
    final fresh = await handle.openChannel('chat');
    expect(fresh.name, 'chat');
    await fresh.close();
    await handle.close();
  });

  test('handle close errors open channels with DwiWorkerClosedException',
      () async {
    final handle = await spawn();
    final channel = await handle.openChannel('chat');
    Object? caught;
    final done = Completer<void>();
    channel.messages.listen(
      (_) {},
      onError: (Object error, StackTrace stack) {
        caught = error;
      },
      onDone: done.complete,
    );
    await handle.close();
    await done.future.timeout(const Duration(seconds: 5));
    expect(caught, isA<DwiWorkerClosedException>());
  });

  test('transfers bytes over a channel', () async {
    final handle = await spawn();
    try {
      final channel = await handle.openChannel('bytes');
      expect(await handle.run('startBytesEcho', 'bytes'), 'listening');
      final received = <Object?>[];
      channel.messages.listen(
        received.add,
        onError: (Object error, StackTrace stack) {},
      );
      final bytes = DwiTransferableBytes(Uint8List.fromList(<int>[1, 2, 3]));
      await channel.sendBytes(bytes);
      expect(bytes.isDetached, isTrue);
      await _waitFor(() => received.isNotEmpty);
      final echoed = received.single! as DwiTransferableBytes;
      expect(echoed.bytes, <int>[1, 2, 3]);
    } finally {
      await handle.close();
    }
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not met within $timeout');
}
