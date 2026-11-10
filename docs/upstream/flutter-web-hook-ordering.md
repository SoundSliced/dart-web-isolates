# Upstream proposal — order web build hooks before Dart compilation

Status: **prepared for review, not posted.** Revised 2026-11-10 after a second
measurement round on a disposable SDK copy. Nothing here is accepted Flutter
behaviour. Evidence: `../../audit/evidence/flutter-web-hook-ordering-2026-11-10.txt`.
The reviewable comment for the existing Dart discussion is
[`dart-issue-56512-comment-draft.md`](dart-issue-56512-comment-draft.md).

Measured on Flutter 3.47.6 stable (framework `5fc346839b`, engine
`692136cb65`, Dart 3.13.5), macOS arm64. The source check covers 3.47.9 stable
and `master` as of 2026-11-10.

## The problem

A Flutter Web app that imports a Dart source file produced by a dependency's
**web build hook** cannot build on its first ordinary Flutter command. The hook
runs, the file it writes is valid, and the next build succeeds — but `dart2js`
and `dart2wasm` have already resolved the import by the time the hook writes
it.

This blocks the supported "generate a typed client from annotations" workflow
(code generation into `lib/`), not just native assets. Any package whose
developer experience is "annotate, then build" hits it.

## Upstream state (2026-11-10)

- `Dart2WebTarget.dependencies` is still
  `[WebEntrypointTarget(), GenerateLocalizationsTarget()]` on **3.47.9**
  (`targets/web.dart:143`) and on **`master`** (`targets/web.dart:200`).
- `web_release_bundle` still depends on
  `LinkHooks(platform: HookPlatform.web, extraDependencies: compileTargets)`,
  so `BuildHooks(platform: web)` remains a linking input, not a compiler input.
- The current stable release is **3.47.9** (2026-10-29), newer than the
  3.47.6 used for the measurements below. The 3.47.9 sources were inspected,
  not built: no 3.47.9 engine artifacts were available offline in the
  measurement environment.
