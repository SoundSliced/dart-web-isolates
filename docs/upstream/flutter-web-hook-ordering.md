# Upstream proposal — order web build hooks before Dart compilation

Status: **posted for guidance (2026-11-10); no design accepted.** Revised after
a second measurement round on a disposable SDK copy. Nothing here is accepted
Flutter behaviour. Posted comment:
[issuecomment-6777658158](https://github.com/dart-lang/sdk/issues/56512#issuecomment-6777658158).
The rebasable prototype patch is
[`flutter-web-hook-ordering.patch`](flutter-web-hook-ordering.patch). Evidence:
`../../audit/evidence/flutter-web-hook-ordering-2026-11-10.txt`.

Measured on Flutter 3.47.6 stable (framework `5fc346839b`, engine
`692136cb65`, Dart 3.13.5), then re-measured on **3.47.9** (framework
`c197ca5199e`, engine `89c39edfdf`, Dart 3.13.7) on both an unmodified and a
patched 3.47.9 checkout — see [3.47.9 measurement](#3479-measurement-2026-11-10).
macOS arm64 throughout.

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
- The current stable release is **3.47.9** (2026-10-29). It has since been
  built here on both an unmodified and a patched checkout; the results are in
  [3.47.9 measurement](#3479-measurement-2026-11-10) and reproduce the 3.47.6
  behaviour exactly.
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

## 3.47.9 measurement (2026-11-10)

Two writable 3.47.9 checkouts under gitignored `.research/`: `flutter-sdk`
(unmodified) and `flutter-sdk-patched` (same revision plus this patch, own
`flutter_tools` snapshot). The patch applied to 3.47.9 **without rebase**; the
build graph at `targets/web.dart:143` is unchanged from 3.47.6.

Fresh app per command, generated proxy / worker / manifest / build output
asserted absent first:

| First command | Unmodified 3.47.9 | Patched 3.47.9 |
| --- | --- | --- |
| `build web --release` (js worker) | exit 1, 27 s | exit 0, 43 s |
| `build web --release` (wasm worker) | exit 1, 27 s | exit 0, 28 s |
| `build web --wasm` (js worker) | exit 1, 12 s | exit 0, 29 s |
| `build web --wasm` (wasm worker) | exit 1, 13 s | exit 0, 27 s |
| `build web --debug` (js worker) | exit 1, 20 s | exit 0, 30 s |
| `build web --profile` (js worker) | exit 1, 23 s | exit 0, 28 s |
| `run -d chrome` (debug) | reaches key commands, 28 s | reaches key commands, 32 s |

In every patched row the verbose trace shows `build_hooks: Complete` **before**
`dart2js: Starting` and `dart2wasm: Starting`; in every unmodified row the hook
completes after the compiler has already failed on
`Error when reading 'lib/dwi_tasks.g.dart'`.

Tests on the patched checkout: `flutter_tools` web target suite **623 passed,
0 failed** (including the two added dependency assertions); the added
integration test **1 passed in 21 s** — a fresh app whose hook writes an
imported `lib/generated.g.dart` builds on its first `flutter build web
--release`.

Regression shapes, all on the patched SDK: asset-only hook (builds, one hook
run); two hook dependencies (both run once, both complete before compilation);
one of two hooks throwing (exit 1, `Target build_hooks failed`, compiler never
starts); no-hook app (cold 17 s vs 18 s unmodified, unchanged 14 s both,
`Skipping target: build_hooks`); unchanged build with a hook (hook skipped);
`dwi.yaml` js → wasm → js → deleted (correct artefact each time, stale Wasm
artefacts retained, hook reruns only while the optional file is absent).

Browser evidence from those production builds, driven by the repository
harness: dart2js host with a JS worker returns the typed result **168** on
Chrome 157.0.8103.50, Safari 26.5, Firefox 159.0.1 and Edge 157.0.4341.42, at
both `/` and `/sub/app/`, with `dwi/worker.dart.js` served 200. The dart2wasm
host with a Wasm worker also returns **168** on all four engines at both
mounts, with `worker.boot.mjs` and the `gen-<hash>` trio served 200 as
`text/javascript` / `application/wasm`.

An earlier run of those Wasm rows failed on every engine with
`minified:hp: worker error`. The cause was the measurement server, not DWI and
not this patch: it served `.mjs` as `application/octet-stream`, and browsers
refuse a module worker with a non-JavaScript MIME type. Changing only that
content type made the same build pass on all four engines, and the same
combination on the **unmodified** 3.47.9 SDK (proxy pre-generated with
`dart run dwi_builder:dwi build`) also passes — so the startup failure is
excluded from the patch's column. The harness now maps `.mjs`, with
`packages/dwi_builder/test/browser_serve_test.dart` as its regression test.

Evidence: `../../audit/evidence/flutter-web-hook-ordering-3.47.9-2026-11-10.txt`.

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
