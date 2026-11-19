# DWI 1.3.0 release notes

Date: 2026-11-19. Additive release. No protocol change.

## What changed

- **Scoped channels and links (ADR-035).** `DwiWorker.withChannel` and
  `DwiWorker.withLink` open a resource before a callback and close it when the
  callback settles. Verified natively in `packages/dwi/test/scoped_channel_link_test.dart`.
- **Typed dedicated worker (ADR-036).** `DwiTasks.withWorker` runs generated typed
  calls on one dedicated worker. The native tasks are registered before the worker
  starts. Verified natively in `packages/dwi_builder/test/generated_integration_test.dart`
  (the call is the first generated dispatch in that program) and in
  `packages/dwi_builder/test/generator_test.dart` (deterministic output).
- **Bounded batch (ADR-034).** `computeParallelBounded` in `dwi_flutter` limits
  submissions per batch. Verified natively in
  `packages/dwi_flutter/test/compute_parallel_bounded_test.dart`, including a peak
  in-flight check. No timing or memory benchmark was run, so no performance claim
  is made.
- **Clean-checkout build docs.** `dart run dwi_builder:dwi build --flutter-build -- --release`
  forwards arguments after `--`, runs the worker build first, and returns Flutter's
  exit code. Read from `packages/dwi_builder/bin/dwi.dart`; an end-to-end Flutter
  build was not run.

- **Served artifact defaults (ADR-037).** Generated proxies apply the build-selected worker
  path and backend. An explicit `Dwi.configure` always wins. Verified natively and in headless
  Chrome (JS backend, custom served path, no configuration):
  `packages/dwi_builder/test/browser_generated_artifact_test.dart`.

## Not in this release

- **Wasm and other browsers.** The Wasm artifact default and Safari, Firefox and Edge are not
  verified for these APIs. `docs/browser-matrix.md` records each engine as unverified.
- **Typed cancellation and batch cancellation** remain out of scope (ADR-034, ADR-036).
- **Pool conflict with a default already dispatched by a non-generated `Dwi.run`** is not
  detected (ADR-037 decision 9).
