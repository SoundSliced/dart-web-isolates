# Architecture

Decision record for DWI. Each ADR states the decision, the evidence behind it,
and what it forbids. Evidence references point at `research/R00x` reports, which
in turn cite source files and measurements.

Status: accepted for v0.1–v0.5; M001 gate applied (PASS WITH LIMITATIONS).

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
- **Fresh-project ordering is not guaranteed (re-measured 2026-11-05 on
  Flutter 3.47.6 stable / Dart 3.13.5; first measured 2026-11-04).** Flutter
  schedules `build_hooks` and `dart2js` as independent web targets: `Dart2WebTarget.dependencies` is only
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
  fallback. See `audit/evidence/flutter-fresh-build-gate-2026-11-04.txt` and
  `audit/evidence/flutter-fresh-build-gate-2026-11-05.txt`; the committed
  reproduction is `tooling/proxy_gate`.
- A hook failure fails the Flutter build; this is intentional and preserves the
  "no main-thread fallback" rule.
- The resolver is conservative: zero or multiple matching app packages means
  "skip", not "guess".

**Evidence.** `audit/evidence/flutter-web-hook-2026-11-03.txt` and
`audit/evidence/flutter-fresh-build-ordering-2026-11-04.txt`; probe logs
`hook-build-cli.log`, `hook-build-inc1.log`, `hook-build-lib.log`,
`hook-build-real.log` (scratch, reproduced by the commands in the audit report).
Unit tests for the resolver: `packages/dwi_builder/test/hook_support_test.dart`.

**Amendment — worker replacement during development (2026-11-05, v0.5).**
Re-measured on Flutter 3.47.6 / Dart 3.13.5 with `flutter run -d chrome`
(debug), driving the real keys through a pty, with a task returning `v1` then
`v2` and every result reported to a local collector. A hot reload (`r`) rebuilt
`web/dwi/worker.dart.js` (sha256 `c5e7f5f5…` → `1b01033e…`) while the live page
kept reporting `v1` for all 12 samples over the next 8 seconds; a hot restart
(`R`) then reported `v2` from the same rebuilt artefact. `flutter run -d
web-server` serves and runs the app, but without the Dart Debug Chrome extension
the reload command never completed, so that mode's reload behaviour is
unverified here.

**Decision.** v0.5 does **not** replace a running worker automatically. After a
task edit the developer must hot restart (`R`) or reload the page; a hot reload
is not sufficient. The page owns its workers, so replacement is a page-level
operation; and silently swapping the context would have to settle live handles
and pending calls and start with fresh state (ADR-013), which would look like a
successful reload while losing work. Automatic replacement is deferred
post-0.5; any future design must state which handles are replaced, what pending
and queued calls receive, that work is never replayed, and that no state
survives replacement. Evidence:
`audit/evidence/flutter-worker-replacement-2026-11-05.txt`.

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
created ──spawn──▶ starting ──ready──▶ ready ──close──▶ closing ──▶ closed
                   │                 │
                   └──▶ failed ◀─────┘
                          │
                    restart()
                          ▼
                       starting
