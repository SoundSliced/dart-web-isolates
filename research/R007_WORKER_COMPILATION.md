# R007 — Worker Compilation

Status: coordinator synthesis of R002 (Flutter build), R004 (dart2js/DDC) and
R005 (dart2wasm), plus verified local compiles. No new unsourced claims.

## The problem in one sentence

A worker is a **second program instance**, so it needs a second compiled
artefact; `flutter build web` compiles exactly one entrypoint per invocation
(R002 §3), and the Dart compilers offer no multi-entrypoint mode (R004 §5).

## JS worker pipeline (v0.1 target)

```text
lib/worker.dart                 (worker entrypoint, imports task implementations)
        │  dart compile js -O2 -o build/web/dwi/worker.dart.js
        ▼
web/dwi/worker.dart.js          (self-contained script, includes Dart runtime)
        │  flutter build web
        ▼
build/web/dwi/worker.dart.js    (copied because it lives under web/)
        │  new Worker('dwi/worker.dart.js')
        ▼
DedicatedWorkerGlobalScope
```

Verified facts that constrain this pipeline:

1. `dart compile js -o out.js entry.dart` produces a self-contained script; there
   is no shared runtime between separately compiled entrypoints (R004 §5).
2. Anything placed in `web/` is served from `build/web/` (R002 §3, inferred from
   Flutter's asset copying).
3. A classic worker (no `type: 'module'`) can load that script directly; a module
   worker would require the compiler to emit ESM (**UNRESOLVED**: whether the
   current SDK can).
4. Worker script loading is subject to CSP `worker-src` (R003 §2).
5. The compiled worker must call `postMessage` to signal `ready`; there is no
   platform event for “Dart runtime finished bootstrapping”.

## Wasm worker pipeline (later)

```text
lib/worker_wasm.dart
        │  dart compile wasm -o build/web/dwi/worker.wasm
        ▼
worker.wasm + worker.mjs
        │  new Worker('dwi/worker.mjs', type: 'module')
        ▼
worker.mjs: compileStreaming(wasm) → instantiate → $invokeMain
```

Constraints (R005 §1, §6): module worker required; `.wasm` must be served with a
Wasm MIME type for streaming; imports object includes `wasm:js-string`; the
loader is ~6 KB and the module is a full program image.

## Compilation must be a build step, not a runtime trick

- No supported hook in `flutter build web` compiles extra entrypoints (R002 §4;
  the absence is verified from the web build sources, not from a failed attempt).
- Therefore the tool compiles the worker *before* (or alongside) the Flutter
  build and writes the artefact where the app serves it.
- The tool must be deterministic and fail loudly:
  - missing worker source → error;
  - compile failure → non-zero exit and the compiler's diagnostics;
  - artefact older than sources → error or rebuild, never “use stale file”;
  - missing artefact at runtime → typed error to the caller, no main-thread
    fallback (AGENTS.md rule 12/17).

## Runtime handshake

Because worker startup is asynchronous and can fail at several stages
(fetch, parse, runtime init, task registration), the protocol needs:

```text
host            worker
 │  spawn()
 ├──────────────►│  (script loads)
 │◄──────────────┤  ready { protocolVersion, capabilities }
 ├──────────────►│  request { taskId, operation, payload }
 │◄──────────────┤  result  { taskId, payload } | error { taskId, … }
 ├──────────────►│  shutdown
 │◄──────────────┤  closed
```

A worker that never sends `ready` within a timeout must be terminated and the
`spawn()` future completed with an error.

## Task selection and tree shaking

`run(fn)` cannot work (R004 §2). The generated registry must contain **static**
references:

```dart
final Map<String, Object? Function(Object?)> _tasks = {
  'calculatePrimes': (Object? input) => calculatePrimes(input! as int),
};
```

A function referenced only by name in data would be tree-shaken away. Generation
must therefore emit real Dart references (R004 §6, **UNRESOLVED** until a
generated-registry probe is run).

## Artefact layout

```text
web/
└── dwi/
    ├── worker.dart.js        # compiled JS worker (checked in? no — generated)
    ├── worker.dart.js.map    # optional, dev builds only
    └── worker.wasm/.mjs      # later, Wasm backend
```

Generated artefacts are build output: they belong in `.gitignore` and in the
build step's output, not in source control (except for M001, where the POC keeps
a build script and ignores the artefact).

## Debugging

- Keep the unminified `-O1`/`-O0` worker build in debug mode; source maps help.
- Worker errors appear in DevTools under a separate target; the protocol must
  forward the stack trace to the main thread for it to be visible in app logs.
- `Worker.terminate()` is abrupt: the worker cannot flush logs on kill.

## Verification status

- **Verified**: single-entrypoint Flutter compilation; self-contained dart2js
  output; Wasm artefact structure; CSP rule; `web/` copying (source-inferred).
- **Unverified**: ESM output from `dart compile js`; generated-registry tree-shaking;
  actual artefact placement in `build/web` on this SDK version (M001 will confirm).
