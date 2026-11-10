# Compiler Strategy

How worker code is produced, and what is deliberately not attempted yet.
Evidence: R002 (Flutter build), R004 (dart2js/DDC), R005 (dart2wasm), R007
(worker compilation), M001 (working proof).

## v0.2: manual entrypoint, automated compile

```text
lib/tasks.dart          # task implementations, no Flutter imports
lib/worker_main.dart    # imports tasks, registers them, starts runtime
        │
        │  dart compile js -O1 -o web/dwi/worker.dart.js lib/worker_main.dart
        ▼
web/dwi/worker.dart.js  # generated, gitignored
        │  flutter build web
        ▼
build/web/dwi/worker.dart.js
```

- v0.2 required the user to write `worker_main.dart`; v0.3 generates it (below).
- DWI provides the runtime half: `DwiWorkerRuntime.start(...)` from
  `package:dwi_web/dwi_worker.dart`.
- In v0.2 compilation was a documented command; v0.3 automates it.

## Flutter web build hooks (v0.3.1)

Flutter 3.47+ exposes web build hooks. `dwi_builder` ships `hook/build.dart`;
when the app lists `dwi_builder` as a normal dependency, Flutter runs the hook
for `flutter build web` and `flutter run -d chrome`, and the hook invokes the
same `DwiBuilder` as the CLI. Web build hooks do not expose the target OS, so a
multi-platform app that has `web/index.html` runs the (cached) worker build
during native builds too. Older Flutter versions, plain Dart web apps and CI
retain the CLI (`dwi build`, `dwi check`, `dwi watch`); see ADR-009.

**Measured ordering limit (Flutter 3.47.6 stable, Dart 3.13.5).** The hook is a
separate web build target (`BuildHooks` under `LinkHooks`), not a prerequisite
of `dart2js`. The hook *can* generate the worker and compile it, but it cannot
reliably create `lib/dwi_tasks.g.dart` before the first application compilation.
On a project with no generated proxy yet, the compiler may start first and fail
with `Error when reading 'lib/dwi_tasks.g.dart': No such file or directory`; the
hook output is valid and the next build succeeds. The supported workflow for a
fresh project is the one-time pre-build step:

```bash
dart run dwi_builder:dwi build      # or: dwi build --flutter-build
flutter build web --release
```

After that, ordinary Flutter commands keep the worker current. This is a build
graph ordering gap, not a discovery or compilation failure (ADR-009, limitations
§7, `audit/evidence/flutter-fresh-build-gate-2026-11-05.txt`).

Each `dart compile js` output is self-contained; there is no shared runtime to
link against (R004 §5). Any future hook must be supported by the Flutter tool,
not by monkey-patching.

## v0.3: generated entrypoint and automatic compilation (shipped)

```dart
@DwiTask()
List<int> calculatePrimes(int max) { ... }
```

The developer writes no worker file. `dwi_builder`:

1. Discovers annotated public top-level functions with the analyzer's resolved
   AST (not source-text regex), including the enclosing library, task-name
   override, parameter/return types and the transitive import closure.
2. Emits `.dwi/generated_worker.dart` with **static references**:

   ```dart
   final Map<String, DwiWorkerTask> _tasks = <String, DwiWorkerTask>{
     'calculatePrimes': (Object? input) =>
         task0.calculatePrimes(_dwiDecode0(input, 'input')),
   };
   ```

   A name in a string would be tree-shaken; a reference is not. The decoder is
   generated from the resolved parameter type and validates the decoded value.
3. Emits `lib/dwi_tasks.g.dart` with typed proxies:

   ```dart
   abstract final class DwiTasks {
     static Future<List<int>> calculatePrimes(int input) =>
         Dwi.run<List<int>>('calculatePrimes', input);
   }
   ```
4. Computes a SHA-256 content hash over the generated sources, the reachable
   dependency files, the Dart compiler version, the DWI version and the
   compiler options. An unchanged hash and a present artefact skip compilation.
