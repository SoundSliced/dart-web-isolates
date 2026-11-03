# R005 — dart2wasm, Wasm Workers and Threads

Status: research report · Agent: 3 (Wasm) · Evidence: `dart-lang/sdk`
@ `e21f924582d55790da4fec00ce179db5629ab6c6`, Dart 3.13.5, `dart compile wasm`
on a local probe; MDN for browser security requirements.

Browser-version support matrices are deliberately marked **UNVERIFIED** where no
authoritative page was fetched: this report does not invent version numbers.

## Summary

- `dart compile wasm` emits two artefacts: a `.wasm` module and a `.mjs` loader.
  The loader compiles the module with the `js-string` builtins and instantiates
  it with an imports object whose only custom namespace observed in the probe is
  `wasm:js-string`.
- `dart:isolate` has a Wasm platform patch too, and like dart2js it throws
  `UnsupportedError` for every operation that matters. Compilation succeeds;
  isolation does not exist.
- Wasm modules are loaded and instantiated per realm. A worker can therefore host
  its own Wasm instance — this is **Strategy A**, and it is the only strategy
  available without shared memory.
- Shared linear memory (**Strategy B**) requires `WebAssembly.Memory({shared: true})`,
  which requires a `SharedArrayBuffer`, which requires a secure context and
  cross-origin isolation (COOP/COEP). This is orthogonal to Dart's object model:
  it shares bytes, not Dart objects.
- dart2wasm currently has no way to share a Dart heap across instances, and the
  `dart:isolate` patch confirms it does not attempt to.

## 1. Output artefacts and loading

Probe: `.research/probes/isolate_run.dart` compiled with
`dart compile wasm -o isolate_run.wasm isolate_run.dart`:

```text
Generated wasm module 'isolate_run.wasm', and JS init file 'isolate_run.mjs'
```

Sizes for this trivial program: `isolate_run.wasm` 16,304 bytes,
`isolate_run.mjs` 6,334 bytes.

The `.mjs` loader (lines cited from the generated file):

- `export async function compileStreaming(source)` and `export async function
  compile(bytes)`, both calling `WebAssembly.compileStreaming/compile` with
  `{builtins: ['js-string']}` (`isolate_run.mjs:5-15`).
- `CompiledApp.instantiate(...)` builds `baseImports`, `additionalImports` and
  imports `"wasm:js-string": jsStringPolyfill`, then
  `WebAssembly.instantiate(this.module, {..., "wasm:js-string": jsStringPolyfill})`
  (`isolate_run.mjs:168-175`).
- `InstantiatedApp.invokeMain(...args)` calls
  `this.instantiatedModule.exports.$invokeMain(args)` (`isolate_run.mjs:180-186`).
- Deferred-load support is parameterised through `loadDeferredModules` /
  `loadDeferredId` callbacks documented in the loader header
  (`isolate_run.mjs:24-40`).

Compiler side:

- `pkg/dart2wasm/lib/compile.dart`, `code_generator.dart`, `closures.dart`,
  `dispatch_table.dart`, `dynamic_dispatch_table.dart`,
  `deferred_load/`, `deferred_loading.dart`.
- Module building goes through `pkg/wasm_builder` (also in the sparse clone).

Implication for a worker: the worker must load the `.mjs`, which in turn fetches
and compiles the `.wasm`. This is asynchronous and requires the artefact to be
served with `application/wasm` (streaming compilation) or fetched as bytes.

## 2. WasmGC and the `js-string` builtins

- The generated loader requests the `js-string` builtin module
  (`isolate_run.mjs:6`, `:13`, `:171`). A browser that does not support the
  builtin cannot instantiate this output as-is.
- dart2wasm's object model relies on WasmGC (struct/array types, reference
  types); `closures.dart`, `class_info.dart`, `dispatch_table.dart` and
  `constructor_info.dart` in `pkg/dart2wasm/lib` are built around GC types.
- **UNVERIFIED**: minimum browser versions for WasmGC + `js-string` in 2026. Any
  concrete matrix must be measured or sourced from caniuse/MDN per browser, and
  belongs in `docs/browser-matrix.md`, not here.

## 3. `dart:isolate` under Wasm

`dart:wasm` mapping: `sdk/lib/libraries.json:509-515` selects
`_internal/wasm/common/isolate_patch.dart` and disables conditional imports.

The patch (`sdk/lib/_internal/wasm/common/isolate_patch.dart`):

