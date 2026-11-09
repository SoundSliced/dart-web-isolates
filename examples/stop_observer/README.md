# Stop observer

Shows how to observe *why* a dedicated `DwiWorker` context stopped (ADR-017).
`stopReason` is `null` while the context is healthy, and `stops` is a broadcast
stream with one event per context generation. The event is delivered before the
stream closes on `close()`.

```bash
cd examples/stop_observer
dart pub get
dart run bin/main.dart
```

Expected output:

```text
before null
count  1
events [DwiWorkerStop.callerClosed]
after  DwiWorkerStop.callerClosed
```

## When to use it

Use `stops` when a long-lived handle backs a session and the application must
log or react to an idle crash, a running-call timeout, a cancellation, or a
protocol failure — not only when a call was in flight. Late observers read
`stopReason`; events are not replayed. A queued-call timeout or a remote task
error keeps the context and emits nothing.

`restart()` starts a new generation, clears `stopReason`, and leaves `stops`
open for the next terminal event. If the replacement cannot start, `restart()`
throws the startup error and no stop event is emitted.

This is not `Isolate.onExit`/`onError` parity: DWI's timeout, cancellation and
restart generation have no `dart:isolate` equivalent. On web the example uses
the generated worker artefact (`DwiConfig.workerScript`, default
`dwi/worker.dart.js`).
