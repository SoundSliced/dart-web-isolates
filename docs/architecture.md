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
  `dev_dependencies` hook did not run. An app-root `hook/build.dart` **does**
  run when the app depends on `hooks` (re-measured 2026-11-10 on 3.47.6; the
  earlier "did not run" observation does not reproduce), but it is scheduled
  with the compiler rather than before it, so it cannot order generated sources
  before application compilation. A dependency hook can be given the app's
  package config path through `Platform.packageConfig` (confirmed in the log and
  at runtime).
- Flutter caches the hook against declared `output.dependencies`. Editing a
  task re-ran it and changed the worker hash. An unchanged build with existing
  dependencies can print `Skipping target: build_hooks`; a missing optional
  `dwi.yaml` is now declared as a dirty input so creating it is detected.

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

**Amendment — fresh-build ordering re-measured (2026-11-10, v0.8).** The gap
was re-measured on Flutter 3.47.6 / Dart 3.13.5 with a writable SDK copy, on
fresh apps, per mode:

| First command | Result |
| --- | --- |
| `flutter build web --release` (dart2js) | exit 1, missing generated proxy |
| `flutter build web --wasm` (dart2wasm host) | exit 1, missing generated proxy |
| `flutter build web --debug` | exit 1, missing generated proxy |
| `flutter run -d chrome` (debug, DDC) | **succeeds**; worker used |

The debug result is structural, not a race: the resident web runner awaits
`runHooks()` inside `assetBundle.build(...)` before `devFS.update(...)`
(`isolated/resident_web_runner.dart`). It is one mode, not the gate. In every
build-system mode the hook is scheduled in the same wave as the compiler and
finished ~14.7 s later, after `dart2js` had already reported the missing import.

Two earlier observations are corrected. An app-root `hook/build.dart` **does**
run on 3.47.6 when the app depends on `hooks` (measured); it is still unordered
relative to the compiler, so it is a race, not a fix. And a disposable-SDK
prototype that adds `BuildHooks(platform: HookPlatform.web)` to
`Dart2WebTarget.dependencies` makes the first `flutter build web --release` and
`--wasm` succeed (twice each, clean apps, 623 `flutter_tools` web tests still
pass). No package-level mechanism exists: `BuildTargets` is a closed interface,
Flutter's generated-source targets are hardwired, and a build hook's only
target output is `build_hooks_result.json`.

Decision unchanged: the one-time `dart run dwi_builder:dwi build` before the
first Flutter build stays the supported workflow; the fix belongs upstream.
Details and the proposed contract: `docs/upstream/flutter-web-hook-ordering.md`.
Evidence: `audit/evidence/flutter-fresh-build-ordering-2026-11-10.txt`.

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
   `cooperativeCancellation` claim in v0.4. *Amended by ADR-027:* with
   `DwiConfig.cancelGracePeriod` set, the task observes `DwiCancelToken` and
   termination becomes the fallback; without it this item still holds.

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

**Correction (2026-11-13).** The implementation does not delay
acknowledgements as decision 5 says: when the receive buffer is full,
`DwiChannelEndpoint.deliver` refuses the message and the sender's `send`
fails with `DwiChannelBufferException`. Bounds and "never dropped silently"
hold; a sender that awaits every send can still fail if the reader stops.
ADR-022 streams add credit-based flow control on top for that reason.

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
| throws `E` with stack `S` | throws `C` | completes with `E`, same object, stack `S` extended with the cleanup failure |

The last row is the only place the two errors collide. The callback error object
is rethrown unchanged (`Error.throwWithStackTrace`), so `identical(caught, E)`
holds, and the future does not switch to the cleanup error. Because one stack
trace travels with one error, the cleanup failure `C` and its stack are appended
to `S`; the caller obtains both from the `catch (error, stack)` pair. Stacks are
where Dart reports a subordinate failure without changing the error, and it is
observable in a plain caller, an ordinary `package:test` test, and
`runZonedGuarded` alike.

The cleanup failure is therefore never silently swallowed, never replaces the
callback error, and is never reported with an uncaught `Zone.handleUncaughtError`
call — that would turn a condition the returned future already describes into a
process-level error and fail plain tests. Calling the zone was the earlier
contract; it is rejected here because an ordinary (unguarded) test zone surfaces
the call as a test failure while the future already carries the callback error.

Shipped backends implement `close()` without awaiting anything that can fail, so
a throwing `close()` is a backend-contract violation; the rule exists so that
violation is visible rather than mistaken for success.

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

## ADR-017 — DWI-4 increment 2: handle termination observation

**Status.** Accepted (2026-11-08); **not implemented** in this revision of the
document. Selected in `research/R015_DWI4_NEXT_INCREMENT.md` after the 0.6.0
release gate. This ADR does not change the protocol or claim `dart:isolate`
parity. Implementation status is recorded at the end of the ADR.

**Problem.** A handle has six states (`created`, `starting`, `ready`, `closing`,
`closed`, `failed`) and callers receive cause-specific typed errors. But a
caller learns *why* a context stopped only if it had a call in flight. An idle
context that crashes is detected (web heartbeat, native isolate-exit listener)
yet nothing public is delivered; afterwards `state == failed` collapses timeout,
cancellation, crash and protocol failure into one value. Consumers cannot log or
react to the cause.

**Public surface.**

```dart
enum DwiWorkerStop {
  callerClosed,
  crashed,
  timedOut,
  cancelled,
  protocolViolation,
}

abstract interface class DwiWorkerHandle {
  /// Latest terminal reason for the current context, or null while active.
  DwiWorkerStop? get stopReason;

  /// Broadcast; one event per terminal transition. Stays open across restart.
  Stream<DwiWorkerStop> get stops;
}
```

`package:dwi` forwards both getters on `DwiWorker`; the enum is exported from
`package:dwi_core` and re-exported by `package:dwi`.

