# Upstream proposal — order web build hooks before Dart compilation

Status: **prepared for review, not posted.** Prepared 2026-11-10 from
measurements on Flutter 3.47.6 stable / Dart 3.13.5. Evidence:
`../../audit/evidence/flutter-fresh-build-ordering-2026-11-10.txt`.

## The problem

A Flutter Web app that imports a Dart source file produced by a dependency's
**web build hook** cannot build on its first ordinary Flutter command. The hook
runs, the file it writes is valid, and the next build succeeds — but `dart2js`
and `dart2wasm` have already resolved the import by the time the hook writes
it.

This blocks the supported "generate a typed client from annotations" workflow
(code generation into `lib/`), not just native assets. Any package whose
developer experience is "annotate, then build" hits it.

## Minimal reproduction

```bash
flutter create --platforms=web demo && cd demo
# pubspec: dependencies: hooks ^2.2.0 (+ any package with a hook/build.dart that
#          writes lib/generated.g.dart)
# lib/main.dart: import 'generated.g.dart';
rm -f lib/generated.g.dart
flutter build web --release
```

Observed on 3.47.6 (framework `5fc346839b`, engine `692136cb65`):

```
+287 ms  build_hooks: Starting due to {}
         dart2js: Starting due to {}
         dart2wasm: Starting due to {}
+11 ms   Running build hooks for web.
         Error: Error when reading 'lib/generated.g.dart': No such file or directory
+14,705 ms  <hook> generated lib/generated.g.dart during this build.
+10 ms   Target dart2js failed: ProcessException ... exit code 1
```

Second build: exit 0, and `build/web/<asset>` is packaged. `flutter build web
--wasm` fails the same way. `flutter build web --debug` fails the same way.
`flutter run -d chrome` (debug) succeeds, because
`isolated/resident_web_runner.dart` `_updateDevFS` awaits `runHooks(...)`
before `devFS.update(...)`.

## Build-graph references (3.47.6)

| Fact | Location |
| --- | --- |
| `Dart2WebTarget.dependencies == [WebEntrypointTarget, GenerateLocalizationsTarget]` — no hooks target | `flutter_tools/lib/src/build_system/targets/web.dart:143` |
| `WebReleaseBundle.dependencies == [...compileTargets, templatedFilesTarget, LinkHooks(platform: HookPlatform.web, extraDependencies: compileTargets)]` | `web.dart:601` |
| `LinkHooks.dependencies` include `BuildHooks(platform: HookPlatform.web)` and the compile targets | `targets/native_assets.dart:140` |
| `BuildHooks.outputs == [{BUILD_DIR}/build_hooks_result.json]`; its depfile is the only other artefact | `targets/native_assets.dart:116` |
| Debug resident path runs hooks before the DDC compile | `isolated/resident_web_runner.dart:752` |
| `BuildTargets` is a closed interface (`BuildTargetsImpl`, `NoOpBuildTargets`); no third-party registration | `build_system/build_targets.dart`, `isolated/build_targets.dart` |

So Flutter's own generated-source target (`GenerateLocalizationsTarget`) is a
**dependency of the compiler**, and a third-party build hook is **not**. The
hook's only declared output is a JSON result that feeds linking.

## Proposed contract

Smallest change that closes the gap:

```dart
// flutter_tools/lib/src/build_system/targets/web.dart
List<Target> get dependencies => const <Target>[
  WebEntrypointTarget(),
  GenerateLocalizationsTarget(),
  BuildHooks(platform: HookPlatform.web),   // <- added
];
```

A dependency on `Dart2WebTarget` covers both `Dart2JSTarget` and
`Dart2WasmTarget`, and therefore `flutter build web` (release/profile/debug) and
any caller of the web compile targets. `BuildHooks` has no dependencies, so the
graph stays acyclic; `LinkHooks` continues to take the compile targets as
`extraDependencies` and to consume `build_hooks_result.json`.

