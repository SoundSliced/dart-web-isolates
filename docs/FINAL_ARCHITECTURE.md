# DWI 1.0 architecture

This is the architecture as shipped in 1.0. Each decision and its evidence are in
`docs/architecture.md`; this report gives the shape of the system and the index.

## Shape

DWI runs Dart code on a worker, not on the host's isolate, and gives the host a
typed call into that worker. There are three moving parts:

1. **The host facade** (`package:dwi`, class `Dwi`). It chooses a backend, runs
   calls, and reports capabilities, metrics and pool state. Applications import only
   this package and the generated proxy file.
2. **The backends.** The native backend (`dwi_native`) runs each task on a Dart
   isolate. The web backend (`dwi_web`) runs each task in a Web Worker, either
   dart2js or dart2wasm, through a pool or a dedicated handle. The facade selects one
   with a conditional import (ADR-005), so no web code reaches the native build.
3. **The build pipeline** (`dwi_builder`, command `dwi`). It discovers annotated
   tasks, and call sites of `DwiFunctions` (ADR-030), checks their parameter and
   payload types, generates the worker entrypoint and typed proxies, and compiles the
   worker. Generated output is deterministic (AGENTS.md rule 11).

Shared packages: `dwi_core` (configuration, exceptions, metrics, channels, the task
registry), `dwi_protocol` (the envelope format, version 2), `dwi_annotations`
(`@DwiTask`, `@DwiPayload`), and `dwi_flutter` (`computeParallel`).

## Protocol

Messages are versioned envelopes sent by structured clone (ADR-004). Protocol version
2 covers tasks, streams (ADR-022), channels and links (ADR-014, ADR-023), cancellation
and pause (ADR-027, ADR-028). A worker reports its version at startup; a host that
receives a different version, or none, fails the start with a typed error (ADR-026 G3).

## Decisions that define the shape

| Area | Decision | Record |
| --- | --- | --- |
| Scope | Package-first; worker-backed concurrency; no claim of isolate parity | ADR-001, ADR-007 |
| Tasks | Named, precompiled tasks; no closures cross the boundary | ADR-002, ADR-030 |
| Workers | One worker per handle; a shared pool for `Dwi.run` | ADR-003, ADR-024 |
| Boundary | Versioned envelopes over structured clone | ADR-004 |
| Facade | One facade, two backends, conditional imports | ADR-005 |
| Build | Worker compilation is tooling; Flutter web build hooks drive it | ADR-006, ADR-008, ADR-009 |
| Lifecycle | Cancellation, transferable bytes, crash detection; cooperative cancellation; pause and ping | ADR-010, ADR-027, ADR-028 |
| Typed proxies | Generated proxies own dispatch and payload decoding | ADR-011, ADR-020 |
| Queueing | Queue waiting has its own deadline | ADR-012 |
| Handles | Long-lived handles; channels; links; scoped lifetime | ADR-013, ADR-014, ADR-015, ADR-023 |
| Fresh context | `Dwi.runFresh` and termination observation | ADR-016, ADR-017 |
| Wasm | dart2wasm worker is an explicit opt-in build target | ADR-018 |
| Function execution | Research decision on arbitrary functions (separate file) | `docs/adr-019-dwi5-function-execution.md` |
| Payloads | Generated encoders for enums, core values, records and payload classes | ADR-021 |
| Streams | Tasks that return a `Stream` | ADR-022 |
| Idle and draining | Idle worker retirement; draining close | ADR-024 |
| Flutter | `dwi_flutter` and runnable examples | ADR-025 |
| Diagnostics | Metrics, pool state, protocol check, strategy measurements | ADR-026 |
| Several parameters | Tasks with several positional parameters travel as one record | ADR-029 |
| Function references | Annotation-free discovery of `DwiFunctions` call sites; closures no-go | ADR-030 |
| 1.0 | Scope, stability and support matrix | ADR-031 |

## Full ADR index

| ADR | Decision |
| --- | --- |
| ADR-001 | Package-first, worker-backed, no isolate parity claim |
| ADR-002 | Tasks are named and precompiled; no closures cross the boundary |
| ADR-003 | Dedicated worker per handle, pooled by default later |
| ADR-004 | Versioned envelope protocol over structured clone |
| ADR-005 | One facade, two backends, conditional imports |
| ADR-006 | Worker compilation is tooling, not a runtime trick |
| ADR-007 | Preservation of isolate-style semantics, with documented gaps |
| ADR-008 | Automatic build-time worker generation and compilation (v0.3) |
| ADR-009 | Automatic worker builds through Flutter web build hooks (v0.3.1) |
| ADR-010 | v0.4: cancellation, transferable bytes, crash detection |
| ADR-011 | Generated proxies own native dispatch and payload decoding (v0.3.1) |
| ADR-012 | Queue waiting has its own deadline (v0.3.1) |
| ADR-013 | Long-lived worker handles (v0.5) |
| ADR-014 | DWI-3: port-like channels over one handle |
| ADR-015 | Scoped worker lifetime helper |
| ADR-016 | DWI-4 increment 1: fresh-context one-shot execution (`Dwi.runFresh`) |
| ADR-017 | DWI-4 increment 2: handle termination observation |
| ADR-018 | dart2wasm worker backend: explicit opt-in behind a build target |
| ADR-019 | DWI-5 function execution research (`docs/adr-019-dwi5-function-execution.md`) |
| ADR-020 | Registered static functions through generated typed adapters |
| ADR-021 | Generated encoders for enums, core value types, records and payload classes |
| ADR-022 | Tasks that return a `Stream` |
| ADR-023 | Links between two handles (port-like messaging, increment 2) |
| ADR-024 | Idle worker retirement and draining close (lifecycle, increment 1) |
| ADR-025 | Flutter surface: `dwi_flutter` and runnable examples |
| ADR-026 | Diagnostics and architecture decisions |
| ADR-027 | Cooperative cancellation (lifecycle, increment 2) |
| ADR-028 | Pausing dispatch and pinging a worker (lifecycle, increment 3) |
| ADR-029 | Tasks with several positional parameters |
| ADR-030 | Function references without an annotation; closures no-go |
| ADR-031 | Scope and stability of the 1.0 release |

## Known architectural limits

These are stated in `docs/limitations.md`. The main ones: no closures or
`Isolate.run` with closures; no `SendPort` objects; worker state is lost on close,
restart, crash or timeout; a running worker is not replaced on hot reload; the first
build of a fresh typed-proxy Flutter app still needs one pre-build command.