**Decision 1 — Observation only.** The API reports a reason a context stopped.
It does not add an exit message, a drain, pause/resume, or a second error
channel. Typed call, channel and startup errors keep their current contracts;
`DwiWorkerStoppedException` is not introduced. `stops` reports the handle's
termination and never replaces or suppresses an error delivered to a call.

**Decision 2 — One reason, first terminal transition wins.** `close()` records
`callerClosed`; context death detected by the backend records `crashed`; a
running-call timeout records `timedOut`; cancelling a running call records
`cancelled`; a malformed or protocol-invalid worker message records
`protocolViolation`. A later `close()` on a failed handle neither overwrites
`stopReason` nor emits a second event.

**Decision 3 — Event ordering.** A terminal transition runs in this order:

1. The handle state changes to `failed` (failure) or `closing` (explicit
   `close()`).
2. If no reason is recorded for the current generation, the reason is stored in
   `stopReason` and queued on the `stops` broadcast controller synchronously.
   From here `stopReason` is readable and always equals the last emitted event.
3. The in-flight reply/task settles with its existing typed error, then queued
   calls settle, then open channels fail.
4. The context is released (isolate killed, worker terminated).
5. For `close()`, the state becomes `closed`, the backend's ownership callback
   runs, and the final event plus stream completion are queued. `close()` does
   not await subscriber processing: a paused, slow, or throwing listener cannot
   hold teardown, and each subscriber still receives the queued event before
   `done` when it resumes.

Listeners are invoked asynchronously by the broadcast controller, so a listener
never observes a partially settled transition: when it runs, `state` is already
`failed`/`closed`, `stopReason` matches the event, and affected callers have
already been settled.

**Decision 4 — Race resolution.** Only the first recorded cause is published.
Because the state is set before settlement, a crash that arrives during
`close()`, a timeout that races a running cancellation, or a second failure
during cleanup sees a terminal state and returns without recording or emitting.
A crash-versus-close race therefore settles exactly once, with the reason of
whichever transition started first.

**Decision 5 — Restart generation.** `restart()` is allowed only from `failed`.
The snapshot is cleared when the replacement actually starts: inside the
backend start path, after the state becomes `starting`. `stops` stays open and
a listener subscribed before the restart receives the next stop of the
replacement generation exactly once. If the replacement cannot start,
`restart()` throws the same `DwiStartupException` as `spawn`, the handle returns
to `failed`, and `stopReason` remains `null`: a failed startup is not the
termination of a running context and emits nothing.

**Decision 6 — Stream completion.** `stops` is a single broadcast stream per
handle and never carries an error. It survives failures and restarts. It closes
only on a final `close()` — explicit or through `Dwi.close()` — after the last
event, so `done` always follows any stop event. Completion is *queued*, not
awaited: closing the controller must not make `close()` wait for a subscriber,
and the controller's close future is treated as handled. There is no replay: a
late subscriber reads `stopReason` instead of receiving history, and there is no
event log.

**Decision 7 — Listener isolation.** Each listener receives events
independently. Queueing an event is not synchronous with listener execution, and
no transition awaits a listener, so a listener that throws cannot prevent
cleanup, change `stopReason`, suppress another listener, or change a caller's
result. A paused subscription buffers the queued event and `done`; it does not
block teardown, and its eventual resume or cancellation is the subscriber's
choice. A throwing listener error is reported to the zone in which it listened.

**Decision 8 — Call-local outcomes are not stops.** A queued-call
`queueTimeout`, a full queue, an unknown task, a call-local serialization
failure, and a task-level `DwiRemoteException` keep the context and emit
nothing. Only a transition to `failed` or to a final `closed` emits.

**Decision 9 — Startup has no handle to observe.** A failed `spawn()` still
throws `DwiStartupException`; no handle exists, so it cannot emit a stop.

**Decision 10 — Classification is explicit per failure path.** Every backend
`_fail` site names its reason; a reason is never inferred from an exception
type, because the same type (for example `DwiRemoteException`) is used for both
crashes and malformed inbound traffic.

| Terminal cause | Reason |
| --- | --- |
| `close()` or `Dwi.close()` | `callerClosed` |
| Unexpected isolate exit (not caused by `close`), isolate port error, `Worker.onerror` | `crashed` |
| Missed heartbeats while idle | `crashed` |
| Running-call task timeout | `timedOut` |
| Cancelling a running call | `cancelled` |
| Native `protocol` report, malformed inbound message/reply/channel message, result or channel payload decode failure, unknown reply code | `protocolViolation` |
| Web non-object message, protocol envelope decode failure, unexpected envelope, channel message missing name/sequence, `Worker.onmessageerror` | `protocolViolation` |
| Queued-call timeout, full queue, unknown task, remote task error, call-local serialization failure | none |
| Failed `spawn()` / failed `restart()` startup | none (throws) |

**Decision 11 — Naming.** `stopReason`/`stops` describe DWI's own terminal
causes. They are not `Isolate.onExit`/`onError` analogues: `dart:isolate` has no
timeout or cancellation states and no restart generation.

**Forbids.** Emitting from call-local failures; replaying events to late
subscribers; a lifecycle event log; adding an error stream in the same
increment; claiming `dart:isolate` parity; exposing `Worker`/`Isolate` types;
adding protocol messages for termination.

**Testing.** VM: every reason; queued timeout and remote task failure emit
nothing; late subscriber reads `stopReason`; restart clears and re-emits;
close after failure does not duplicate; close during restart and crash-versus-
close races settle once; the event precedes stream completion; `Dwi.close()`
closes owned handles and streams; a throwing listener cannot interrupt cleanup;
a paused listener cannot hold `close()` (including through `Dwi.close()` and on
a failed-then-closed handle) and still receives the event before `done` when it
resumes, or can cancel instead. Browser: the same in Chrome, Safari, Firefox and
Edge, including an idle heartbeat crash and a malformed inbound message.
Existing suites must stay green. Results belong in `docs/browser-matrix.md`, per
engine.

