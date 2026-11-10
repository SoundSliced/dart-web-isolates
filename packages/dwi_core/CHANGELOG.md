# Changelog

## 0.8.1

- Synchronised release with `dwi` 0.8.1. No API change.

## 0.8.0

- Add `DwiWorkerBackend` (`js`, `wasm`), `DwiConfig.workerBackend`,
  `DwiConfig.defaultWasmWorkerScript` and `DwiCapabilities.workerBackend`
  (ADR-018). The default remains `DwiWorkerBackend.js`; a Wasm worker is
  explicit and never a fallback.

## 0.7.0

- Add `DwiWorkerStop` and the `stopReason`/`stops` members to
  `DwiWorkerHandle` (ADR-017): one terminal reason per context generation and a
  broadcast event per transition. Observation only; no protocol change.

## 0.6.0

- Synchronised release with `dwi` 0.6.0. No code changes.

## 0.5.3

- Synchronised release with the other DWI packages. No code changes.

## 0.5.2

- Add `example/` so usage is documented on the pub.dev Example tab. No code
  changes.

## 0.5.1

- Declare pub.dev `topics` (`isolate`, `concurrency`, `web-worker`, `wasm`) for
  discovery. No code changes.

## 0.5.0

- Platform-independent abstractions for Dart Web Isolates.
- Long-lived worker handles (ADR-013) and DWI-3 channels (ADR-014).
- Protocol v2: rebuild worker artefacts with `dwi build`.

See the repository changelog for the full release notes:
https://github.com/SoundSliced/dart-web-isolates/blob/main/CHANGELOG.md
