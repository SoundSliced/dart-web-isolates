# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - unreleased

### Added

- `dwi_annotations` with the `@DwiTask({String? name})` marker.
- `dwi_builder` Flutter web build hook (`hook/build.dart`, ADR-009). With
  `dwi_builder` as a normal dependency, `flutter run -d chrome` and
  `flutter build web` generate and compile the worker automatically; no separate
  DWI command is required. Tested on Flutter 3.47.6.
- `dwi_builder`: analyzer-based discovery of annotated top-level functions,
  deterministic worker/proxy/manifest generation, `dart compile js`
  compilation, SHA-256 content-hash caching, and the
  `build`/`generate`/`check`/`watch`/`clean` CLI.
- `dwi_web` worker runtime (`DwiWorkerRuntime`, `DwiWorkerDispatcher`,
  `DwiWorkerTask`) for generated entrypoints, with VM-testable protocol
  dispatch.
- Typed generated proxies (`DwiTasks.calculatePrimes(input)`) and a generated
  worker manifest.
- Build-time diagnostics `DWI001`–`DWI010` for unsupported signatures,
  duplicate tasks, non-transferable types, non-worker-safe imports and
  compilation failures.
- `examples/automatic_worker`, verified in Chrome.
- `research/R013_RUNTIME_WORKER_COMPILATION.md`, ADR-008 and
  `docs/automatic-workers.md`.
- 20 `dwi_builder` tests, 8 worker-runtime tests, and facade/annotation tests.

### Changed

- `DwiConfig.workerScript` now defaults to `dwi/worker.dart.js`, matching the
  generated artefact; explicit configuration is optional.
- The `DwiTask` typedef is renamed `DwiTaskFunction`; `@DwiTask` is now the
  annotation exported by `package:dwi/dwi.dart`.
- `package:dwi` depends on and re-exports `dwi_annotations`.
- All packages now declare version `0.3.0`.

### Fixed

- Worker-pool callers queued behind a task no longer starve when a worker times
  out, fails to start, or crashes. Termination and failure now hand capacity to
  waiting callers and spawn replacement workers.
- A synchronous `postMessage` failure (for example `DataCloneError`) no longer
  leaves a worker slot permanently busy.
- Non-cloneable payloads (closures, class instances, enums, non-String map keys)
  now fail with `DwiSerializationException` in both directions instead of being
  silently delivered as `{}`.
- `WebBackend.capabilities()` reports `transferables: false`; v0.3 does not
  implement transfer semantics.
- Discovery rejects types that cannot round-trip in v0.3 (`List<int>`,
  `Map<String,int>`, `Set<int>`, classes, enums, `DateTime`, unknown interface
  types) instead of generating a proxy that fails at runtime.
- `dwi build --no-compile` no longer prints a manifest path as if a manifest had
  been written. Documentation now states that the manifest is a compilation
  output.

- `DwiConfig.maxPayloadBytes` is now enforced approximately by the host before
  sending and by the worker for results; oversized payloads fail with
  `DwiSerializationException` instead of crossing the boundary.

### Known limitations (v0.3)

- Plain `flutter build web` now triggers worker generation and compilation when
  `dwi_builder` is a normal dependency and Flutter exposes web build hooks
  (measured on Flutter 3.47.6). Older Flutter versions still need
  `dwi build`/`dwi build --flutter-build`.
- No closures, function tear-offs, `Dwi.run(fn)` or runtime compilation.
- No Wasm worker generation, hot reload of a running worker, or Flutter
  `compute()` integration.
- Only Chrome has been measured.

## [Unreleased]

### Added

- Repository scaffolding, governance documents and the engineering rules in
  `AGENTS.md`.
- Phase 0 evidence base: `docs/current-state-2026.md`, `docs/prior-art.md` and
  research reports R001–R010, grounded in `dart-lang/sdk` @ `e21f9245`, the local
  Flutter SDK, `package:web` 1.1.2, MDN sources and reproducible probes.
- `experiments/dart_worker_poc` (M001): Flutter Web demo comparing CPU work on
  the main thread against a Web Worker, with ticker-based frame measurement,
  headless `?auto=1` mode, raw evidence JSON and an error-propagation probe.
- `M001_FINDINGS.md` with the verdict **PASS WITH LIMITATIONS** (Chrome measured;
  Firefox/Safari/Edge unverified).
- `docs/architecture.md` (ADR-001…007), `docs/api-proposal.md`,
  `docs/protocol.md`, `docs/critical-review.md`, `docs/limitations.md`,
  `docs/compatibility-matrix.md`, `docs/dart-isolate-semantics.md`,
  `docs/serialization.md`, `docs/compiler-strategy.md`,
  `docs/upstream-strategy.md`, `docs/benchmarks.md` and
  `docs/browser-matrix.md`.
- Packages `dwi_protocol`, `dwi_core`, `dwi_native`, `dwi_web` and `dwi`:
  versioned envelopes, typed errors, task registry, isolate backend, pooled
  worker backend with startup/task timeouts, and a conditional-import facade.
- Unit tests for protocol, core, native and facade (29 tests), plus a browser
  integration test that exercises the protocol end to end.
- `examples/fibonacci` and a measured benchmark table.

### Known limitations

- Only Chrome 156 has been measured; Firefox, Safari and Edge remain unverified.
- Named precompiled tasks only; no closures or arbitrary functions.
- JS backend only; no Wasm worker.
- Worker compilation is a separate build step.
- `dart2wasm`, ports, cancellation and pooling policies are proposed, not
  shipped.

<!-- Packages are versioned independently and keep their own CHANGELOG.md. -->