**Implementation status.** Implemented in `packages/dwi_core`,
`packages/dwi_native`, `packages/dwi_web` and `packages/dwi` on 2026-11-08; not
published. The enum and both getters are exported from `package:dwi_core` and
forwarded by `package:dwi`. Evidence:

- Native VM: `packages/dwi_native/test/native_worker_handle_test.dart` covers
  every reason, queued timeout and remote failure emitting nothing, late
  subscribers, restart, close-after-failure, close-during-restart,
  crash-versus-close, backend close, stream completion and a throwing listener.
- Facade: `packages/dwi/test/dwi_worker_test.dart` verifies the public getters.
- Browser: cases N–Z in
  `packages/dwi_builder/test/browser_handle_test.dart`; three page loads pass in
  Chrome 157.0.8103.38, Safari 26.5, Firefox 159.0.1 and Edge 157.0.4341.42,
  after the close fix. Firefox needs every per-process sandbox switch this build
  exposes; see `docs/browser-matrix.md`.
- Prompt close: `close()` queues the final event and stream completion without
  awaiting subscriber processing. Native tests cover a paused listener, the
  backend path, a failed-then-closed handle and cancelling a paused
  subscription; the browser harness covers the paused native/web equivalents.
- Checkout consumer: `examples/stop_observer/` uses only `package:dwi` and
  prints the reason and stream event. The hosted `0.7.0` fixture passes in
  Chrome, Safari, Firefox and Edge at the site root and `/sub/app/`, including
  `stopReason`/`stops`, and the hosted-resolution and first-build gates hold.
- Repository gates: analysis clean for `dwi_core`, `dwi_native`, `dwi_web`,
  `dwi` and `dwi_builder`; core, native, web and facade suites pass; non-browser
  builder tests pass; browser harnesses are run one engine at a time.

No protocol message, no new error type, and no public backend type were added.

## ADR-018 — dart2wasm worker backend: explicit opt-in behind a build target

**Status.** Accepted and implemented as an opt-in backend. Measured on
2026-11-10 for dart2js and dart2wasm hosts with Wasm workers in Chrome, Edge,
Firefox and Safari, at `/` and `/sub/app/`, with publication-safety,
deployment, target-selection and benchmark evidence. It is supported as an
opt-in backend since 0.8.0; 0.7.0 has no Wasm worker. JS remains the
default and there is no release-number claim in this ADR.

**Context.** The measured baseline separates the two sides:

- A **dart2wasm host** can host DWI (`flutter build web --wasm`, Chrome only,
  ADR-017 evidence). Its worker was still dart2js and that result says nothing
  about a Wasm worker.
- A **dart2wasm worker** capability probe passed on 2026-11-10 in Chrome
  157.0.8103.50, Edge 157.0.4341.42, Firefox 159.0.1 and Safari 26.5, at `/`
  and `/sub/app/` (`audit/evidence/dart2wasm-worker-probe-2026-11-10.txt`).
  `dart compile wasm` (Dart 3.13.5) emits `worker.wasm` and `worker.mjs`; the
  loader exports `compileStreaming`/`compile` and `instantiate` but **never
  invokes `main`**. A generic module-worker bootstrap is therefore a required
  runtime artefact. `application/wasm` serving is mandatory, and a missing or
  corrupt module, wrong MIME, or missing loader is an engine-specific typed
  startup failure. Uncaught Wasm failures reach the host through the coarse
  worker `error` event (Safari reports only `Script error.`), so failures that
  must reach a caller have to be encoded in-band as typed envelopes.
- The probe is a capability test, not a DWI worker acceptance test. It did not
  exercise DWI's protocol, channels, transferables, cancellation, heartbeat,
  lifecycle or performance.

**Decision.**

1. **One build target per worker.** `dwi_builder` gains a build-time `target`
   (`js` | `wasm`), default `js`. A single worker id always refers to one
   backend; a manifest never mixes JS and Wasm artefacts for the same worker.
   The target is part of the content hash, so switching it invalidates the
   cache and a stale artefact of the other kind is never reused.
2. **Explicit runtime selection, no silent fallback.** `DwiConfig` gains
   `workerBackend` (`DwiWorkerBackend.js` | `.wasm`, default `.js`). The default
   `workerScript` (`dwi/worker.dart.js`) is unchanged. A Wasm worker is
   selected by pointing `workerScript` at the generated `dwi/worker.boot.mjs`
   and setting `workerBackend: DwiWorkerBackend.wasm`. The host then creates a
   **module** worker; the JS path keeps a classic worker. DWI never retries on
   the main thread and never silently switches backend.
3. **Packaging.** For `target=wasm` the builder publishes a content-addressed
   **generation directory** plus one small stable entry:
   - `gen-<generation>/worker.wasm` — the compiled module;
   - `gen-<generation>/worker.mjs` — the compiler-emitted loader, byte-identical
     to the compiler output;
   - `worker.boot.mjs` — a generated, versioned, application-independent
     bootstrap that imports the loader and fetches the module for exactly one
     generation.
   The generation id is the content hash already used for the build cache. A
   generation is written completely before the entry references it, and the
   entry is replaced by a single atomic rename. The source map is not published.
   `worker.support.js` is not required at runtime for the module-worker path
   (the probe logged zero fetches) and is not published. The manifest records
   the target, the generation, the entry URL, the file list and a SHA-256
   digest per file. For `target=js` the existing single-file `worker.dart.js`
   layout is unchanged.
4. **URL resolution.** Every reference inside `worker.boot.mjs` is relative to
   `import.meta.url` (`gen-<generation>/worker.mjs`,
   `gen-<generation>/worker.wasm`). No absolute or base-href-specific path is
   embedded. The probe verified the same artefacts at `/` and `/sub/app/`
   without recompilation.
