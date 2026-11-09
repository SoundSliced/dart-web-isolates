# Changelog

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
