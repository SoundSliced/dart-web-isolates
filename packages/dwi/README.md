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

## Basic example: pooled calls and a dedicated worker

This program uses native task registration. Browser apps use the generated
`DwiTasks` proxies shown above instead.

```dart
import 'package:dwi/dwi.dart';

Future<void> main() async {
  Dwi.registerTask('sum', (input) {
    final limit = input! as int;
    var total = 0;
    for (var i = 1; i <= limit; i++) {
      total += i;
    }
    return total;
  });

  // One call, borrowing a worker from the shared pool.
  final pooled = await Dwi.run<int>('sum', 100);
  print('pooled: $pooled');

  // A dedicated worker keeps its own context between calls.
  final worker = await DwiWorker.spawn();
  try {
    final first = await worker.run<int>('sum', 10);
    final second = await worker.run<int>('sum', 20);
    print('dedicated: $first then $second');
  } finally {
    await worker.close();
  }

  // Releases the pool. Safe to call when nothing is running.
  await Dwi.close();
}
```

## Advanced features

The snippets below come from the advanced example. They use native task
registration, so the worker-side helpers are defined in the same file.
The full program is linked at the end of this section.

### Pool configuration

Configure the pool before the first call. `maxWorkers` bounds concurrency,
`metrics` enables `Dwi.metrics()`, and `cancelGracePeriod` sets how long a
running task may stop after a cancel request.

```dart
await Dwi.configure(
  const DwiConfig(
    maxWorkers: 2,
    metrics: true,
    cancelGracePeriod: Duration(seconds: 1),
  ),
);
```

### Fresh calls, dispatch control and streams

`Dwi.pause` holds dispatch so a call can be queued before work starts.
`Dwi.runFresh` runs in a new context with no state from earlier calls.
`Dwi.runStream` consumes a stream task.

```dart
Dwi.pause();
final call = Dwi.run<int>('double', 21);
Dwi.resume();
print(await call); // 42
print(await Dwi.runFresh<int>('double', 10)); // 20
print(await Dwi.runStream('countStream', 3).toList()); // [1, 2, 3]
```

Worker side, the stream task and the double task are registered by name:

```dart
int doubleInput(Object? input) => (input as int) * 2;

Future<Object?> countStream(Object? request) =>
    DwiStreamTask.serve(request, (input) async* {
      for (var value = 1; value <= (input as int); value++) {
        yield value;
      }
    });
```

### Transferable bytes

`DwiTransferableBytes` moves a byte buffer to the worker without copying it.
The sender's buffer is no longer usable after the transfer.

Worker side, the byte task reads the buffer it receives:

```dart
int byteCount(Object? input) => (input as DwiTransferableBytes).lengthInBytes;
```

Host side:

```dart
import 'dart:typed_data';

final bytes = DwiTransferableBytes(Uint8List.fromList([1, 2, 3]));
print('Transferred bytes: ${await Dwi.run<int>('byteCount', bytes)}'); // 3
```

### Cancelling a queued call

`Dwi.runCancellable` returns a handle with `result` and `cancel()`. Attach
the error handler to `result` before cancelling, as shown here.

Worker side, the task waits until the host cancels it:

```dart
Future<int> waitForCancel(Object? input) async {
  final token = DwiCancelToken.current;
  await token.whenCancelled;
  token.throwIfCancelled();
  return 0;
}
```

Host side:

```dart
Dwi.pause();
final pending = Dwi.runCancellable<int>('waitForCancel');
final observed = pending.result.then<void>(
  (_) => throw StateError('Expected cancellation'),
  onError: (Object error) {
    if (error is! DwiCancelledException) throw error;
    print('Cancelled queued call');
  },
);
await pending.cancel();
Dwi.resume();
await observed;
```

### Dedicated worker health and a named-port round trip

`DwiWorker.using` spawns a dedicated worker and closes it when the callback
ends. `ping` checks that the worker answers. `bindPort` attaches a
`workers`-scope port to that worker, so the worker can reach it by name.

```dart
final echo = Dwi.createPort('echo', scope: DwiPortScope.workers);

await DwiWorker.using((worker) async {
  print('Ping: ${await worker.ping()}');
  final binding = await worker.bindPort(echo);
  try {
    if (!await worker.run<bool>('listenForEcho', echo.name)) {
      throw StateError('The worker did not find the echo port');
    }
    final response = echo.messages.first;
    await echo.send('hello');
    print(await response); // echo: hello
  } finally {
    await binding.close();
    await binding.done;
  }
});
```

Worker side, look up the reserved channel `port:<name>` and reply on it:

```dart
bool listenForEcho(Object? input) {
  final channel = DwiWorkerChannels.find('port:${input as String}');
  if (channel == null) return false;
  channel.messages
      .asyncMap((message) => channel.send('echo: $message'))
      .listen(
        (_) {},
        onError: (Object error) => print('Echo channel closed with $error'),
      );
  return true;
}
```

### Host broadcast

A `hostOnly` port with `DwiPortListeners.broadcast` delivers each message to
every host listener. Look the port up again with `Dwi.port` to get a second
listener.

```dart
final local = Dwi.createPort(
  'status',
  scope: DwiPortScope.hostOnly,
  listeners: DwiPortListeners.broadcast,
);

final first = local.messages.first;
final second = Dwi.port('status')!.messages.first;
await local.send('starting worker');
print(await Future.wait([first, second])); // [starting worker, starting worker]
```

### Diagnostics and cleanup

`capabilities`, `poolState` and `metrics` report what the backend supports and
what the pool is doing. Close the ports you created, then close Dwi. Passing
`drain: true` waits for tracked pool work to finish.

```dart
print((await Dwi.capabilities()).toMap());
print(Dwi.poolState());
print(Dwi.metrics());

await echo.close();
await local.close();
await Dwi.close(drain: true);
```

The full program with all of these features is
[dwi_advanced.dart](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi/example/dwi_advanced.dart).

## Port rules

A `hostOnly` port delivers messages in the host. A `workers` port sends host
messages to its bindings and delivers worker replies to host listeners. Open
the port and bind it before sending. Subscribe before expecting a reply, and
await sends to respect backpressure. Close a binding to detach one worker and
close the port to end all its listeners and bindings.

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
| Route messages by name | Use `Dwi.createPort`, `Dwi.port` and `worker.bindPort`. See the named-port examples above. |
| Inspect backend and pool activity | Read `Dwi.capabilities()`, `Dwi.poolState()` and `Dwi.metrics()`. Enable metrics in `DwiConfig`. |
| Shut down | Use `Dwi.close(drain: true)` to drain tracked pool work and explicitly close dedicated workers and named ports when their owners are done. |
| Use a Wasm worker | Follow the [Wasm example](https://github.com/SoundSliced/dart-web-isolates/tree/main/examples/wasm_worker) for build target, runtime config, MIME types and CSP. Host and worker compilation targets are separate. |
| Run a typed batch in Flutter | See [dwi_flutter](https://pub.dev/packages/dwi_flutter). |

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
