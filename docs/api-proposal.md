# API Proposal (v0.3 target)

Status: v0.2 surface shipped; v0.3 surface shipped with ADR-008. Public API
changes require this document plus an ADR (AGENTS.md rule 2). Implemented
surface must not exceed what is written here.

## Level 1 — named task

```dart
import 'package:dwi/dwi.dart';

final count = await Dwi.run<int>(
  'primes',
  {'limit': 5000000, 'rounds': 40},
);
```

Rules:

- `task` is a name registered in the worker (and, on native, in the isolate
  registry). Unknown names throw `DwiUnknownTaskException` **without** starting
  a worker.
- `input` must be a structured-cloneable value (see `serialization.md`).
  Unsupported values throw `DwiSerializationException` on the caller's side.
- The return value is the decoded result; type is checked by the caller. A
  mismatched `R` throws `DwiResultTypeException`.
- No closure overload exists. There is no `Dwi.run(fn)` in v0.3.

## Level 1.5 — annotated task and generated proxy (v0.3)

A public top-level function is annotated once:

```dart
// lib/tasks.dart
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int calculatePrimes(int limit) {
  // ...
}
```

Task libraries import `dwi_annotations`, not `package:dwi`, so the worker
dependency closure does not pull in the host facade. Application code may use
`package:dwi/dwi.dart` directly; it re-exports the same `DwiTask` annotation.

`dwi_builder` discovers annotated functions and emits `lib/dwi_tasks.g.dart`:

```dart
abstract final class DwiTasks {
  static Future<int> calculatePrimes(int input) {
    return Dwi.run<int>('calculatePrimes', input);
  }
}
```

The proxy is the supported zero-boilerplate call shape:

```dart
import 'package:dwi/dwi.dart';
import 'dwi_tasks.g.dart';

final count = await DwiTasks.calculatePrimes(5_000_000);
```

Rules:

- The function must be public, top-level, non-generic and take zero or one
  required positional parameter.
- The result may be `T`, `Future<T>`, `FutureOr<T>` or `void`.
- `@DwiTask(name: 'custom')` overrides the task name.
- Only a constant `name:` argument is accepted.
- Discovery uses the resolved AST. Unsupported signatures, duplicate names,
  non-worker-safe imports and non-transferable DOM/function types are reported
  as `DWI001`–`DWI010` diagnostics before compilation.
- Generated files are build output, not source: `.dwi/`,
  `lib/dwi_tasks.g.dart`, `web/dwi/`.

### Build tooling

```bash
dart run dwi_builder:dwi build
dart run dwi_builder:dwi generate
dart run dwi_builder:dwi check
dart run dwi_builder:dwi watch
dart run dwi_builder:dwi clean
```

`build` generates sources, compiles the worker with `dart compile js` and writes
the manifest. An unchanged content hash and a matching artefact digest reuse the
compiled artefact. `--flutter-build` runs `flutter build web` after the worker
step; arguments after `--` are forwarded. On Flutter 3.47+ a normal dependency
on `dwi_builder` installs a web build hook, so plain `flutter build web` and
`flutter run -d chrome` also generate and compile the worker (ADR-009). The
wrapper remains the supported path for older Flutter versions and plain Dart
web apps.

The generated worker imports `DwiWorkerRuntime` from
`package:dwi_web/dwi_worker.dart`. That runtime is generated-code API, not
application API.

## Configuration

```dart
Dwi.configure(const DwiConfig(
  workerScript: 'dwi/worker.dart.js',
  maxWorkers: 4,
  taskTimeout: Duration(seconds: 30),
  startupTimeout: Duration(seconds: 10),
));
```

- `workerScript` defaults to `dwi/worker.dart.js` on web, matching the builder
  output, and is ignored on native. Set it explicitly when the artefact is
  served from a different path. Set it to an empty string to force a startup
  error.
- Defaults: `maxWorkers = min(hardwareConcurrency - 1, 4)`, at least 1.
- Timeouts are mandatory: a worker that never becomes ready must fail
  (`DwiStartupException`), a task that never returns must fail
  (`DwiTimeoutException`), and the worker must be terminated.

## Capability query

```dart
final caps = await Dwi.capabilities();
// { backend: 'isolate' | 'worker' | 'unsupported',
//   transferables: bool, workerCount: int, protocolVersion: 1 }
```

`backend: 'unsupported'` is reported when no worker script is configured on web;
calls then throw `DwiUnsupportedException`. There is no transparent fallback to
the main thread.

