# Dart Web Isolates (DWI)

**Background parallel execution for Dart and Flutter Web, with the same
programming model on native.**

Dart web applications have no `dart:isolate`. `Isolate.run`, `Isolate.spawn`,
`SendPort` and `ReceivePort` are unavailable under `dart2js`, `DDC` and
`dart2wasm`, and Flutter's `compute()` therefore runs on the main thread on web.
DWI is an experimental project that investigates closing that gap with browser
Web Workers, a versioned message protocol, and — where it is honest to do so —
an isolate-shaped API.

> **Status: research and proof-of-concept.** DWI is not an isolate
> implementation and does not yet claim semantic parity with `dart:isolate`.
> Read [`docs/limitations.md`](docs/limitations.md) before relying on it.

## What is being proven, in order

| Stage | Question | Artefact |
| --- | --- | --- |
| Phase 0 | What exactly does the current Dart/Flutter web toolchain do with isolates, ports, closures and workers? | `docs/current-state-2026.md`, `research/` |
| M001 | Can compiled Dart run in a worker while Flutter keeps rendering? | `experiments/dart_worker_poc/`, `M001_FINDINGS.md` |
| v0.1 | Can one API map Native → isolate and Web → worker without lying? | `packages/` |

## Repository layout

```text
docs/            vision, architecture, semantic differences, limitations
research/        evidence reports (R001–R010) and research notes
packages/        dwi, dwi_core, dwi_web, dwi_native, dwi_protocol, ...
tooling/         worker compilation, code generation, benchmark runner
experiments/     time-boxed proofs such as M001
examples/        runnable demos
benchmarks/      methodology and measured results
integration_tests/  cross-browser, cross-compiler checks
```

## Quickstart

The proof-of-concept demo (once M001 artefacts exist):

```bash
cd experiments/dart_worker_poc
flutter pub get
dart run tool/build_worker.dart      # compiles worker.dart -> build/web/dwi/worker.js
flutter run -d chrome
```

## Principles

- No shared mutable Dart state across the worker boundary, by default.
- No browser API leaks into the public API unless it is genuinely necessary.
- Web JS and Web Wasm are separate targets and are documented separately.
- Every concurrency claim ships with a reproducible benchmark.
- Semantic gaps against `dart:isolate` are documented, not emulated deceptively.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and the mandatory engineering rules in
[`AGENTS.md`](AGENTS.md). Security reports: [`SECURITY.md`](SECURITY.md).

## Licence

BSD-3-Clause. See [`LICENSE`](LICENSE).
