# Changelog

## 1.3.0

- Version aligned with the 1.3.0 release; no API change in this package.

## 1.2.0

- Version aligned with the 1.2.0 release; no API change in this package.

## 1.1.1

- Documentation: the pub.dev README shows the basic and advanced examples inline, so the features can be read without running the example files.

## 1.1.0

- Version 1.1.0 with the other packages. No behaviour change in this package.

## 1.0.0

- Worker URLs of the `blob:`, `data:` and `javascript:` kinds are refused at start
  (through `DwiConfig.requireWorkerScript`, ADR-006). Version 1.0.0 is the stable API.

## 0.11.0

- Version bump to match 0.11.0. No behaviour change in this package.

## 0.10.0

- Checks the protocol version in the worker's `ready` message and fails the
  startup on a mismatch (ADR-026 G3, `protocol_check.dart`).
- Reports the shared pool through `DwiPoolInspector` (ADR-026 G2).
- Cooperative cancellation (ADR-027), idle retirement and draining close
  (ADR-024), links (ADR-023) and `ping` (ADR-028), as listed in the root
  changelog.

## 0.9.0

- Fix: cancelling a pooled call while its worker is still starting now
  cancels it (`DwiCancelledException`) instead of returning `false` and
  letting the task run.

## 0.8.1

- Report missing JS or Wasm worker assets as typed startup failures for pooled
  calls and dedicated handles, even when the browser omits error details.

## 0.8.0

- Load a Wasm worker as a module worker, report the observed worker backend and
  reject a requested/observed mismatch with `DwiStartupException` (ADR-018).
- Treat an in-band bootstrap startup error as a typed startup failure.
- Normalize integral doubles in channel meta (`gen`, `seq`) on the worker and
  host sides, as a dart2wasm boundary yields.

## 0.7.0

- Record and publish the terminal stop reason for a dedicated worker (ADR-017),
  including an idle heartbeat failure that no call observed.
- `close()` queues the final `stops` event and completion instead of awaiting a
  subscriber, so a paused listener cannot hold teardown.

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

- Browser DWI backend backed by dedicated Web Workers.
- Long-lived worker handles (ADR-013) and DWI-3 channels (ADR-014).
- Protocol v2: rebuild worker artefacts with `dwi build`.

See the repository changelog for the full release notes:
https://github.com/SoundSliced/dart-web-isolates/blob/main/CHANGELOG.md
