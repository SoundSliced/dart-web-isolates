# Architecture

Decision record for DWI. Each ADR states the decision, the evidence behind it,
and what it forbids. Evidence references point at `research/R00x` reports, which
in turn cite source files and measurements.

Status: accepted for v0.1 and v0.3; M001 gate applied (PASS WITH LIMITATIONS).

## ADR-001 — Package-first, worker-backed, no isolate parity claim

**Decision.** DWI ships as Dart packages that provide *worker-backed,
isolate-like concurrency*. It does not implement `dart:isolate`, does not pretend
to, and does not modify the Dart or Flutter SDK.

**Evidence.** Web `dart:isolate` is a deliberate stub (R002, R004, R005); the
VM model depends on isolate groups sharing a heap and copying object graphs
(R001), which browsers cannot provide; upstream discussion explicitly
contemplates a *restricted* model, not parity (R010).

**Forbids.** Public APIs described as “isolates” without a documented difference
table; any SDK patch attempt before the package proves value.

## ADR-002 — Tasks are named and precompiled; no closures cross the boundary

**Decision.** The unit of work is a **task name** plus a payload, resolved
against a dispatch table compiled into the worker. Function values and closures
are rejected with a typed error.

```dart
await Dwi.run<int>('primes', {'limit': 5000000, 'rounds': 40});
```

**Evidence.** A captured closure compiles to a JS object with fields; a tear-off
is a cached JS function registered by name; neither is cloneable across realms
(R004 §2). Structured clone throws `DataCloneError` for functions (R003 §3,
measured in Chrome).

**Forbids.** `Dwi.run(() => ...)` in any release before a compiler feature
exists. Compatibility level stays at DWI-1 until then.

## ADR-003 — Dedicated worker per handle, pooled by default later

**Decision.** A worker handle owns exactly one dedicated `Worker` and one task
queue. `Dwi.run` uses a small pool (default `min(hardwareConcurrency - 1, 4)`)
with lazy spawn; long-running handles are explicit.

**Evidence.** Worker startup measured 7–15 ms warm in the POC, 51–60 ms cold in
the capability harness; task dispatch is much cheaper than spawning (R003 §7,
M001). One worker per task would pay startup every time.

**Forbids.** Unbounded worker creation and unbounded queues; both must be
configurable with a defined default.

## ADR-004 — Versioned envelope protocol over structured clone

**Decision.** Every message is an object with at least
`{v, type, id, task, payload, meta}` (see `protocol.md`). Control messages and
payloads use structured-cloneable values only; binary payloads use transferables
where available.

**Evidence.** Structured clone's type universe and prototype loss (R003 §3);
VM `RemoteError`-style errors need an explicit envelope because browser error
events are insufficient (R001 §5, R003 §6).

**Forbids.** JSON-only encoding of arbitrary Dart objects; stringly-typed
dispatch without validation; protocol changes without a version bump.

## ADR-005 — One facade, two backends, conditional imports

**Decision.** `dwi` exposes one API. Native selects an isolate backend
(`Isolate.run`), web selects the worker backend; the choice is a conditional
import, not a runtime `kIsWeb` branch scattered through user code.

**Evidence.** Flutter's own `compute()` uses this mechanism
(`_isolates_io.dart` / `_isolates_web.dart`, R002 §1). A single API is the
project's core value proposition (§3 Objective B).

**Forbids.** Browser types in the public API (`package:web` stays inside
`dwi_web`); silent main-thread fallback when workers are unavailable.

## ADR-006 — Worker compilation is tooling, not a runtime trick

**Decision.** A worker entrypoint is a separate Dart program compiled with
`dart compile js` (later `dart compile wasm`) and served as a static artefact.
The build tool fails loudly on missing or stale artefacts; there is no fallback.

**Evidence.** `flutter build web` compiles one target and exposes no
extra-entrypoint hook (R002 §3–4); each `dart compile js` output is
self-contained (R004 §5); emitted Wasm needs `.wasm` + `.mjs` (R005 §1).

**Forbids.** Claiming “automatic” worker compilation before a build integration
exists; committing generated artefacts.

## ADR-007 — Preservation of isolate-style semantics, with documented gaps

**Decision.** Default semantics: no shared mutable state, explicit transfer of
ownership for binary data, abrupt kill, typed remote errors. Differences from
`dart:isolate` are enumerated in `compatibility-matrix.md`.

**Evidence.** VM isolation guarantees (R001 §2–4); browser realm isolation and
transferables (R003 §4–5).

