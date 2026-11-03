# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