5. **Protocol.** Wire protocol v1 is unchanged. The worker `ready` envelope's
   `capabilities` map gains `'backend': 'dart2wasm' | 'dart2js'`; the host
   compares the observed value with `workerBackend` and treats a mismatch as
   `DwiStartupException`. Channels, transferables, cancellation, heartbeat,
   restart/`stopReason`/`stops` keep their existing contracts; each must be
   proven on the Wasm backend before any cell is marked supported.
6. **Capability reporting.** `Dwi.capabilities()` reports both the transport
   (`worker`) and the observed worker backend. The requested backend is not
   reported as the observed one.
7. **Unsupported browsers/assets.** If WasmGC or the `js-string` builtins are
   missing, or the loader/module is missing, corrupt or mis-served, the
   bootstrap emits a typed `startup-error`; the host raises
   `DwiStartupException` naming the failed phase. There is no main-thread
   execution and no implicit JS retry.
8. **Publication, cache, check, clean and watch.** The worker hash includes
   `target`; for Wasm it is also the generation id. Publication order is fixed:
   1. write the module and loader into `gen-<generation>/` (not referenced yet;
      safe to retry or interrupt);
   2. atomically replace `worker.boot.mjs` so it references that complete
      generation;
   3. write the manifest.
   A reader therefore observes either the previous entry with its previous
   complete generation, or the new entry with its new complete generation. It
   can never mix files from two generations. A failed build before step 2
   leaves the old entry and generation untouched; a failure after step 2 leaves
   a working new entry and an old manifest, which `dwi check` rejects until the
   next build completes.
   `dwi check` verifies the target, the recorded generation, the entry and every
   generation file against the manifest. `clean` removes the entry, all
   `gen-*` directories and interrupted temporary directories. A successful
   build never deletes a published `gen-*` directory (amended 2026-11-10; see
   "Retention and cache contract" below). Live workers are unaffected by a
   switch: their assets are already loaded. `watch` republishes the same order.
   Deployment contract: upload generation directories before replacing the
   entry, and serve the entry without long-lived caching. A reader that arrives
   between those two steps gets a typed startup error (missing generation), not
   a mixed pair.
9. **Version compatibility.** The manifest carries the target, the generation, a
   bootstrap format version and the per-file digests. A host/loader/worker
   mismatch of the bootstrap format, protocol version or requested backend is
   rejected before the first request, not worked around.
10. **Defaults.** JS remains the default and the only backend in any supported
    release statement. Wasm is opt-in and experimental until the acceptance
    gates in this milestone pass on all four engines for every contract.
11. **One target setting.** The application package may contain `dwi.yaml`
    (`target: js|wasm`) next to `pubspec.yaml`. The Flutter build hook and the
    CLI both read it through `DwiProjectConfig`; an explicit CLI `--target`
    overrides it. The hook declares the file as a dependency, so a target change
    re-runs it. An invalid or unknown setting fails the build rather than
    silently selecting the other backend, and the hook can never replace a
    requested Wasm worker with a JS one.

**Retention and cache contract (amended 2026-11-10).**

The 0.8.0 implementation pruned generations automatically, keeping only the
current and the immediately previous one. Measurement showed that is unsafe: a
browser that keeps the `worker.boot.mjs` response it cached during deployment A
requests `gen-A/worker.mjs` after two later builds, receives 404, and the host
raises `DwiStartupException`
(`audit/evidence/cached-bootstrap-reproduction-2026-11-10.txt`,
`audit/evidence/flutter-production-cache-2026-11-10.txt`). The same measurement
showed Flutter 3.47.6's generated service worker is a self-unregistering stub
that caches nothing, so the deployment's HTTP headers, not Flutter, decide
whether a cached bootstrap survives.

The contract is therefore:

1. **A build never deletes a published generation.** `dwi build`, `dwi watch`
   and the Flutter build hook create `gen-<generation>/` directories and the
   entry; they do not remove any `gen-*` directory. Only an explicit action
   removes one.
2. **A cached bootstrap may reference its generation for as long as that
   bootstrap can be served from any cache.** Because a bootstrap is immutable
   for a generation, the only safe rule is that every generation ever served
   stays reachable while a client may still hold its bootstrap. The builder
   cannot know that lifetime, so it does not guess it.
3. **The deployment owner decides when a generation can be removed.** Removal is
   an explicit maintenance action by the deployment system or operator, after
   the retention window that system promises for cached bootstraps. No
   automatic retention rule is applied by the tool, and no prune command is
   added in this release because a correct one needs that operator-supplied
   window first.
4. **A default build must not delete assets still used by deployed clients.**
   This is why pruning is gone. A build that would need to delete a generation
   to stay under a storage budget is a deployment decision, not a build
   decision.
5. **Local development storage.** Generations are content-addressed: rebuilding
   without changing the worker hash reuses the existing `gen-<hash>/` and adds
   nothing. Storage grows only with genuinely different worker content, plus at
   most one transient `.dwi-wasm-*` directory per interrupted build, which the
   next wasm build removes. `dwi clean` removes generated sources, the manifest,
   the entry, every `gen-*` directory and abandoned `.dwi-wasm-*` directories.
6. **Deployment order.** Upload every `gen-<generation>/` directory the new
   entry references *before* replacing `worker.boot.mjs`. Delete old generations
   *last*, and only when no bootstrap that names them can still be served. Old
   entries must never outlive their generations.
7. **Serving the entry.** Serve `worker.boot.mjs` without a long-lived cache
   (`no-cache`, or a `max-age` shorter than the generation retention window) so
   a reload after a deployment picks up the new entry. Serve `gen-*` files as
   immutable (`Cache-Control: public, max-age=31536000, immutable`). A long
   cached entry combined with short generation retention is the configuration
   that produced the failure; it is unsupported unless the operator keeps every
   generation that entry can name.
8. **Clients open across releases.** A running worker is unaffected: its loader
   and module are already loaded. A new spawn from an open page resolves against
   whatever the deployment (or the browser cache) can serve at that moment.
   With generations retained and served immutably, the cached generation is
   used. With the generation gone and not cached, the spawn fails with a typed
   `DwiStartupException`. No configuration loads a mixed generation: the
   bootstrap only ever requests its own generation's `worker.mjs` and
   `worker.wasm`.
