# Fresh typed-proxy build gate

A small, reproducible case for the Flutter build-graph ordering gap recorded in
[ADR-009](../../docs/architecture.md) and
[limitations item 7](../../docs/limitations.md). It is not a package test and is
not part of any dependency graph.

## What it does

Creates a new Flutter web app in a scratch directory, gives it path dependencies
on `dwi`, `dwi_annotations` and `dwi_builder`, and makes `lib/main.dart` import
the generated proxy `dwi_tasks.g.dart` **before that file exists**. Then it runs
the ordinary command twice:

1. `flutter build web --release` — expected to fail, because Flutter can start
   `dart2js` before the web `build_hooks` target writes the proxy;
2. the same command again — expected to succeed and package
   `build/web/dwi/worker.dart.js`.

## Prerequisites

- Flutter with web build hooks (measured on 3.47.6 stable, Dart 3.13.5).
- A writable pub cache. If the default cache is read-only, point `PUB_CACHE` at
  a writable directory whose `hosted` entry symlinks the real hosted cache.

## Run

```bash
FLUTTER=/path/to/flutter PUB_CACHE=/writable/pub-cache ./run.sh
```

Inputs: `FLUTTER` (default `flutter`), `WORK_DIR` (default a new temp directory),
`PUB_CACHE`. Outputs: the scratch app and both build logs on stdout.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Reproduced: first build failed on the missing proxy, second build succeeded and packaged the worker |
| 2 | The first build succeeded — Flutter's ordering changed; re-measure and update the docs |
| 3 | The second build failed or did not package the worker |
| 4 | The first build failed for a different reason |
| other | `flutter create` or the environment failed |

## Why the first build fails (source-verified)

- `Dart2WebTarget.dependencies` is
  `[WebEntrypointTarget(), GenerateLocalizationsTarget()]`
  (`flutter_tools/lib/src/build_system/targets/web.dart`): the web `BuildHooks`
  target is not a dependency of the compiler.
- `BuildHooks` is a dependency of `LinkHooks`, and `LinkHooks` takes the compile
  targets as `extraDependencies` (`web.dart`,
  `native_assets.dart`): hooks feed linking, after compilation.
- A build hook's only declared output is
  `{BUILD_DIR}/build_hooks_result.json`; it cannot declare a Dart source file
  that `dart2js` must wait for.

Measured 2026-11-05 on macOS arm64 with Flutter 3.47.6 / Dart 3.13.5: first
build exit 1 with `Error when reading 'lib/dwi_tasks.g.dart'` and
`Undefined name 'DwiTasks'`; the hook produced the proxy, worker and manifest
during that same build; the second build exited 0 and the app requested
`/dwi/worker.dart.js`. Evidence:
`audit/evidence/flutter-fresh-build-gate-2026-11-05.txt`.

Re-measured 2026-11-10 (same SDK, writable SDK copy, per mode):

| First command | Result |
| --- | --- |
| `flutter build web --release` | exit 1, missing proxy |
| `flutter build web --wasm` | exit 1, missing proxy |
| `flutter build web --debug` | exit 1, missing proxy |
| `flutter run -d chrome` (debug) | succeeds |

The debug run succeeds structurally: the resident web runner awaits
`runHooks()` before `devFS.update()`. It is not this gate. In the verbose first
release build, `build_hooks`, `dart2js` and `dart2wasm` all start in the same
wave, and the hook reports generating the proxy at +14.7 s — after `dart2js`
already failed. Evidence:
`audit/evidence/flutter-fresh-build-ordering-2026-11-10.txt`.

The fixture writes a `pubspec_overrides.yaml` pinning all DWI packages to this
checkout. Without it the app cannot resolve: `dwi_builder` (published) depends on
hosted `dwi_annotations` while the app depends on it by path, and pub rejects a
package resolved from two sources.

## Why this is not fixed in the package

No supported Flutter mechanism orders a dependency's build hook before
application compilation: `BuildTargets` is a closed interface with no
third-party registration, the hook cannot be a compiler dependency, its outputs
are linking inputs only, and a `dev_dependencies` hook is not run. (An app-root
`hook/build.dart` **does** run on 3.47.6 when the app depends on `hooks`, but it
is scheduled with the compiler rather than before it, so it is a race, not a
fix.) Committing generated proxies would be stale by design and contradict
ADR-008 determinism.

The upstream proposal and the disposable-SDK prototype that closes the gap are
in `docs/upstream/flutter-web-hook-ordering.md`.

The supported workflow remains: run `dart run dwi_builder:dwi build` (or
`dwi build --flutter-build`) once before the first Flutter build; afterwards
ordinary Flutter commands keep the worker fresh. An app that calls `Dwi.run`
directly and imports no generated proxy builds on the first command.
