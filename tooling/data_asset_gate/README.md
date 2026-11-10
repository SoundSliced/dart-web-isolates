# Dependency-hook `DataAsset` gate

Does a **dependency package's** web build hook keep the data assets it declares
through the hooks API bundled for `flutter build web` — on an unmodified SDK and
on the SDK carrying the hook-ordering prototype?

This gate exists because the earlier "asset-only hook" case wrote a file as a
side effect. That proved nothing about a declared `DataAsset`. Here the hook
uses the real API (`output.assets.data.add(DataAsset(...))`) and the gate
asserts the resulting files under `build/web`.

## What it does

Creates a scratch Flutter web app that path-depends on
`fixture/` (name `data_asset_gate_package`), whose `hook/build.dart` declares:

- `data/id1.txt` — a declared asset whose content the gate changes;
- `data/generated.txt` — a file the hook itself generates.

Then, on that one app:

| Case | Required behaviour |
| --- | --- |
| first build | exit 0; both assets present with matching content |
| unchanged rebuild | exit 0; the hook is **not** re-run; the asset stays |
| changed input | exit 0; bundled content follows the new file |
| removed input | build **fails** (no silent success) |
| throwing hook | build **fails**; `dart2js` never starts |

A failing build leaves the previous `build/web` output on disk. The gate reads
exit codes, not file presence, for the failure cases.

## Prerequisites

- A Flutter SDK with web build hooks.
- Dart data assets enabled for that SDK:

  ```bash
  flutter config --enable-dart-data-assets --enable-native-assets
  ```

  The gate checks this and exits 7 rather than changing your config.
- A writable `PUB_CACHE`.

## Run

```bash
FLUTTER=/path/to/flutter PUB_CACHE=/writable/pub-cache ./run.sh
```

Inputs: `FLUTTER` (default `flutter`), `WORK_DIR` (default a new temp
directory), `PUB_CACHE`. Output: per-case lines on stdout and the scratch app.

Exit codes: `0` all cases behaved; `2` asset missing or wrong content; `3`
unchanged rebuild re-ran the hook or lost the asset; `4` changed input not
reflected; `5` removed input did not fail the build; `6` throwing hook did not
fail or the compiler started anyway; `7` data assets not enabled; other values
are environment failures.

## Measured results

3.47.9, macOS arm64, both SDKs (unmodified `c197ca5199e` and the same revision
with [`flutter-web-hook-ordering.patch`](../../docs/upstream/flutter-web-hook-ordering.patch)):
**PASS**, identical on both. Details and assertions:
[`audit/evidence/data-asset-gate-2026-11-10.txt`](../../audit/evidence/data-asset-gate-2026-11-10.txt).

## Scope

- The hook is a **dependency package** hook, which is what the ordering change
  affects. An app-root hook is not covered here; Flutter's own
  `dev/integration_tests/data_asset_app` fixture covers that shape upstream.
- Data assets require the feature flag above on 3.47.x; that is Flutter's
  state, not this gate's.
