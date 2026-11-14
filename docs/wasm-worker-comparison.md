# Wasm worker comparison: instances, shared memory, threads (ADR-026 G7)

Written 2026-11-14. Sources: ADR-018 (`docs/architecture.md`), the Wasm benchmark
`audit/evidence/wasm-worker-benchmark-2026-11-13.json`, and limitations 19 to 21
in `docs/limitations.md`. Nothing here is measured beyond those sources.

## The three options

**1. One Wasm instance per worker (current design, ADR-018).** Each worker loads
its own module instance with its own memory. Calls and results cross the boundary
by structured clone or by transfer (ADR-010 §10.2). Nothing is shared between
workers, which keeps the isolate-style rule of no shared mutable state (AGENTS.md
rule 10).

**2. Shared linear memory across workers.** Workers would read and write one
memory through a `SharedArrayBuffer`. The browser only allows that under
cross-origin isolation (COOP/COEP headers), which changes deployment
(limitation 20). It also breaks the no-shared-mutable-state default unless every
access is an explicit, documented contract.

**3. Wasm threads.** Threads need shared memory plus atomics. This is a further
step beyond option 2 and needs toolchain support that the repository does not
have evidence for: no measured dart2wasm output in this repository uses threads.

## What is measured for option 1

From `wasm-worker-benchmark-2026-11-13.json` (Chrome 157.0.8103.78, macOS 26.5.1,
8 cores, Dart 3.15.0-133.0.dev; one run, per-target medians):

| Metric | JS worker (dart2js) | Wasm worker (dart2wasm) |
| --- | --- | --- |
| Cold start | 12.3 ms | 16.6 ms |
| Warm dispatch | 0.10 ms | 0.10 ms |
| Prime sieve, round trip | 54.2 ms | 7.1 ms |
| Worker CPU with UI ticks | 183.6 ms | 63.8 ms |
| 1 KiB copy | 0.1 ms | 0.1 ms |
| 1 MiB transfer | 0.6 ms | 0.1 ms |

Reading: dart2wasm is faster on the CPU workload and starts slower. Payload and
warm dispatch costs are the same at this size. This is Chrome only and one run,
so it is a single data point, not a cross-engine result.

## What this comparison does not establish

- Option 2 and option 3 have no measurement in this repository. No shared-memory
  worker has been built or timed. Their costs are unknown here.
- The benchmark measures one workload (a sieve) and one payload size. It says
  nothing about other workloads.
- Memory was read once at the end and only from Chrome, so no memory comparison
  is claimed.

## Decision

Option 1 stays the only shipped design. Option 2 is recorded as a limitation
(limitation 20) and is not added. Option 3 is not pursued: no toolchain evidence
exists for it, and it depends on option 2's deployment cost. Reopening option 2
needs a measured use case that transfers cannot serve, and an ADR.
