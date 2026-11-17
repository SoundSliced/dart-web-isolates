# dwi

Run CPU-heavy Dart work off the UI thread with native isolates or dedicated browser workers. The worker-backed API is available in Dart and Flutter.

## Start with one task

For a Dart app, run `dart pub add dwi dwi_annotations` and
`dart pub add --dev dwi_builder`. Use `flutter pub add` in a Flutter app.
For automatic Flutter web builds, add `dwi_builder` as a regular dependency
on a Flutter toolchain that supports the build hook.

Create `lib/tasks.dart`:

```dart
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int sumTo(int n) => n * (n + 1) ~/ 2;
```

From the app root, run:

```sh
dart run dwi_builder:dwi build
```

Create `lib/main.dart`:

```dart
import 'package:dwi/dwi.dart';
import 'dwi_tasks.g.dart';

Future<void> main() async {
  try {
    print(await DwiTasks.sumTo(100)); // 5050
  } finally {
    await Dwi.close();
  }
}
```

Run `dart run lib/main.dart` on native Dart. For a browser app, compile the
host with `dart compile js -o web/main.dart.js lib/main.dart`, load that
script from your HTML, and serve `web/` over HTTP. Deploy the generated
`web/dwi/` directory with the same origin as the host. For Flutter web use
your normal Flutter run or build command after worker generation.

The pub.dev **Example** tab also includes a native quick start using
`Dwi.registerTask`. Manual host registration is native-only. Web callers
use the task table compiled into the worker.

## Choose an API by workload

| Workload | API and example |
| --- | --- |
| Run independent tasks | Use generated `DwiTasks` methods or `Dwi.run`. Configure pool size, limits and timeouts with `Dwi.configure` before dispatch. |
| Choose a registered function at runtime, pass records or enums, or return progress as a stream | Use `DwiFunctions.run` and generated stream proxies in the [automatic worker example](https://github.com/SoundSliced/dart-web-isolates/tree/main/examples/automatic_worker). Use `Dwi.runStream` for a task registered by name. |
| Start with fresh worker state | Call `Dwi.runFresh`. |
| Keep worker-owned state across calls | Use `DwiWorker.using` or pair `spawn` with `close`. See the [stateful worker](https://github.com/SoundSliced/dart-web-isolates/tree/main/examples/stateful_worker). |
| Cancel a task | Use `Dwi.runCancellable` or `worker.runCancellable`. Attach an error handler to `result` before cancelling. See [cooperative cancellation](https://github.com/SoundSliced/dart-web-isolates/tree/main/examples/cooperative_cancel) for the worker token and grace period. |
| Pause dispatch or check a dedicated worker | Use `Dwi.pause`, `Dwi.resume` and `worker.ping`. See [dispatch controls](https://github.com/SoundSliced/dart-web-isolates/tree/main/examples/dispatch_control). |
| Inspect shutdown or recover a dedicated worker | Read `state`, `isUsable`, `stopReason` and `stops`. See the [stop observer](https://github.com/SoundSliced/dart-web-isolates/tree/main/examples/stop_observer) for restart and stop handling. |
| Exchange messages with one worker or relay between two workers | Use `worker.openChannel` and `DwiWorker.link`. See the [worker link](https://github.com/SoundSliced/dart-web-isolates/tree/main/examples/worker_link). Use `sendBytes` with `DwiTransferableBytes` for transferable binary payloads. |
| Route messages by name | In 1.1, use `Dwi.createPort`, `Dwi.port` and `worker.bindPort`. See below. |
| Inspect backend and pool activity | Read `Dwi.capabilities()`, `Dwi.poolState()` and `Dwi.metrics()`. Enable metrics in `DwiConfig`. |
| Shut down | Use `Dwi.close(drain: true)` to drain tracked pool work and explicitly close dedicated workers and named ports when their owners are done. |
| Use a Wasm worker | Follow the [Wasm example](https://github.com/SoundSliced/dart-web-isolates/tree/main/examples/wasm_worker) for build target, runtime config, MIME types and CSP. Host and worker compilation targets are separate. |
| Run a typed batch in Flutter | See [dwi_flutter](https://pub.dev/packages/dwi_flutter). |

## Advanced example with named ports

Run `dart run example/dwi_advanced.dart` from the package checkout. It exercises
pool configuration, fresh calls, dedicated worker health, named-port
round trips, host broadcast, diagnostics and cleanup.

A `hostOnly` port delivers messages in the host. A `workers` port sends host
messages to its bindings and delivers worker replies to host listeners. Open
the port and bind it before sending. In worker task code, look up the
reserved channel with `DwiWorkerChannels.find('port:echo')` for a port
named `echo`. Subscribe before expecting a reply and await sends to respect
backpressure. Close a binding to detach one worker and close the port to
end all its listeners and bindings.

[Advanced source](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi/example/dwi_advanced.dart) ·
[API limits and platform differences](https://github.com/SoundSliced/dart-web-isolates/tree/main/docs/limitations.md)

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
