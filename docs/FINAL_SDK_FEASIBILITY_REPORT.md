# DWI 1.0 SDK feasibility report

This report answers one question for 1.0: which parts of `dart:isolate` semantics
can a package provide on the web without changing the Dart SDK, and which need the
SDK. It draws on `research/R016_DWI5_FUNCTION_FEASIBILITY.md`,
`docs/adr-019-dwi5-function-execution.md`, ADR-002 and ADR-030 in
`docs/architecture.md`, and `docs/upstream/dwi-function-lowering.md`.

## Conclusion

A package can deliver named tasks, typed proxies, registered static functions,
streams, handles, channels, cancellation and pools on the web, with the limits in
`docs/limitations.md`. It cannot deliver closures, `Isolate.run` with a closure, or
`SendPort` objects. Those three need changes to the compiler or the SDK, and DWI
does not make them.

## Feature by feature

| Feature | Package can do it? | Why | Decision |
| --- | --- | --- | --- |
| Named tasks (`Dwi.run` with a name) | yes | Static references; no code crosses the boundary (ADR-002) | shipped |
| Typed proxies and registered static functions | yes | Generated adapters bind a name to a static function (ADR-020) | shipped |
| Function references without annotation | yes, for top-level and static functions of the package | The build sees the call site and the declaration (ADR-030) | shipped 0.11.0 |
| Closures passed to `DwiFunctions` or `Dwi.run` | **no** | A closure has no name the worker can bind to; its identity is not stable across the boundary; the build cannot rewrite the call site before compilation (R016) | recorded no-go (ADR-030) |
| `Isolate.run` with a closure | **no** | Same reason as closures | SDK (tranche I) |
| `Isolate.run` with a named task | yes | Named form only (ADR-002) | shipped |
| `Isolate.spawn` | partly | One dedicated worker per handle; no heap sharing (ADR-013) | shipped with limits |
| `Isolate.spawnUri` | no | A second program means a second compilation (R002 §4) | not planned |
| `SendPort` / `ReceivePort` objects | no | `MessagePort` is transferable once, not cloneable; emulation would be a new protocol (R001 §3, R003 §5) | not implemented; limitation 3 |
| Message as an arbitrary object graph | no | Structured clone loses prototypes and rejects functions (R001 §4) | limitation 2 |
| Typed data transfer | yes | Transferable bytes, detached on the sender (ADR-010) | shipped |

## Why closures stay a no-go

- The worker must run the same code the host names. A closure is created at run
  time, so the worker has no table entry for it.
- Serialising a closure requires the closure's code and captured state, which the
  web's structured clone cannot carry.
- Rewriting the call site needs a build phase that runs before the compiler resolves
  the call (R016). No supported build phase offers that.
- The annotation-free discovery of ADR-030 covers statically named functions, which
  is the part the build can see. It is not an approximation of closures.

The no-go is recorded with its probe: a closure passed to `DwiFunctions` produces a
discovery warning and no task (`packages/dwi_builder/test/function_reference_discovery_test.dart`).
A closure that reaches the runtime fails with `DwiUnknownTaskException`, as
limitation 8 in `docs/limitations.md` states; that runtime path is not separately tested.

## What would change the answer

- A compiler or build-contract change that gives a build phase the resolved call
  sites before compilation (DWI-5, via tranche I).
- A web-compatible closure serialisation format with a stable identity, which the
  SDK would need to provide.

Neither exists today. DWI-5 and DWI-6 are not raised by this report.

## Upstream

DWI's SDK requests are summarised in `docs/UPSTREAM_PROPOSAL.md`. Two comments are
posted on dart-lang/sdk#56512. No SDK fork has been made, and no prototype has been
built, by decision (maintainer, 2026-11-15).

## Verified, not verified, could not determine

- **Verified:** the no-go probes above; the named-task and annotation-free paths on
  dart2js and dart2wasm.
- **Not verified:** any SDK change; a closure serialisation format.
- **Could not determine:** whether a future SDK exposes resolved call sites to a
  build phase.