**Forbids.** Shared-memory APIs on the default path; emulating pause/resume;
pretending a `SendPort` is a cloneable capability.

## ADR-008 — Automatic build-time worker generation and compilation (v0.3)

**Decision.** A task is declared by `@DwiTask()` on a public top-level function.
`dwi_builder` discovers it with the analyzer, emits a deterministic worker
entrypoint containing static references, emits typed caller proxies, writes a
manifest, and compiles the worker with `dart compile js`. A content hash of the
generated sources, the transitive dependency closure, the Dart compiler version
and the compiler options skips unchanged compilations. `DwiConfig.workerScript`
defaults to `dwi/worker.dart.js`, so no path configuration is required.

```dart
@DwiTask()
int calculatePrimes(int limit) { ... }

final count = await DwiTasks.calculatePrimes(5_000_000);
```

The build surface is `dart run dwi_builder:dwi build` (plus `generate`, `check`,
`watch`, `clean`, and `--flutter-build` to run Flutter after the worker step).
The generated worker imports `DwiWorkerRuntime` from `dwi_web`; protocol
handling lives in the pure-Dart `DwiWorkerDispatcher` and is unit-tested on the
VM.

**Evidence.** R013 compares manual, generated, build-hook, compiler-integrated
and runtime-compilation strategies. R007 establishes that a worker is a second
compilation. R004 §6 establishes that string-only task names are tree-shaken, so
the generated map uses static references. R002 §3–4 and local probes (`dart
build` exposes only `cli`; `dart compile` has no extra-entrypoint mode) show
there is no Flutter web build hook in this SDK. The v0.3 build test compiles a
generated worker with `dart compile js`, and the example runs it in Chrome.

**API change.** The `DwiTask` typedef in `dwi_core` is renamed
`DwiTaskFunction` so the public annotation can be named `DwiTask` without an
import collision. `package:dwi` re-exports the annotation for application code;
task libraries import `package:dwi_annotations/dwi_annotations.dart` to keep the
worker dependency closure free of the host facade.

**Forbids.** Manual worker creation as the only supported path; claiming that
plain `flutter build web` triggers worker generation; runtime compilation in the
browser; `Dwi.run(fn)` or closures before compiler support exists; source-text
regex discovery instead of the resolved AST; committing generated worker
artefacts; and treating the in-process build wrapper as a Flutter hook.

## ADR-009 — Automatic worker builds through Flutter web build hooks (v0.3.1)

**Status.** Accepted, supersedes the "no web build hook" conclusion in ADR-008
and R013 §4.3.

**Context.** ADR-008 shipped `dwi build` as a separate command because the
v0.3 research concluded that Flutter exposes no web build hook. That conclusion
is wrong for Flutter 3.47. Re-probing the installed SDK (3.47.6, engine
`b8c8d3d8d5d0`) shows:

- `flutter_tools` has `BuildHooks(platform: HookPlatform.web)`, wired into the
  web build graph (`build_system/targets/web.dart:604`); `HookPlatform` is
  explicitly `{native, web}` (`targets/native_assets.dart:31`).
- A `flutter build web --release -v` log contains
  `Running build hooks for web`, compiles `hook/build.dart` with the
  application's `.dart_tool/package_config.json`, and runs it in the web build.
  The hook is a **separate build target**: in the measured 3.47.6 build the
  hook and `dart2js` started concurrently, so the hook does **not** run before
  application compilation in a guaranteed order (see the fresh-build limitation
  below).
- `flutter run -d web-server` runs the same hooks in debug mode.
- A hook may call `Process.run` (observed: `dart --version`), read the package
  root, and write files (observed: a marker and a compiled worker).
- Only **regular dependencies** are scanned for `hook/build.dart`; a
  `dev_dependencies` hook did not run, and an app-root `hook/build.dart` did not
  run. A dependency hook can be given the app's package config path through
  `Platform.packageConfig` (confirmed in the log and at runtime).
- Flutter caches the hook and re-runs it only when its declared
  `output.dependencies` change. Observed: editing a task re-ran the hook and
  changed the worker hash; an unchanged build printed
  `Skipping target: build_hooks`.

**Decision.** `dwi_builder` ships `hook/build.dart`. An application opts in by
listing `dwi_builder` as a **normal dependency** (not `dev_dependencies`).
During `flutter run -d chrome` and `flutter build web`, the hook:

1. reads `Platform.packageConfig`;
2. finds the one package whose own `.dart_tool/package_config.json` is that
   config, whose `pubspec.yaml` depends on `dwi`, and which has
   `web/index.html` (`findDwiAppRoot` in `lib/src/hook_support.dart`);