9. **`dwi clean` and deployed clients.** `dwi clean` intentionally removes all
   generated worker assets. Deployed clients whose cached bootstrap names a
   removed generation get the typed startup failure described above. `clean` is
   a local reset, not a deployment operation; a deployment must not publish the
   result of a clean while older bootstraps are still reachable.

The supported configuration is therefore: retained generations, an uncached
(or short-lived) entry, immutable generation files, and generation directories
uploaded before the entry and deleted only after their retention window.

**Consequences and open gates.**

- The builder's single-file publication path becomes a content-addressed
  generation publication: generation files first, then one atomic entry switch,
  then the manifest. Generations are retained until an explicit maintenance
  action, because a cached bootstrap can name any generation the deployment has
  served (amended 2026-11-10).
- The Wasm runtime artefact graph is larger (a generation directory plus one
  entry) and each request still crosses a structured-clone boundary. Startup and
  dispatch cost must be measured, not assumed, before any performance statement.
- A module worker is required, so a deployment that serves `.mjs` with the
  wrong MIME now has a new failure mode; it is a typed startup failure.
- The generated bootstrap is an application-independent DWI artefact. It is not
  a place for user code, and it must remain deterministic.
- Open: whether `DwiWorkerRuntime` and the generated registry compile and run
  unmodified under dart2wasm; whether channels and transferables behave
  identically; Safari's opaque uncaught-error reporting; Firefox/Safari/Edge
  Wasm-host combinations.
- Not decided here: any `flutter build web --wasm` hook integration, any
  automatic backend negotiation, and any default change.

## ADR-020 — Registered static functions through generated typed adapters

**Status.** Accepted for implementation, 2026-11-11. This is the restricted
increment approved separately from ADR-019. It does not implement full DWI-5
or DWI-6, transmit functions, or change `Dwi.run`/`Dwi.runFresh`.

The existing generated proxy file additionally exports `DwiFunctions`:

```dart
static Future<R> run<I, R>(FutureOr<R> Function(I) function, I input);
static Future<R> run0<R>(FutureOr<R> Function() function);
```

Only discovered `@DwiTask` top-level functions and public class static methods
are registered. A private map uses Dart function equality/hash semantics to
select the existing typed proxy; no function crosses a worker boundary and
the target is never invoked on the host. Proxies remain responsible for native
registration and result decoding, including JS-number normalization on Wasm
hosts. The map is not exposed or mutable by consumers.

Lookup occurs before native registration or worker startup. Unknown functions,
closures and bound instance methods produce `DwiUnknownTaskException`, not null
or local execution. A registered function presented with a type-widened,
incompatible caller signature produces `DwiUnsupportedException` before
execution; generated typed proxy signatures must satisfy the requested input
and output types. Existing transport, serialization, remote errors, timeouts,
pooling and cleanup are unchanged. No new fresh/handle/cancellation surface is
added. Runtime lookup cannot inspect captures or give capture-specific errors.

`DwiTaskDescriptor` gains optional `declaringType`, plus derived
`qualifiedName` and `proxyName`; existing top-level constructors remain valid.
A method's default task ID is `Class.method`, and its proxy is
`DwiTasks.Class$method`. Explicit task-name overrides keep their existing
meaning. Top-level IDs and proxy names are unchanged. All generated proxy-name
collisions, including a top-level name containing `$`, are DWI004 errors.
References in both worker and native registries use `Class.method`.

Static methods must have the same concrete zero/one-required-positional
signature and worker-safe types/import closure as top-level tasks. Instance
members, private classes/methods, generic classes/methods, getters/setters,
mixins, `external` declarations and unsupported signatures are rejected with
source diagnostics. So is every other placement of the annotation: extension
and extension-type members (static or instance), enum instance methods and
constants, constructors, fields, local functions, parameters, and class, mixin,
enum, extension, extension-type or typedef declarations each produce `DWI003`.
No annotated declaration is skipped silently.

Amendment (2026-11-11, after the ADR-020 audit): static methods of public,
non-generic enums are supported on the same terms as class static methods —
task ID `Enum.method`, proxy `DwiTasks.Enum$method`, same signature, type,
import-closure and collision rules. Private and generic enums are rejected like
private and generic classes. Extension and extension-type statics remain
unsupported.
Annotation discovery and generated code use resolved declarations, not text
rewriting or whole-program dynamic target inference.

The host retains static references to annotated task libraries. Code duplication
and host bundle cost are not measured performance improvements. Generated
sources must be produced using the documented explicit pre-build on released
SDKs; this API does not repair Flutter hook ordering.

Acceptance requires deterministic generation; positive and negative discovery
tests; sync/async/void/nullable/collection adapter cases; repeated tear-offs;
typed failures before startup; real VM isolate execution; separate JS/Wasm host
and worker compilation in each measured browser; actual worker realm and
independent task state; clean builds, cache invalidation and cleanup. Prototype
identity or worker-only compilation cannot satisfy that gate.

## ADR-028 — Pausing dispatch and pinging a worker (lifecycle, increment 3)

**Status.** Accepted, 2026-11-13. Completion-plan tranche D, third increment
(master plan §27, handoff §26: "pause/resume of dispatch; `ping`"). No
protocol version change: `ping` reuses the `heartbeat` message with a string
nonce, and the native handle gains a `ping`/`pong` pair.

**Problem.** An application could not hold background work (a page going to
the background, a burst of interaction) without cancelling it and calling it
again later. The pool's heartbeat checked liveness internally, but nothing
told the caller whether a dedicated worker's event loop was responsive.

**Decision.**

```dart
Dwi.pause();          // new pooled and fresh calls are held
Dwi.resume();         // held calls are dispatched in order
Dwi.isPaused;

final latency = await worker.ping(timeout: const Duration(seconds: 1));
```

