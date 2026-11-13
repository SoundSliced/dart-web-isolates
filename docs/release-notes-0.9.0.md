# DWI 0.9.0 — release review

Status: **prepared for publication (2026-11-13).** Minor release with three
additive features and two fixes. Existing APIs, protocol v2 and the generated
code for previously supported types are unchanged. Rebuild worker artefacts
with `dart run dwi_builder:dwi build`.

| Package | Version | Upload order |
| --- | --- | --- |
| `dwi_annotations` | 0.9.0 | 1 |
| `dwi_protocol` | 0.9.0 | 2 |
| `dwi_core` | 0.9.0 | 3 |
| `dwi_native` | 0.9.0 | 4 |
| `dwi_web` | 0.9.0 | 5 |
| `dwi_builder` | 0.9.0 | 6 |
| `dwi` | 0.9.0 | 7 |

Upload in that order so every `^0.9.0` constraint is satisfiable on pub.dev
before a dependent package is uploaded.

## Features

### Registered static functions (ADR-020)

`DwiFunctions.run(fn, input)` and `run0(fn)`, in the generated file, select an
annotated top-level, class-static or enum-static task by its tear-off and call
its existing typed proxy. No function is sent to a worker. Unregistered
functions, closures and instance tear-offs fail with `DwiUnknownTaskException`
before startup; an incompatible caller signature fails with
`DwiUnsupportedException`.

### Payload types (ADR-021)

Task inputs and results may be public enums, `DateTime`, `Duration`, `BigInt`,
`Uri`, records and classes annotated with the new `@DwiPayload()`, alone or in
typed collections. A record input is the supported way to pass several values
that a closure would have captured. A payload class is rebuilt from its
constructor parameters; identity, other state and subtype are not preserved.

### Stream tasks (ADR-022)

A task may return `Stream<T>`. `DwiTasks.task(input)` returns a typed stream,
`Dwi.runStream` is the name-based form and `DwiFunctions.stream`/`stream0`
select by function. Each listen runs in a fresh context with credit-based flow
control; cancelling terminates it.

## Fixes

- **Silent discovery gaps (ADR-020 audit).** Every `@DwiTask` placement that
  is not a supported task — extension and extension-type members, enum
  instance methods and constants, constructors, fields, local functions,
  parameters, annotated type declarations — and every `external` task is now a
  `DWI003` build error. Previously they were ignored without a diagnostic.
- **Cancelling a starting call (web).** Cancelling a pooled call while its
  worker was still starting returned `false` and the task then ran. It is now
  cancelled with `DwiCancelledException`, nothing is sent, and the started
  worker serves the next call. Found by the first four-engine lifecycle run
  (Safari), reproduced in Chrome.

## Documentation corrections

- ADR-014 decision 5 described delayed acknowledgements; the code rejects a
  send when the receive buffer is full. The ADR now says so.
- README status and the "not in 0.7.0" wording for the Wasm worker backend
  were stale and are corrected.
- The master plan, engineering handoff and zero-boilerplate addendum are now in
  `docs/`, with `IMPLEMENTATION_STATUS.md` and `completion-plan.md`.

## Verification before upload

- `dart analyze` clean for all seven packages; package tests pass: annotations
  3, protocol 14, core 35, native 62, web 24, dwi 39.
- `dwi_builder`: discovery, generator, integration, native, build and browser
  suites pass.
- Browser/compiler matrices, all four host/worker compiler pairs in Chrome
  157.0.8103.78, Safari 26.5, Firefox 160.0 and Edge 157.0.4341.46 (48 of 48
  cells), with stamped evidence whose source hashes match the release tree:
  `stream-tasks-acceptance-2026-11-13T012032.json`,
  `payload-types-acceptance-2026-11-13T012032.json`,
  `dwi5-static-acceptance-2026-11-13T012032.json`.
- Pool lifecycle contract in all four engines:
  `pool-lifecycle-four-engines-2026-11-11T220557.json`.
- Seven `dart pub publish --dry-run` runs: 0 warnings (hints are the local
  `pubspec_overrides.yaml` path overrides, which pub ignores on upload).

## Not in this release

Port objects, cooperative cancellation, CI and the remaining 1.0 gates
(`docs/completion-plan.md`). No compatibility level is raised.
