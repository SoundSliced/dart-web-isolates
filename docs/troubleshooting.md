# Troubleshooting

Each entry gives the symptom as the error text the code produces, the cause, and
the fix. Errors are typed; match on the type, not the text, in application code.

## Startup

**`DwiStartupException`: "did not send ready within …"** (or a "worker … failed"
text).
Cause: the worker script did not load, or it loaded but never reported ready
before `DwiConfig.startupTimeout` (default 10 s).
Fix: check that `workerScript` points to the served path of the generated worker
(default `dwi/worker.dart.js`). Run `dart run dwi_builder:dwi check` to see whether
the artefact is missing or stale. A missing worker fails with a typed error; DWI
never falls back to the main thread (limitation 21).

**`DwiStartupException`: "worker reported protocol version N; the host speaks
protocol M"** (or "did not report a protocol version").
Cause: the worker was built by a different DWI version, so its messages differ
from the host's (ADR-026 G3).
Fix: rebuild the worker with the same DWI version as the host (`dart run
dwi_builder:dwi build --force`), then reload the page.

**`DwiStartupException`: "worker reported backend … but … was requested".**
Cause: the worker is a dart2js build but `workerBackend` is set to Wasm, or the
reverse (ADR-018).
Fix: set `DwiConfig.workerBackend` to the compiler that built the worker, or
rebuild with the target you configured.

## Flutter web build

**`flutter build web` fails on a fresh app that uses DWI typed proxies.**
Cause: Flutter's build hook orders the worker build after its own compile on the
first build (`docs/upstream/flutter-web-hook-ordering.md`, measured on Flutter
3.47.6 and later).
Fix: run `dart run dwi_builder:dwi build` once before the first `flutter build
web`. The second build succeeds.

**The page loads but the worker returns 404.**
Cause: the worker is not under the served path. Flutter copies `web/` into
`build/web`; a worker generated after the copy is missing from it.
Fix: rebuild with `flutter build web` after `dwi build`, and serve `build/web`.

## Calls

**`DwiUnsupportedException`: "task queue is full (N waiting)".**
Cause: more calls wait for a worker than `DwiConfig.maxQueuedTasks` (default 64).
Fix: raise `maxQueuedTasks`, or limit how many calls you start at once.

**`DwiTimeoutException` while queued.**
Cause: a call waited longer than `queueTimeout` (default 30 s) for a worker.
Fix: raise `maxWorkers` or `queueTimeout`, or find the long-running task (see
`Dwi.poolState()` and `Dwi.metrics()`, ADR-026 G1 and G2).

**`DwiTimeoutException` while running.**
Cause: the task exceeded `taskTimeout` (default 30 s). The worker is terminated.
Fix: make the task shorter, or raise `taskTimeout`.

**A payload is rejected as too large.**
Cause: the input exceeds `DwiConfig.maxPayloadBytes` (default 64 MiB).
Fix: split the input into chunks, or raise `maxPayloadBytes` if the memory is
acceptable. The browser matrix raised it to 128 MiB for its 100 MiB case.

**Cancelling a running call did not keep the worker.**
Cause: without `DwiConfig.cancelGracePeriod`, cancelling a running call
terminates its worker (ADR-010, ADR-027). With a grace period the task may still
finish, and a pooled worker is kept only if it returns within that period.
Fix: set `cancelGracePeriod` and check `DwiCancelToken` in long tasks.

**A late result arrived after a cancel and was ignored.**
Cause: expected. The host ignores the reply of a call that has already settled
(ADR-027). It is not an error.

## Hot restart and teardown

**Workers keep running after a Flutter hot restart.**
Cause: DWI does not replace workers on hot restart. The facade keeps its backend
in static state, so a restart that re-initialises it drops the reference to live
workers (ADR-026 G5, decided 2026-11-14).
Fix: call `Dwi.close()` in your teardown path. Use `Dwi.poolState()` to see which
workers are still live.

## Browsers

**`safaridriver` refuses to create a session.**
Cause: Safari's remote automation is off.
Fix: in Safari, open Develop, then Allow Remote Automation, and restart Safari.

**Workers do not start under a strict Content Security Policy.**
Cause: the policy lacks `worker-src 'self'` (or equivalent), or it blocks
`blob:` workers. DWI loads workers from a same-origin URL only (limitation 19).
Fix: allow `worker-src 'self'`. The browser matrix runs under such a policy
(`audit/evidence/browser-matrix-csp-2026-11-14.json`).

## Native

**Each `Dwi.run` call starts a new isolate.**
Cause: on native, `Dwi.run` uses one isolate per call, with no shared pool or
queue (see `DwiPoolState`). For reuse, use `DwiWorker.spawn()`.
