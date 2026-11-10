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

**Pooled state differs between backends.** `Dwi.run` starts a fresh isolate per
call on native, but on web it reuses an idle pooled worker, so worker-local state
can persist between `Dwi.run` calls. Measured with the published 0.5.3 packages:
two sequential `Dwi.run('tick')` calls returned `1` then `2` in Chromium 156.
Use `Dwi.runFresh` (ADR-016) when a call must not observe earlier state; it pays
startup per call. `dart:isolate`'s `Isolate.run` always starts fresh, so this is
a documented DWI-4 gap in `Dwi.run`, closed only by the explicit fresh API.

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
   typed `DwiTasks` proxies need that one pre-build step. The ordering gap was
   re-measured on 2026-11-05 with a writable SDK; `tooling/proxy_gate`
   reproduces it and exits non-zero if the first build ever starts succeeding.
   Older Flutter
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
14. **Wasm worker generation is experimental.** `dwi build --target=wasm`
    publishes a content-addressed `gen-<generation>/` directory (module and
    loader) plus a small `worker.boot.mjs` entry that is switched atomically;
    the host must opt in with
    `workerBackend: DwiWorkerBackend.wasm`. It is not part of any supported
    release statement. A dart2wasm worker receives JS numbers as `double`
    (generated `int` decoders and meta fields accept integral doubles), and
    uncaught Wasm failures are coarse, so failures stay in-band.
    Deployment constraints are measured on all four engines: `.wasm` must be
    served as `application/wasm` and `.mjs` as a JavaScript type; a CSP must
    allow `worker-src` for the entry and `'wasm-unsafe-eval'` for compilation;
    and the entry plus its `gen-*` generation must be same-origin with the page
    (cross-origin workers are rejected). Every unsupported configuration ends
    in a typed `DwiStartupException`, never a JS/main-thread fallback; message
    text is engine-specific. A dart2wasm host with a dart2wasm worker and
    Flutter hook integration are not verified here (ADR-018,
    `audit/evidence/dart2wasm-worker-deployment-2026-11-10.txt`).
15. **Runtime compilation is not implemented and is not planned for v0.x.** A
    browser-hosted Dart compiler, CSP `eval` restrictions, size and attack
    surface make it non-viable on current evidence (R013 §4.5).
16. **No hot reload of a running worker.** Re-measured on Flutter 3.47.6 stable
    (2026-11-05) with `flutter run -d chrome` (debug): a hot reload rebuilds
    `web/dwi/worker.dart.js` (the build hook recompiled it, sha256 changed), but
    the live page keeps its existing `Worker` and every task result for the next
    8 s still came from the old code. A hot restart reloads the page and the app
    then uses the rebuilt worker. `flutter run -d web-server` serves and runs the
    app, but this environment has no Dart Debug Chrome extension, so the reload
    command never completed and web-server hot reload is **unverified** here (no
    result is claimed for it). In release mode (`flutter run -d chrome
    --release`) Flutter still prints the `r`/`R` key commands, but pressing them
    produced no reload — a worker change needs a manual page reload. `dwi watch`
    plus a page reload behaves the same way. v0.5 does not replace a running
    worker automatically (ADR-009 amendment); a hot restart or reload is
    required, and no state survives it.
17. **Queueing and deadlines are bounded.** Waiting callers are capped by
    `maxQueuedTasks` (failing with `DwiUnsupportedException` when full) and by
    `queueTimeout` (failing with `DwiTimeoutException`). `taskTimeout` starts
    only after a worker is executing the call; `startupTimeout` bounds the
    `ready` handshake. `close()` settles queued and in-flight work immediately
    and is idempotent. A worker whose startup fails repeatedly stops being
    respawned after three consecutive failures.
18. **Browser coverage differs by harness.** The capability probe and the
    compiler matrix are Chrome-only; the v0.4 runtime benchmark covers Chrome and
    Safari; the v0.5 handle matrix covers Chrome, Safari, Firefox and Edge.
    `docs/browser-matrix.md` records which engine each cell came from.
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
27. **v0.4 is measured in Chrome and Safari.** Cancellation, transfer and
    heartbeat behaviour in Firefox and Edge is **unverified** for this level;
    Safari automation needs "Allow remote automation", and Edge could not be
    installed on the measurement machine (`docs/browser-matrix.md`).
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
34. **Dedicated handles are verified on web in Chrome, Safari, Firefox and
    Edge.** Each engine passes the same handle contract on three page loads
    (`docs/browser-matrix.md`).
35. **Handle memory is reported coarsely.** Only process RSS is observable in
    the benchmark, with ~16 KiB granularity; no per-handle memory figure is
    claimed (`docs/benchmarks.md`).