```

| Transition | Trigger | Queued calls | In-flight call |
| --- | --- | --- | --- |
| `created → starting` | `spawn()` / `restart()` | n/a (calls rejected) | n/a |
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
`dwi_native` VM tests, `dwi` facade tests, and the handle matrix in Chrome,
Safari, Firefox and Edge (three page loads per engine).

## ADR-014 — DWI-3: port-like channels over one handle (ACCEPTED)

**Status.** Accepted for implementation after v0.5 (2026-11-05). This ADR is
additive: `DwiWorker.run`, `runCancellable`, `restart`, `close` and `Dwi.run`
keep their contracts. DWI-3 is **not** `SendPort`/`ReceivePort` parity, and this
ADR does not claim any.

**Public surface (host side).**

```dart
final worker = await DwiWorker.spawn();
final channel = await worker.openChannel('progress');
channel.messages.listen((Object? message) { ... });
await channel.send(<String, Object?>{'step': 1});
await channel.sendBytes(DwiTransferableBytes(bytes)); // one-way transfer
await channel.close();
```

**Public surface (worker side, importable by task libraries).**

```dart
final channel = DwiWorkerChannels.find('progress');
if (channel != null) {
  await channel.send('half-way');
  channel.messages.listen((Object? message) { ... });
}
```

**Decision 1 — Attachment.** Channels attach to the existing `DwiWorker`; they
are not a separate handle and never create a context. One handle still owns
exactly one isolate or worker (ADR-013 decision 1). Opening a channel costs one
handshake, not a worker, and does not count against `maxWorkers`.

**Decision 2 — Creation and naming.** `openChannel(name)` is asynchronous and
resolves after the worker confirms the channel. A name is non-empty, at most 64
UTF-16 units, and contains no control characters. One live channel per name per
handle; a duplicate name throws `DwiChannelStateException`. Opening on a handle
that is not `ready` throws the ADR-013 state error. A name may be reopened after
its channel closes; the new channel has no buffered history.

**Decision 3 — Ordering.** Delivery is FIFO per channel and per direction:
messages sent on one channel arrive in send order. There is **no** ordering
guarantee across channels, or between channel messages and task calls; the
transport is ordered, but the API promises per-channel order only.

**Decision 4 — Subscription.** `messages` is a single-subscription stream. A
second `listen` throws `StateError`. Broadcast is not supported: it would
require per-listener buffers and make backpressure ambiguous.

**Decision 5 — Backpressure and bounds.** `DwiConfig.channelBufferSize`
(default 64) is the bound per channel and per direction. The receiver buffers up
to the bound and delays acknowledgements when full. `send` completes only when
the peer has enqueued the message. At most `channelBufferSize` sends may be
unacknowledged on one channel; a further send throws
`DwiChannelBufferException` *before* sending. Messages are never dropped,
coalesced or reordered. A consumer that stops reading therefore causes further
sends to be rejected instead of growing memory without bound.

**Decision 6 — Serialization and ownership.** Every message is validated like a
task payload on web and must be structured-cloneable on native. `send` copies;
`sendBytes` transfers `DwiTransferableBytes` under ADR-010 §10.2: the sender is
marked detached only after the transport accepted the message, and a failure
after acceptance means the bytes belong to the failed context and are gone.
Each message is independently owned; no message shares mutable state.

**Decision 7 — Failure and close.** A peer `close()` closes the stream normally
(`onDone`) and settles pending sends. A worker crash, task timeout, heartbeat
failure, malformed message, running cancellation, or `DwiWorker.close()` errors
every channel's stream with the same typed error
(`DwiWorkerFailedException`, `DwiTimeoutException`, `DwiCancelledException` or
`DwiWorkerClosedException`), completes every pending send with that error, and
rejects later sends. A malformed channel message fails the handle (ADR-013
decision 5) because the transport is no longer trustworthy. Channels have no
timeout of their own: pending sends settle on failure or close and are never
silently dropped; a caller that needs a deadline applies its own.

**Decision 8 — Restart and lifetime.** Channels do not survive `restart()`. A
restarted handle has no channels; reopening a name starts empty. `close()` on
the handle settles channels before terminating the context. No channel outlives
its handle.

**Decision 9 — Native and web mapping.** Native: messages travel over the
handle's persistent isolate `ReceivePort` as
`['channelOpen', name]`, `['channelOpened', name, ok, error]`,
`['channelMessage', name, seq, payload]`, `['channelAck', name, seq]`,
`['channelClose', name]`, `['channelClosed', name]`. Web: protocol envelopes with
the same names and `meta.channel` / `meta.seq`. No `Worker`, `MessagePort`,
`Isolate` or `SendPort` type appears in the public API (AGENTS.md rule 9).

**Decision 10 — Protocol version.** Protocol v2 adds the six channel types and
advertises `ready.meta.capabilities = {protocolVersion: 2, channels: true}`. A
v1 worker is rejected with `DwiUnsupportedException` when a channel is opened,
and `Dwi.run` requires v2 as well. Migration is to rebuild the worker artefact
(`dwi build`); a stale artefact fails loudly instead of silently lacking
channels.

**Decision 11 — Unsupported `dart:isolate` semantics.** Not provided: port
objects (`SendPort`/`ReceivePort`), transferring a port to another isolate or
worker, broadcast subscriptions, shared memory, reusing transferred bytes,
synchronous send, ordering across channels, selective receive, pause/resume,
and channels that cross handles or survive a restart. Channels are logical,
single-handle, single-subscriber message queues.

**State machine.**

```text
opening ──ack──▶ open ──close──▶ closing ──▶ closed
   │               │
   └──error──▶ handler error: stream errors, pending sends settle, channel closed