3. runs the same `DwiBuilder` as the CLI (`compile: true`);
4. declares every task dependency and the app pubspec as hook dependencies so
   Flutter invalidates correctly.

The CLI (`dwi build`, `generate`, `check`, `watch`, `clean`,
`--flutter-build`) remains for older Flutter versions, non-Flutter Dart web
apps, CI checks and diagnostics. Generated files remain gitignored.

**Consequences and limitations.**

- Requires Flutter with web build hooks (measured on 3.47.6). Older Flutter
  falls back to the CLI; the hook is absent from those builds rather than
  silently skipping a needed step.
- `dwi_builder` becomes a normal dependency, so its `analyzer` dependency enters
  the app's package graph for the build. It is not linked into the app bundle.
- Hooks do not expose the target OS in `hooks` 2.2.0. The `web/index.html` guard
  limits work to web-capable apps, but a multi-platform app that also builds
  iOS/Android will pay a (cached) worker compile during those builds.
- Dart workspaces where the app has no own `.dart_tool/package_config.json`
  are not resolved yet; use the CLI there.
- The hook runs before app compilation and the page owns its workers, so it
  cannot hot-patch a worker already running in a page. Measured on 3.47.6 stable
  (`flutter run -d chrome`, debug): a hot reload does rebuild
  `web/dwi/worker.dart.js`, but the page keeps the old `Worker` and still runs
  the old code; a hot restart reloads the page and picks the new worker up.
  Reload or restart after a task change.
- **Fresh-project ordering is not guaranteed (re-measured 2026-11-04 on
  Flutter 3.47.6 stable / Dart 3.13.5).** Flutter schedules `build_hooks` and
  `dart2js` as independent web targets: `Dart2WebTarget.dependencies` is only
  `[WebEntrypointTarget, GenerateLocalizationsTarget]`, and the web
  `BuildHooks` target is a dependency of `LinkHooks`, which itself runs after
  the compile targets. On a project that has never generated
  `lib/dwi_tasks.g.dart`, the compiler can start before the hook writes the
  proxy; the first `flutter build web` then fails with "Error when reading
  'lib/dwi_tasks.g.dart'". The hook's output is valid and the next build
  succeeds, and the worker it produced is already packaged into `build/web` by
  the same build. The supported workflow is to generate the proxies once before
  the first Flutter build: `dart run dwi_builder:dwi build` (or
  `dwi build --flutter-build`), after which ordinary Flutter commands keep the
  worker fresh. A fresh project that calls `Dwi.run` directly and imports no
  generated proxy does build and run in a worker on a single ordinary command
  (measured at the root and under `/sub/app/`); typed `DwiTasks` proxies need
  the one pre-build step. The hook prints an explicit diagnostic when it
  creates proxies during a build. This is a Flutter build graph ordering gap,
  not a discovery or compilation failure; the CLI wrapper remains the supported
  fallback. See `audit/evidence/flutter-fresh-build-gate-2026-11-04.txt`.
- A hook failure fails the Flutter build; this is intentional and preserves the
  "no main-thread fallback" rule.
- The resolver is conservative: zero or multiple matching app packages means
  "skip", not "guess".

**Evidence.** `audit/evidence/flutter-web-hook-2026-11-03.txt` and
`audit/evidence/flutter-fresh-build-ordering-2026-11-04.txt`; probe logs
`hook-build-cli.log`, `hook-build-inc1.log`, `hook-build-lib.log`,
`hook-build-real.log` (scratch, reproduced by the commands in the audit report).
Unit tests for the resolver: `packages/dwi_builder/test/hook_support_test.dart`.

## ADR-010 — v0.4: cancellation, transferable bytes, crash detection (ACCEPTED)

**Status.** Accepted for v0.4 implementation (2026-11-04). This ADR supersedes
the earlier proposal in this section. It settles three design gaps *before* code:
cancellation, transferable bytes, and heartbeat/crash detection. Each decision
below is normative; the "Implementation status" line at the end of each part is
updated as code lands, and a part must not be reported as shipped before its
line says so.

`Dwi.run` keeps its current signature and semantics. Every addition is
additive, and every new type is a public API change recorded here and in
`docs/api-proposal.md` (AGENTS.md rule 2).

### 10.1 Cancellation

**Public surface.**