## Errors

```dart
sealed class DwiException implements Exception {}

class DwiStartupException extends DwiException {}
class DwiTimeoutException extends DwiException {}
class DwiUnknownTaskException extends DwiException {}
class DwiSerializationException extends DwiException {}
class DwiResultTypeException extends DwiException {}
class DwiUnsupportedException extends DwiException {}
class DwiRemoteException extends DwiException {
  final String remoteType;      // best-effort Dart type name
  final String message;
  final String remoteStackTrace;
  final String? workerId;
  final int? taskId;
}
```

`DwiRemoteException` is thrown for failures inside the worker. Its
`remoteStackTrace` is whatever the worker runtime captured; it is never presented
as a local stack trace.

## v0.4 surface (ADR-010, accepted; implementation tracked per item)

Cancellation — **implemented** (`Dwi.runCancellable`):

```dart
final task = Dwi.runCancellable<int>('primes', 5_000_000);
final value = await task.result;        // Future<int>, settles exactly once
final cancelled = await task.cancel();  // Future<bool>, never throws
```

- `DwiCancellableTask<R>`: `Future<R> result`, `Future<bool> cancel()`,
  `bool get isDone`.
- `cancel()` on a queued task removes it from the queue and completes `result`
  with `DwiCancelledException`; on a running web task it terminates the worker
  and completes `result` with the same exception; after completion it returns
  `false` and changes nothing.
- `DwiCancelledException extends DwiException` is delivered through `result`
  only. `cancel()` itself never throws.
- Native parity requires replacing `Isolate.run` with a retained
  `Isolate.spawn` handle (ADR-010 §10.1). Until that is implemented, native
  cancellation must be documented as narrower, not as parity.

Transferable bytes — **implemented** (`Dwi.run` with `DwiTransferableBytes`):

```dart
await Dwi.run<DwiTransferableBytes>('hash', DwiTransferableBytes(payload));
```

- `DwiTransferableBytes(TypedData)` / `.fromBuffer(ByteBuffer)`,
  `lengthInBytes`, `isDetached`, `bytes`.
- Views that do not span their whole buffer are copied into exact-size bytes at
  construction; the transfer unit is exactly what the caller passed.
- After a successful send the wrapper is detached and a second send throws
  `DwiSerializationException`. Native detachment is DWI bookkeeping only.
- `DwiCapabilities.transferables` stays `false` on web until the path is
  verified end to end for arguments and results.

Capabilities and config:

```dart
caps.cancellation;   // 'queued' | 'running' | 'none'
DwiConfig(heartbeatInterval: Duration(seconds: 5), heartbeatMisses: 2);
```

Heartbeats ping **idle** workers only — implemented. A busy worker cannot answer
a ping while it runs synchronous CPU code; its work is bounded by `taskTimeout`
instead. A slot is dead after `heartbeatMisses` consecutive missed replies and is
replaced lazily, with startup retries bounded by three consecutive failures.

Until each item's "Implementation status" in ADR-010 says implemented, the
corresponding surface is a proposal and must not be documented as available.

## Long-lived worker handles (v0.5, ADR-013 implemented)

A handle owns one dedicated execution context for its whole lifetime. It is
separate from the `Dwi.run` pool and does not consume a `maxWorkers` slot.

```dart
final worker = await DwiWorker.spawn();
try {
  final first = await worker.run<int>('counter', null);
  final second = await worker.run<int>('counter', null);
  // first == 1, second == 2: worker-local state persists between calls.
} finally {
  await worker.close();
}
```

Public surface:

```dart
abstract final class DwiWorker {
  static Future<DwiWorker> spawn();

  DwiWorkerState get state;      // created | starting | ready | closing | closed | failed
  bool get isUsable;             // state == ready

  Future<R> run<R>(String task, [Object? input]);
  DwiCancellableTask<R> runCancellable<R>(String task, [Object? input]);

  Future<void> restart();        // only from failed; fresh context, fresh state
  Future<void> close();          // immediate, idempotent
}
```

Rules (normative, ADR-013):

- **One task at a time, FIFO.** Extra calls queue up to
  `DwiConfig.maxQueuedTasks`; a full queue throws
  `DwiUnsupportedException`, and waiting longer than `DwiConfig.queueTimeout`
  throws `DwiTimeoutException`.
- **Identity.** Repeated calls reach the same worker/isolate. `restart()` and a
  new `spawn()` start with fresh state; a lost state is never restored.
