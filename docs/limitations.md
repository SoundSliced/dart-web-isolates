# Limitations

Known gaps, stated plainly. This file is part of the public contract: if a
limitation is not here or in `compatibility-matrix.md`, that is a bug.

## Semantic limitations

1. **No arbitrary function or closure execution.** Work is selected from
   a precompiled registry. Generated `DwiFunctions` adapters accept only
   registered static tear-offs; they do not transport functions.
   `Dwi.run(() => ...)` does not exist. This is the
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
   normal dependency (ADR-009). In the build-system path Flutter compiles the
   application before, or concurrently with, the hook: `dart2js` does not depend
   on the web `build_hooks` target, and hook outputs feed linking only. On a
   project with no generated proxies yet, `dart2js` can therefore start before
   the hook writes `lib/dwi_tasks.g.dart`; run `dart run dwi_builder:dwi build`
   once (or `dwi build --flutter-build`) before the first Flutter build. A fresh
   project that calls `Dwi.run` and imports no generated proxy compiles on the
   first ordinary Flutter command (measured 2026-11-04, root and `/sub/app/`),
   but typed `DwiTasks` proxies need that one pre-build step. Re-measured
   2026-11-10 on Flutter 3.47.6 / Dart 3.13.5: first builds fail for
   `--release`, `--wasm` and `--debug`, while `flutter run -d chrome` (debug)
   **succeeds** because the resident web runner awaits the hooks before its DDC
   compile. `tooling/proxy_gate` reproduces the gap and exits non-zero if the
   first build ever starts succeeding. The current stable release is 3.47.9
   (2026-10-29); its source and `master` still omit the hooks target from
   `Dart2WebTarget.dependencies`, so no released SDK fixes this. A
   disposable-SDK prototype that makes the web compiler depend on
   `BuildHooks(platform: web)` passes on the first command for js and wasm; the
   fix is upstream-only and unmerged — no package-level mechanism exists (see
   `docs/upstream/flutter-web-hook-ordering.md`).
   Older Flutter
   versions, plain Dart web apps and CI checks use
   `dart run dwi_builder:dwi build`; `--flutter-build` wraps the Flutter build
   after the worker step for that path. Web build hooks do not expose the target
   OS, so a multi-platform app with `web/index.html` also runs the (cached)
   worker build during native builds.
8. **Discovery requires explicit annotations.** Public top-level functions and
   static methods of public non-generic classes and enums are supported.
   Nothing else is: static methods of extensions and extension types,
   `external` functions, constructors, fields, local functions and annotated
   type declarations are build errors (`DWI003`), not tasks, and are never
   skipped silently. Generated
   `DwiFunctions.run(task, input)` / `run0(task)` select their existing typed
   proxies (ADR-020, since 0.9.0). Unregistered functions,
   closures and instance tear-offs fail with `DwiUnknownTaskException` before
   startup; this cannot inspect captures or give capture-specific diagnostics.
   `Dwi.run(fn)` and arbitrary body lifting remain unsupported.
   Native execution and all four JS/Wasm host-worker pairs pass in Chrome,
   Safari, Firefox and Edge; evidence is
   `audit/evidence/dwi5-static-acceptance-2026-11-13T012032.json`.
   The host retains task-library references, so a host that imports the
   generated file carries a copy of the task code the worker also contains;
   a host that only calls `Dwi.run` by name carries none. Measured on a
   one-task fixture (Dart 3.13.7, `-O2`): typed proxy +906 B JS / +869 B Wasm
   and `DwiFunctions` +1532 B JS / +1837 B Wasm over the name-only host. The
   duplicated part grows with the task library; only the fixed adapter part is
   bounded (`host_bundle_cost_test.dart`,
   `audit/evidence/dwi5-host-bundle-cost-2026-11-11T214451.json`).
   [`R016`](../research/R016_DWI5_FUNCTION_FEASIBILITY.md) and
   [`ADR-019`](adr-019-dwi5-function-execution.md) retain the separate
   arbitrary-function research decision. DWI-5/DWI-6 are not raised.
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
    Public enums, `DateTime`, `Duration`, `BigInt`, `Uri`, records and
    `@DwiPayload` classes are converted by generated code (ADR-021, since
    0.9.0; native and all sixteen browser cells,
    `audit/evidence/payload-types-acceptance-2026-11-13T012032.json`). A payload class is rebuilt from its constructor
    parameters: identity, other state and the runtime subtype are not
    preserved, and a cyclic object graph is not supported. Classes without
    `@DwiPayload`, functions, streams and non-String map keys are build errors
    (`DWI001`). The name-based `Dwi.run` does no conversion.
12. **Payload size is enforced approximately.** `DwiConfig.maxPayloadBytes` is
    checked by the host before send and by the worker for results (the limit is
    sent in request metadata). The estimate counts strings by UTF-16 code units,
    so it is a resource guard rather than an exact wire size.
13. **Generated-registry tree shaking is verified for tested shapes.** The
    generated worker uses static references, and v0.3 compiles and runs in
    Chrome. A universal proof for every library shape is not claimed.
