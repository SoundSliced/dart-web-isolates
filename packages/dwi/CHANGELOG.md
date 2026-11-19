# Changelog

## 1.3.0

- Adds `DwiWorker.withChannel` and `DwiWorker.withLink`: channels and links opened
  before a callback and closed when it settles (ADR-035). Explicit `openChannel`,
  `link` and `close()` are unchanged.
- Adds `DwiTasks.withWorker` to the generated proxy, a typed dedicated-worker entry
  (ADR-036). Generated code requires `dwi_builder` 1.3.0.

## 1.2.0

- Scoped ports: `Dwi.withPort` (host-only) and `DwiWorker.withPort` (bound to the handle) create a port for one callback and close it on every exit path (ADR-033). Requires `dwi_core` 1.2.0.

## 1.1.1

- Documentation: the pub.dev README shows the basic and advanced examples inline, so the features can be read without running the example files.

## 1.1.0

- Named ports: `Dwi.createPort`, `Dwi.port`, `DwiWorker.bindPort` (ADR-032).

## 1.0.0

- Version 1.0.0: the stable API of this package; see `docs/release-notes-1.0.0.md`. No behaviour change in this package at 1.0.0.

## 0.11.0

- Version bump to match 0.11.0. No behaviour change in this package.

## 0.10.0

- `Dwi.metrics()`, `Dwi.poolState()` and `DwiConfig(metrics: true)` (ADR-026
  G1, G2).
- Pause, resume and ping (ADR-028), cooperative cancellation (ADR-027), draining
  close and idle retirement (ADR-024), and links (ADR-023), as listed in the root
  changelog.

## 0.9.0

- Add `Dwi.runStream` for tasks that return `Stream<T>` (ADR-022) and
  re-export `DwiStreamTask`.
- Pick up the `dwi_web` fix for cancelling a pooled call while its worker is
  still starting.

## 0.8.1

- Pick up `dwi_web` 0.8.1: a missing worker asset now settles `Dwi.run` and
  `DwiWorker.spawn` with `DwiStartupException` instead of an uncaught page
  error.
- `Dwi.close()` keeps the applied `DwiConfig`. The next call gets a fresh
  backend configured with the same settings instead of silently falling back to
  the defaults (for example the JS worker script in a Wasm-configured app).

## 0.8.0

- Re-export `DwiWorkerBackend` and support the opt-in Wasm worker backend
  (ADR-018). The default remains the dart2js worker.

## 0.7.0

- Add `DwiWorker.stopReason` and `DwiWorker.stops` (ADR-017): observe why a
  dedicated handle's context stopped, including an idle crash that no call
  observed. One broadcast event per generation, first terminal cause wins, no
  replay, and a queued timeout or remote task error emits nothing. This is
  observation only; typed call, channel and startup errors are unchanged.
- `close()` no longer waits for a stop listener to process the final event. A
  paused or slow subscriber cannot hold teardown; it receives the event before
  `done` when it resumes.

## 0.6.0

- Add `DwiWorker.using` (ADR-015): spawns one dedicated handle, awaits a
  `FutureOr<R>` callback, and closes that handle on every path. Spawn failures
  propagate unchanged; closing the handle inside the callback is allowed
  because `close()` is idempotent. The helper does not wait for unawaited work.
- Add `Dwi.runFresh` (ADR-016): runs exactly one task in a fresh dedicated
  context and closes it before completing, so no worker-local state is shared
  between calls on native or web. `Dwi.run` keeps its pooled semantics.
- When the callback and `close()` both fail, the callback error remains the
  returned future's error (same object) and the cleanup failure is appended to
  its stack trace. It is no longer reported as an uncaught zone error, which
  failed ordinary calls and plain tests.
- Requires the other DWI packages at `^0.6.0`.

## 0.5.3

- Synchronised release with the other DWI packages. No code changes.

## 0.5.2

- Add `example/` so usage is documented on the pub.dev Example tab. No code
  changes.

## 0.5.1

- Declare pub.dev `topics` (`isolate`, `concurrency`, `web-worker`, `wasm`) for
  discovery. No code changes.

## 0.5.0

- Isolate-like background execution for Dart and Flutter Web.
- Long-lived worker handles (ADR-013) and DWI-3 channels (ADR-014).
- Protocol v2: rebuild worker artefacts with `dwi build`.

See the repository changelog for the full release notes:
https://github.com/SoundSliced/dart-web-isolates/blob/main/CHANGELOG.md
