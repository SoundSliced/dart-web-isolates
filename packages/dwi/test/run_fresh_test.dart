import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

var counter = 0;

void main() {
  setUpAll(() async {
    Dwi.registerTask('counter', (Object? input) => ++counter);
    Dwi.registerTask('echo', (Object? input) => input);
    Dwi.registerTask('boom', (Object? input) => throw StateError('boom'));
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  test('each runFresh call starts from fresh worker-local state', () async {
    expect(await Dwi.runFresh<int>('counter', null), 1);
    expect(await Dwi.runFresh<int>('counter', null), 1);
  });

  test('a scoped handle still retains state, unlike runFresh', () async {
    final values = await DwiWorker.using((worker) async {
      return <int>[
        await worker.run<int>('counter', null),
        await worker.run<int>('counter', null),
      ];
    });
    expect(values, <int>[1, 2]);
  });

  test('concurrent runFresh calls never share a context', () async {
    final results = await Future.wait(<Future<int>>[
      Dwi.runFresh<int>('counter', null),
      Dwi.runFresh<int>('counter', null),
      Dwi.runFresh<int>('counter', null),
    ]);
    expect(results, <int>[1, 1, 1]);
  });

  test('runFresh returns a typed result and echoes payloads', () async {
    expect(await Dwi.runFresh<int>('echo', 7), 7);
    expect(
      await Dwi.runFresh<List<Object?>>('echo', <Object?>[1, 'two']),
      <Object?>[1, 'two'],
    );
  });

  test('runFresh rejects a mismatched result type', () async {
    await expectLater(
      Dwi.runFresh<String>('echo', 7),
      throwsA(isA<DwiResultTypeException>()),
    );
  });

  test('runFresh surfaces typed task failures without retrying', () async {
    await expectLater(
      Dwi.runFresh<void>('boom', null),
      throwsA(isA<DwiRemoteException>()),
    );
    await expectLater(
      Dwi.runFresh<void>('does-not-exist', null),
      throwsA(isA<DwiUnknownTaskException>()),
    );
    // The backend is still healthy after both failures.
    expect(await Dwi.runFresh<int>('counter', null), 1);
  });

  test('runFresh recreates the backend after Dwi.close()', () async {
    await Dwi.close();
    // `Dwi.close()` forgets the backend; the next call creates one again and
    // still gets a fresh context. Spawn-failure propagation itself is covered
    // by the injected-open cases in worker_scope_test.dart.
    expect(await Dwi.runFresh<int>('counter', null), 1);
    await Dwi.configure(const DwiConfig());
  });
}
