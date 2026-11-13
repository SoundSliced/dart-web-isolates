# Current State — 2026

Ground truth for Phase 0 of DWI. This document answers the twenty questions in
the project plan (§13) directly, and points at the evidence. It distinguishes
what was verified from source or measurement from what remains unresolved.

Environment: Dart 3.13.5 (stable, 2026-09-29) shipped with Flutter
`3.47-candidate.0` (engine `692136cb6582dbfc5af3fb33c2515a069f2f66d0`), macOS
arm64. Evidence base: `dart-lang/sdk` @ `e21f9245`, MDN/WHATWG pages fetched
2026-11-03, local probes in `.research/probes/`.

**That environment is the recording stamp for the answers below, not the
current toolchain.** Since 2026-11-13 the project uses a single SDK for research
and implementation — Dart 3.15.0-133.0.dev at `.research/dart-sdk-dev/dart-sdk`
(see `docs/benchmarks.md` § Project toolchain). Anything in this document or in
`research/` that cites 3.13.5/3.13.7 stays valid for the version it names and is
not restated as a 3.15 result.

Release status: **0.8.0 is published on pub.dev** (2026-11-10, all seven
packages; `dwi_builder` and `dwi` carry the opt-in dart2wasm worker backend,
ADR-018). The dart2js worker is still the default; the Wasm worker is opt-in and
experimental. Release notes and the deployment/cache contract:
`docs/release-notes-0.8.0.md`, `audit/evidence/pub-0.8.0-upload-2026-11-10.txt`.
The answers below describe the platform research that release is built on, not
the release mechanics.

## Answers

**1. Why exactly is `dart:isolate` unavailable under dart2js?**
It is not unavailable at compile time: all web targets map `dart:isolate` to a
platform patch (`sdk/lib/libraries.json:607` dart2js, `:509` dart2wasm, `:796`
DDC) whose members throw `UnsupportedError`. The VM implementation depends on a
process-wide port registry (`runtime/vm/port.h:34`), isolate groups sharing a
heap (`runtime/vm/isolate.h:321`), and graph copying/serialisation
(`runtime/vm/message_snapshot.h:16`). None of that exists in a JS realm.
Verified compile + runtime probe: `Isolate.run` reaches `RawReceivePort`, which
throws.

**2. What does its web stub contain?**
`Isolate.current`, `spawn`, `spawnUri`, `kill`, listeners, `RawReceivePort` and
`TransferableTypedData.fromList` throw `UnsupportedError`; `ReceivePort`
construction succeeds but its stream never delivers (R004 §3, R005 §3). DDC's
message is explicit: `dart:isolate is not supported on dart4web`.

**3. What happens under dart2wasm?**
Same shape, different patch (`sdk/lib/_internal/wasm/common/isolate_patch.dart`):
compilation succeeds, every operation throws at runtime (R005 §3).

**4. Where does `Isolate.run()` resolve in each compiler?**
It is ordinary Dart in `sdk/lib/isolate/isolate.dart:253`, built on
`Isolate.spawn` + `RawReceivePort`; each compiler resolves those to its patch, so
all three web targets fail at the same conceptual point.

**5. Where is `Isolate.spawn()` implemented?**
Declared `external` at `isolate.dart:461`; VM patch in
`sdk/lib/_internal/vm/lib/isolate_patch.dart`; web patches throw.

**6. How are SendPorts represented internally?**
As capabilities carrying a global port ID; `SendPort implements Capability`
(`isolate.dart:849`), and the VM maps IDs to isolate message handlers in
`PortMap` (`runtime/vm/port.h:34`). Ports are sent inside messages via
`kSendPortCid` (`message_snapshot.cc:3079`).

**7. How does message serialization work in the Dart VM?**
Same isolate group: `CopyMutableObjectGraph` (`message_snapshot.cc:3396`), sharing
only deeply immutable objects. Across groups: snapshot write/read
(`message_snapshot.h:16`, `ReadMessage`). `TransferableTypedData` is a single-use
byte payload (R001 §4).

**8. How does `compute()` dispatch by platform?**
Conditional import keyed on `dart.library.js_interop`
(`packages/flutter/lib/src/foundation/isolates.dart:13`). Native →
`Isolate.run` (`_isolates_io.dart:19-30`); web → call the callback on the current
thread after `await null` (`_isolates_web.dart`). Verified from source.

**9. Which Flutter tooling controls web compilation?**
`packages/flutter_tools/lib/src/web/compile.dart` (single `target` parameter,
`:70`) and `compiler_config.dart` (compiler selection). The build invokes the
Dart compiler; no extra-entrypoint hook was found (R002 §3-4).

**10. How are secondary Dart entrypoints compiled?**
By invoking the Dart compiler again:
`dart compile js -o worker.js worker.dart` (R004 §5), or
`dart compile wasm` for the Wasm pair (R005 §1). There is no shared-runtime
mechanism between independent compilations.