A stronger, longer-term contract worth discussing: let a build hook declare a
**generated Dart source** as a compiler input (for example an
`output.dartSources` list resolved relative to the package root), so only
projects that ask for it pay the ordering cost, and so the compiler can depend
on the file rather than on the whole hook target.

## Prototype and cost (measured)

The one-line change was prototyped in a disposable Flutter checkout (installed
SDK untouched):

- `flutter build web --release`, clean app: **exit 0**, `✓ Built build/web`,
  worker asset packaged — reproduced twice on two independent clean apps.
- `flutter build web --wasm`, clean app: **exit 0**, `main.dart.wasm` plus the
  worker.
- `flutter_tools` web target suite: **623 tests pass**, including two added
  assertions that `Dart2JSTarget` and `Dart2WasmTarget` depend on
  `BuildHooks(platform: HookPlatform.web)`.
- Cost: every web compile now waits for every dependency's web build hook.
  Measured 14.7 s for a first cold hook run. An unchanged DWI build skips the
  hook when `dwi.yaml` exists. When it is absent, Flutter reruns the hook to
  detect its later creation; DWI's content hash avoids recompiling unchanged
  worker code.

Regression test (as prototyped):

```dart
group('web compiler ordering', () {
  testWithoutContext('Dart2JSTarget depends on the web build hooks target', () {
    final Target target = Dart2JSTarget(const JsCompilerConfig());
    final List<BuildHooks> hooks = target.dependencies.whereType<BuildHooks>().toList();
    expect(hooks, hasLength(1));
    expect(hooks.single.platform, HookPlatform.web);
  });

  testWithoutContext('Dart2WasmTarget depends on the web build hooks target', () {
    final Target target = Dart2WasmTarget(const WasmCompilerConfig(), const NoOpAnalytics());
    final List<BuildHooks> hooks = target.dependencies.whereType<BuildHooks>().toList();
    expect(hooks, hasLength(1));
    expect(hooks.single.platform, HookPlatform.web);
  });
});
```

## Impact on ordinary web builds and on hook consumers

- Apps with no packages that ship `hook/build.dart`: `BuildHooks` is a cheap
  package scan (measured ~3 ms for 36 packages) and is then skipped; the
  compiler's inputs and outputs are unchanged.
- Apps with hooks that only produce native assets for other platforms: the web
  hook runs before the compile instead of beside it. For a slow hook this moves
  the cost before compilation rather than overlapping it. That is the trade the
  ordering guarantee buys.
- Link-hook consumers: unchanged. `LinkHooks` still depends on `BuildHooks` and
  on the compile targets, so linking still happens last.
- `flutter run -d chrome` (debug): already ordered this way; unchanged.

## Separate dart2js / dart2wasm results

| Mode | 3.47.6 without change | With the prototype |
| --- | --- | --- |
| `flutter build web --release` (dart2js) | first build exit 1 | first build exit 0 |
| `flutter build web --wasm` (dart2wasm host) | first build exit 1 | first build exit 0 |
| `flutter build web --debug` | first build exit 1 | not re-measured |
| `flutter run -d chrome` (debug, DDC) | first command succeeds | unchanged |

Worker compilation target (the generated worker itself) is a separate axis: the
prototype was checked with a dart2js worker on both app compilers, and with a
dart2wasm worker (`dwi.yaml: target: wasm`) publishing
`build/web/dwi/gen-<hash>/{worker.mjs,worker.wasm}` plus `worker.boot.mjs`.

## What DWI does until this lands

`dart run dwi_builder:dwi build` (or `dwi build --flutter-build`) before the
first Flutter build. The build hook prints an explicit diagnostic when it
creates proxies during a build. `dwi check` reports stale or missing artefacts.
No main-thread fallback exists at any point.

## Not claimed here

- That every hook should run before compilation for every platform.
- That a generated-source input contract is unnecessary (it is the better long
  term design; the dependency is the minimal one).
- Results on any Flutter version other than 3.47.6.
