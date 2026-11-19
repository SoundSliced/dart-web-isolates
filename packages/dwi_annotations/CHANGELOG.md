# Changelog

## 1.2.0

- Version aligned with the 1.2.0 release; no API change in this package.

## 1.1.1

- Documentation: the pub.dev README shows the basic and advanced examples inline, so the features can be read without running the example files.

## 1.1.0

- Version 1.1.0 with the other packages. No behaviour change in this package.

## 1.0.0

- Version 1.0.0: the stable API of this package; see `docs/release-notes-1.0.0.md`. No behaviour change in this package at 1.0.0.

## 0.11.0

- Version bump to match 0.11.0. No behaviour change in this package.

## 0.10.0

- Version bump to match 0.10.0. No API change.

## 0.9.0

- Add `@DwiPayload()` for classes that may cross the worker boundary
  (ADR-021).
- Document that unsupported `@DwiTask` placements are build errors and that
  static methods of public non-generic enums are tasks.

## 0.8.1

- Synchronised release with `dwi` 0.8.1. No API change.

## 0.8.0

- Synchronised release with `dwi` 0.8.0. No API change.

## 0.7.0

- Synchronised release with `dwi` 0.7.0. No code changes.

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

- Annotations for declaring Dart Web Isolates worker tasks.
- Long-lived worker handles (ADR-013) and DWI-3 channels (ADR-014).
- Protocol v2: rebuild worker artefacts with `dwi build`.

See the repository changelog for the full release notes:
https://github.com/SoundSliced/dart-web-isolates/blob/main/CHANGELOG.md
