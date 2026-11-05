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

7. **Worker compilation is automatic for Flutter web on Flutter 3.47+, with one
   ordering caveat.** A `dwi_builder/hook/build.dart` build hook runs during
   `flutter run -d chrome` and `flutter build web` when `dwi_builder` is a
   normal dependency (ADR-009). Flutter compiles the application before, or
   concurrently with, the hook: `dart2js` does not depend on the web
   `build_hooks` target, and hook outputs feed linking only. On a project with
   no generated proxies yet, `dart2js` can therefore start before the hook
   writes `lib/dwi_tasks.g.dart`; run `dart run dwi_builder:dwi build` once (or
   `dwi build --flutter-build`) before the first Flutter build. A fresh project
   that calls `Dwi.run` and imports no generated proxy compiles on the first
   ordinary Flutter command (measured 2026-11-04, root and `/sub/app/`), but
   typed `DwiTasks` proxies need that one pre-build step. Older Flutter
   versions, plain Dart web apps and CI checks use
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
16. **No hot reload of a running worker.** Measured on Flutter 3.47.6 stable
    (2026-11-05) in both `flutter run -d chrome` (debug) and
    `flutter run -d web-server`: a hot reload does rebuild the worker artefact on
    disk (the build hook recompiled it), but the running page keeps its existing
    `Worker`, so the app still runs the old code. A hot restart reloads the page
    and the app then uses the rebuilt worker. In release mode
    (`flutter run -d chrome --release`) Flutter still prints the `r`/`R` key
    commands, but pressing them produced no reload — a worker change needs a
    manual page reload. `dwi watch` plus a page reload behaves the same way.
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

## v0.4 limitations

22. **Cancellation is termination, not cooperation.** A web task cannot observe
    a cancel message while it runs synchronous code, so `cancel()` on a running
    task terminates the worker and settles the call with
    `DwiCancelledException`. There is no cancellation token and no partial
    result. Native cancellation kills the isolate for the same reason.
23. **Native detachment is bookkeeping.** `DwiTransferableBytes` moves bytes
    with `TransferableTypedData`, which does not detach the sender's memory.
    `isDetached` is a DWI flag there, so a second send is refused by DWI rather
    than by the VM. On web the detach is real (`byteLength == 0`).
24. **A transfer is one-way.** After a successful send the bytes belong to the
    worker. A timeout, cancel or crash means they are gone; retrying needs a new
    `DwiTransferableBytes`.
25. **Heartbeats only cover idle workers.** A busy worker is never pinged,
    because a synchronous task cannot answer until it returns. A worker that
    hangs while busy is still bounded by `taskTimeout`, not by the heartbeat.
26. **The heartbeat is a liveness probe, not a health check.** It detects a
    worker that can no longer reply (closed, crashed without an `error` event).
    It does not detect a worker that answers but computes wrongly.
27. **v0.4 is measured in Chrome only.** Cancellation, transfer and heartbeat
    behaviour in Safari, Firefox and Edge is **unverified**; Safari automation
    needs "Allow remote automation", and Firefox/Edge were not installed on the
    measurement machine (`docs/browser-matrix.md`).
## v0.5 limitations (dedicated handles)

28. **One handle runs one task at a time.** Extra calls queue in FIFO order up to
    `DwiConfig.maxQueuedTasks`; a full queue fails with
    `DwiUnsupportedException`, and `DwiConfig.queueTimeout` bounds the wait.
    There is no parallel dispatch inside one handle. Create more handles when
    you need concurrency.
29. **Worker-local state is not durable.** Closing a handle, a task timeout, a
    crash, a heartbeat failure, or cancelling a running call loses everything the
    task kept inside the context. No state survives a restart, and DWI never
    restores or migrates it.
30. **Replacement is explicit.** A failed handle stays failed; recovery is
    `restart()` or a new `DwiWorker.spawn()`. Queued and in-flight calls settle
    with `DwiWorkerFailedException`/the specific error and are never replayed.
31. **`close()` is immediate.** It cancels queued and running calls with
    `DwiWorkerClosedException` and terminates the context; there is no graceful
    drain variant. Await the work you want to finish before closing.
32. **Cancelling a running call destroys the handle.** A running task cannot
    observe a cancel message, so running cancellation is termination, after
    which the handle is `failed`.
33. **Handles capture their tasks and config at spawn.** The native isolate gets
    a snapshot of the `DwiTaskRegistry`; tasks registered or config changed after
    `spawn()` are not visible to that handle. Create a new handle to pick them
    up.
34. **Dedicated handles are Chrome-verified only on web.** Native tests run on
    the Dart VM; Firefox, Safari and Edge handle behaviour is **unverified**
    (`docs/browser-matrix.md`).
35. **Handle memory is reported coarsely.** Only process RSS is observable in
    the benchmark, with ~16 KiB granularity; no per-handle memory figure is
    claimed (`docs/benchmarks.md`).
36. **No port-like messaging or streams.** The handle exposes `run`,
    `runCancellable`, `restart` and `close` only. `SendPort`/`ReceivePort`
    emulation remains a separate, later ADR.
29. **dart2wasm host support is new and Chrome-only.** A dart2wasm application
    (`flutter build web --wasm`) can host DWI since the 2026-11-05 fix that
    lets the envelope accept integral doubles for `v`, `id` and
    `error.taskId`; before it, the first envelope failed with
    `message.v must be an int`. The worker is still a dart2js artefact — there
    is no wasm worker — and the combination is measured only in Chrome 156 on
    Flutter 3.47.6 stable. Firefox, Safari and Edge are unverified for wasm as
    for every other cell.

## Research debt (unresolved, tracked)

- Generated-registry tree shaking for every library shape (the tested shapes
  compile; R004 unresolved for the general case).
- ESM output from `dart compile js` for module workers.
- WasmGC and `js-string` browser support matrix.
- Worker memory limits on mobile browsers.
- Flutter Wasm runtime inside a worker.
