import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';
import 'package:test/test.dart';

int countPrimes(int limit) {
  final sieve = List<bool>.filled(limit + 1, false);
  var count = 0;
  for (var i = 2; i <= limit; i++) {
    if (sieve[i]) continue;
    count++;
    for (var j = i * i; j <= limit; j += i) {
      sieve[j] = true;
    }
  }
  return count;
}

void main() {
  late DwiTaskRegistry registry;
  late NativeBackend backend;

  setUp(() {
    registry = DwiTaskRegistry()
      ..register('primes', (Object? input) {
        final args = input! as Map<Object?, Object?>;
        return countPrimes(args['limit']! as int);
      })
      ..register('slow', (Object? input) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return 'done';
      })
      ..register('boom', (Object? input) => throw StateError('boom'))
      ..register('spin', (Object? input) {
        // Synchronous CPU work: it cannot observe a message until it returns,
        // so only killing the isolate can stop it.
        final until = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(until)) {}
        return 'spun';
      });
    backend = NativeBackend(registry);
  });

  test('runs a registered task on an isolate', () async {
    await backend.configure(const DwiConfig());
    final result = await backend.run('primes', <String, Object?>{'limit': 1000});
    expect(result, 168);
  });

  test('throws DwiUnknownTaskException for an unregistered task', () {
    expect(
      () => backend.run('nope', null),
      throwsA(isA<DwiUnknownTaskException>()),
    );
  });

  test('throws DwiTimeoutException when the task outlives its budget',
      () async {
    await backend.configure(
      const DwiConfig(taskTimeout: Duration(milliseconds: 50)),
    );
    expect(
      () => backend.run('slow', null),
      throwsA(isA<DwiTimeoutException>()),
    );
  });

  test('delivers a typed remote error with the remote type and stack', () async {
    await backend.configure(const DwiConfig());
    await expectLater(
      backend.run('boom', null),
      throwsA(
        isA<DwiRemoteException>()
            .having((error) => error.remoteType, 'remoteType', 'StateError')
            .having((error) => error.message, 'message', contains('boom'))
            .having((error) => error.remoteStack, 'remoteStack', isNotEmpty),
      ),
    );
  });

  test('reports isolate capabilities', () async {
    final caps = await backend.capabilities();
    expect(caps.backend, DwiBackendKind.isolate);
    expect(caps.transferables, isTrue);
  });

  test('refuses work after close', () async {
    await backend.close();
    expect(
      () => backend.run('primes', <String, Object?>{'limit': 10}),
      throwsA(isA<DwiUnsupportedException>()),
    );
  });

  group('cancellation', () {
    test('reports running cancellation in capabilities', () async {
      final caps = await backend.capabilities();
      expect(caps.cancellation, DwiCancellation.running);
    });

    test('runCancellable returns a value like run', () async {
      await backend.configure(const DwiConfig());
      final task = backend.start('primes', <String, Object?>{'limit': 1000});
      expect(await task.result, 168);
      expect(task.isDone, isTrue);
      expect(await task.cancel(), isFalse);
    });

    test('cancels a running task by killing its isolate', () async {
      await backend.configure(const DwiConfig());
      final task = backend.start('spin', null);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final watch = Stopwatch()..start();
      expect(await task.cancel(), isTrue);
      await expectLater(
        task.result,
        throwsA(isA<DwiCancelledException>()),
      );
      // The isolate is killed, not abandoned: the caller is not waiting for the
      // five second loop to finish.
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });

    test('cancel after completion is a no-op returning false', () async {
      await backend.configure(const DwiConfig());
      final task = backend.start('primes', <String, Object?>{'limit': 10});
      expect(await task.result, 4);

      expect(await task.cancel(), isFalse);
      expect(await task.result, 4);
    });

    test('repeated cancellation reports true once and false afterwards',
        () async {
      await backend.configure(const DwiConfig());
      final task = backend.start('spin', null);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await task.cancel(), isTrue);
      expect(await task.cancel(), isFalse);
      await expectLater(
        task.result,
        throwsA(isA<DwiCancelledException>()),
      );
    });

    test('a timeout kills the isolate and later work still runs', () async {
      await backend.configure(
        const DwiConfig(taskTimeout: Duration(milliseconds: 100)),
      );
      final timedOut = backend.start('spin', null);
      await expectLater(
        timedOut.result,
        throwsA(isA<DwiTimeoutException>()),
      );
      expect(timedOut.isDone, isTrue);

      await backend.configure(const DwiConfig());
      expect(
        await backend.run('primes', <String, Object?>{'limit': 1000}),
        168,
      );
    });
  });
}