| Member | Line | Behaviour |
| --- | --- | --- |
| `Isolate.debugName` | 18 | `UnsupportedError` |
| `Isolate.current` | 23 | `UnsupportedError` |
| `Isolate.spawn` | 42-51 | `throw UnsupportedError("Isolate.spawn")` |
| `Isolate.spawnUri` | 55-70 | `throw UnsupportedError("Isolate.spawnUri")` |
| `ReceivePort` | 132 | `throw UnsupportedError("ReceivePort")` |
| `RawReceivePort` | 145 | `UnsupportedError` |
| `Capability` | 153 | `UnsupportedError` |
| `TransferableTypedData.fromList` | 161 | `UnsupportedError` |

Coordinator-verified: the same program compiles under `dart compile wasm`
(exit 0), so the failure is runtime-only — identical in shape to dart2js, with
slightly different line numbers and messages.

## 4. Strategy A — one Wasm instance per worker (recommended direction)

```text
Main page (Wasm instance)          Worker (separate Wasm instance)
    │  postMessage(structured clone)   │
    └─────────────►  message  ────────►│
                                       │  fetch worker.wasm + worker.mjs
                                       │  WebAssembly.instantiate(...)
                                       │  invokeMain -> task dispatch
    ◄────────────  result  ────────────┘
```

Properties:

- Separate linear memories and separate GC heaps: closest analogue to
  isolate-style isolation.
- Data crosses as structured clone or transferable `ArrayBuffer` (R003). Dart
  objects do not cross; they must be encoded.
- Cost: a second full runtime instance (the trivial probe is 16 KB wasm + 6 KB
  loader, but real apps pull in the whole compiled program plus runtime).
- No COOP/COEP requirement.

## 5. Strategy B — shared-memory Wasm threads

- `WebAssembly.Memory({shared: true})` requires a `maximum` and a
  `SharedArrayBuffer` (MDN, WebAssembly.Memory, checked 2026-11-03).
- `SharedArrayBuffer` requires a secure context and cross-origin isolation;
  `crossOriginIsolated` reports it, and COOP/COEP headers are what create it
  (MDN, SharedArrayBuffer, checked 2026-11-03). Without isolation,
  `postMessage` of a `SharedArrayBuffer` throws.
- Wasm threads add `memory.atomic.*` and `wait`/`notify`; they share a linear
  memory, not Dart objects. Dart's GC heap cannot be placed in that memory in
  the current dart2wasm design (no evidence of support in `pkg/dart2wasm`).
- Consequence: Strategy B could accelerate bulk numeric pipelines, but it
  abandons the isolate mental model and imposes deployment requirements
  (headers) that many Flutter Web apps do not have.
- **UNVERIFIED**: current browser/engine support for Wasm threads and
  shared-everything in 2026; needs a measured matrix.

## 6. Loading a dart2wasm app inside a worker

Requirements established from the artefacts:

1. A **module worker** (`new Worker(url, {type: 'module'})`) is needed if the
   loader is loaded as an ES module; the generated `.mjs` uses `export`.
2. The worker must `fetch` the `.wasm` relative to the worker script URL, or be
   given an absolute URL; `compileStreaming` needs `application/wasm`.
3. CSP must allow `worker-src` for the worker script and `script-src`/`connect-src`
   for the module and wasm fetch (R003).
4. Cross-origin hosting of `.wasm` requires CORS; the loader does not inline the
   module.

## 7. What this means for DWI

- The Wasm backend is architecturally *simpler* than JS in one respect: the
  loader is explicit about instantiation, so a worker entrypoint is a pair of
  artefacts with a documented API.
- It is harder in another: the same compile-each-entrypoint problem applies, and
  the artefact graph is larger.
- No shared-object story exists. Any DWI API that implies sharing mutable state
  is unimplementable on both backends.

## Unresolved

- Browser version support for WasmGC and `js-string` builtins (needs measurement).
- Whether `dart compile wasm` can emit a worker-compatible module without the
  `invokeMain` bootstrap (i.e. a custom entrypoint that does not call `main`).
- Whether Flutter's Wasm runtime can be instantiated inside a worker at all.
- Performance comparison Strategy A vs main thread for realistic payloads.

## Verification status

- **Verified**: emitted artefact structure and import namespace; compile success
  for `dart:isolate`; patch behaviour line-by-line; MDN statements on
  `SharedArrayBuffer` and `WebAssembly.Memory`.
- **Unverified**: browser support versions; Wasm-thread support matrix; Flutter
  Wasm-in-worker feasibility.
