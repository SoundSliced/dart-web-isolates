# DWI 0.10.0 — release review

Status: **prepared 2026-11-14; not yet published to pub.dev.** The upload needs a
pub.dev login on the maintainer's machine (see "Publication" below). Minor release
with additive features only. Existing APIs, protocol version 2 and the generated
code for previously supported types are unchanged. Rebuild worker artefacts with
`dart run dwi_builder:dwi build`.

| Package | Version | Upload order |
| --- | --- | --- |
| `dwi_annotations` | 0.10.0 | 1 |
| `dwi_protocol` | 0.10.0 | 2 |
| `dwi_core` | 0.10.0 | 3 |
| `dwi_native` | 0.10.0 | 4 |
| `dwi_web` | 0.10.0 | 5 |
| `dwi_builder` | 0.10.0 | 6 |
| `dwi` | 0.10.0 | 7 |
| `dwi_flutter` | 0.10.0 | 8 (new package) |

Upload in that order so every `^0.10.0` constraint is satisfiable on pub.dev
before a dependent package is uploaded.

## Features

- **Links, idle retirement, draining close, cooperative cancellation, pause,
  resume and ping** (ADR-023, ADR-024, ADR-027, ADR-028). See the root changelog.
- **`computeParallel`** in the new package `dwi_flutter` (ADR-025), with two
  runnable Flutter examples.
- **`Dwi.metrics()`** with `DwiConfig(metrics: true)` (ADR-026 G1), off by default.
- **`Dwi.poolState()`** (ADR-026 G2).

## Fixes and hardening

- The host checks the protocol version in a worker's `ready` message and fails
  the startup on a mismatch (ADR-026 G3).
- Packages formatted with `dart format`; CI added (format, analyze, VM tests).

## Measured

- Browser matrix in Chrome, Safari, Firefox and Edge, three passes: burst, leak,
  payloads 1 KiB to 100 MiB, strict CSP, late replies, workloads, pool sizing,
  metrics and pool state, worker-use strategies. See `docs/browser-matrix.md`.
- Flutter examples in the same four engines. See `docs/browser-matrix.md`.
- Tree-shaking probe for seven annotated shapes at dart2js `-O1`, `-O2`, `-O4`
  (`tooling/tree_shaking_probe`).

## Known limits

- Startup time and copied-input size are not in `DwiMetrics`.
- Native `Dwi.run` uses one isolate per call, with no queue.
- Hot restart does not replace workers (ADR-026 G5).
- Flutter's `compute()` on web blocks frames for its whole work in the measured
  build (`docs/browser-matrix.md`).
- Windows, Linux, Android and iOS are not measured.

## Publication

Pub.dev upload needs `dart pub login` on the maintainer's machine. Run, for each
package in the order above:

```bash
cd packages/<package>
dart pub publish
```

Dry runs pass for all eight packages. `dwi_flutter` needed its LICENSE, README and
CHANGELOG, which are now present. The root `README.md` still states the 0.9.0
publication until the upload is done.
