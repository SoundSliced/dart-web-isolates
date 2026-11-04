# Limitations

Known gaps, stated plainly. This file is part of the public contract: if a
limitation is not here or in `compatibility-matrix.md`, that is a bug.

## Semantic limitations

1. **No closure or function-value execution.** Work is selected by task name from
   a precompiled registry. `Dwi.run(() => ...)` does not exist. This is the
   largest difference from `Isolate.run` (R004 §2).
2. **No shared mutable Dart state, and no shared immutable state either.** Every
   payload is copied or transferred; there is no equivalent of the VM's canonical
   object sharing (R001 §2, R003 §3).
3. **No `SendPort`/`ReceivePort`.** A later port model can only be an emulation
   over one transport, with logical IDs (R001 §3, R003 §5).
4. **`kill` is `terminate()`.** No pause, resume, `Isolate.ping`, or graceful
   `Isolate.exit`; in-flight work and queued work are lost.
5. **Startup cost is paid per worker.** Pooling amortises it; there is no
   zero-cost spawn (M001, R003 §7).
6. **Errors are reconstructed, not propagated.** A `DwiRemoteException` carries
   what the worker captured; the local stack trace is the host side only.

## Engineering limitations

7. **Worker compilation is automatic for Flutter web on Flutter 3.47+.** A
   `dwi_builder/hook/build.dart` build hook runs during `flutter run -d chrome`
   and `flutter build web` when `dwi_builder` is a normal dependency (ADR-009).
   Older Flutter versions, plain Dart web apps and CI checks use
   `dart run dwi_builder:dwi build`; `--flutter-build` wraps the Flutter build
   after the worker step for that path. Web build hooks do not expose the target
   OS, so a multi-platform app with `web/index.html` also runs the (cached)
   worker build during native builds.
8. **Discovery covers annotated top-level functions only.** `Dwi.run(fn)`,
   function tear-offs, closures and arbitrary expression bodies are not
   supported; generated typed proxies (`DwiTasks.foo(input)`) are the supported
   call shape. The annotation cannot be inferred from a call site without
   compiler cooperation (R013 §4.4).
9. **Generated proxies require one generated import.** Application code imports
   `lib/dwi_tasks.g.dart`; task libraries import
   `package:dwi_annotations/dwi_annotations.dart` rather than the host facade,
   so the worker closure stays pure. The generated files are build output and
   are gitignored.
10. **Task libraries must be worker-safe.** Flutter, `dart:ui`, `dart:io`,
    `dart:html` and `dart:isolate` in the task import closure are build errors
    (`DWI002`). Browser-safe `package:web` is allowed, but DOM objects are not
    transferable (`DWI001`).
11. **Serialization is structural and type-directed in v0.3.1.** Primitives,
    nullable forms, `List<T>`, `Set<T>`, `Map<String, V>` and typed data
    (`Uint8List`, other typed lists, `ByteData`, `ByteBuffer`) round-trip.
    Generated codecs validate decoded values on both sides and fail with
    `DwiSerializationException` naming the path; they never silently coerce.
    Custom classes, enums, records, functions, streams, `DateTime` and
    non-String map keys are build errors (`DWI001`).
12. **Payload size is enforced approximately.** `DwiConfig.maxPayloadBytes` is
    checked by the host before send and by the worker for results (the limit is
    sent in request metadata). The estimate counts strings by UTF-16 code units,
    so it is a resource guard rather than an exact wire size.
13. **Generated-registry tree shaking is verified for tested shapes.** The
    generated worker uses static references, and v0.3 compiles and runs in
    Chrome. A universal proof for every library shape is not claimed.
14. **Wasm worker generation is not implemented.** Wasm requires a `.wasm` +
    `.mjs` loader pair and a module worker (R005). No Wasm support is claimed.
15. **Runtime compilation is not implemented and is not planned for v0.x.** A
    browser-hosted Dart compiler, CSP `eval` restrictions, size and attack
    surface make it non-viable on current evidence (R013 §4.5).
16. **No hot reload of a running worker.** A rebuild produces a new script;
    existing workers keep the old one. Reload the page (or hot restart) after
    the build hook or `dwi watch` rebuilds. Flutter hot reload does not reload
    the worker script.
17. **Queueing and deadlines are bounded.** Waiting callers are capped by
    `maxQueuedTasks` (failing with `DwiUnsupportedException` when full) and by
    `queueTimeout` (failing with `DwiTimeoutException`). `taskTimeout` starts
    only after a worker is executing the call; `startupTimeout` bounds the
    `ready` handshake. `close()` settles queued and in-flight work immediately
    and is idempotent. A worker whose startup fails repeatedly stops being
    respawned after three consecutive failures.
18. **Only Chrome has been measured.** Firefox, Safari and Edge are unverified
    (M001_FINDINGS, docs/browser-matrix.md).
19. **No Flutter `compute()` integration.** Changing Flutter's web `compute()`
    is an upstream proposal, not a package feature.

## Operational limitations

19. **CSP and hosting matter.** Worker scripts need `worker-src` permission and a
    same-origin (or CORS) URL. Blob workers are not supported by design.
20. **No cross-origin isolation requirement for the JS backend**, but any future
    shared-memory work would require COOP/COEP and change deployment.
21. **Stale artefacts are fatal by design.** `dwi check` fails when generated
    sources, the manifest hash or the compiled artefact are stale, and a
    missing worker fails with a typed startup error. DWI never silently falls
    back to the main thread.

## Research debt (unresolved, tracked)

- Generated-registry tree shaking for every library shape (the tested shapes
  compile; R004 unresolved for the general case).
- ESM output from `dart compile js` for module workers.
- WasmGC and `js-string` browser support matrix.
- Worker memory limits on mobile browsers.
- Flutter Wasm runtime inside a worker.