36. **No port-like messaging or streams.** The handle exposes `run`,
    `runCancellable`, `restart` and `close` only. `SendPort`/`ReceivePort`
    emulation remains a separate, later ADR.
29. **dart2wasm host support is measured in all four engines.** A dart2wasm
    application (`flutter build web --wasm`) can host DWI since the 2026-11-05
    integral-double fix. A 2026-11-10 Flutter 3.47.6 matrix measured, at `/`:
    dart2wasm host + dart2js worker (control), dart2wasm host + dart2wasm
    worker, and dart2js host + dart2wasm worker in Chrome 157, Edge 157,
    Firefox 159 and Safari 26.5. The two Wasm-worker combinations also passed
    at `/sub/app/`; the control was measured at `/` only. The Flutter build hook
    reads `dwi.yaml` for the target (ADR-018,
    `audit/evidence/flutter-wasm-worker-matrix-2026-11-10.txt`).
    A dart2wasm **host** additionally receives channel `gen` values as
    `double`; the host normalizes them, and a channel exchange is part of the
    measured contract. No debug/profile wasm-host run, hot restart or PWA
    offline behaviour is claimed.

## DWI-3 limitations (channels, ADR-014)

37. **Single subscriber.** A channel has one `messages` listener; a second
    `listen` throws. There is no broadcast mode and no replay for a late
    subscriber.
38. **Bounded per channel, not global.** `channelBufferSize` bounds outstanding
    sends per channel and per direction; many channels multiply memory. A
    consumer that stops reading causes further sends to be rejected with
    `DwiChannelBufferException` rather than dropping messages.
39. **No port parity.** Channels are not `SendPort`/`ReceivePort`: no port
    objects, no port transfer, no shared memory, no synchronous send, no
    cross-channel ordering, no selective receive, no pause/resume.
40. **Handles only.** A channel belongs to one `DwiWorker`. It cannot cross to
    another handle or isolate, and it does not survive `close()` or `restart()`.
41. **No implicit channel deadline.** Pending sends settle only on peer close,
    handle failure or handle close. A caller that needs a deadline applies its
    own; DWI never silently drops a message.
42. **Protocol v2 required.** A v1 worker artefact cannot open channels and is
    rejected with `DwiUnsupportedException`. Rebuild it with `dwi build`.
43. **Channel errors are lifecycle errors.** A remote task error remains a task
    result/error; a channel error always ends the channel.

## v0.7 limitations (handle termination observation, ADR-017)

44. **Observation only, not an event log.** `stopReason` holds one reason for
    the current context generation and `stops` emits one broadcast event per
    terminal transition. There is no history, no replay to late subscribers and
    no exit message. Read `stopReason` when subscribing late.
45. **The first terminal cause wins.** A later `close()` on a failed handle does
    not overwrite `stopReason` and does not emit a second event. When a crash,
    timeout, running cancellation and explicit close race, the transition that
    started first is reported; the others are ignored.
46. **A failed restart is not a stop event.** `restart()` clears `stopReason`
    when the replacement starts. If the replacement cannot start, `restart()`
    throws `DwiStartupException` and no stop event is emitted: no running
    context stopped. A listener that was subscribed before the restart stays
    subscribed for the next real termination.
47. **Call-local failures are not stops.** A queued-call timeout, a full queue,
    an unknown task, a call-local serialization failure and a task-level
    `DwiRemoteException` leave the context healthy and emit nothing. `stops`
    never replaces or suppresses the typed error delivered to a call.
48. **No `dart:isolate` parity.** `stopReason`/`stops` are DWI concepts.
    `dart:isolate` has no timeout, cancellation or restart-generation state, so
    they are not `Isolate.onExit`/`onError` analogues.
49. **Closing a handle does not wait for a stop listener.** The final event and
    stream completion are queued when `close()` runs; a paused or slow
    subscriber cannot hold worker teardown. It receives the queued event before
    `done` when it resumes, or it can cancel. This applies to an explicit
    `close()`, `Dwi.close()`, and a failed-then-closed handle, and repeated
    `close()` remains prompt and idempotent.
50. **All four engines are measured for this increment.** Chrome 157.0.8103.38,
    Safari 26.5, Firefox 159.0.1 and Edge 157.0.4341.42 each pass three page
    loads of the ADR-017 contract. Firefox requires disabling every per-process
    sandbox its build exposes under this host; the engine result is independent
    and recorded in `docs/browser-matrix.md`.

## Research debt (unresolved, tracked)

- Generated-registry tree shaking for every library shape (the tested shapes
  compile; R004 unresolved for the general case).
- ESM output from `dart compile js` for module workers.
- WasmGC and `js-string` browser support matrix.
- Worker memory limits on mobile browsers.
- Flutter Wasm runtime inside a worker.
