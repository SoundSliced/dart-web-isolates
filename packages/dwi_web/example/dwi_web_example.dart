/// Runs a task in a dedicated Web Worker through the browser backend.
///
/// Compile the worker with `dwi_builder` first, serve the artefact at the path
/// configured by `workerScript`, and run this example with the Dart web
/// compiler. Application code usually uses `package:dwi`, which selects this
/// backend when compiled to JavaScript or Wasm.
library;

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_web/dwi_web.dart';

Future<void> main() async {
  final backend = WebBackend();
  await backend.configure(
    const DwiConfig(
      workerScript: 'dwi/worker.dart.js',
      maxWorkers: 2,
      taskTimeout: Duration(seconds: 10),
    ),
  );

  try {
    // The task table lives in the generated worker, so the caller only names
    // the task and passes the input.
    final result = await backend.run('sum', 1000);
    print('sum(1000) = $result');

    final capabilities = await backend.capabilities();
    print(
      'backend: ${capabilities.backend.name}, '
      'workers: ${capabilities.workerCount}, '
      'transferables: ${capabilities.transferables}',
    );
  } finally {
    await backend.close();
  }
}