1. `Dwi.pause()` / `Dwi.resume()` / `Dwi.isPaused`, implemented in the facade
   so web and native behave the same and `DwiBackend` is unchanged. While
   paused, `run`, `runCancellable`, `runFresh` and generated proxies are held
   before reaching the backend; calls already dispatched keep running.
2. Held calls obey the queue limits: at most `maxQueuedTasks` are held (more
   fail with `DwiUnsupportedException`) and each waits at most `queueTimeout`
   (then `DwiTimeoutException`). After `resume`, the backend's own queue
   limits apply as usual.
3. A held `runCancellable` call can be cancelled: `cancel()` returns `true`
   and the call is never dispatched. Once dispatched, cancellation follows
   ADR-010 and ADR-027.
4. `close()` fails held calls with `DwiUnsupportedException` and ends the
   pause; `close(drain: true)` resumes first, so held calls run and are
   drained (ADR-024).
5. Dedicated handles, links and `runStream` are not held: a handle owns its
   context and its own FIFO queue (ADR-013).
6. `DwiWorkerHandle.ping({timeout})` / `DwiWorker.ping`: resolves with the
   round-trip time. The worker answers from its event loop, outside the task
   queue, so an asynchronous task in progress delays the answer only until
   its next `await`; a synchronous task makes the ping time out with
   `DwiTimeoutException`. A missed ping does not fail the handle; the
   automatic heartbeat (ADR-010 §10.3) remains the failure detector. Default
   timeout: `heartbeatInterval`. Not-ready handles throw the same state
   errors as `run`; closing or failing the handle settles pending pings.

**Alternatives rejected.** Pausing inside each backend (two queues with the
same rules); pausing handles (their single queue already serialises calls and
the caller controls when to call them); `ping` on the pool (pool workers are
interchangeable and already supervised by the heartbeat; a pool ping would
report on an arbitrary worker); failing the handle on a missed ping
(synchronous work is legitimate, and `taskTimeout` bounds it).

**Acceptance.** Native: held calls start only after resume and in order, a
running call is unaffected, a held call cancels without starting, hold limits
and timeouts, close fails and drain runs held calls, idempotence, handles are
not paused; ping answers while idle and during an asynchronous task, times
out during synchronous work without failing the handle, settles on close and
refuses on a closed handle. Web, four host/worker compiler pairs in four
engines (`browser_dispatch_control_test.dart`): the same pause, cancel, close
and drain cases through generated proxies, and ping idle, during an
asynchronous task, timed out during a synchronous one, usable afterwards and
refused once closed.

## ADR-027 — Cooperative cancellation (lifecycle, increment 2)

**Status.** Accepted, 2026-11-13. Completion-plan tranche D, second increment
(master plan §27, handoff §26 "cancellation token observed between awaits").
Amends ADR-010 §10.1 item 8. Uses the `cancel` message already reserved in
protocol v1 (`docs/protocol.md`); no version change.

**Problem.** Cancelling a running call terminates its worker or isolate. The
task cannot release what it holds, and the pool pays a fresh worker start for
every cancellation even when the task was idle in an `await`.

**Decision.**

```dart
await Dwi.configure(const DwiConfig(cancelGracePeriod: Duration(seconds: 1)));

// task code (web: import package:dwi_core/dwi_worker.dart)
for (final item in items) {
  DwiCancelToken.current.throwIfCancelled();
  await process(item);
}
```

1. `DwiConfig.cancelGracePeriod` (`Duration?`, default `null`). With `null`
   nothing changes: a running call is terminated at once (ADR-010).
2. With a period set, `cancel()` on a running call still settles `result` with
   `DwiCancelledException` at once and returns `true`; the ADR-010 race rules
   are unchanged. The host then signals the task:
   - web: a `cancel` envelope with the request id. The worker cancels that
     request's token and sends nothing. The task's own `result` or `error`
     reply, ignored because the caller was settled, frees the worker for the
     next call. If no reply arrives within the period, the worker is
     terminated. `taskTimeout` still applies.
   - native: the task isolate reports a control port when it starts; the host
     sends the signal on it and kills the isolate when the period ends. A
     cancel that arrives before the port is delivered when the port arrives.
3. `DwiCancelToken.current` is a zone value set around each task call, so
   `DwiTaskFunction` and generated signatures are unchanged. Outside a task,
   in a call that was not cancelled, or without a grace period, the token
   never fires. API: `isCancelled`, `whenCancelled`, `throwIfCancelled()`
   (throws `DwiCancelledException`); `cancel()` and `runWith` are for
   backends. It is exported from `package:dwi/dwi.dart` and from the
   worker-side `package:dwi_core/dwi_worker.dart`.
4. Termination stays the fallback and the documented guarantee: a task that
   never yields (a synchronous loop) cannot observe the token and is
   terminated when the period ends.
5. Scope: pooled `Dwi.runCancellable` calls. Handles (`DwiWorker.run`) have no
   per-call cancellation, and `runStream` keeps closing its channel on
   cancellation (ADR-022). `DwiCapabilities.cancellation` stays `running`.

A worker built before this change answers `cancel` with a protocol error that
carries the request id. The host treats that reply on a cancelled call as
"worker still busy" and terminates it, so mixing versions cannot hand a busy
worker to the next caller.

**Alternatives rejected.** A token parameter on every task (changes
`DwiTaskFunction` and every generated adapter); reusing the worker without
waiting for the task's reply (the next call would share a worker with a task
still running); an acknowledgement message (`cancelled` in the protocol table)
— the task's own reply already says the worker is free.

**Acceptance.** Core: token zone scoping across awaits, idempotent cancel,
config validation. Dispatcher (VM): the cancel envelope reaches only its
request, sends no reply, and unknown ids are ignored. Native: a cooperative
task stops and records it, a cancel before the control port arrives still
reaches it, a task that never yields is killed at the end of the period, no
period means immediate kill, and an uncancelled call's token never fires.
Web, four host/worker compiler pairs in four engines
(`browser_cooperative_cancel_test.dart`, one pooled worker, 1 s period): the
caller settles within 200 ms, the task observes the token, the same worker
serves the next call, a cancelled synchronous loop is terminated near 1 s and
replaced, and every worker is terminated at the end.