```

| Transition | Trigger | Pending sends | Stream |
| --- | --- | --- | --- |
| `opening → open` | worker acknowledges | queued on the channel | accepts one listener |
| `open → closing` | `close()` either side | settle as acknowledged or with the close reason | `onDone` after close |
| any → closed | handle failure / handle close | complete with the typed error | error, then closed |

**Implementation plan (separate commits).** Protocol v2; core channel types,
worker-side registry and `DwiConfig.channelBufferSize`; native handle and isolate
runtime; web handle, dispatcher and runtime; the `DwiWorker.openChannel` facade;
tests; documentation. Every stream and pending send must settle or close on
worker failure and explicit shutdown, with no unbounded buffering and no leaked
listeners.

**Testing.** Native: normal flow, per-channel FIFO, a slow consumer hitting the
buffer bound, crash, running cancellation, close, restart, transfer and worker
close. Dispatcher VM tests for channel envelopes and malformed input. Browser:
the same scenarios through the four-engine handle harness (Chrome, Safari,
Firefox and Edge measured).

**Implementation status.** Implemented for native and web JS under protocol v2.
Covered by `dwi_core` endpoint tests, `dwi_native` VM tests, `dwi_web` dispatcher
tests, and the browser handle matrix (Chrome, Safari, Firefox and Edge pass three
page loads each). A v1 worker artefact is rejected, so existing
projects must rebuild their worker (`dwi build`).

## ADR-015 — Scoped worker lifetime helper (ACCEPTED)

**Status.** Accepted for implementation (2026-11-08). This ADR is additive:
`DwiWorker.spawn`, `run`, `runCancellable`, `restart`, `close`, `openChannel`
and `Dwi.run` keep their ADR-013/ADR-014 contracts. The helper is implemented in
the public facade; no backend or protocol change is allowed under this ADR.

**Problem.** Every existing handle example repeats the same ownership
boilerplate: spawn, `try`, work, close in `finally`. Forgetting the `finally`
leaks a dedicated isolate or Web Worker until page teardown. A scoped helper
removes that boilerplate without changing what a handle promises.

**Public surface.**

```dart
final values = await DwiWorker.using((worker) async {
  final first = await worker.run<int>('counter');
  final second = await worker.run<int>('counter');
  return (first, second); // (1, 2): worker-local state persists in the scope
});
```

```dart
abstract final class DwiWorker {
  static Future<R> using<R>(FutureOr<R> Function(DwiWorker worker) body);
}
```

`using` spawns exactly one handle, passes it to `body`, awaits `body`'s
`FutureOr<R>` result, and closes the handle it created on every path. The
helper is sugar over `spawn()` + `try`/`finally`; it adds no new execution
model and no new error type.

**Decision 1 — Ownership.** The helper owns the handle it creates. Callers that
need to own a handle themselves keep using `spawn()` and `close()`. Ownership
does not transfer to the callback: the callback receives a live handle for the
duration of the scope only. A handle retained past the scope rejects calls with
`DwiWorkerClosedException`, exactly like any closed handle.

**Decision 2 — Spawn failure.** If spawning fails before a handle exists, the
callback never runs, no `close()` is attempted, and the spawn error propagates
unchanged (`DwiUnsupportedException`, `DwiStartupException`, or another
`DwiException`). There is no main-thread fallback and no synthetic result.

**Decision 3 — Scope end and unawaited work.** The scope ends when the
callback's future completes; that future is always awaited. The helper does not
enumerate, track, or wait for individual calls, sends, or channels started
inside the callback. On scope exit `close()` cancels queued and running calls,
settles them with `DwiWorkerClosedException`, and fails open channels — so
unawaited work is *not* safe and may be cancelled. Callers must await every
operation whose result they need. The helper never implies a graceful drain;
ADR-013 has no drain variant and none is added here.

**Decision 4 — Error precedence.** Cleanup must not be able to hide the
callback's failure, and a cleanup failure must not disappear:

| Callback | `close()` | The helper's future |
| --- | --- | --- |
| returns `value` | succeeds | completes with `value` |
| returns `value` | throws | completes with the close error |
| throws `E` with stack `S` | succeeds | completes with `E`, original stack `S` |
| throws `E` with stack `S` | throws `C` | completes with `E`, original stack `S`; `C` is reported to `Zone.current.handleUncaughtError(C, stack)` |

The last row is the only place the two errors collide. The original callback
error and stack are preserved (rethrown with `Error.throwWithStackTrace`), and
the cleanup error is delivered to the current zone so `runZonedGuarded`, a test
harness, or `FlutterError` observes it instead of losing it. It is never
silently swallowed and never replaces the callback error. Shipped backends
implement `close()` without awaiting anything that can fail, so a throwing
`close()` is a backend-contract violation; the rule exists so that violation is
visible rather than mistaken for success.

**Decision 5 — The callback closes the handle itself.** Permitted. `close()` is
idempotent (ADR-013 Decision 4), so the helper's close is a no-op and the scope
still ends normally. Calls made after the callback closed the handle throw
`DwiWorkerClosedException`. The helper does not treat an early close as an
error.

**Decision 6 — Cancellation, failure, restart, channels.** Cancelling a queued
call keeps the context; cancelling a running call fails the handle (ADR-013
Decision 7). A failed handle is still closed by the helper (`failed → closing →
closed`). `restart()` inside the callback is allowed and replaces the context;
the helper closes the replacement. Channels opened inside the scope are failed
with `DwiWorkerClosedException` at scope exit if they are still open; callers
that need a clean channel termination call `channel.close()` before returning.
None of these need special handling from the helper beyond the guarantee that
`close()` runs exactly once.

**Decision 7 — Generic typing.** `body` returns `FutureOr<R>`, so synchronous
and asynchronous callbacks are both accepted. `R` is inferred from the callback
and may be `void`; `Future<void> using<void>(...)` is a valid, common call. The
returned `Future<R>` completes with the callback's value, not a wrapper type.
There is no `Future<void>` overload and no callback-returned status object.

**Decision 8 — No `onError` or `onFinally` in this release.** An `onError`
callback could only observe errors the returned future already carries, and an
`onFinally` could not do work that the callback body, a `finally` inside the
callback, or the guaranteed `close()` cannot. Cleanup failures have their own
rule (Decision 4). Adding either requires a concrete consumer case and a new
ADR; neither is part of this surface.

**Decision 9 — No implicit close anywhere else.** `DwiWorker.run`,
`runCancellable`, channel `send`/`sendBytes`, and `Dwi.run` do not own a handle
and do not close anything. `DwiWorker.using` is the only scoped close in the
API. `Dwi.close()` retains its ADR-013 responsibility for live handles.

**Forbids.** Making a successful callback look like a failed one; converting
typed exceptions into success-shaped status objects; promising that unawaited
work completes before scope exit; suppressing the callback error to report a
cleanup error; retrying a task after a failure; adding a drain variant.

**Implementation status.** Implemented in `packages/dwi` (facade only) for
native and web JS. Not published: consumers receive it only in a future release.
Covered by `packages/dwi/test/worker_scope_test.dart`.

**Testing.** Successful callback with several calls and retained state; typed
and `void` return; synchronous callback; task failure and callback failure;
spawn failure (callback not entered); callback closing the handle itself;
timeout during the callback; channels opened within the scope; close exactly
once and no live handle after exit; callback error plus cleanup error.

## ADR-016 — DWI-4 increment 1: fresh-context one-shot execution (`Dwi.runFresh`)

**Status.** Accepted for implementation (2026-11-08). This ADR defines one
narrow DWI-4 increment selected in `research/R014_DWI4_SCOPE.md`. It is additive:
`Dwi.run`, `DwiWorker`, channels, errors and transferables are unchanged. The
increment is **not** `dart:isolate` parity and does not add closure execution
(DWI-5) or a Wasm worker.

**Problem.** `Dwi.run` is a pool. On native it starts a fresh isolate per call
(`native_backend.dart:122`), which matches `Isolate.run`'s fresh-context
guarantee. On web it acquires an idle pooled worker and releases it afterwards
(`web_backend.dart:341-352`), so worker-local state can persist between calls.
Measured with the published 0.5.3 packages: two sequential
`Dwi.run<int>('tick', 0)` calls in Chromium 156 returned `1` then `2`, proving
the second call reused the first call's worker. That is a real cross-platform
semantic difference and a gap against `Isolate.run`.

**Public surface.**

```dart
final value = await Dwi.runFresh<int>('primes', 5000000);
```

```dart
abstract final class Dwi {
  static Future<R> runFresh<R>(String task, [Object? input]);
}
```

**Decision 1 — One call, one fresh context.** `runFresh` spawns a dedicated
handle through the existing backend, runs exactly one task on it, and closes it
before completing the returned future. No worker or isolate is reused, so no
worker-local state enters or leaves the call, and two calls never share a
context. This holds on native and web alike.

**Decision 2 — Composition, not a second implementation.** `runFresh` is
`DwiWorker.using((worker) => worker.run<R>(task, input))`. It therefore inherits
ADR-015's cleanup guarantee and error precedence and needs no backend or
protocol change. `Dwi.run` keeps its pooled semantics; it is not redefined.

**Decision 3 — Typing and errors.** The result is checked against `R` exactly as
`Dwi.run` and `DwiWorker.run` do (`DwiResultTypeException` on mismatch). A
spawn failure propagates unchanged (`DwiUnsupportedException`,
`DwiStartupException`); a task failure propagates its typed error
(`DwiRemoteException`, `DwiUnknownTaskException`, `DwiTimeoutException`,
`DwiSerializationException`, or a handle-state error). There is no fallback and
no retry. Failure paths are identical to running one call on a scoped handle.

**Decision 4 — Cost is explicit.** Startup is paid per call: a fresh isolate on
native and a fresh Web Worker (7–60 ms measured, R003 §7) on web. `Dwi.runFresh`
is for callers who need `Isolate.run`-style isolation from pooled state; it is
not a performance improvement and not a replacement for the pool.

**Decision 5 — What this does not close.** Entry selection is still by task name,
so `Dwi.runFresh` is not `Isolate.run(fn)`. Ports, graceful exit with a message,
closure execution, `onExit`/`onError` streams, and Wasm workers remain open; each
needs its own ADR and evidence.

**Forbids.** Reusing a pooled worker in `runFresh`; adding state-clearing hooks
to `Dwi.run`; claiming `dart:isolate` parity; documenting `runFresh` as faster.

**Implementation status.** Implemented in `packages/dwi` (facade only) for native
and web JS. Not published. Acceptance tests: VM tests in
`packages/dwi/test/run_fresh_test.dart`, and the browser harness case in
`packages/dwi_builder/test/browser_handle_test.dart` (`runFresh` returns `1,1`
while pooled `Dwi.run` returns `1,2` in Chrome, Safari, Firefox and Edge, three
page loads per engine).

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