```dart
// package:dwi (implemented by each backend)
final task = Dwi.runCancellable<int>('primes', 5_000_000);
final value = await task.result;        // Future<int>, settles exactly once
final cancelled = await task.cancel();  // Future<bool>, never throws

// package:dwi_core, re-exported by package:dwi
class DwiCancelledException extends DwiException { ... }
```

`DwiCancellableTask<R>` exposes `Future<R> result`, `Future<bool> cancel()` and
`bool get isDone`. `cancel()` reports whether *this call* changed the outcome.

**State model.** A task is in exactly one of: `queued`, `running`, `done`.
Completion is decided by a single per-task completer; the first transition to
`done` wins (JavaScript is single-threaded, so the check and the termination
happen in one turn of the event loop).

**Web semantics.**

| Call made while… | Effect on `task.result` | `cancel()` returns | Worker |
| --- | --- | --- | --- |
| `queued` | completes with `DwiCancelledException` | `true` | none started |
| `running` | completes with `DwiCancelledException` | `true` | that slot is terminated |
| `done` (result/error already delivered) | unchanged | `false` | untouched |
| result envelope in flight, not yet delivered | unchanged, result wins | `false` | untouched |

Rules:

1. **Queued cancellation** removes the caller's waiter from the pool queue
   before any worker is acquired and completes `result` with
   `DwiCancelledException`. It decrements nothing else and does not disturb
   FIFO order for the remaining waiters.
2. **Running cancellation terminates the worker.** A synchronous Dart task
   cannot read a `cancel` envelope until it returns, so termination is the only
   reliable mechanism on the web. The protocol still carries a `cancel` message
   (protocol v1 already defines the type), but the host does not wait for it:
   it calls `Worker.terminate()` and settles the pending call immediately.
3. **Only `task.result` receives `DwiCancelledException`.** `cancel()` itself
   never throws for races or repeats; it returns `false`.
4. **Deterministic race rule.** If the result has already completed the
   completer when `cancel()` runs, the result stands and `cancel()` returns
   `false`. If cancel wins, the late `result`/`error` envelope is ignored
   (the completer is already settled) and must not become an unhandled error.
5. **Timeout race.** `taskTimeout` and `cancel()` both terminate the same slot.
   Whichever settles the completer first decides the outcome: a timeout yields
   `DwiTimeoutException` and a later `cancel()` returns `false`; a cancel yields
   `DwiCancelledException` and the timer is cancelled.
6. **Repeated cancellation** is a no-op returning `false` after the first
   successful cancel.
7. **Worker replacement.** A terminated slot is removed from the pool
   immediately and its capacity is offered to queued callers (the existing
   `_terminate` → `_drainWaiters` path). Replacement is lazy: the next request
   that needs capacity spawns a new worker. There is no eager respawn, and no
   request is retried on the caller's behalf.
8. **Not cooperative, and not advertised as cooperative.** A `cancel` envelope
   is advisory only; adding a cooperative token is a separate, later change and
   must not alter `DwiTaskFunction`. `DwiCapabilities` gains no
   `cooperativeCancellation` claim in v0.4.

**Native semantics.** Native cancellation is *not* the same mechanism and must
not be described as parity.

- `Isolate.run` keeps no handle, so it cannot be cancelled. v0.4 therefore
  replaces the native execution path with `Isolate.spawn` plus a retained
  `Isolate` handle and a `SendPort` for the result/error. `run()` keeps its
  observable behaviour (one isolate per call, typed errors, timeout).
- `cancel()` while the isolate has not started yet: the call is not started and
  `result` completes with `DwiCancelledException` (`true`).
- `cancel()` while running: `isolate.kill(priority: Isolate.immediate)` and
  `result` completes with `DwiCancelledException` (`true`). This is a real
  termination, not an abandoned future.
- `cancel()` after completion, repeated cancellation, and races follow the web
  rules above.
- If the spawn-based path is not implemented, native `cancel()` on a running
  task must return `false` and the documentation must say cancellation is
  queued-only on native. It must never silently pretend to cancel.

**Capability reporting.** `DwiCapabilities` gains `cancellation` with values
`queued`, `running`, or `none`, so callers can see the actual contract instead
of assuming parity.

**Implementation status.** Implemented in v0.4. `Dwi.runCancellable`,
`DwiCancellableTask` and `DwiCancelledException` are public; queued cancellation
removes a waiter, running cancellation terminates the worker on web and kills
the isolate on native, and both backends report `DwiCancellation.running`.
Covered by `dwi_core` unit tests, `dwi_native` VM tests, `dwi` facade tests and
the Chrome lifecycle test in `dwi_builder/test/browser_lifecycle_test.dart`.