## ADR-024 — Idle worker retirement and draining close (lifecycle, increment 1)

**Status.** Accepted, 2026-11-13. Completion-plan tranche D, first increment
(master plan §27 idle termination, handoff §26 graceful shutdown). Cooperative
cancellation is the next increment. No protocol change.

**Decision.**

```dart
await Dwi.configure(const DwiConfig(idleTimeout: Duration(seconds: 30)));
await Dwi.close(drain: true);
```

1. `DwiConfig.idleTimeout` (`Duration?`, default `null`): a pooled web worker
   that has been idle that long is terminated. Handing it a task cancels the
   timer. A retired worker is replaced on demand. Native `Dwi.run` keeps no
   idle isolate (one per call), so the setting has nothing to retire there;
   dedicated handles are never retired by it. Non-positive values are
   rejected by `validated()`.
2. `Dwi.close({bool drain = false})`: with `drain`, new `run`,
   `runCancellable` and `runFresh` calls are refused with
   `DwiUnsupportedException` while calls already started settle normally,
   each bounded by its own timeouts; then the usual close runs. Without
   `drain`, behaviour is unchanged: running pooled calls are settled with
   `DwiUnsupportedException`.

Draining is implemented in the `Dwi` facade by tracking unsettled calls, so
both backends share it and `DwiBackend` is unchanged. Handles, links and
`runStream` streams are not waited for.

**Alternatives rejected.** Draining inside each backend (two implementations
of the same rule); an idle timeout on by default (changes the warm-pool
latency users already rely on).

**Acceptance.** Native: started pooled, cancellable and fresh calls complete
during a drain, new ones are refused, a failing call does not block the
drain, a plain close does not wait, and work is accepted after close. Web, all
four host/worker compiler pairs in four engines: one worker retired after
300 ms idle, replaced on the next call, kept alive by steady work, two slow
calls drained while a new call is refused, a plain close still cutting a
running call, and every worker terminated.

## ADR-023 — Links between two handles (port-like messaging, increment 2)

**Status.** Accepted, 2026-11-13. Completion-plan tranche C, second increment
(master plan §30, handoff §24). Closes the ADR-014 decision 11 gap "channels
that cross handles". No protocol version change.

**Problem.** A channel connects the host to one worker. Two workers could only
talk through host code written for that purpose, and a worker writing faster
than the other read failed with `DwiChannelBufferException`.

**Decision.**

```dart
final link = await DwiWorker.link(producer, consumer, 'rows');
// in each worker: DwiWorkerChannels.find('rows')
await link.close();   // or: await link.done
```

`DwiWorker.link(a, b, name)` opens channel `name` on both handles and relays
messages in both directions. New public API: `DwiWorker.link`, `DwiLink`
(`name`, `done`, `isClosed`, `close`), and
`DwiWorkerHandle.openChannel(name, {ackOnConsume})` /
`DwiChannelEndpoint.ackOnConsume` for backends.

**Flow control.** Both link channels are opened with `ackOnConsume`: each end
acknowledges a message when its reader takes it, not when it is buffered. A
worker that awaits each send therefore waits for the relay, and the relay
waits for the other worker's reader, so a slow reader paces the writer end to
end. The worker-side endpoint learns the mode from `channelOpen` (native: a
fifth list element; web: `meta.ackOnConsume`). Ordinary channels keep
acknowledge-on-buffer (ADR-014, corrected).

**Semantics.**

- Per-direction FIFO. Each message is copied by the relay; transferred bytes
  reach the host by transfer and the other worker by copy.
- Closing either end, a failed or closed handle, or `DwiLink.close()` closes
  both ends. The surviving worker sees its channel end normally; the host sees
  the failure through `done`.
- The two handles must differ and the name must be free on both; a failure
  opening the second end closes the first.
- A channel name is a plain `String`, so "sending a port" is sending the name.

**Not provided.** A direct worker-to-worker path (`MessageChannel` on web,
`SendPort` hand-over on native): it would save one hop but needs a protocol
change and its own failure signalling, because a `MessagePort` reports no
closure when its peer worker dies. Revisit only with a before/after benchmark
(AGENTS.md rule 15). No `SendPort`/`ReceivePort` objects, broadcast, or links
that survive `restart()`.

**Alternatives rejected.** Changing every channel to acknowledge on
consumption (changes shipped, tested ADR-014 behaviour); rejecting at the relay
(a fast writer would fail under ordinary load, which the first prototype did:
9 of 25 native runs failed with `channel "pipe" is full`).

**Acceptance.** 200 ordered messages; 150 messages through a 4-message window
to a reader that pauses every 25; request and reply; names released after
close; closing the producer mid-stream (consumer keeps three messages, `done`
reports `DwiWorkerClosedException`, consumer stays usable); same-handle and
duplicate-name rejection with cleanup; every web worker terminated. Native and
all four host/worker compiler pairs in Chrome, Safari, Firefox and Edge.

## ADR-022 — Tasks that return a `Stream`

**Status.** Accepted, 2026-11-13. Completion-plan tranche C, first increment
(master plan §31, handoff §25). Ports are a separate, later increment. No
protocol change: streams are built on ADR-014 channels and ADR-013 handles.

**Problem.** A task returned one value. Progress reports and incremental
results needed a hand-built handle, a named channel and matching code on both
sides.

**Decision.** A `@DwiTask` may return `Stream<T>` (usually an `async*`
function). `T` follows the ADR-021 type rules; `Stream<void>`,
`Stream<dynamic>`, a `Stream` input and a stream nested in another value are
`DWI001`.

