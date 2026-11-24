# dwi_web

Run DWI work in dedicated browser workers compiled to JavaScript or Wasm.

Most apps should use [dwi](https://pub.dev/packages/dwi) for cross-platform
selection. To use this backend directly, add `dwi_web` and `dwi_core` to
a web host project. Declare and compile a task named `sum` following the
[dwi_builder](https://pub.dev/packages/dwi_builder) quick start. The example
expects a single integer input. Create `lib/tasks.dart` with:

```dart
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int sum(int n) => n * (n + 1) ~/ 2;
```

Copy the basic example into the host project as `lib/main.dart`. Run
`dart compile js -o web/main.dart.js lib/main.dart`, add
`<script defer src="main.dart.js"></script>` to `web/index.html`, and
serve the `web/` directory over HTTP. Open the browser console for the
result. Serve worker assets from the same origin.

The host can also use `dart compile wasm`. Choose the worker target
independently using `DwiWorkerBackend.wasm` and the matching generated entry
asset for a Wasm worker. Dedicated workers and transferable bytes work without
COOP/COEP on both worker targets. The default per-message estimated task
payload budget is 64 MiB and can be raised with `DwiConfig.maxPayloadBytes`.
See the [dwi guide](https://pub.dev/packages/dwi) for the Wasm loader and
deployment settings. The dispatcher and runtime exports serve custom worker
integration. The standard builder generates that wiring for the application.

## Basic example

Runs the `sum` task in a dedicated worker through the browser backend.


```dart
/// Runs a task in a dedicated Web Worker through the browser backend.
///
/// Compile the worker with `dwi_builder` first, serve the artefact at the path
/// configured by `workerScript`, and run this example with the Dart web
/// compiler. Application code usually uses `package:dwi`, which selects this
/// backend when compiled to JavaScript or Wasm.

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
```

## Advanced example

Pings a dedicated worker and calls it twice, so both calls reach the same
worker context.


```dart
import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_web/dwi_web.dart';

Future<void> main() async {
  final backend = WebBackend();
  try {
    await backend.configure(const DwiConfig());
    final worker = await backend.spawnHandle();
    try {
      print(await worker.ping());
      print(await worker.run('sum', 10));
      print(await worker.run('sum', 20));
    } finally {
      await worker.close();
    }
  } finally {
    await backend.close();
  }
}
```

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