### 10.2 Transferable bytes

**Public surface.**

```dart
// package:dwi_core, re-exported by package:dwi
class DwiTransferableBytes {
  DwiTransferableBytes(TypedData data);          // copies a view into exact bytes
  DwiTransferableBytes.fromBuffer(ByteBuffer b); // takes ownership of b
  int get lengthInBytes;
  bool get isDetached;                           // true after a successful send
  Uint8List get bytes;                           // throws once detached
}

await Dwi.run<DwiTransferableBytes>('hash', DwiTransferableBytes(payload));
```

**Wire representation.** A `DwiTransferableBytes` travels as the `ArrayBuffer`
(`ByteBuffer`) itself, with `meta['payloadKind'] = 'transferableBytes'`, and the
buffer is listed in the `postMessage` transfer list. The receiver wraps the
received buffer without copying. A task may return `DwiTransferableBytes`; the
worker runtime applies the same representation and transfer list on the result
path, so return values are transferred rather than copied.

**Rules.**

1. **Accepted inputs** are `TypedData` (all typed lists and `ByteData`) and
   `ByteBuffer`. `List<int>` and strings are not accepted; they are ordinary
   copied payloads.
2. **Views with offsets are copied at construction.** If the input view does not
   span its whole buffer (non-zero `offsetInBytes`, or `lengthInBytes` smaller
   than `buffer.lengthInBytes`), the constructor copies the referenced bytes into
   an exact-size buffer. The transfer unit is then exactly what the caller
   passed, and transferring it never detaches unrelated memory. This is stated
   in the dartdoc; it is the only copying the wrapper performs.
3. **Ownership and sender detachment.** After a successful send the sender's
   buffer is detached on the web (`byteLength == 0`) and `isDetached` becomes
   `true`. On native, `TransferableTypedData` does not detach the sender's
   memory, so `isDetached` is a DWI bookkeeping flag only: the wrapper refuses a
   second send, but the bytes remain readable through the wrapper's own
   reference. This difference is documented rather than hidden.
4. **Repeated transfer throws.** Sending an already-sent wrapper throws
   `DwiSerializationException` before `postMessage`; this is a caller bug, not a
   transport failure.
5. **Failure before send** (validation, unknown task, no capacity) leaves the
   wrapper usable and not detached.
6. **Failure after a successful transfer** (timeout, cancel, worker crash) means
   the bytes belong to the terminated worker and are gone. The caller must not
   reuse the wrapper; `isDetached` remains `true`. Retrying requires a fresh
   `DwiTransferableBytes`.
7. **Native semantics.** On native the wrapper maps to
   `TransferableTypedData.fromList([bytes])` on send and `materialize()` on
   receipt, so the payload is transferred rather than copied. Detachment is
   DWI-level only (rule 3).
8. **Capability reporting.** `DwiCapabilities.transferables` becomes `true` only
   when this path works end to end for both arguments and results. On web it
   stays `false` until browser tests cover send, return, offsets, repeated
   transfer and post-transfer failure. Native keeps `true`, because
   `TransferableTypedData` is a real transfer.

**Implementation status.** Implemented in v0.4. `DwiTransferableBytes` is public
and travels as the `ArrayBuffer` with a transfer list on web and
`TransferableTypedData` on native, for both arguments and results.
`DwiCapabilities.transferables` is `true` on both backends. Covered by
`dwi_core` wrapper tests, `dwi_native` VM tests, a builder type test, and the
Chrome lifecycle test (`echoBytes`, `makeBytes`, repeated send, post-detach
read).

### 10.3 Heartbeats and crash detection

**Worker states.** A slot is `starting` (spawned, no `ready` yet), `idle`
(ready, no in-flight request), `busy` (request in flight), or `dead`.

**Heartbeat policy.**

1. **Only idle slots are pinged.** A `busy` slot is executing a task that may be
   synchronous CPU code; it cannot process a ping until it returns, so treating a
   late reply as a crash would kill healthy long-running work. Busy work is
   already bounded by `taskTimeout`.
2. **Ping shape.** An idle slot receives a `heartbeat` envelope with a nonce in
   `meta['nonce']`; the worker answers with `heartbeat` echoing the nonce. Any
   other inbound message from that worker also proves liveness and resets the
   miss counter.
3. **A miss is a missing reply.** Each tick increments the slot's miss counter;
   a valid reply resets it to zero. `heartbeatMisses` consecutive misses mark the
   slot dead. Defaults: `heartbeatInterval` 5 s, `heartbeatMisses` 2 (both
   validated positive, configurable in `DwiConfig`).
