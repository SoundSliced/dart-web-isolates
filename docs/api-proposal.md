# API Proposal (v0.5 target)

Status: v0.2 surface shipped; v0.3 surface shipped with ADR-008; v0.4 additions
shipped with ADR-010; the v0.5 handle surface is implemented under ADR-013. The
DWI-3 channel surface is implemented under ADR-014. Public API changes require this document plus an ADR (AGENTS.md
rule 2). Implemented surface must not exceed what is written here.

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

### Fresh-context one-shot call (DWI-4 increment 1, ADR-016)

`Dwi.run` is a pool. On web a call may reuse a pooled worker, so worker-local
state can persist across calls; on native each call starts a fresh isolate. When
a call must start from a clean context, use:

```dart
final count = await Dwi.runFresh<int>('primes', 5000000);
```

- `runFresh` spawns one dedicated handle, runs exactly one task, and closes the
  handle before completing. No state enters or leaves the call and two calls
  never share a context on either backend.
- It is `DwiWorker.using((worker) => worker.run<R>(task, input))`: the same typed
  results and typed failures, including `DwiResultTypeException` on a type
  mismatch and an unchanged spawn error (`DwiUnsupportedException`,
  `DwiStartupException`). Nothing is retried.
- Startup is paid per call (a fresh isolate or Web Worker), so this is for
  isolation from pooled state, not for speed. `Dwi.run` keeps its pooled
  semantics.
- The task is still selected by name: `runFresh` is **not** `Isolate.run(fn)`
  and does not promise `dart:isolate` parity. See `research/R014_DWI4_SCOPE.md`.

### Handle termination observation (DWI-4 increment 2, ADR-017)

Implemented under ADR-017. The contract is observation only: typed call,
channel and startup errors are unchanged, and no second error channel exists.

```dart
enum DwiWorkerStop {
  callerClosed,
  crashed,
  timedOut,
  cancelled,
  protocolViolation,
}

abstract interface class DwiWorker {
  DwiWorkerStop? get stopReason;   // latest terminal reason, null while active
  Stream<DwiWorkerStop> get stops; // broadcast, one per terminal transition
}

final worker = await DwiWorker.spawn();
final stops = worker.stops.listen((reason) => log('stopped: $reason'));
// ... later, including after an idle crash:
final reason = worker.stopReason; // null while the context is healthy
await stops.cancel();
await worker.close();
```

- Reports why a context stopped, including an idle crash that no call observed.
  `stopReason` becomes readable when the terminal transition starts, before
  affected calls and channels settle.
- Only a transition to `failed` or to a final `closed` emits. A queued-call
  timeout, a full queue, an unknown task, and a task-level remote error keep the
  context and emit nothing.
- The first terminal cause wins; a later `close()` on a failed handle does not
  overwrite it or emit again. Reason mapping (and every backend failure path)
  is defined in ADR-017 Decision 10.
- `restart()` clears `stopReason` when the replacement starts. `stops` stays
  open and the next terminal transition emits once. If the replacement cannot
  start, `restart()` throws `DwiStartupException`, `stopReason` stays `null`,
  and nothing is emitted (a failed startup is not a running context stopping).
- `stops` is broadcast, never carries an error, has no replay, and closes only
  on a final `close()` — including one performed by `Dwi.close()` — after the
  last event. A late subscriber reads `stopReason`.
- A listener that throws cannot interrupt cleanup, change `stopReason`, or
  change another caller's result.
- This is not `dart:isolate` `onExit`/`onError` parity: DWI's timeout,
  cancellation and restart generation have no `dart:isolate` equivalent.

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

## Level 2 — channels (DWI-3, ADR-014)

Channels carry progress updates, multiple results and long-lived request/reply
conversations over one existing handle. They are **not** `SendPort`/
`ReceivePort` parity and the API must not be described as such.

```dart
final worker = await DwiWorker.spawn();

final progress = await worker.openChannel('progress');
progress.messages.listen((Object? message) {
  // progress updates, partial results, replies
});
await progress.send(<String, Object?>{'step': 1});
await progress.sendBytes(DwiTransferableBytes(bytes)); // one-way transfer
await progress.close();
```

