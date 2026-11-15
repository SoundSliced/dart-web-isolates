# DWI 1.0.0 — release notes

Status: **prepared 2026-11-15; not yet published to pub.dev.** The publication
record is added after each upload is verified on pub.dev.

DWI 1.0.0 is the first stable release. It fixes the supported API and the support
matrix (ADR-031), and it finishes the master plan's tranches A to H. Tranche I
(SDK fork, prototypes, further upstream posting) is deferred by decision and is not
part of 1.0.

## Package versions and upload order

| Package | Version | Upload order |
| --- | --- | --- |
| `dwi_annotations` | 1.0.0 | 1 |
| `dwi_protocol` | 1.0.0 | 2 |
| `dwi_core` | 1.0.0 | 3 |
| `dwi_native` | 1.0.0 | 4 |
| `dwi_web` | 1.0.0 | 5 |
| `dwi_builder` | 1.0.0 | 6 |
| `dwi` | 1.0.0 | 7 |
| `dwi_flutter` | 1.0.0 | 8 |

Upload in that order so every `^1.0.0` constraint is satisfiable on pub.dev before a
dependent package is uploaded.

## Supported API

The stable surface is listed in ADR-031 (`docs/architecture.md`): the `Dwi` facade and
its handle types, `DwiConfig`, the exception types, `DwiTask` and `DwiPayload`, the
generated `DwiTasks` and `DwiFunctions`, `computeParallel` in `dwi_flutter`, and the
`dwi` command line. Breaking changes to that surface need a new major version and an ADR.

## Support matrix

- **Supported and measured:** Dart VM (native); Dart Web JavaScript and Dart/Wasm
  workers; Flutter web (JavaScript) through `dwi_flutter`. The web platforms were
  measured in Chrome, Safari, Firefox and Edge on macOS 26.5.1 arm64.
- **Not supported in 1.0:** mobile browsers and other operating systems (not
  measured); Flutter native (not run); closures and `Isolate.run` with closures
  (recorded no-go, ADR-030); `SendPort` objects (not implemented).

The full per-feature table is `docs/compatibility-matrix.md`.

## What 1.0 adds to 0.11.0

- `dartdoc` on every exported member of `dwi` and `dwi_core`.
- `DwiConfig.requireWorkerScript` refuses `blob:`, `data:` and `javascript:` worker
  URLs with a typed startup error (critical review S9, ADR-006). Applications that
  pass one of these URLs now fail at start; they must serve the worker as a file.
- The compatibility matrix with five platform columns.
- The final reports: `docs/FINAL_IMPLEMENTATION_REPORT.md`,
  `docs/FINAL_ARCHITECTURE.md`, `docs/FINAL_BROWSER_MATRIX.md`,
  `docs/FINAL_BENCHMARK_REPORT.md`, `docs/FINAL_SECURITY_REVIEW.md`,
  `docs/FINAL_SDK_FEASIBILITY_REPORT.md`, and `docs/UPSTREAM_PROPOSAL.md`.
- Status updates: every objective in `docs/IMPLEMENTATION_STATUS.md` is complete,
  complete with limitations, SDK-dependent, superseded, or the closure no-go.
  None is partial or open.

## Upgrade notes

- No API from 0.11.0 is removed or changed in signature.
- Worker files and the protocol are unchanged (protocol version 2). Rebuild worker
  artefacts with `dart run dwi_builder:dwi build`.
- If a worker URL was a `blob:`, `data:` or `javascript:` URL, serve it as a file
  under the application's origin.

## Limits that apply to 1.0

- Heap growth is visible only in Chromium.
- The strict CSP measurement covers same-origin workers only; `blob:` workers are not
  measured and are refused.
- The Wasm worker was compared with the JS worker in Chrome only, in one run.
- The duplicate-reply branch is unreachable through the public API.
- The first build of a fresh typed-proxy Flutter app needs one pre-build command
  (limitation 7).
- A running worker is not replaced on hot reload (limitation 16).

The full list is `docs/limitations.md`. The security review does not replace an
external audit (`docs/FINAL_SECURITY_REVIEW.md`).

## Verification

Format, analyze (`--fatal-infos`) and the full test suite are run on the 1.0.0
release commit. The results are recorded in `audit/evidence/pub-1.0.0-upload-*.txt`
when the upload is made.

## Publication

Pending. Each package will be uploaded with `dart pub publish --force` in the order
above, checked on pub.dev before the next upload, and recorded in the evidence file.
