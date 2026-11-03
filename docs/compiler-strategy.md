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

- The user writes `worker_main.dart` (or uses the generated one in v0.3).
- DWI provides the runtime half: `DwiWorkerRuntime.register(...)` and
  `DwiWorkerRuntime.start()`.
- Compilation is a documented command (and a helper script); staleness must fail
  loudly.

## Why not automate inside `flutter build web`

- The web build compiles a single `target` (R002 §3); no extra-entrypoint hook
  was found in the web build sources.
- Each `dart compile js` output is self-contained; there is no shared runtime to
  link against (R004 §5).
- Any future hook would need to be supported by the Flutter tool, not by
  monkey-patching.

## v0.3: code generation

```dart
@DwiTask()
List<int> calculatePrimes(int max) { ... }
```

Generator responsibilities:

1. Discover annotated functions (build_runner or a standalone tool).
2. Emit a registry with **static references**:

   ```dart
   final Map<String, Object? Function(Object?)> _tasks = {
     'calculatePrimes': (Object? input) => calculatePrimes(input! as int),
   };
   ```

3. Emit the worker entrypoint (`register`, `start`).
4. Emit typed host wrappers (optional; keeps names out of user code).
5. Be deterministic: stable ordering, no timestamps, byte-identical output for
   identical input (AGENTS.md rule 11).

**Unresolved:** whether a generated registry survives tree shaking end to end.
Static references should keep the functions, but this needs a probe before the
generator is promised (R004 unresolved).

## Wasm path (later)

```text
dart compile wasm -o web/dwi/worker.wasm lib/worker_main.dart
new Worker('dwi/worker.mjs', type: 'module')
```

- Requires a module worker, `application/wasm` serving, and a browser with
  WasmGC + `js-string` builtins (R005).
- Not shipped until the browser matrix proves it.

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