**11. Which browser Worker APIs are accessible through `package:web`?**
`Worker` (`html.dart:12804`), `WorkerOptions` (`:12836`), `WorkerGlobalScope`
(`:12461`), `DedicatedWorkerGlobalScope` (`:12659`, `postMessage` `:12682`),
`MessagePort.postMessage` (`:12372`), `StructuredSerializeOptions` (`:12394`),
`navigator.hardwareConcurrency` (`:11957`, worker-side `:13058`). Verified in
package:web 1.1.2.

**12. What WebAssembly threading facilities are usable?**
Shared linear memory requires `WebAssembly.Memory({shared: true})` (needs
`maximum`) plus `SharedArrayBuffer`, which needs a secure context and
cross-origin isolation (MDN, 2026-11-03). Wasm `memory.atomic.*` follows from
that. **UNVERIFIED**: engine support matrix for Wasm threads in 2026.

**13. What restrictions exist around WasmGC?**
dart2wasm emits GC types and imports the `js-string` builtin module
(`isolate_run.mjs:6`, `:171`). A browser without WasmGC + `js-string` cannot run
the output. **UNVERIFIED**: minimum versions per engine; must be measured.

**14. What happens to closures during Dart compilation?**
A captured closure becomes a JS object whose fields hold the environment;
tear-offs become cached function objects registered by name
(`closure_o0.js:2808`, `:2814-2816`, `:3218`). Nothing serialisable survives
(R004 §2).

**15. Can functions be identified reliably during compilation?**
Yes at the source/AST level, and generated code can hold static references that
keep them alive. No compiler metadata channel for “compile this function into a
worker” was found. A name in a string is not a reference and can be tree-shaken
(R004 §6).

**16. What tree-shaking complications exist?**
Reachability is a whole-program property (`WorldImpact`,
`pkg/compiler/lib/src/universe/world_impact.dart:22`). Generated dispatch tables
must use static references; string-keyed reflection is removed. v0.3 compiles a
generated static-reference registry and runs it in Chrome; the general case is
still not proven for every library shape. **PARTIALLY RESOLVED**

**17. Can worker entrypoints share compiled modules?**
Not with independent `dart compile js` invocations; each output contains the
runtime (R004 §5). Deferred loading splits one compilation, not two entrypoints.

**18. Can workers load Flutter-generated Wasm?**
Not established. A Flutter Wasm app is not a plain dart2wasm module loader; it
has its own bootstrap. **UNRESOLVED / experiment**.

**19. What CSP restrictions affect worker startup?**
`worker-src` (fallback `child-src`, `script-src`); `blob:` workers need explicit
permission; cross-origin scripts need CORS or fail with an `error` event
(R003 §2). **UNVERIFIED**: exact per-engine fallback behaviour.

**20. What browser compatibility constraints exist?**
Dedicated workers are universally available; module workers, WasmGC,
`js-string`, SharedArrayBuffer and CSP behaviour vary. Every cell must be
measured per engine (R008). Cross-origin isolation is required only for shared
memory, which the JS backend does not need.

## The four findings that shape the architecture

1. **`dart:isolate` on web is a deliberate stub, not an oversight.** Two closed
   SDK issues and the patch files make that clear.
2. **Closures cannot cross realms.** Any API taking a function value must either
   regenerate code (not feasible) or address a precompiled task (feasible).
3. **A worker is a second compilation.** Flutter's build compiles one entrypoint
   and exposes no extra-entrypoint hook.
4. **Errors need a protocol.** Platform events alone cannot reproduce
   `RemoteError` with a stack trace, and unhandled rejections disappear.

## What is still unknown (tracked as research debt)

- Tree shaking of a generated task registry (probe planned).
- Whether `dart compile js` can emit ESM for module workers.
- Engine support and cost of WasmGC/`js-string`; Wasm threads matrix.
- Flutter Wasm runtime inside a worker.
- Worker startup and messaging latency on real hardware (M001 measures).
- CSP behaviour per engine (M001 measures).

## Evidence map

| Question area | Report |
| --- | --- |
| VM isolates, ports, serialization | `R001_DART_ISOLATE_ARCHITECTURE.md` |
| Flutter `compute()` and web build | `R002_DART_WEB_LIMITATIONS.md` |
| Browser workers, clone, transfer | `R003_WEB_WORKERS.md` |
| dart2js/DDC, closures, tree shaking | `R004_DART2JS.md` |
| dart2wasm, Wasm workers/threads | `R005_DART2WASM.md` |
| Serialization comparison | `R006_MESSAGE_SERIALIZATION.md` |
| Worker compilation and artefacts | `R007_WORKER_COMPILATION.md` |
| Browser matrix framework | `R008_BROWSER_COMPATIBILITY.md` |
| Prior art | `R009_EXISTING_PACKAGES.md`, `../docs/prior-art.md` |
| Upstream issues | `R010_UPSTREAM_DART_ISSUES.md` |