5. Runs `dart compile js -O1 -o web/dwi/worker.dart.js
   .dwi/generated_worker.dart` when needed.
6. Writes `.dwi/worker_manifest.json` (protocol, hash, tasks, artefact,
   optimisation, compiled flag).
7. Fails loudly with `DWI001`–`DWI010` diagnostics instead of producing an
   obscure runtime worker failure.

The generated worker imports `DwiWorkerRuntime` from `dwi_web`; protocol
dispatch is in the pure-Dart `DwiWorkerDispatcher`, so it is tested on the VM.

### Build integration reality

Web build hooks are a Flutter feature (ADR-009). Outside Flutter there is no
supported hook for a Dart web build:

- `dart build --help` lists only `cli`;
- `dart compile` has no extra-entrypoint mode;
- the hooks protocol is not invoked by a plain Dart web build.

Therefore, for plain Dart web apps, older Flutter versions and CI, DWI ships a
wrapper command rather than pretending that `dart build` invokes the worker
compiler:

```bash
dart run dwi_builder:dwi build --flutter-build -- --release
```

During development:

```bash
dart run dwi_builder:dwi watch
```

The watcher polls (500 ms), regenerates and recompiles on change. It does not
hot-patch a live worker; reload the page. See `automatic-workers.md` for the
full workflow, diagnostics and manifest.

**Resolved by the v0.3 tests:** the generated registry survives compilation
(`dart compile js` in `dwi_builder/test/build_test.dart`), and the generated
worker runs in Chrome (`examples/automatic_worker`). Tree shaking of the
generated registry is verified for the tested task shapes, not for every
possible library.

## Wasm path (supported opt-in, not in 0.7.0)

Keep the two sides apart:

- **Host compiled with dart2wasm** (`flutter build web --wasm`): measured in
  Chrome 156 on Flutter 3.47.6, with a dart2js worker
  (`docs/browser-matrix.md` §4). This says nothing about the worker.
- **Worker compiled with dart2wasm**: implemented as an opt-in experimental
  slice (ADR-018). `dwi build --target=wasm`, or `target: wasm` in the
  application's `dwi.yaml` (read by the Flutter hook and the CLI), publishes a
  content-addressed
  `gen-<generation>/` directory (`worker.wasm` and the compiler's `worker.mjs`
  loader) plus one small `worker.boot.mjs` entry, which is switched atomically;
  the host loads them as a module worker with `workerBackend:
  DwiWorkerBackend.wasm` and `workerScript: DwiConfig.defaultWasmWorkerScript`.
  A dart2js host with this worker passed the contracts in
  `docs/browser-matrix.md` §7 on Chrome, Edge, Firefox and Safari at `/` and
  `/sub/app/`. A dart2wasm host with a dart2wasm worker is not measured, and
  the Flutter hook does not select the target.

The measured boundaries are recorded: Flutter target selection, dart2wasm host +
dart2wasm worker, deployment (MIME/CSP/same-origin) and benchmarks. The backend
is supported as an opt-in in `main` and is not in 0.7.0; JS remains the default.

## Closure research (DWI-5, no design)

The only way to support `Dwi.run(() { ... })` is compiler cooperation:
identifying the closure, generating an entrypoint for it, and mapping captured
variables to a serialized environment. Nothing in the current Dart toolchain
exposes that. DWI does not promise it.

## Rejected approaches

| Approach | Why rejected |
| --- | --- |
| `Function.toString()` + `eval` in the worker | dart2js output is not re-compilable source; CSP and security |
| Blob worker with inlined code | CSP, debuggability, and it still cannot carry closures |
| Running the whole app bundle in the worker | the bundle is the UI program; no task dispatch, huge startup |
| Shipping a JS shim library | still leaves users writing worker entrypoints; no Dart API |
| Forking the SDK in v0.x | violates AGENTS.md rule 3 and the project gate |
