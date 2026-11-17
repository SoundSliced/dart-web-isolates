# DWI 1.0 browser matrix

This summarises `docs/browser-matrix.md`, which holds every measurement and its
method. Each cell reports a result from one engine; nothing is copied between
engines (AGENTS.md rules 7 and 8).

## Platform

- macOS 26.5.1, Apple M2 (arm64), 8 cores (`navigator.hardwareConcurrency` = 8).
- Chrome 157.0.8103.78, Safari 26.5, Firefox 160.0, Edge 157.0.4341.60.
- Dart 3.15.0-133.0.dev built the pages. Flutter appears only in the two Flutter
  examples, which were built with Flutter 3.50.0.
- **No other operating system, architecture or device was measured.** Mobile
  browsers were run only as the reduced probe in `audit/evidence/mobile-probes-2026-11-17.txt`
  (iOS Safari on the iOS 26.5 simulator, Chrome 124 on an Android emulator). No
  other result here applies to mobile.

## What is measured in four engines

| Area | Result | Evidence |
| --- | --- | --- |
| Cold start, warm dispatch, payloads 1 KiB to 100 MiB | all passes correct | `audit/evidence/browser-matrix-extended-four-engines-2026-11-14.json` |
| Cancellation and late replies | late reply correct on every pass | same file; `docs/browser-matrix.md` (late reply) |
| Workloads: sort, JSON, Adler-32, run-length, box blur | checksums match the main thread | same file; `docs/benchmarks.md` |
| Pool sizing, `maxWorkers` 1, 2, 4, 8 | correct on every pass; near-linear to 4 | same file; `docs/browser-matrix.md` (pool sizing) |
| 1,000-task burst and 20×100 leak run | all results correct; heap growth only where `performance.memory` exists | `docs/browser-matrix.md` (burst, leak and payload range) |
| Metrics and pool state (ADR-026) | correct | `audit/evidence/metrics-pool-state-four-engines-2026-11-14.json` |
| Worker strategies and protocol check (ADR-026 G3, G6) | correct | `audit/evidence/worker-strategies-and-protocol-check-2026-11-14.json` |
| Flutter web counter and jank demo (ADR-025) | correct; main-thread blocks measured | `audit/evidence/flutter-counter-four-engines-2026-11-14.json`; `audit/evidence/flutter-jank-demo-four-engines-2026-11-14.json` |
| Strict same-origin CSP, inline-script control blocked | pass in every engine, three passes | `audit/evidence/browser-matrix-csp-2026-11-14.json` |
| Payload types, 16 cells (JS and Wasm host and worker, four engines) | pass | `packages/dwi_builder/test/browser_payload_types_test.dart` |
| Multi-parameter tasks (ADR-029), 16 cells | pass | `packages/dwi_builder/test/browser_multi_parameter_test.dart` |
| Cooperative cancellation (ADR-027) and pause and ping (ADR-028), 16 cells each | pass | `docs/architecture.md` ADR-027, ADR-028 |

## Limits

- **Heap growth** is visible only in Chromium (`performance.memory`). The leak run
  checks that every result is correct; it does not prove the absence of a leak in
  Safari or Firefox.
- **Strict CSP** covers same-origin scripts and workers only. A `blob:` worker needs
  `worker-src blob:`, which is weaker and is not measured. DWI refuses blob, data
  and javascript worker URLs (`DwiConfig.requireWorkerScript`).
- **Wasm versus JS** was compared in Chrome only, in one run. The comparison is in
  `docs/wasm-worker-comparison.md`.
- **Timers** in Safari and Firefox round to whole milliseconds at small sizes, so
  rows under about 3 ms are not comparable between engines.
- **Duplicate replies** cannot be produced through the public API on any backend,
  so they are not tested.

## Not measured

- Mobile browsers beyond the reduced probe (other devices, other engines).
- Windows, Linux and any other operating system.
- Flutter native beyond the reduced probe on iPhone 15 and an Android emulator
  (desktop and other mobile targets).
- Engines beyond the four above.

## Conclusion for 1.0

For the four desktop engines on macOS arm64, every shipped level passes every
recorded check. Every other platform is listed as not measured in
`docs/compatibility-matrix.md`, and the 1.0 release notes say so.
