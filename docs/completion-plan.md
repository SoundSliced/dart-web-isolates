# Completion Plan — 2026-11-11

The ordered work that finishes the project. Objectives come from
[`MASTER_PLAN.md`](MASTER_PLAN.md), [`ENGINEERING_HANDOFF.md`](ENGINEERING_HANDOFF.md)
and [`ZERO_BOILERPLATE_ADDENDUM.md`](ZERO_BOILERPLATE_ADDENDUM.md); the
per-objective classification is in
[`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md). This file only schedules
what that classification leaves open.

The master plan text in the repository is a reconstruction by its original
author; `AGENTS.md` cites section numbers of the original that it does not
reproduce. Where the plans and the implementation differ by recorded decision
(API names, version numbering, file layout), the implementation stands — see
`IMPLEMENTATION_STATUS.md` §1.

## 1. Position

Published: 0.9.0 (2026-11-13): ADR-020 (registered static
functions, including enum statics) with its audit corrections, ADR-021 (payload
types) and ADR-022 (stream tasks).

| Level | Status |
| --- | --- |
| DWI-0 … DWI-1.5 | shipped |
| DWI-1.6 cancel, transfer, heartbeat | shipped, four engines |
| DWI-2 handles, DWI-3 channels and links | shipped, four engines; links (ADR-023) unreleased |
| DWI-4 API similarity | two increments plus payload types (ADR-021) and stream tasks (ADR-022), both in 0.9.0, and handle links (ADR-023, unreleased); idle retirement, draining close (ADR-024) cooperative cancellation (ADR-027), pause/resume and ping (ADR-028) unreleased; scheduling comparison open (D) |
| DWI-5 functions | annotated function references only; closures need the compiler (F, I) |
| DWI-6 SDK integration | proposal only (I) |

## 2. What cannot be done in a package

Stated once, so no tranche is read as promising it.

| Objective | Verdict |
| --- | --- |
| Closures, `Dwi.run(() => …)`, `Isolate.run` on web | A closure object has no identity generated code can key on, and no supported build phase can rewrite a call site before compilation (R016). Needs a compiler or build contract. Tranche F tests the last package-level ideas; tranche I carries the SDK work. |
| Shared immutable objects, isolate groups, shared heap | Impossible: separate realms and heaps. Shared bytes via `SharedArrayBuffer` are possible only under COOP/COEP (G). |
| Pausing or cancelling running synchronous code | Impossible: no browser primitive. Only termination, or cooperation between awaits (D). |
| Runtime compilation in the browser | Rejected on evidence (R013 §4.5). |
| First `flutter build web` of a fresh typed-proxy app with no pre-build | Needs a Flutter tool change; prototype and write-up exist (I). |

## 3. Tranches

One concern each. A tranche that changes public API gets an accepted ADR in
`docs/architecture.md` and `docs/api-proposal.md` first, then tests on native
and on the 16-cell host/worker/engine matrix, then an evidence file. A
compatibility level is raised only when its matrix passes.

| # | Tranche | ADR | Contents | Exit criteria |
| --- | --- | --- | --- | --- |
| A | 1.0 gates and evidence debt | none | A1 pool lifecycle contract in four engines (done; found and fixed the startup-cancellation defect). A2 `critical-review.md` reconciled (done). A3 host bundle cost (done). A4 host tests for late and duplicate replies. A5 1,000-task and sustained leak run. A6 benchmark harness for Firefox and Edge, payloads 1 KB–100 MB, and sorting/JSON/hash/compression/image workloads. A7 JS worker under a strict CSP per engine. A8 tree-shaking probe for more library shapes. A9 CI workflow for format, analyze, VM tests and web compilation. A10 pool-sizing guidance from the measurements. A11 compatibility matrix columns per platform. | no "unverified" cell for a shipped feature on a desktop engine; every open critical-review item closed with a test reference |
| B | Payload types (done 2026-11-13: native + 16 cells pass) | ADR-021 | generated encoders and decoders for enums, `DateTime`, `Duration`, `BigInt`, `Uri`, records and `@DwiPayload` classes; `DWI001` narrowed. Open follow-up: tasks with more than one parameter | round trip on native and 16 cells; unsupported types still fail at build time |
| C | Ports and streams (done 2026-11-13) | ADR-022 (streams), ADR-023 (links) | tasks returning `Stream<T>` with credit flow control, cancellation and cleanup; `DwiWorker.link` connects two handles with acknowledge-on-consume flow control. Not done by design: `SendPort` objects and a direct worker-to-worker path (needs a benchmark first) | DWI-3 complete; no leaked subscription after close, cancel or crash |
| D | Lifecycle and pool | ADR-024 (increment 1 implemented 2026-11-13: idle retirement, draining close), ADR-027 (increment 2 implemented 2026-11-13: cooperative cancellation, sixteen cells), ADR-028 (increment 3 implemented 2026-11-13: pause/resume of dispatch, `ping`; sixteen cells pass) | cancellation token observed between awaits; `close(drain: true)`; pause/resume of dispatch; `ping`; spawn from an explicit worker script; idle worker termination; scheduling policies compared by benchmark before any is added | task states `queued/running/completed/failed/cancelled/timedOut` observable; termination remains the documented fallback |
| E | Flutter surface and examples | ADR-025 | `dwi_flutter` with `computeParallel` over registered functions; responsiveness demo against the main thread and Flutter's `compute()`; fill or remove the empty example directories (transfers, pool, cancellation, streaming, JSON, image) | Flutter web matrix in four engines; every listed example runs |
| F | Function references and closures | ADR-019 decision | annotation-free discovery of statically resolvable `DwiFunctions.run(fn, …)` targets; then a time-boxed closure experiment | accept only what binds deterministically on dart2js and dart2wasm without SDK changes; otherwise a recorded no-go with probes |
| G | Diagnostics and architecture decisions | ADR-026 and per finding | opt-in metrics (workers, queue depth, startup, task time, transfer size, failures); public pool state; protocol version negotiation; explicit opt-in fallback policy; worker replacement on hot restart in debug; universal vs per-task vs chunked workers measured; written Wasm comparison (instances vs shared memory vs threads); `SharedArrayBuffer` bytes | each item either shipped with tests or closed with a dated decision |
| H | Release and documentation | none | 0.9.0 = ADR-020 + A; one minor release per later tranche; troubleshooting guide; hygiene (`vision.md`, `tooling/README.md`, limitation numbering, README counts); at 1.0 the `FINAL_*` reports and `UPSTREAM_PROPOSAL.md` | handoff §55 release gates met for the stable API |
| I | Upstream and SDK experiments | none | post the hook-ordering and secondary-entrypoint proposals; experimental Dart SDK branch for worker entrypoint emission and compiler-known function references; `Isolate.run` and Flutter `compute()` prototypes | each step needs the maintainer's approval at the time; DWI-5/6 rise only on a demonstrated contract |

Order: A first because it needs no design and removes every blocker to a 1.0
claim. B is the most common reason a real task cannot be annotated. C and D
close the `dart:isolate` surface a package can reach and raise DWI-4. E depends
on B–D. F and I come last because current evidence says they end in the
compiler, not the package; a useful 1.0 does not depend on them (handoff §55).

Not practical on the current measurement machine: mobile browsers and
constrained devices (master plan §52). They stay **unverified** until a device
lab is available.

## 4. Definition of finished

1. Every row of `IMPLEMENTATION_STATUS.md` is complete, limited with its limit
   documented, superseded, infeasible with the platform reason, or SDK-dependent
   with a posted proposal.
2. No "unverified" cell remains for a shipped feature in a supported engine.
3. Every open item in `critical-review.md` is closed with a test reference.
4. DWI-4 is raised when B–D pass; DWI-5 only if F succeeds or upstream ships a
   build contract; DWI-6 only on SDK integration.

## 5. Not delegated

Posting upstream, editing or forking an SDK, and publishing to pub.dev each
need the maintainer's explicit approval at the time.

## Verified / not verified / could not determine

- **Verified:** tranche contents against `IMPLEMENTATION_STATUS.md`.
- **Not verified:** feasibility of B–E beyond design reasoning; none has a
  prototype yet.
- **Could not determine:** requirements present only in the original,
  unreconstructed master plan.
