# R002 — Flutter Web Limitations

Status: research report · Agent: 5 (Flutter) · Evidence: local Flutter SDK
`/Users/christophechanteur/Development/flutter`, git head `5fc346839b5`
(`flutter-3.47-candidate.0`, engine `692136cb6582dbfc5af3fb33c2515a069f2f66d0`),
Dart 3.13.5.

Citations are relative to that SDK root. **UNRESOLVED** marks anything not
established from source.

## Summary

- Flutter's `compute()` is a conditional-import fork: `_isolates_io.dart` calls
  `Isolate.run`, `_isolates_web.dart` calls the callback **on the current
  thread** after one microtask (`await null`).
- The conditional import key is `dart.library.js_interop`, so the web
  implementation is selected for dart2js, DDC and dart2wasm alike.
- `flutter build web` compiles exactly one Dart entrypoint per invocation
  (`compile(String target, …)`); the build produces `main.dart.js`/`.wasm` plus
  assets, and copies the contents of `web/`.
- No documented extension point in `flutter build web` compiles a second Dart
  entrypoint into a worker script. A DWI worker therefore has to be compiled
  separately and copied/served alongside the Flutter output.
- This is the concrete product gap DWI targets: Flutter's own API documents
  `compute()` as spawning an isolate, and on web it demonstrably does not.

## 1. `compute()` dispatch

`packages/flutter/lib/src/foundation/isolates.dart`:

```dart
import '_isolates_io.dart' if (dart.library.js_interop) '_isolates_web.dart' as isolates;   // :13
...
Future<R> compute<M, R>(ComputeCallback<M, R> callback, M message, {String? debugLabel}) {   // :81
  return isolates.compute<M, R>(callback, message, debugLabel: debugLabel);
}
```

Native implementation (`_isolates_io.dart:19-30`):

```dart
return Isolate.run<R>(() {
  return callback(message);
}, debugName: debugLabel);
```

Web implementation (`_isolates_web.dart`, complete body):

```dart
@pragma('dart2js:tryInline')
Future<R> compute<M, R>(isolates.ComputeCallback<M, R> callback, M message,
    {String? debugLabel}) async {
  // To avoid blocking the UI immediately for an expensive function call, we
  // pump a single frame to allow the framework to complete the current set of
  // work.
  await null;
  return callback(message);
}
```

Facts that follow directly:

1. The callback runs in the page's main realm. There is no worker, no second
   thread, and no message boundary.
2. `await null` yields one microtask; it does not yield to the event loop in a
   way that lets rendering happen *during* the callback. A CPU-bound callback
   still blocks frames for its full duration.
3. `debugLabel` is accepted and ignored on web.
4. The web path depends on `dart:isolate` nowhere, which is why it compiles.

Cross-check with the web stub of `dart:isolate`: the coordinator's probe
(Chrome, dart2js, Dart 3.13.5) showed `Isolate.current`, `Isolate.run` and
`Isolate.spawn` throwing `UnsupportedError`, while `ReceivePort` constructs but
does nothing. Flutter avoids the stub rather than failing.

## 2. Why the web build cannot just "turn on" isolates

- `dart:isolate` has a platform patch for every web target
  (`sdk/lib/libraries.json`, dart2js section, line 607: patch
  `_internal/js_runtime/lib/isolate_patch.dart`; wasm section line 509; ddc
  section line 796). All three throw for spawning and ports (see R004/R005).
- A worker is a separate *realm* with its own module graph. Compiling it is a
  second compilation, not a runtime flag.
- Even if the compiler emitted worker code, structured clone cannot carry Dart
  closures or arbitrary object graphs (R003), so the API contract would still
  differ from `Isolate.run`.

## 3. The `flutter build web` pipeline

`packages/flutter_tools/lib/src/web/compile.dart`:

- `compile(String target, …)` (`:70`) takes a single `target` — the Dart
  entrypoint — and creates the output directory (`:89-94`), then drives the web
  build (`:104-116`, `kTargetFile: target`).