4. **A dead idle slot has no in-flight call**, so it is terminated and removed
   without settling anything. Any *pending* work for that worker can only exist
   if the slot was busy, which is not pinged; those calls settle through
   `taskTimeout`, a cancel, or an `onerror`/`onmessageerror` failure.
5. **Failure detection is unchanged for busy slots**: `onerror`,
   `onmessageerror`, an undecodable message, and `taskTimeout` terminate the slot
   and settle every pending completer with a typed error.

**Bounded restart.**

- Replacement stays **lazy**: a dead slot is removed and capacity is offered to
  queued callers; the next request that needs capacity spawns a fresh worker.
- Restart attempts are bounded globally by `maxConsecutiveSpawnFailures` (3).
  A successful spawn resets the counter; the third consecutive startup failure
  fails every queued caller with `DwiStartupException` and stops retrying.
- No caller is retried automatically. A caller whose worker died settles with a
  typed error and decides for itself whether to call again.

**Queue and in-flight settlement.** Every pending call settles exactly once:

- queued callers after a death: remain queued against the replacement; they
  fail only through `queueTimeout`, a full queue, close, or the bounded startup
  failure above;
- in-flight callers at termination: `DwiCancelledException` (cancel),
  `DwiTimeoutException` (timeout), `DwiRemoteException` (protocol/decoding) or
  `DwiStartupException` (failed start);
- close: queued callers first, then every slot.

**Config additions.** `DwiConfig.heartbeatInterval` and
`DwiConfig.heartbeatMisses`; both must be positive.

**Implementation status.** Implemented in v0.4. `DwiConfig.heartbeatInterval`
(5 s) and `DwiConfig.heartbeatMisses` (2) are validated; idle slots are pinged,
a busy slot is never treated as a missed heartbeat, any inbound message resets
the miss count, and a dead idle slot is terminated and replaced lazily.
`onerror`, `onmessageerror`, timeout and bounded startup failure keep their
existing behaviour. Covered by a Chrome case where a worker closes its own
global scope after answering (`dieAfter`) and the next call succeeds without
waiting for a task timeout, plus a bounded-restart case with a missing script.

### 10.4 Acceptance criteria for v0.4

- Browser tests: cancel queued, cancel running, cancel after completion,
  cancel/timeout race, repeated cancel, pool recovery after termination,
  transfer with detach, views with offsets, returned buffers, repeated transfer
  rejection, post-transfer failure, idle-worker death detected by heartbeat,
  active-worker failure, startup failure, late messages, queue settlement, and
  sustained concurrency.
- Native tests: queued/not-yet-started cancel, running cancel via
  `Isolate.kill`, completion race, repeated cancel, and recovery after cancel.
- Benchmarks: transfer versus copy at several payload sizes, and cancellation
  latency, with environment details and repeated measurements.
- Browser results are per engine. An engine that was not run is **unverified**.

### 10.5 Not implemented by this ADR

Cooperative cancellation tokens, long-lived worker handles, port-like
messaging/streams, a dart2wasm worker path, and any parity claim with
`dart:isolate`.



## ADR-011 — Generated proxies own native dispatch and payload decoding (v0.3.1)

**Decision.** `dwi_builder` emits, into `lib/dwi_tasks.g.dart`, a private
registration function that registers every generated task with
`Dwi.registerTask` on first use, using the same statically referenced lambda as
the worker. It also emits type-directed decoders for input (worker side) and
result (proxy side). Types are captured from the analyzer's resolved element
model (library URI, name, type arguments, nullability), never from declaration
source text, and generated imports qualify names from non-`dart:core` libraries.

**Why.** Before this decision, a generated proxy called `Dwi.run` without a
registered native implementation (so the VM raised
`DwiUnknownTaskException`), and `Uint8List`/qualified/imported types produced
invalid generated source. On web, `jsify`/`dartify` erase collection element
types, so a decoded `List<dynamic>` cannot be returned as `List<int>` without an
explicit conversion. Registration is idempotent and guarded before it runs, so
concurrent first calls are deterministic; the registry survives `Dwi.close()`,
so a closed backend can be recreated and reused.

**Supported payload types.** `null`, `num`/`int`/`double`/`bool`/`String`,
`dynamic`/`Object?`, nullable forms, `List<T>`, `Set<T>`, `Map<String, V>` with
supported keys/values, and typed data (`Uint8List`, other typed lists,
`ByteData`, `ByteBuffer`). Custom classes, enums, records, functions, streams,
`DateTime` and non-String map keys remain build errors (`DWI001`). Decoding
validates every element and fails with `DwiSerializationException` naming the
path (`input[1]`, `result[0]`) instead of coercing.

