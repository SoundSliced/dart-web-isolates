# DWI 0.8.1 — release review (prepared, not published)

Status: **prepared for review, not published.** Patch release for two fixes on
top of 0.8.0. No public API changed; the typed-error contract is the same, and a
missing worker asset now reaches the caller as a `DwiStartupException` instead
of an uncaught page error.

| Package | Version | Upload order |
| --- | --- | --- |
| `dwi_annotations` | 0.8.1 | 1 |
| `dwi_protocol` | 0.8.1 | 2 |
| `dwi_core` | 0.8.1 | 3 |
| `dwi_native` | 0.8.1 | 4 |
| `dwi_web` | 0.8.1 | 5 |
| `dwi_builder` | 0.8.1 | 6 |
| `dwi` | 0.8.1 | 7 |

Upload in that order: the `^0.8.1` constraints must be satisfiable on pub.dev
before the dependent package is uploaded. `dwi` depends on `dwi_annotations`,
`dwi_core`, `dwi_native` and `dwi_web`; `dwi_builder` on `dwi_annotations`;
`dwi_native` and `dwi_web` on `dwi_core`; `dwi_web` also on `dwi_protocol`.

## Fixes

### 1. Missing worker assets settle with a typed failure

A 404 for the worker script (or the Wasm bootstrap, loader or module) used to
raise an uncaught `TypeError` from the worker-error callback, and the caller's
future never completed. The runtime now guards the error details a browser may
omit, so both `Dwi.run` and `DwiWorker.spawn` settle with
`DwiStartupException` and never fall back to another generation or the main
thread.

Measured in Flutter production builds (`flutter build web --release`), at `/`
and `/sub/app/`, in Chrome 157.0.8103.50, Safari 26.5, Firefox 159.0.1 and
Edge 157.0.4341.42: every missing-asset case settled in 2–174 ms against a 30 s
startup deadline, proving the error callback settled the call rather than the
timeout. A present-but-incompatible worker (a script that throws on load) also
settles with `DwiStartupException` in all four engines.

### 2. A `dwi.yaml` created after a first build is detected

The Flutter build hook now declares `dwi.yaml` as a dependency even when the
file is absent. Creating it after a successful build switches the worker target
on the next ordinary build, without editing Dart sources or cleaning. While the
file is absent, Flutter reruns the hook on each build (the missing input is
dirty) and the builder's content hash still skips recompiling an unchanged
worker.

Measured on Flutter 3.47.6 / Dart 3.13.5, release app: js → wasm by creating
the file, wasm → js by editing it, and back to the default js by deleting it,
all through `flutter build web --release`. A `--wasm` host build follows the
same switch.

### 3. `Dwi.close()` keeps the applied configuration

`Dwi.close()` used to forget the configuration along with the backend object:
the next `Dwi.run`, `DwiWorker.spawn` or `Dwi.capabilities` call created a
backend with the compiled-in defaults. A Wasm-configured app that closed the
pool then spawned a handle therefore requested `dwi/worker.dart.js` (404)
instead of `dwi/worker.boot.mjs`. The replacement backend is now configured with
the settings that were in effect, so a teardown cannot change the worker script,
task timeout or worker count. No API change: the behaviour now matches the
documented contract.

This does **not** change the fresh-project ordering gap: a typed-proxy app still
needs one `dart run dwi_builder:dwi build` before its first Flutter build
(ADR-009, `docs/upstream/flutter-web-hook-ordering.md`).

## Test and tooling changes

- `packages/dwi_builder/test/browser_missing_worker_test.dart`: real-browser
  regression for missing JS and Wasm entries, pooled calls and dedicated
  handles.
- `packages/dwi_builder/dart_test.yaml`: `concurrency: 1`, so browser test files
  run sequentially and two Safari suites can share one `dart test` invocation.

## Verification before upload

- `dart analyze` clean for `dwi`, `dwi_builder` and `dwi_web`.
- `dwi`: tests pass, including `close keeps the applied configuration for the
  next call`. `dwi_builder`: 88 tests pass, including every browser suite in all
  four engines. `dwi_web`: 24 tests pass.
- `git diff --check` clean; the tree contains only the release bump.
- Seven `dart pub publish --dry-run` runs must pass before the upload, which is
  a separate, reviewed step. The published-consumer test
  (`tooling/hosted_consumer`) runs after publication, against `0.8.1`, because
  pub.dev must serve the new archives first.