- Output is reported as `Built <relative outputDirectory>` (`:163`).
- A "dual-compile" path exists when more than one compiler configuration is
  requested (`:174`), which is how JS + Wasm builds are produced together; it is
  still the *same* entrypoint compiled twice, not two entrypoints.
- `compiler_config.dart:11` declares `sealed class WebCompilerConfig`, with a
  Dart-to-JS configuration (`:55`) and a Wasm counterpart; optimisation levels
  are mapped per compiler (`:113`).

Layout implied by the tool (and by `build/web` conventions):

```text
build/web/
├── main.dart.js          # dart2js entrypoint (or main.dart.mjs + .wasm)
├── flutter.js
├── flutter_bootstrap.js
├── assets/
└── <everything copied from web/>
```

Anything a package places in `web/` is served, which is the practical route for
a precompiled worker artefact: build `worker.js` yourself, put it in `web/dwi/`,
and it lands in `build/web/dwi/worker.js`.

## 4. Multiple entrypoints and custom build steps

- **Verified**: one target per `compile()` call; no parameter for a list of
  entrypoints.
- **Verified**: the tool has no documented "compile this extra Dart file" flag in
  the web build sources inspected (`compile.dart`, `compiler_config.dart`,
  `workflow.dart`).
- **UNRESOLVED**: whether a `build_runner` builder could invoke the Dart
  compiler as part of a Flutter build in a supported way. `build_runner` is a
  separate tool and its output is not part of `flutter build web`'s asset graph
  unless the builder writes into the project.
- **UNRESOLVED**: whether the new native-assets / build-hooks mechanism covers
  web workers. Nothing in the inspected web sources references it.

Consequence: the honest v0.1 story is *"a tool compiles the worker entrypoint and
writes it to a served location"*, not *"the Flutter compiler does it for you"*.
Promising otherwise would violate AGENTS.md rule 17.

## 5. Wasm build path

- `flutter build web --wasm` compiles the same entrypoint with dart2wasm; the
  compiler configuration is selected in `compiler_config.dart` and passed to the
  web build.
- A Wasm worker needs its own `.wasm` + `.mjs` pair (R005), so the JS and Wasm
  worker artefacts are genuinely different deliverables.
- **UNRESOLVED**: Flutter's canvaskit/skwasm renderer bootstrap does not expose
  a worker entrypoint of its own; whether the Flutter Wasm runtime can be
  instantiated inside a worker is a separate experiment (M001 handles JS only).

## 6. Development workflow implications

- `flutter run -d chrome` uses DDC with hot restart. A precompiled worker is a
  static file: editing worker code requires recompiling it, not hot restart.
- `flutter test --platform chrome` also uses the web test compiler; a worker
  script must be served by the test server to be loadable.
- Stale worker artefacts are a real failure mode. The DWI tooling must fail
  loudly when the artefact is missing or older than its sources, rather than
  falling back to main-thread execution (AGENTS.md rule 12).

## 7. What a worker-backed `compute()` would require (constraints only)

1. A second compiled artefact per web build, produced outside the single-target
   `flutter build web` invocation.
2. A runtime that can start a dedicated worker from that artefact and keep it
   alive across calls (worker startup is not free).
3. A protocol that carries the callback's *identity* (compiled in the worker),
   because the closure cannot be shipped (R004).
4. Error and exit semantics translated into a `Future<R>` failure, including a
   stack trace from a different realm.
5. A decision about the Flutter-specific message types the callback expects —
   they must be structured-cloneable or explicitly encoded.

## Verification status

- **Verified**: all Flutter source citations above; compute() web path is
  same-thread; single-target `compile()`; `web/` contents are copied into
  `build/web`.
- **Unverified / unresolved**: existence of any supported build hook for a second
  entrypoint; Wasm renderer instantiation inside a worker; exact `build/web`
  layout produced by this SDK version (inferred from tool sources and Flutter
  conventions, not from a build run in this sandbox).