```dart
@DwiTask()
Stream<Progress> scan(List<String> paths) async* { ... }

await for (final progress in DwiTasks.scan(paths)) { ... }
await for (final item in Dwi.runStream('scan', paths)) { ... }  // untyped
final items = DwiFunctions.stream(scan, paths);                   // by function
```

New public API: `Dwi.runStream(String task, [Object? input])`;
`DwiFunctions.stream` and `stream0` in the generated file; `DwiStreamTask`
(worker-side, used by generated code) exported from `dwi_core` and `dwi`.

**Mechanism.** Listening spawns a dedicated handle, opens the channel
`dwi.stream` on it, and runs the task with `[channel, input, window]`. The
generated worker entry calls `DwiStreamTask.serve`, which sends each item over
the channel and closes it when the stream ends. The handle is closed when the
host stream ends, fails or is cancelled.

**Flow control.** ADR-014 channels reject a send when the receiver's buffer is
full (see the correction under ADR-014), so a slow listener would otherwise
fail the producer. Streams therefore use credit on the same channel: the worker
may have at most `window` (`DwiConfig.channelBufferSize`) items the host
listener has not taken; the host returns credit in batches of `window ~/ 2`.
The receive buffer never fills, a paused listener pauses the producer, and no
item is dropped, coalesced or reordered.

**Semantics.**

- One fresh context per listen (the `Dwi.runFresh` model). Startup is paid per
  stream; worker-local state does not carry over.
- Cancelling the subscription terminates the context. Items produced but not
  delivered are discarded; the task gets no notification.
- A task error is delivered after the items sent before it, then the stream
  closes. Startup, timeout, crash and `Dwi.close()` failures are the usual
  typed errors.
- `DwiConfig.taskTimeout` bounds the whole stream, not one item.
- Calling a stream task through the pooled `Dwi.run` fails with
  `DwiUnsupportedException`; `DwiFunctions.run` on a stream task fails the
  same way before startup.

**Alternatives rejected.** Streams over the pool (a stream would hold a pooled
worker indefinitely and need a new protocol message); changing ADR-014 to
delay acknowledgements (a behaviour change to a shipped API; credit gives the
same result locally).

**Acceptance.** Ordered items, 300 items through a 4-item window read slowly,
converted input and items, an error after two items, cancellation of an
infinite stream followed by a new stream, zero-input and nullable items,
`DwiFunctions.stream`/`stream0`, both misuse errors, and on web every worker
created by a stream terminated. Native and all four host/worker compiler pairs
in Chrome, Safari, Firefox and Edge.

## ADR-021 — Generated encoders for enums, core value types, records and payload classes

**Status.** Accepted, 2026-11-12. Completion-plan tranche B. No protocol,
transport or lifecycle change; the envelope still carries only values that
structured clone and the payload validator already accept.

**Problem.** A task could only take and return primitives, collections and
typed data. Enums, `DateTime`, records and application classes were `DWI001`
build errors, so real tasks needed hand-written conversion on both sides, and a
value that a closure would simply have captured had no typed way to reach a
task (ADR-019 keeps closures out of the package).

**Decision.** The generator emits an encoder next to each decoder, for these
types only:

| Dart type | Wire form |
| --- | --- |
| a public enum | its constant name (`String`) |
| `DateTime` | `[microsecondsSinceEpoch, isUtc]` |
| `Duration` | microseconds (`int`) |
| `BigInt`, `Uri` | `toString()` |
| a record | a list: positional fields, then named fields sorted by name |
| a `@DwiPayload` class | a map from constructor parameter name to encoded value |

Collections of these (`List<T>`, `Set<T>`, `Map<String, V>`) and nullable forms
compose. The host encodes the input and decodes the result; the worker, or the
native registration, decodes the input and encodes the result. Types that were
already supported are still sent as-is and their generated code is unchanged.

New public API, in `dwi_annotations`:

```dart
final class DwiPayload { const DwiPayload(); }
```

A `@DwiPayload` class must be public, concrete and non-generic, declared under
`lib/`, with a public unnamed constructor, and must expose for every
constructor parameter a public getter or field of the same name and type. The
decoder calls that constructor. A class may refer to itself.

`DwiTypeDescriptor` gains `kind`, `positional`, `named`, `shape`, `codecKey`
and `needsEncoding`; `DwiPayloadShape` and `DwiPayloadField` are new. Codecs
are keyed by `codecKey`, which includes the declaring library for enums and
payload classes, so equal names in two libraries do not collide.

**Semantics that differ from `dart:isolate`.**

- A payload object is rebuilt from its constructor parameters. Identity, state
  outside those parameters, and the runtime subtype are not preserved; a
  subclass instance arrives as the declared class.
- Shared references inside one message are duplicated, and a cyclic object
  graph does not terminate; payload classes must be trees.
- `DateTime` keeps its instant and `isUtc`; a local time is rebuilt in the
  receiver's time zone, which is the same zone in a page and its workers.
- A `Set` of converted values is sent as a list and rebuilt as a `Set`.
- Enums travel by name, so a host and a stale worker that disagree about an
  enum fail with `DwiSerializationException` instead of mapping to the wrong
  constant.

**Rejected at build time (`DWI001`).** Classes without `@DwiPayload`; private,
generic or abstract payload classes; a missing unnamed constructor; a parameter
without a matching public getter or with a different type; enums or payload
classes that are private or declared outside `lib/`; the bare `Record` and
`Enum` types; non-`String` map keys (unchanged).

**Alternatives rejected.** JSON `toJson`/`fromJson` conventions (untyped,
hand-written, and silently lossy); sending enums by index (a stale worker maps
to the wrong constant); reflecting over fields (no reflection on web, and
private state would cross silently).

**Acceptance.** Round trip of every form on native isolates and in all four
host/worker compiler pairs in Chrome, Safari, Firefox and Edge, including a
recursive class, nested collections, a wrong enum name and a wrong record
arity; negative discovery tests for every rejection; generated output unchanged
for existing types.

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