Task code inside the worker uses the same channel by name:

```dart
import 'package:dwi_core/dwi_worker.dart';

final channel = DwiWorkerChannels.find('progress');
if (channel != null) {
  await channel.send('half-way');
  channel.messages.listen((Object? message) { ... });
}
```

Rules:

- `openChannel(name)` resolves after the worker acknowledges the channel. Names
  are non-empty, at most 64 UTF-16 units, without control characters. One live
  channel per name per handle; a duplicate live name throws
  `DwiChannelStateException`. Opening on a non-`ready` handle throws the
  ADR-013 state error. A name may be reopened after its channel closes.
- `messages` is a single-subscription stream; a second `listen` throws
  `StateError`. There is no broadcast mode.
- Delivery is FIFO per channel and per direction. No ordering is promised across
  channels, or between channel messages and task calls.
- `send`/`sendBytes` complete when the peer has enqueued the message. At most
  `DwiConfig.channelBufferSize` (default 64) sends may be outstanding per
  channel; a further send throws `DwiChannelBufferException` before sending.
  Messages are never dropped, coalesced or reordered.
- `send` copies its message; `sendBytes` transfers `DwiTransferableBytes`
  exactly once (ADR-010 §10.2). A failed context loses the transferred bytes.
- A peer `close()` ends the stream normally. A worker crash, task timeout,
  running cancellation, malformed message, or handle `close()` errors the
  stream, settles every pending send with the same typed error, and rejects
  later sends.
- Channels never survive `restart()`; a restarted handle has no channels and a
  reopened name starts empty.
- Protocol v2 is required. A v1 worker artefact is rejected with
  `DwiUnsupportedException`; rebuild it with `dwi build`.

Not supported: port objects, transferring a port, broadcast, shared memory,
synchronous send, cross-channel ordering, selective receive, pause/resume, and
channels across handles or restarts.

## Configuration

```dart
Dwi.configure(const DwiConfig(
  workerScript: 'dwi/worker.dart.js',
  maxWorkers: 4,
  taskTimeout: Duration(seconds: 30),
  startupTimeout: Duration(seconds: 10),
  channelBufferSize: 64,
));
```

- `channelBufferSize` bounds outstanding sends per channel per direction
  (ADR-014). Its receiver-side buffer is the same size; no message is dropped.

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
  static Future<R> using<R>(FutureOr<R> Function(DwiWorker worker) body);

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

### Scoped lifetime helper (ADR-015)

`DwiWorker.using` is the supported way to own a handle for one block of work:

```dart
final values = await DwiWorker.using((worker) async {
  final first = await worker.run<int>('counter');
  final second = await worker.run<int>('counter');
  return (first, second); // (1, 2)
});

await DwiWorker.using<void>((worker) async {
  await worker.run('counter', null);
});
```

- The helper spawns the handle, awaits the callback's `FutureOr<R>`, and closes
  the handle on every path. It adds no new error type and no new execution
  model.
- If spawning fails, the callback never runs, no `close()` is attempted, and
  the spawn error propagates unchanged.
- The helper does **not** track or wait for calls, sends, or channels started
  inside the callback. Unawaited work may be cancelled by the guaranteed
  `close()` and settle with `DwiWorkerClosedException`. Callers must await work
  they need; there is no implicit drain.
- Error precedence: a callback failure is rethrown unchanged (same object). If
  `close()` also fails, the callback error still wins and the cleanup failure is
  appended to its stack trace, so it is observable without being swallowed, and
  without an uncaught zone error. If the callback succeeded, a close failure is
  the scope's error.
- Closing the handle inside the callback is allowed; the helper's second close
  is a no-op because `close()` is idempotent. Channels left open are failed at
  scope exit.
- `onError`/`onFinally` callbacks are deliberately not part of the surface
  (ADR-015 Decision 8). `DwiWorker.run`, `Dwi.run`, cancellable calls and
  channel sends never close a handle implicitly.

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
