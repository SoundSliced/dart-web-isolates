# Changelog

## 0.7.0

- Synchronised release with `dwi` 0.7.0; depends on `dwi_annotations ^0.7.0`.
  No public builder API change. The Firefox browser probe now disables every
  per-process sandbox switch the installed build exposes so the ADR-017 matrix
  can run under this host.

## 0.6.0

- Synchronised release with `dwi` 0.6.0. No code changes.

## 0.5.3

- Upgrade `analyzer` to `^14.0.0` (resolved to 14.7.0) and port discovery to
  the analyzer 14 API: `NamedExpression` is now `NamedArgument`, and
  `AnalysisContextCollection` no longer takes `excludedPaths` (discovery already
  filters excluded files before handing paths to the analyzer).
- Discovery results, generated output, diagnostics and the public API are
  unchanged; the suite passes against analyzer 14.7.0.

## 0.5.2

- Add `example/` so usage is documented on the pub.dev Example tab. No code
  changes.

## 0.5.1

- Declare pub.dev `topics` (`isolate`, `concurrency`, `web-worker`, `wasm`) for
  discovery. No code changes.

## 0.5.0

- Build-time discovery, generation and compilation of DWI worker entrypoints.
- Long-lived worker handles (ADR-013) and DWI-3 channels (ADR-014).
- Protocol v2: rebuild worker artefacts with `dwi build`.

See the repository changelog for the full release notes:
https://github.com/SoundSliced/dart-web-isolates/blob/main/CHANGELOG.md
