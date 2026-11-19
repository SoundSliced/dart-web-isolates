import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

void main() {
  test('the same generated artifact may be applied repeatedly', () async {
    await Dwi.useGeneratedWorker(
      workerScript: 'dwi/worker.dart.js',
      workerBackend: DwiWorkerBackend.js,
    );
    await Dwi.useGeneratedWorker(
      workerScript: 'dwi/worker.dart.js',
      workerBackend: DwiWorkerBackend.js,
    );
  });

  test('a different generated artifact fails with a typed error', () async {
    await expectLater(
      Dwi.useGeneratedWorker(
        workerScript: 'other/worker.boot.mjs',
        workerBackend: DwiWorkerBackend.wasm,
      ),
      throwsA(isA<DwiUnsupportedException>()),
    );
    // The owning artifact is unchanged, so the first one is still accepted.
    await Dwi.useGeneratedWorker(
      workerScript: 'dwi/worker.dart.js',
      workerBackend: DwiWorkerBackend.js,
    );
  });

  test('concurrent first applications share one outcome', () async {
    final results = await Future.wait<Object?>(<Future<Object?>>[
      Dwi.useGeneratedWorker(
        workerScript: 'dwi/worker.dart.js',
        workerBackend: DwiWorkerBackend.js,
      ),
      Dwi.useGeneratedWorker(
        workerScript: 'dwi/worker.dart.js',
        workerBackend: DwiWorkerBackend.js,
      ),
    ]);
    expect(results, everyElement(isNull));
  });
}