- [dart-lang/sdk#56512](https://github.com/dart-lang/sdk/issues/56512)
  (`hook/generate.dart`) is open, with 30 comments and no decision recorded on
  how generated Dart sources are ordered relative to compilation. The last
  update is 2026-08-07.
- No released Flutter SDK contains an ordering fix or a generated-source
  contract that closes this gap.

## Minimal reproduction

Independent of DWI: an app depends on `hooks: ^2.2.0` and on a package (or has
an app-root hook) whose `hook/build.dart` writes `lib/generated.g.dart`;
`lib/main.dart` imports it.

```bash
flutter create --platforms=web demo && cd demo
# pubspec: dependencies: hooks: ^2.2.0 (+ a package whose hook writes
#          lib/generated.g.dart, or a hook/build.dart in the app itself)
# lib/main.dart: import 'generated.g.dart';
rm -f lib/generated.g.dart
flutter build web --release
```

Measured on 3.47.6, fresh fixture per command:

| First command | Result | Hook vs compiler |
| --- | --- | --- |
| `flutter build web --release` | exit 1, `Error when reading 'lib/dwi_tasks.g.dart'` then `Undefined name 'DwiTasks'` | hook generated the proxy at +8.5 s, after dart2js failed |
| `flutter build web --wasm` | exit 1, same missing import | hook generated at +6.0 s, after dart2wasm failed |
| `flutter build web --debug` | exit 1, same missing import | hook generated at +7.7 s, after dart2js failed |
| `flutter run -d chrome` (debug) | first command succeeds | resident runner awaits `runHooks()` before `devFS.update()` |

The DWI proxy gate (`tooling/proxy_gate`) reproduces the release case and exits
non-zero if a first build ever starts succeeding.

## Build-graph references (3.47.6)

| Fact | Location |
| --- | --- |
| `Dart2WebTarget.dependencies == [WebEntrypointTarget, GenerateLocalizationsTarget]` — no hooks target | `flutter_tools/lib/src/build_system/targets/web.dart:143` |
| `WebReleaseBundle.dependencies == [...compileTargets, templatedFilesTarget, LinkHooks(platform: HookPlatform.web, extraDependencies: compileTargets)]` | `web.dart:601` |
| `LinkHooks.dependencies` include `BuildHooks(platform: HookPlatform.web)` and the compile targets | `targets/native_assets.dart:140` |
| `BuildHooks.outputs == [{BUILD_DIR}/build_hooks_result.json]`; its depfile is the only other artefact | `targets/native_assets.dart:116` |
| Debug resident path runs hooks before the DDC compile | `isolated/resident_web_runner.dart:752` |
| `BuildTargets` is a closed interface (`BuildTargetsImpl`, `NoOpBuildTargets`); no third-party registration | `build_system/build_targets.dart`, `isolated/build_targets.dart` |

Flutter's own generated-source target (`GenerateLocalizationsTarget`) is a
**dependency of the compiler**; a third-party build hook is **not**. The hook's
only declared output is a JSON result that feeds linking.

## Prototype (disposable SDK copy only)

The installed SDK was not modified. A writable copy of the 3.47.6 SDK was
created outside the repository, with the large engine artefacts referenced in
place. One source file changed:

```dart
// flutter_tools/lib/src/build_system/targets/web.dart
List<Target> get dependencies => const <Target>[
  WebEntrypointTarget(),
  GenerateLocalizationsTarget(),
  // A dependency's web build hook may generate Dart sources that the
  // application imports. The compiler must not start until those hooks have
  // run. See https://github.com/dart-lang/sdk/issues/56512.
  BuildHooks(platform: HookPlatform.web),
];
```

A dependency on `Dart2WebTarget` covers both `Dart2JSTarget` and
`Dart2WasmTarget`, and therefore `flutter build web` (release/profile/debug) and
any caller of the web compile targets. `BuildHooks` has no dependencies, so the
graph stays acyclic; `LinkHooks` continues to take the compile targets as
`extraDependencies` and to consume `build_hooks_result.json`.

The dependency was prototyped as-is; it is not a mandate. A supported contract
for generated sources would be preferable (see the comparison below).

## Tests and prototype results

- `flutter_tools` web target suite: **623 tests pass**, including two added
  assertions that `Dart2JSTarget` and `Dart2WasmTarget` each depend on exactly
  one `BuildHooks` with `HookPlatform.web`.
- Added integration test
  `test/integration.shard/build_hooks_generate_dart_web_test.dart`: a fresh app
  whose build hook writes `lib/generated.g.dart`, imported by `lib/main.dart`,
  builds on its **first** `flutter build web --release --no-pub`, and both the
  source and `build/web/main.dart.js` exist afterwards. **Passes** in the
  disposable SDK.
- Ordering is structural, not a timing coincidence: the verbose first build
  logs `build_hooks: Complete` before `dart2js: Starting due to {}`.

## Acceptance matrix (fresh fixture per row, disposable patched SDK)

| Host compiler | Worker target (`dwi.yaml`) | First command | Result |
| --- | --- | --- | --- |
| dart2js (`--release`) | js | `flutter build web --release` | exit 0; `main.dart.js` + `dwi/worker.dart.js` |
| dart2js (`--release`) | wasm | `flutter build web --release` | exit 0; `main.dart.js` + `dwi/worker.boot.mjs` + `dwi/gen-<hash>/{worker.mjs,worker.wasm}` |
| dart2wasm (`--wasm`) | js | `flutter build web --wasm` | exit 0; `main.dart.{js,wasm}` + `dwi/worker.dart.js` |
| dart2wasm (`--wasm`) | wasm | `flutter build web --wasm` | exit 0; `main.dart.{js,wasm}` + Wasm worker bundle |
| dart2js (debug) | js | `flutter build web --debug` | exit 0; `main.dart.js` + `dwi/worker.dart.js` |
| dart2js (profile) | js | `flutter build web --profile` | exit 0; `main.dart.js` + `dwi/worker.dart.js` |
| DDC (debug) | js | `flutter run -d chrome` | reaches `Flutter run key commands` on the first command |

Runtime, Chrome only:

- Release dart2js build served at `/`: task result **168**, server logged
  `200 /dwi/worker.dart.js`.
- Wasm host with a Wasm worker (app configured with
  `DwiWorkerBackend.wasm` and `DwiConfig.defaultWasmWorkerScript`) served at
  `/` and at `/sub/app/` (built with `--base-href=/sub/app/`): result **168**
  and `200` for `worker.boot.mjs`, `gen-<hash>/worker.mjs` and `worker.wasm`.

Safari, Firefox and Edge were not automated in this environment. Their absence
is a gap in runtime evidence, not evidence about the build-ordering fix.

## Cost

Every web compile now waits for every dependency's web build hook.

- App with **no hooks**, release: patched vs unpatched on the same disposable
  SDK — cold 20.07 s vs 21.00 s; unchanged 17.16–18.16 s vs 17.39–18.18 s. No
  measurable cost; `build_hooks` is skipped on unchanged builds.
- DWI app, release: cold 31.7 s. Unchanged with no `dwi.yaml` 26.7 s (the hook
  reruns because the missing optional file is a dirty input); unchanged with
  `dwi.yaml` 19.2 s once stable. These numbers are noisy on the measurement
  machine and are indicative, not a benchmark.
- For a slow hook the cost moves **before** compilation instead of overlapping
  it. That is the trade the ordering guarantee buys.

## Design comparison for maintainers

| Route | What it solves | Open questions |
| --- | --- | --- |
| Order `BuildHooks(platform: web)` before the web compiler | The measured Flutter-only build race, for every web target | Does it establish a supported contract for generated Dart sources and for analyzer/IDE use, or only fix the build race? Every web build with hooks pays the serialization. |
| Dedicated `hook/generate.dart` phase (dart-lang/sdk#56512) | One explicit pre-compilation source-generation contract for Dart and Flutter | Input/output declarations, cache invalidation, IDE/analyzer timing, package ordering, and how existing hooks migrate. |
| Declared generated-Dart outputs from existing hooks | Limits ordering to hooks that actually generate source | Needs a hooks API and a compiler/build-graph contract; feasibility must be decided by maintainers. |

DWI can adopt any of the three; the builder already separates discovery,
generation and worker compilation.

## Regression cases measured

- Hook failure: a throwing `hook/build.dart` fails the build (exit 1,
  `Target build_hooks failed`, `Bad state: hook boom`); `dart2js` never starts
  and no `build/web` is produced.
- `dwi.yaml` lifecycle: first build (no config) packages the JS worker; creating
  `target: wasm` produces the Wasm worker bundle on the next build; deleting it
  recompiles the JS worker on the following build. Old Wasm artefacts are
  retained, not deleted.
- Link hooks and final packaging still run: the worker asset is present in
  `build/web/dwi` in every row above.

Not measured: a dependency hook that emits only assets (no Dart source),
multiple dependencies with web hooks, non-Chrome engines, and a build on
3.47.9 (source inspection only).

## What DWI does until this lands

`dart run dwi_builder:dwi build` (or `dwi build --flutter-build`) before the
first Flutter build. The build hook prints an explicit diagnostic when it
creates proxies during a build. `dwi check` reports stale or missing artefacts.
No main-thread fallback exists at any point.

## Not claimed here

- That this prototype is accepted, merged, or shipped in any released SDK.
- That every hook should run before compilation for every platform.
- That a generated-source input contract is unnecessary (it is the better long
  term design; the dependency is the minimal one).
- Results on any Flutter version other than 3.47.6, or on 3.47.9 beyond the
  source inspection above.
