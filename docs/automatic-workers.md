# Automatic Workers (v0.3)

DWI's v0.3 developer experience: annotate a top-level function, run one DWI
build command, and call a generated typed proxy. No hand-written worker
entrypoint, registry, manifest, worker path or separate compiler invocation.

```dart
// lib/tasks.dart — a pure-Dart library (no Flutter, no DOM).
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int calculatePrimes(int limit) {
  // ...
}
```

```dart
// lib/main.dart
import 'package:dwi/dwi.dart';
import 'dwi_tasks.g.dart';

final count = await DwiTasks.calculatePrimes(5_000_000);
```

```bash
dart run dwi_builder:dwi build
# or, to also run the Flutter build:
dart run dwi_builder:dwi build --flutter-build -- --release
```

On web the proxy routes through the pooled worker backend; on native it uses an
isolate. `DwiConfig.workerScript` defaults to `dwi/worker.dart.js`, so no
`Dwi.configure(workerScript: ...)` call is required.

## Pipeline

```text
@DwiTask top-level function
        │
        ▼
analyzer discovery (resolved AST, not source-text regex)
        │
        ├── diagnostics DWI001–DWI010
        │
        ▼
.dwi/generated_worker.dart       static task references + DwiWorkerRuntime
lib/dwi_tasks.g.dart             typed DwiTasks proxies
        │
        ▼
dart compile js                  automatic, cached by content hash
        │
        ├── .dwi/worker_manifest.json   protocol, hash, tasks, artefact
        │
        ▼
web/dwi/worker.dart.js           copied by flutter build web
        │
        ▼
Dwi.run(...) → lazy worker pool → Web Worker
```

The generated worker uses `DwiWorkerRuntime.start` from
`package:dwi_web/dwi_worker.dart`. It sends `ready`, dispatches `request`
envelopes, awaits asynchronous tasks, forwards typed errors, and handles
`shutdown`. The pure-Dart dispatcher is unit-tested on the VM.

## Discovery rules

- The annotation is `@DwiTask({String? name})`. It must be on a **public
  top-level function** in a library reachable from the configured include paths.
- A task takes no input or exactly one **required positional** input. Named,
  optional and additional parameters are rejected.
- Parameter and result types must round-trip: primitives, `dynamic`, `Object?`,
  `Future<T>`/`FutureOr<T>`, nullable forms, typed collections
  (`List<T>`, `Set<T>`, `Map<String, V>`), and typed data (`Uint8List` and the
  other typed lists, `ByteData`, `ByteBuffer`). Generated codecs validate and
  convert decoded `List`/`Map` values on both sides. Custom classes, enums,
  records, functions, streams, `DateTime` and non-String map keys are build
  errors (`DWI001`).
- Generated proxies also register their native implementations, so the same
  `DwiTasks.foo(input)` call runs on an isolate on the VM and in a worker on
  web; no manual `Dwi.registerTask` is required for generated tasks.
- The result may be `T`, `Future<T>`, `FutureOr<T>` or `void`. The worker awaits
  the future before replying.
- Generic functions, getters/setters, methods, private functions, `main` and
  variables are rejected.
- Task libraries must not import Flutter, `dart:ui`, `dart:io`, `dart:html` or
  `dart:isolate`, directly or through the project dependency closure.
- Generated `.g.dart` files and `.dwi/` are skipped by discovery; the analyzer's
  `exclude` rules are respected by convention.

Diagnostics:

| Code | Meaning |
| --- | --- |
| `DWI001` | A parameter/result type cannot cross the boundary (DOM, functions, ports, `Stream`, records, classes, enums, `DateTime`, non-String map keys). |
| `DWI002` | The task library closure imports Flutter, `dart:ui`, `dart:io`, `dart:html` or `dart:isolate`. |
| `DWI003` | Unsupported declaration or signature. |
| `DWI004` | Duplicate task name or colliding generated proxy method. |
| `DWI005` | Analyzer error in a file that declares a task, or no task found (warning). |
| `DWI007` | Worker compilation failed; compiler output is attached. |
| `DWI009` | Invalid `@DwiTask` annotation argument. |
| `DWI010` | The task's library cannot be imported by the generated worker. |

Diagnostics are build-time; they never turn into a silent main-thread fallback.

## Manifest

```json
{
  "protocol": 1,
  "generator": "dwi_builder",
  "generatorVersion": "0.3.0",
  "hash": "<sha256>",
  "target": "js",
  "optimization": "O1",
  "compiled": true,
  "artifactDigest": "<sha256 of the compiled worker>",
  "workers": {
    "default": {
      "artifact": "dwi/worker.dart.js",
      "entrypoint": ".dwi/generated_worker.dart",
      "tasks": ["calculatePrimes"]
    }
  }
}
```

The developer never edits this file. It is written only by `dwi build` when
compilation is enabled; `dwi generate` and `dwi build --no-compile` write the
sources and proxies only and leave any previous manifest untouched, so
`dwi check` correctly reports the build as stale until it is compiled. `dwi
check` fails when generated sources, the manifest hash or the compiled artefact
are stale.

