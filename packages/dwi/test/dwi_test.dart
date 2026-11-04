import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

@DwiTask()
int annotatedExample(int value) => value + 1;

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
  setUpAll(() async {
    Dwi.registerTask('primes', (Object? input) {
      final args = input! as Map<Object?, Object?>;
      return countPrimes(args['limit']! as int);
    });
    Dwi.registerTask('echo', (Object? input) => input);
    Dwi.registerTask('boom', (Object? input) => throw StateError('boom'));
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  test('runs a named task and returns a typed result', () async {
    final count = await Dwi.run<int>('primes', <String, Object?>{
      'limit': 1000,
    });
    expect(count, 168);
  });

  test('echoes a structured value', () async {
    final value = await Dwi.run<List<Object?>>('echo', <Object?>[1, 'two']);
    expect(value, <Object?>[1, 'two']);
  });

  test('throws DwiResultTypeException on a type mismatch', () {
    expect(
      () => Dwi.run<String>('primes', <String, Object?>{'limit': 10}),
      throwsA(isA<DwiResultTypeException>()),
    );
  });

  test('throws DwiUnknownTaskException for an unregistered task', () {
    expect(
      () => Dwi.run<Object?>('does-not-exist', null),
      throwsA(isA<DwiUnknownTaskException>()),
    );
  });

  test('propagates a typed remote task failure', () async {
    await expectLater(
      Dwi.run<Object?>('boom', null),
      throwsA(
        isA<DwiRemoteException>()
            .having((error) => error.remoteType, 'remoteType', 'StateError')
            .having((error) => error.message, 'message', contains('boom')),
      ),
    );
  });

  test('reports isolate capabilities on the VM', () async {
    final caps = await Dwi.capabilities();
    expect(caps.backend, DwiBackendKind.isolate);
    expect(caps.cancellation, DwiCancellation.running);
  });

  test('runCancellable delivers a value and cannot cancel a finished task',
      () async {
    final task = Dwi.runCancellable<int>('primes', <String, Object?>{
      'limit': 1000,
    });
    expect(await task.result, 168);
    expect(task.isDone, isTrue);
    expect(await task.cancel(), isFalse);
  });

  test('runCancellable reports a type mismatch through result', () async {
    final task = Dwi.runCancellable<String>('primes', <String, Object?>{
      'limit': 10,
    });
    await expectLater(
      task.result,
      throwsA(isA<DwiResultTypeException>()),
    );
  });

  test('runCancellable keeps DwiUnknownTaskException typed', () async {
    final task = Dwi.runCancellable<Object?>('does-not-exist', null);
    await expectLater(
      task.result,
      throwsA(isA<DwiUnknownTaskException>()),
    );
    expect(await task.cancel(), isFalse);
  });

  test('re-exports the @DwiTask marker and typed task function', () {
    const marker = DwiTask(name: 'annotatedExample');
    expect(marker.name, 'annotatedExample');
    expect(annotatedExample(41), 42);

    final DwiTaskFunction task = (input) => input;
    Dwi.registerTask('typed', task);
    expect(Dwi.registry.contains('typed'), isTrue);
  });
}
