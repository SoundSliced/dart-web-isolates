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
  application's `.dart_tool/package_config.json`, and runs it before `dart2js`.
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
- The hook runs before app compilation, so it cannot hot-patch a worker already
  running in a page. Reload the page (or hot restart) after a task change.
- A hook failure fails the Flutter build; this is intentional and preserves the
  "no main-thread fallback" rule.
- The resolver is conservative: zero or multiple matching app packages means
  "skip", not "guess".

**Evidence.** `audit/evidence/flutter-web-hook-2026-11-03.txt`; probe logs
`hook-build-cli.log`, `hook-build-inc1.log`, `hook-build-lib.log`,
`hook-build-real.log` (scratch, reproduced by the commands in the audit report).
Unit tests for the resolver: `packages/dwi_builder/test/hook_support_test.dart`.

## ADR-010 — v0.4 proposal: cancellation, transferables, crash recovery (PROPOSED, NOT IMPLEMENTED)

**Status.** Proposed. This ADR records the design required before any v0.4 public
API changes. Only the resource-safety subset described at the end is implemented
in the v0.3.1 patch; cancellation and transfer semantics are **not shipped** and
must not be reported as complete.

**Problem.** v0.3 has backpressure (bounded queue) and timeout-based recovery,
but:

- a caller cannot cancel a queued or running task;
- binary payloads are copied, with no ownership/transfer contract;
- `maxPayloadBytes` was declared but unenforced (now enforced approximately);
- a worker killed without an `error` event is only detected by a timeout;
- there are no committed browser concurrency/stress or performance benchmarks.

**Proposed public API (additive; needs approval).**

```dart
// dwi_web / dwi facade
final task = Dwi.runCancellable<int>('primes', 5_000_000);
final value = await task.result;      // Future<int>
final cancelled = await task.cancel(); // true if it was queued or terminated

// dwi_core
class DwiCancelledException extends DwiException { ... }

// Explicit binary ownership; the sender's buffer is detached after send.
await Dwi.run('hash', DwiTransferableBytes(bytes));
```

Rules:

1. `Dwi.run` keeps its current signature and semantics.
2. `cancel()` on a queued task removes it from the host queue and completes
   `result` with `DwiCancelledException`; no worker is started.
3. `cancel()` on a running non-cooperative task calls `Worker.terminate()`,
   fails the task with `DwiCancelledException`, and replaces the worker. This is
   the only reliable mechanism on the web.
4. Cooperative cancellation, if added, must be additive: a task may opt into a
   `DwiCancellationToken` argument (a new task shape) so the dispatcher can stop
   between iterations. It must not change the `DwiTaskFunction` typedef.
5. Transferables use a wrapper type, not an implicit flag, so ownership is
   explicit. The host passes a transfer list to `postMessage`; the worker checks
   that the buffer is not detached. `DwiCapabilities.transferables` becomes
   `true` only when this path exists.
6. Crash detection adds `onmessageerror`, a heartbeat/ping envelope, and a
   bounded restart policy. Every failure still ends in a typed error.

**Acceptance criteria.** Browser tests for: cancel queued, cancel running
(non-cooperative), cancel after completion (no-op), transfer ownership/detach,
worker crash and restart, 100-task concurrency with bounded queue, and no leaked
workers or pending completers. Before/after benchmarks for transfer vs copy and
for cancellation latency. Chrome, Firefox, Safari and Edge must be measured
separately; unmeasured engines stay "unverified".

**Implemented now (non-breaking).** `validateDwiPayload` enforces an approximate
`maxPayloadBytes` budget from `DwiConfig`; the host sends the limit in request
metadata and the worker applies it to results, so an oversized payload fails with
`DwiSerializationException` instead of crossing the boundary. The queue already
wakes waiters after termination/failure (v0.3.1 fix).

**Explicitly not implemented.** Cancellation, cooperative tokens, transferables,
heartbeat, restart policy, and the multi-browser benchmark matrix. v0.5–v1.0
remain proposals.

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