## Cache

The content hash covers:

- generated worker source and generated proxies;
- every source file reachable from a task library;
- the DWI runtime and generator sources compiled into the worker
  (`dwi_web`, `dwi_protocol`, `dwi_core`, `dwi_annotations`, `dwi_builder`);
- the project's `.dart_tool/package_config.json`, so package-resolution changes
  invalidate the cache;
- the identity of the **selected** compiler executable (`<dart> --version`), not
  the SDK running the build tool;
- `dwi_builder` version, manifest protocol and worker id;
- target (`js`) and optimisation level.

If the hash and a compiled artefact **plus its recorded digest** are unchanged,
compilation is skipped. A corrupted, truncated or deleted artefact fails
`dwi check` and forces a rebuild. `--force` bypasses the cache. Compilation
writes a temporary file and publishes it by rename, so a failed compilation
never replaces a valid artefact; concurrent builds are last-writer-wins and
`dwi check` reports any interleaved mismatch.

## Lazy startup and bundling

Compilation is automatic; worker **startup** is not eager. `Dwi.run` acquires a
pooled worker on first use, spawns lazily up to `maxWorkers`, and retains it
according to the pool policy. A task timeout terminates the worker.

v0.3 ships one universal worker bundle. Multiple or chunked workers are not a
default because they multiply compilation and startup; they are a
benchmark-driven decision, not a promise.

## Zero-command Flutter Web (v0.3.1)

Flutter 3.47 runs build hooks for web. List `dwi_builder` as a **normal
dependency** (not only a dev dependency) and the worker is generated and
compiled by the ordinary Flutter commands:

```yaml
dependencies:
  flutter:
    sdk: flutter
  dwi:
    path: ../dart_web_isolates/packages/dwi
  dwi_builder:
    path: ../dart_web_isolates/packages/dwi_builder
```

```bash
flutter run -d chrome
flutter build web --release --base-href /sub/app/
```

`dwi_builder/hook/build.dart` finds the application package from Flutter's
package config, runs the same builder as the CLI, writes
`web/dwi/worker.dart.js`, and declares task files as hook dependencies so
Flutter re-runs it only when they change. See ADR-009 in
`docs/architecture.md` for evidence and limitations. The hook is skipped for
packages without a `dwi` dependency or without `web/index.html`.

**Fresh projects need one generation step.** Flutter runs `build_hooks` and
`dart2js` as independent targets; on a project that has no
`lib/dwi_tasks.g.dart` yet, the compiler can start before the hook writes it and
the first build fails with
`Error when reading 'lib/dwi_tasks.g.dart': No such file or directory`. The
generated files are valid and the next build succeeds, but the supported
workflow is to generate them once first:

```bash
dart run dwi_builder:dwi build      # or: dwi build --flutter-build
flutter build web --release --base-href /sub/app/
```

After that, ordinary Flutter commands keep the worker current. This ordering
gap is a Flutter build-graph limitation, measured on Flutter 3.47.6; it is not
covered by a hook-only promise.

The separate `dwi build` command remains supported for older Flutter versions,
plain Dart web apps, CI `check`, and diagnostics.

## Development workflow

For a Flutter app, no watcher is required: `flutter run -d chrome` runs the
hook on start and whenever a declared task dependency changes (hot reload does
not rebuild a running worker; hot restart or reload the page). For plain Dart
web apps, use the watcher:

```bash
dart run dwi_builder:dwi watch
```

The watcher polls the configured source paths, the task dependency closure
(including dependencies outside `--include`), `pubspec.yaml`, `pubspec.lock` and
`.dart_tool/package_config.json` (500 ms), excludes generated files, regenerates
and recompiles on change, and reruns a build if inputs change while it is
running. It does not hot-patch a running worker: reload the page after a
rebuild.

Why the CLI still exists: build hooks are Flutter-specific. `dart build` has
only a `cli` subcommand, `dart compile js` has no extra-entrypoint mode, and a
plain Dart web server has no hook mechanism. For those workflows DWI provides
the wrapper command (`dwi build --flutter-build`). ADR-009 records the
correction to the earlier "no web build hook" conclusion.

## What is deliberately not implemented

- `Dwi.run(expensiveFunction, input)` and `Dwi.run(() { ... })`: function
  values/closures are not structured-cloneable and no compiler metadata channel
  exists. See R013 §4.4–4.5 and ADR-002.
- Runtime compilation in the browser: no browser-hosted Dart compiler; CSP and
  size make it non-viable for v0.x. See R013 §4.5.
- Wasm worker generation (v0.6).
- Flutter hot reload of an existing worker (page reload is required).

## Verification

- `dwi_builder` unit tests cover discovery, diagnostics, deterministic
  generation, hashing, compilation, cache reuse, stale detection and clean.
- `dwi_web` tests cover the worker dispatcher (results, async tasks, typed
  errors, shutdown, unsupported cancellation).
- `examples/automatic_worker` generates, compiles and runs in Chrome; it
  displays a worker-computed result through generated typed proxies.