- **Close.** `close()` cancels queued and running calls with
  `DwiWorkerClosedException`, terminates the context once, and is idempotent.
  `Dwi.close()` closes every live handle.
- **Failure.** Timeout, crash, malformed message, heartbeat failure, or
  cancelling a running call moves the handle to `failed`. The in-flight call
  gets the specific error (`DwiTimeoutException`, `DwiCancelledException`,
  `DwiRemoteException`); queued calls get `DwiWorkerFailedException`. Recovery
  is explicit via `restart()` or a new `spawn()`, never an automatic retry.
- **Healthy errors.** A remote task exception, unknown task name, or
  serialization rejection fails only that call; the handle stays `ready`.
- **Cancellation.** Queued cancellation removes the call and keeps the context;
  running cancellation terminates the context and fails the handle.
- **Transferables.** ADR-010 §10.2 ownership is unchanged. A transfer that
  succeeds followed by a failure loses the bytes.

New public types (AGENTS.md rule 2, recorded here before implementation):

```dart
enum DwiWorkerState { created, starting, ready, closing, closed, failed }

abstract interface class DwiWorkerHandle { /* backend-facing contract */ }

class DwiWorkerClosedException extends DwiException {}  // call on a closed handle
class DwiWorkerFailedException extends DwiException {}  // call on a failed handle / queued call at failure
class DwiWorkerStateException extends DwiException {}   // call during starting/closing, or invalid restart()
```

`DwiBackend.spawnHandle()` creates a handle; it is backend API, not application
API. No `Worker`, `MessagePort`, `Isolate`, or `SendPort` type is exposed.

The earlier `DwiPool` sketch is **not** part of this release; `Dwi.run` remains
the pooled API.

## Native mapping

| DWI | Native backend |
| --- | --- |
| `Dwi.run(task, input)` | registry lookup → `Isolate.run(() => fn(input))` |
| `DwiTasks.foo(input)` | generated proxy → `Dwi.run` → registry |
| `Dwi.capabilities()` | `backend: 'isolate'`, `transferables: true` |
| errors | local exceptions; `DwiRemoteException` only if the isolate sends one |
| timeout | `Future.timeout` + isolate cannot be killed mid-run (documented) |

Native task registration is explicit:

```dart
Dwi.registerTask('primes', (Object? input) {
  final args = input! as Map<String, Object?>;
  return countPrimes(args['limit']! as int, args['rounds']! as int);
});
```

## Web mapping

| DWI | Web backend |
| --- | --- |
| `Dwi.run(task, input)` | pool acquire → protocol `request` → `result` |
| `DwiTasks.foo(input)` | generated proxy → `Dwi.run` |
| `Dwi.capabilities()` | worker count, transferables from feature detection |
| errors | `error` envelope → `DwiRemoteException` |
| timeout | terminate worker, `DwiTimeoutException` |

The web worker entrypoint is generated by `dwi_builder` in v0.3. The v0.2
manual entrypoint remains valid for advanced users but is no longer required.

## Non-goals for v0.3

- Closures or function values (`Dwi.run(fn)`, `Dwi.run(() { ... })`).
- `Dwi.runTask(expensiveFunction, input)` with a function tear-off.
- Runtime compilation of Dart in the browser.
- `SendPort`/`ReceivePort` emulation.
- Shared memory.
- Wasm backend.
- A Flutter `compute()` replacement.
- Hooking plain `flutter build web` without a supported Flutter build API.

Closures and function tear-offs require compiler cooperation (R013 §4.4–4.5);
runtime compilation is rejected for v0.x on evidence grounds.

## Public API changes in v0.3

- Added `dwi_annotations` with `@DwiTask({String? name})`; re-exported from
  `package:dwi/dwi.dart`.
- Renamed the `DwiTask` typedef to `DwiTaskFunction` to avoid a name collision
  with the annotation. `Dwi.registerTask` and `DwiTaskRegistry` use
  `DwiTaskFunction`.
- `DwiConfig.workerScript` now defaults to `DwiConfig.defaultWorkerScript`
  (`dwi/worker.dart.js`) instead of being null.
- Added `package:dwi_web/dwi_worker.dart` (`DwiWorkerRuntime`,
  `DwiWorkerDispatcher`, `DwiWorkerTask`) for generated workers.
- Added `dwi_builder` and its CLI; no application runtime dependency on it.

## Documentation requirement

Every exported declaration is dartdoc'd and has a runnable example in
`examples/` (AGENTS.md rule 14).
