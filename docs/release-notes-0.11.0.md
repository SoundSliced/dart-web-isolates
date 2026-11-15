# DWI 0.11.0 — release notes

Status: **prepared 2026-11-15; publication recorded in the section "Publication"
below once the upload is verified on pub.dev.** Minor release with additive
features only. Existing APIs, protocol version 2 and the generated code for
previously supported single-parameter tasks are unchanged. Rebuild worker
artefacts with `dart run dwi_builder:dwi build`.

This is not 1.0. The 1.0 gates in `docs/completion-plan.md` (section 4) and the
`FINAL_*` reports are still open.

| Package | Version | Upload order |
| --- | --- | --- |
| `dwi_annotations` | 0.11.0 | 1 |
| `dwi_protocol` | 0.11.0 | 2 |
| `dwi_core` | 0.11.0 | 3 |
| `dwi_native` | 0.11.0 | 4 |
| `dwi_web` | 0.11.0 | 5 |
| `dwi_builder` | 0.11.0 | 6 |
| `dwi` | 0.11.0 | 7 |
| `dwi_flutter` | 0.11.0 | 8 |

Upload in that order so every `^0.11.0` constraint is satisfiable on pub.dev
before a dependent package is uploaded.

## Features

- **Tasks with several positional parameters** (ADR-029). A task with two or
  more required positional parameters is sent as one record. The generated proxy
  keeps the separate parameters, for example `Future<int> add(int left, int
  right)`. Named, optional and generic parameters are still rejected.
- **Functions named to `DwiFunctions` need no annotation** (ADR-030). A top-level
  or static function of this package passed to `DwiFunctions.run`, `run0`,
  `stream` or `stream0` is discovered as a task. Closures are not supported; they
  produce a `DWI003` warning. This is a recorded decision, not a limitation to be
  fixed in the package (it needs an SDK change, tranche I).

## Verification

- Format, analyze (`--fatal-infos`) and VM tests pass for all eight packages.
  Test counts: `dwi_annotations` 3, `dwi_protocol` 14, `dwi_core` 41, `dwi_native`
  72, `dwi_web` 30, `dwi_builder` 152, `dwi` 56, `dwi_flutter` 5.
- `dwi_builder` browser tests run serially (`dart test -j 1`), because Safari
  accepts one WebDriver session at a time.
- Multi-parameter tasks: native, dart2js, and four browser engines across JS and
  Wasm hosts and workers (`test/browser_multi_parameter_test.dart`).
- Function references: native, dart2js and dart2wasm
  (`test/function_reference_discovery_test.dart`).
- GitHub CI on `main` passed for the previous release commit.

## Known limits

- Strict CSP is measured in Chrome only (`audit/evidence/browser-matrix-csp-2026-11-14.json`).
- Heap-growth checks are available only where `performance.memory` exists.
- No mobile browser has been measured.
- No Flutter native run.
- The closure experiment is recorded as a no-go (ADR-030).

## Publication

Pending. The upload will use `dart pub publish --force` from each package, in the
order above, with a maintainer login listed as an uploader on each existing
package. Each version is checked on pub.dev before the next upload.
