# Published-consumer regression fixture

A reproducible version of the disposable `dwi: ^0.5.3` probe recorded in
`docs/browser-matrix.md`, now targeting the published version selected by
`DWI_HOSTED_VERSION` (default `0.6.0`). It is **not** a package test and does not
run against the checkout: every DWI package resolves from pub.dev, with no path
overrides and an isolated `PUB_CACHE`, so a local path dependency cannot silently
satisfy the constraint. It is deliberately kept separate from tests of checkout
code.

## What it does

1. Creates a throwaway Flutter Web app in a scratch directory.
2. Writes a pubspec with hosted `dwi`, `dwi_core`, `dwi_annotations` and
   `dwi_builder` at `^$DWI_HOSTED_VERSION` (and `flutter` from the SDK). No
   `pubspec_overrides.yaml`, no `path` entries.
3. Prints the resolved package versions and asserts every `dwi*` package in
   `pubspec.lock` is `source: hosted` at `https://pub.dev`.
4. Runs the first-build gate (below).
5. Runs `dart run dwi_builder:dwi build`, then builds the app twice: once for
   the site root and once with `--base-href /sub/app/`.
6. Drives Chrome, Safari, Firefox and Edge (via the package's tested browser
   support) against both mounts and validates the page payload.

The fixture page exercises:

| Check | Expected |
| --- | --- |
| generated typed proxy | `DwiTasks.counter(0) == 1` |
| fresh-context calls | `Dwi.runFresh` returns `[1, 1]` |
| scoped handle | `DwiWorker.using` sees `[1, 2]` |
| persistent handle | explicit `spawn`/`close` sees `[1, 2]` |
| channel exchange | send `ping`, receive `echo:ping` |
| typed remote error then success | `DwiRemoteException`, then `echo == ok` |
| worker asset loading | `dwi/worker.dart.js` fetched at the deployment mount |

Results are written as JSON per engine (`root.json`, `sub.json`) in the scratch
directory, with the exact browser version reported by each engine. An engine
that cannot run is recorded as `blocked` with its verbatim reason, never omitted
and never assumed to pass.

## First-build limitation (asserted, not assumed)

- The generated-proxy app imports `lib/dwi_tasks.g.dart` before it exists. The
  first ordinary `flutter build web --release` is **expected to fail** on the
  missing proxy; the fixture then runs `dart run dwi_builder:dwi build` and
  builds again. If the first build ever succeeds, the script exits **2**:
  Flutter's ordering changed and `docs/architecture.md` (ADR-009),
  `docs/limitations.md` and this fixture must be updated. A later successful
  build is never counted as a first-build pass.
- A second, proxy-free app (`Dwi.capabilities()` only, no generated-proxy
  import) must build on the **first** ordinary Flutter command. This is checked
  separately.

## Run

```bash
FLUTTER=/path/to/flutter ./run.sh
```

Inputs: `FLUTTER` (default `flutter`), `DART` (default the sibling `dart` of
`FLUTTER`), `WORK_DIR` (default a new temp directory), `PUB_CACHE` (default
`$WORK_DIR/pub-cache`), `ENGINES` (default `chrome,safari,firefox,edge`),
`DWI_HOSTED_VERSION` (default `0.6.0`; set to `0.5.3` to re-run the historical
baseline, whose page has no `runFresh`/`using` cases).

Prerequisites: Flutter with web build hooks (measured on 3.47.6 / Dart 3.13.5),
network access to pub.dev, and the four engines installed. `safaridriver` ships
with macOS; `DWI_FIREFOX_BINARY` and `DWI_EDGE_BINARY` can point at engines
outside `/Applications`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | All checks passed |
| 2 | The generated-proxy app built on the first command — behaviour changed |
| 3 | A later build failed or did not package the worker |
| 4 | The first build failed for a reason other than the missing proxy |
| 5 | A resolved `dwi*` package is not hosted on pub.dev |
| 6 | An engine payload did not match the expected fixture values |
| other | Setup/environment failure (`flutter create`, `pub get`, probe launch) |

## Notes

- The probe under `probe/` reuses
  `packages/dwi_builder/test/support/browser_probe.dart` through a relative
  import. That keeps CDP/WebDriver handling in one tested place; this tool is
  internal and ships in no package.
- This fixture verifies the **published** version selected by
  `DWI_HOSTED_VERSION`, including `DwiWorker.using` and `Dwi.runFresh` from
  0.6.0. The checkout-consumer matrix remains separate evidence for checkout
  builds.