14. **Wasm worker generation is supported as an opt-in backend (since 0.8.0).** `dwi build --target=wasm`
    publishes a content-addressed `gen-<generation>/` directory (module and
    loader) plus a small `worker.boot.mjs` entry that is switched atomically;
    the host must opt in with
    `workerBackend: DwiWorkerBackend.wasm` or `dwi.yaml: target: wasm`. It is
    not the default; a missing or unsupported configuration never falls back. A dart2wasm worker receives JS numbers as `double`
    (generated `int` decoders and meta fields accept integral doubles), and
    uncaught Wasm failures are coarse, so failures stay in-band.
    Deployment constraints are measured on all four engines: `.wasm` must be
    served as `application/wasm` and `.mjs` as a JavaScript type; a CSP must
    allow `worker-src` for the entry and `'wasm-unsafe-eval'` for compilation;
    and the entry plus its `gen-*` generation must be same-origin with the page
    (cross-origin workers are rejected). Every unsupported configuration ends
    in a typed `DwiStartupException`, never a JS/main-thread fallback; message
    text is engine-specific. A dart2wasm host with a dart2wasm worker and
    Flutter hook integration are covered by the 2026-11-10 matrices (ADR-018,
    `audit/evidence/dart2wasm-worker-deployment-2026-11-10.txt`,
    `audit/evidence/flutter-wasm-worker-matrix-2026-11-10.txt`).

    **Retention is the deployment's job, not the build's.** A build never
    deletes a published `gen-*` generation, because a browser can keep the
    `worker.boot.mjs` it cached and that bootstrap names one generation until it
    is revalidated. Removing a generation is an explicit deployment-maintenance
    action, after the window in which the deployment promises cached bootstraps
    stay valid. A cached bootstrap whose generation was removed fails with a
    typed `DwiStartupException`; it never loads a mixed generation. Serving the
    entry with a long cache lifetime combined with short generation retention is
    therefore unsupported. Flutter 3.47.6's generated service worker caches
    nothing (it unregisters itself), so these are HTTP cache-header decisions;
    a client is safe only while its generation is either retained by the
    deployment or still in the browser cache. Measured in Chrome, Safari,
    Firefox and Edge, for both the DWI fixture and a real Flutter 3.47.6
    production build
    (`audit/evidence/cached-bootstrap-deployment-2026-11-10.txt`,
    `audit/evidence/flutter-production-cache-2026-11-10.txt`,
    `audit/evidence/flutter-production-cache-four-engines-2026-11-10.txt`).
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
27. **The v0.4 pool contract is measured in all four engines; its benchmark is
    not.** Timeout, overflow, close, startup failure, cancellation, transfer
    and heartbeat pass in Chrome 157.0.8103.78, Safari 26.5, Firefox 159.0.1
    and Edge 157.0.4341.46 (2026-11-11, `audit/evidence/pool-lifecycle-four-engines-2026-11-11T220557.json`).
    The timing benchmark in `docs/browser-matrix.md` still covers Chrome and
    Safari only. Cancelling a call whose worker is still starting is supported
    since this run: it was ignored before, which Safari exposed.
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
36. **Streams are per-call contexts; there are no port objects.** A task may
    return `Stream<T>` (ADR-022, since 0.9.0): each listen spawns a fresh
    context, cancelling terminates it and discards undelivered items, and
    `taskTimeout` bounds the whole stream. A stream task cannot run on the
    pool. Native and all sixteen browser cells pass
    (`audit/evidence/stream-tasks-acceptance-2026-11-13T012032.json`).
    Two handles can be connected with `DwiWorker.link` (ADR-023, checkout
    only): the host relays every message (one extra copy and hop), both ends
    acknowledge on consumption, and the surviving worker sees a closed channel,
    not an error, when its peer fails. There are no `SendPort`/`ReceivePort`
    objects and no direct worker-to-worker path. Native and all sixteen
    browser cells pass (`audit/evidence/worker-link-acceptance-2026-11-13T100732.json`).
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
51. **A missing worker asset fails startup.** The worker error event may omit
    its message when the script returns 404. Both pooled calls and dedicated
    handle creation now settle with `DwiStartupException` in that case; there
    is no fallback to another worker generation or to the main thread. The
    regression is covered for missing JS and Wasm entries by a real-browser
    test in Chrome.
52. **An absent optional `dwi.yaml` costs an incremental hook run.** Flutter's
    file cache marks missing inputs dirty, so the hook declares `dwi.yaml` even
    when absent. Creating it after a successful build now selects the requested
    target on the next ordinary build, without a source touch or clean. While
    it remains absent, Flutter reruns the hook on every build (the builder's
    content hash still avoids recompiling an unchanged worker). A disposable
    Flutter 3.47.6 release app was measured switching js → wasm → js by file
    creation and deletion alone.

## Research debt (unresolved, tracked)

- Generated-registry tree shaking for every library shape (the tested shapes
  compile; R004 unresolved for the general case).
- ESM output from `dart compile js` for module workers.
- WasmGC and `js-string` browser support matrix.
- Worker memory limits on mobile browsers.
- Flutter Wasm runtime inside a worker.
