# Architecture

Decision record for DWI. Each ADR states the decision, the evidence behind it,
and what it forbids. Evidence references point at `research/R00x` reports, which
in turn cite source files and measurements.

Status: accepted for v0.1, gate applied (M001 = PASS WITH LIMITATIONS).

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

## Consequences

- The first release is deliberately narrow: named tasks, one worker pool, typed
  errors, JS backend only.
- Features that need compiler cooperation (closures, automatic discovery) are
  research items, not roadmap promises.
- Every performance claim must cite a benchmark, as M001 does.

## Critical review

Objections raised by the security reviewer and the skeptical-maintainer reviewer
are recorded verbatim in `critical-review.md`, including those that remain open.
