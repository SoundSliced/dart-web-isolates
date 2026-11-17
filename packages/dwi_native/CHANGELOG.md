# Changelog

## 1.1.0

- Version 1.1.0 with the other packages. No behaviour change in this package.

## 1.0.0

- Version 1.0.0: the stable API of this package; see `docs/release-notes-1.0.0.md`. No behaviour change in this package at 1.0.0.

## 0.11.0

- Version bump to match 0.11.0. No behaviour change in this package.

## 0.10.0

- Reports the running calls through `DwiPoolInspector` (ADR-026 G2).
- Cooperative cancellation (ADR-027), idle retirement and draining close
  (ADR-024), and `ping` (ADR-028), as listed in the root changelog.

## 0.9.0

- Synchronised release with `dwi` 0.9.0. No API change.

## 0.8.1

- Synchronised release with `dwi` 0.8.1. No API change.

## 0.8.0

- Synchronised release with `dwi` 0.8.0. No API change.

## 0.7.0

- Record and publish the terminal stop reason for a dedicated isolate
  (ADR-017), including an idle exit that no call observed.
- `close()` queues the final `stops` event and completion instead of awaiting a
  subscriber, so a paused listener cannot hold teardown.

## 0.6.0

- Synchronised release with `dwi` 0.6.0. No code changes.

## 0.5.3

- Lengthen the package description so pub.dev's analysis accepts it. No code
  changes.

## 0.5.2

- Add `example/` so usage is documented on the pub.dev Example tab. No code
  changes.

## 0.5.1

- Declare pub.dev `topics` (`isolate`, `concurrency`, `web-worker`, `wasm`) for
  discovery. No code changes.

## 0.5.0

- Native DWI backend backed by real Dart isolates.
- Long-lived worker handles (ADR-013) and DWI-3 channels (ADR-014).
- Protocol v2: rebuild worker artefacts with `dwi build`.

See the repository changelog for the full release notes:
https://github.com/SoundSliced/dart-web-isolates/blob/main/CHANGELOG.md