**Forbids.** Relying on source-text type rendering, silently registering tasks
outside generated code, and changing the public `Dwi`/`DwiTaskFunction` API for
this feature (none was needed). Generated code is build output and must stay
deterministic.

## ADR-012 — Queue waiting has its own deadline (v0.3.1)

**Decision.** `DwiConfig` gains `queueTimeout` (default 30 s, must be positive).
A call waiting for pool capacity fails with `DwiTimeoutException` when it
exceeds that deadline; `taskTimeout` starts only once a worker is executing the
call. `startupTimeout` remains the bound for a worker's `ready` handshake.

**Why.** Before this decision a queued caller had no bound at all: if every
worker was stuck, the caller waited forever. The three delays have different
causes and different operators, so one combined deadline would either
mis-report a fast task behind a slow queue or let a queued call hang.

**Forbids.** An unbounded queue wait. `close()` settles queued and in-flight
requests immediately with `DwiUnsupportedException`; it is idempotent, and
repeated worker-startup failures are capped at three before remaining callers
receive the terminal startup error.

## ADR-013 — Long-lived worker handles (v0.5, ACCEPTED)

**Status.** Accepted for v0.5 implementation (2026-11-04). This ADR defines the
public contract and the lifecycle rules for one dedicated execution context per
caller. It is the design that ADR-003 left as "pooled by default later".

**Public surface.**

```dart
import 'package:dwi/dwi.dart';

final worker = await DwiWorker.spawn();
try {
  final first = await worker.run<int>('calculate', 10);
  final second = await worker.run<int>('calculate', 20);
} finally {
  await worker.close();
}
```

`DwiWorker.spawn()` takes no positional argument. On web the worker artefact is
`DwiConfig.workerScript` (default `dwi/worker.dart.js`); on native there is no
URL. The task table comes from the same sources as `Dwi.run`: the native
`DwiTaskRegistry` for the isolate, and the generated worker entrypoint's static
`Map<String, DwiWorkerTask>` for the Web Worker.

**Decision 1 — Ownership.** One `DwiWorker` owns exactly one dedicated
execution context for its whole lifetime. It never borrows a slot from the
`Dwi.run` pool, and `Dwi.run` never uses a dedicated handle. A handle is created
only by `spawn()` and released only by `close()` (or backend teardown). Creating
a handle does not count against `DwiConfig.maxWorkers`, which bounds the pool.

**Decision 2 — Identity and state.** Every call through a healthy handle reaches
the same isolate or worker. Task implementations may keep local state between
calls: a counter increments across calls, a parser cache stays warm. Two handles
have two contexts and never share mutable state. This is worker-local state, not
shared memory: payloads are still copied or transferred (ADR-010 §10.2).

**Decision 3 — Concurrency.** A handle runs **one task at a time**. Additional
calls are queued in FIFO order. The queue is bounded by
`DwiConfig.maxQueuedTasks` (default 64; a full queue fails with
`DwiUnsupportedException`, matching `Dwi.run`), and a queued call that waits
longer than `DwiConfig.queueTimeout` fails with `DwiTimeoutException`. Ordering
is enforced by the handle, not by the worker's message handler. Parallel calls
inside one context are not part of this release; a task that needs parallelism
creates more handles.

**Decision 4 — Close.** `close()` is immediate and idempotent. It cancels the
running call and every queued call, settles each with
`DwiWorkerClosedException`, terminates the context exactly once, and moves the
handle to `closed`. There is no graceful-drain variant in this release: a caller
that wants to finish current work awaits it before calling `close()`. Repeated
`close()` is a no-op. `Dwi.close()` closes every handle the backend owns before
releasing the pool, so page or application teardown cannot leak a dedicated
context.

**Decision 5 — Failure.** The following failures move a handle from `ready` to
`failed`: a task timeout (the call gets `DwiTimeoutException`), a worker
`error`/`messageerror`, an undecodable or malformed message, an isolate exit
that the handle did not cause, a heartbeat failure (web), and cancellation of a
running call (`DwiCancelledException`). Calls that were queued behind the failed
call settle with `DwiWorkerFailedException`; they are not retried. A remote task
exception, an unknown task name or a serialization rejection fails only that
call and leaves the handle `ready`, because the context is still healthy.

