import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

void main() {
  test('an explicit configuration wins over a generated artifact', () async {
    await Dwi.configure(const DwiConfig(workerScript: ''));
    // A conflicting generated artifact is ignored after explicit configuration.
    await Dwi.useGeneratedWorker(
      workerScript: 'dwi/worker.boot.mjs',
      workerBackend: DwiWorkerBackend.wasm,
    );
    await Dwi.useGeneratedWorker(
      workerScript: 'dwi/worker.dart.js',
      workerBackend: DwiWorkerBackend.js,
    );
  });

  tearDownAll(() => Dwi.close());
}
