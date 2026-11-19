# Changelog

## 1.3.0

- Version aligned with the 1.3.0 release; no API change in this package.

## 1.2.0

- Scoped ports (ADR-033): a worker stop or failure now fails a port binding even while the host listener is paused. `DwiPortEndpoint.attach` takes the handle's stop stream.

## 1.1.1

- Documentation: the pub.dev README shows the basic and advanced examples inline, so the features can be read without running the example files.

## 1.1.0

- Named port core: `DwiPort`, `DwiPortBinding`, `DwiPortEndpoint` (ADR-032). Internal to the package boundary.

## 1.0.0

- Refuses `blob:`, `data:` and `javascript:` worker URLs with a typed startup error
  (`DwiConfig.requireWorkerScript`, ADR-006). Version 1.0.0 is the stable API.

## 0.11.0

- Version bump to match 0.11.0. No behaviour change in this package.

## 0.10.0

- `DwiConfig(metrics: true)`, `DwiMetrics`, `DwiPoolState`, `DwiPoolWorker` and
  the optional `DwiPoolInspector` interface (ADR-026 G1, G2).
- Earlier unreleased work in this package, from ADR-023 to ADR-028: link and
  stream types, idle retirement and draining close, cooperative cancellation
  through `cancelGracePeriod`, and ping and pause.

## 0.9.0

- Add `DwiStreamTask`, the worker-side half of stream tasks (ADR-022).

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