**Decision 6 — Replacement.** A failed handle stays failed. Recovery is
explicit: `restart()` (allowed only from `failed`) or a new `spawn()`. A restart
starts a fresh isolate/worker with fresh local state; it never replays a task,
and no caller's future is re-attached to the new context. `restart()` on any
state other than `failed` throws `DwiWorkerStateException`. Calls made while
`starting` or `closing` throw `DwiWorkerStateException`; calls on `closed` throw
`DwiWorkerClosedException`; calls on `failed` throw `DwiWorkerFailedException`.

**Decision 7 — Cancellation.** `DwiWorker.runCancellable` reuses
`DwiCancellableTask` unchanged. Cancelling a **queued** call removes it from the
handle's queue, leaves the context running, and settles the call with
`DwiCancelledException`. Cancelling a **running** call terminates the dedicated
context (native `Isolate.kill`, web `Worker.terminate`) because a synchronous
task cannot observe a cancel message; the call settles with
`DwiCancelledException` and the handle moves to `failed`. Cancelling after
settlement returns `false` and changes nothing.

**Decision 8 — Transferables.** Argument and result ownership follows ADR-010
§10.2 unchanged. The sender's wrapper is marked detached only after the
transport accepted the transfer. If the transfer succeeds and the context then
fails before replying, the bytes belong to the failed context and are gone; the
caller must create a new `DwiTransferableBytes`. DWI never retries a transfer.

**Decision 9 — Backend closure.** The backend keeps an explicit set of live
handles. `Dwi.close()` closes them before closing the pool. A handle closed by
the caller is removed from that set. No handle outlives its backend.

**Decision 10 — Native mapping.** One `Isolate.spawn` per handle with a
persistent receive loop. The registry snapshot and a reply `SendPort` are sent
at startup; the isolate creates its own `ReceivePort`, answers with its
`SendPort`, and dispatches requests by their registry names. Tasks registered
after `spawn()` are not visible to that handle. A per-task `Isolate.spawn` would
pay startup on every call and could not retain state, so it is not the mapping.

**Decision 11 — Capabilities.** Available on both supported backends (native and
web JS): spawn, persistent identity and state, one-at-a-time FIFO, close,
restart, cancellable calls, typed errors, transferable bytes. Not available:
parallel calls inside one handle, cooperative cancellation, ports/streams,
state surviving a restart, and any claim of `dart:isolate` parity. Web Wasm is
not implemented.

**State machine.**

```
new ──spawn──▶ starting ──ready──▶ ready ──close──▶ closing ──▶ closed
                   │                 │
                   └──▶ failed ◀─────┘
                          │
                    restart()
                          ▼
                       starting
```

| Transition | Trigger | Queued calls | In-flight call |
| --- | --- | --- | --- |
| `new → starting` | `spawn()` / `restart()` | n/a (calls rejected) | n/a |
| `starting → ready` | isolate started / `ready` envelope | run after ready only | n/a |
| `starting → failed` | startup timeout or spawn error | none exist | none exist |
| `ready → ready` | remote exception, unknown task, serialization rejection | unaffected | that call fails only |
| `ready → failed` | timeout, crash, malformed message, heartbeat, running cancel | `DwiWorkerFailedException` | timeout/cancel/remote error |
| `ready → closing` | `close()` | `DwiWorkerClosedException` | `DwiWorkerClosedException` |
| `failed → closing` | `close()` | already settled | already settled |
| `closing → closed` | context terminated | settled | settled |
| `closed → closed` | repeated `close()` | n/a | n/a |
| `failed → starting` | `restart()` | none (all settled) | none (all settled) |

**Forbids.** Making a pooled slot look dedicated; implicitly respawning or
retrying; implying state survived a restart; adding port-like messaging to the
handle API; exposing `Worker`, `MessagePort`, `Isolate` or `SendPort`.

**Implementation status.** Implemented in v0.5 for native and web JS. Covered by
`dwi_native` VM tests, `dwi` facade tests, and the browser integration harness
(Chrome; other engines unverified).

## Consequences

- The first release is deliberately narrow: named tasks, one worker pool, typed
  errors, JS backend only.
- Automatic discovery and generation are shipped for annotated top-level
  functions (ADR-008). Arbitrary function values and closures still need
  compiler cooperation and remain research items.
- Every performance claim must cite a benchmark, as M001 does.

## Critical review

Objections raised by the security reviewer and the skeptical-maintainer reviewer
are recorded verbatim in `critical-review.md`, including those that remain open.
