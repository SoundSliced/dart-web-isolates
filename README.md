# Dart Web Isolates (DWI)

**Background parallel execution for Dart and Flutter Web, with the same
programming model on native.**

Dart web applications have no `dart:isolate`. `Isolate.run`, `Isolate.spawn`,
`SendPort` and `ReceivePort` are unavailable under `dart2js`, `DDC` and
`dart2wasm`, and Flutter's `compute()` therefore runs on the main thread on web.
DWI investigates closing that gap with browser Web Workers, a versioned message
protocol, and — where it is honest to do so — an isolate-shaped API.

> **Status: 0.9.0 is prepared for publication (2026-11-13).** It adds
> registered static functions (`DwiFunctions`, ADR-020), generated payload
> types (`@DwiPayload`, enums, `DateTime`, records…, ADR-021) and tasks that
> return `Stream<T>` (ADR-022). The previous release, 0.8.1 (2026-11-10). v0.8
> adds the opt-in dart2wasm worker backend (ADR-018); 0.8.1 settles missing
> worker assets as typed startup failures. v0.7 adds
> handle termination observation (`DwiWorker.stopReason`, `stops`, ADR-017),
> the scoped lifetime helper (`DwiWorker.using`, ADR-015) and the first DWI-4
> increment (`Dwi.runFresh`, ADR-016). v0.5 adds long-lived worker handles
> (`DwiWorker`): one dedicated worker or isolate per handle, with worker-local
> state retained between calls. v0.4 adds cancellation, transferable bytes and
> crash detection.
> DWI is not an isolate implementation and does not claim semantic parity with
> `dart:isolate`. Read [`docs/limitations.md`](docs/limitations.md) and
> [`docs/compatibility-matrix.md`](docs/compatibility-matrix.md) before relying
> on it.

## What was proven

M001 (see [`experiments/dart_worker_poc/M001_FINDINGS.md`](experiments/dart_worker_poc/M001_FINDINGS.md))
runs identical CPU work on the main thread and in a worker, measured in Chrome
156 on an 8-core machine:

| Mode | Task time | Frames during task | Dropped frames |
| --- | --- | --- | --- |
| Main thread | 613–620 ms | 0 | 36–37 |
| Web Worker | 680–734 ms wall | 41–44 | 0 |

Same result (348,513 primes) both ways; worker errors return a typed envelope.
**Verdict: PASS WITH LIMITATIONS** — M001 is Chrome-only; Firefox, Safari and
Edge were not measured for that experiment. The v0.5 handle matrix is measured
separately in Chrome, Safari, Firefox and Edge, and the capability probe remains
Chrome-only: see [`docs/browser-matrix.md`](docs/browser-matrix.md).

## Packages

All seven packages are published on pub.dev at **0.8.1** (2026-11-10); 0.9.0
is prepared for publication (2026-11-13).

| Package | What it does | Status |
| --- | --- | --- |
| `dwi` | Public API: `Dwi.configure`, `Dwi.run`, `Dwi.runFresh`, `DwiWorker` (tasks, scoped lifetime, channels, termination observation), `Dwi.capabilities`, re-exported `@DwiTask` | implemented, 38 tests |
| `dwi_annotations` | `@DwiTask` marker | implemented, 2 tests |
| `dwi_builder` | Analyzer discovery, worker/proxy/manifest generation, compile CLI, cache | implemented, 57 tests |
| `dwi_core` | Config, capabilities, task registry, exceptions, channel endpoint, backend and handle interfaces | implemented, 32 tests |
| `dwi_protocol` | Protocol v2 envelopes (tasks and channels), error payloads, validation | implemented, 14 tests |
| `dwi_native` | Isolate backend plus dedicated persistent-isolate handles and channels | implemented, 62 tests |
| `dwi_web` | Pooled Web Worker backend, dedicated-handle and channel backend, generated-worker runtime | implemented, 23 tests, browser-tested |

## Zero-boilerplate workers (v0.3)

Annotate a top-level function or public class static method; DWI discovers it, generates the worker entrypoint
and typed proxy, compiles the worker, and writes the manifest:

```dart
// lib/tasks.dart
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int calculatePrimes(int limit) {
  // ...
}
```

```dart
// lib/main.dart
import 'package:dwi/dwi.dart';
import 'dwi_tasks.g.dart';

final count = await DwiTasks.calculatePrimes(5000000);
```

```bash
dart run dwi_builder:dwi build
# or run the Flutter build after the worker step:
dart run dwi_builder:dwi build --flutter-build -- --release
```

`DwiConfig.workerScript` defaults to `dwi/worker.dart.js`, so no path
configuration is required. `dart run dwi_builder:dwi watch` rebuilds on task
changes; `check` fails when generated sources or the artefact are stale. See
[`docs/automatic-workers.md`](docs/automatic-workers.md).

The lower-level named-task API remains available:

```dart
Dwi.registerTask('primes', (input) => countPrimes(input! as int));
final count = await Dwi.run<int>('primes', 5000000);
```

Registered static tear-offs can also select the existing typed proxy (ADR-020,
since 0.9.0):

```dart
import 'tasks.dart';
import 'dwi_tasks.g.dart';

final count = await DwiFunctions.run(calculatePrimes, 5000000);
```

`DwiFunctions.run0(task)` accepts registered zero-input tasks. Unknown
functions, closures and instance tear-offs fail with `DwiUnknownTaskException`;
a registered task called through an incompatible caller signature fails with
`DwiUnsupportedException`. [`examples/automatic_worker`](examples/automatic_worker)
shows the call.
no function is transported or executed locally. Direct static-method proxies
are named `DwiTasks.Class$method`. On native these calls run on an isolate;
on web there is no main-thread fallback. Arbitrary functions and closures
remain unsupported (see
[`docs/compiler-strategy.md`](docs/compiler-strategy.md) and
[`research/R013_RUNTIME_WORKER_COMPILATION.md`](research/R013_RUNTIME_WORKER_COMPILATION.md)).
The measured DWI-5 feasibility decision is in
[`research/R016_DWI5_FUNCTION_FEASIBILITY.md`](research/R016_DWI5_FUNCTION_FEASIBILITY.md).

## Long-lived worker handles (v0.5)

`Dwi.run` is a pool: each call may land on a different worker, and a native call
starts a fresh isolate. When several calls must share warm worker-local state or
identity, own one dedicated context explicitly:

```dart
final worker = await DwiWorker.spawn();

try {
  final first = await worker.run<int>('counter', null);   // 1
  final second = await worker.run<int>('counter', null);  // 2
} finally {
  await worker.close();
}
```

- One handle owns one persistent isolate (native) or one dedicated Web Worker
  (web). It does not borrow a `Dwi.run` pool slot.
- Calls run one at a time in FIFO order; `DwiConfig.maxQueuedTasks` and
  `DwiConfig.queueTimeout` bound the queue.
- `runCancellable` reuses `DwiCancellableTask` unchanged.
- A timeout, crash, malformed message, heartbeat failure, or cancelling a
  running call moves the handle to `failed`. Queued calls settle with
  `DwiWorkerFailedException`. Recovery is an explicit `restart()` (fresh state)
  or a new `spawn()`; DWI never retries a call.
- `close()` is immediate and idempotent; `Dwi.close()` closes live handles too.
- `stopReason` and `stops` (ADR-017) report *why* the current context stopped —
  including an idle crash that no call observed — with one broadcast event per
  context generation. A queued timeout or a remote task error emits nothing; the
  first terminal cause wins. See [`examples/stop_observer/`](examples/stop_observer/).

For one block of work, `DwiWorker.using` owns the handle instead of you:

```dart
final values = await DwiWorker.using((worker) async {
  final first = await worker.run<int>('counter', null);   // 1
  final second = await worker.run<int>('counter', null);  // 2
  return (first, second);
});
```

The helper closes the handle when the callback returns or throws (ADR-015). It
does not wait for calls you forgot to await: on exit, `close()` cancels active
work. See [`examples/scoped_worker/`](examples/scoped_worker/).

Losing a handle loses its state. Use a handle for repeated work that benefits
from a warm cache or retained identity; use `Dwi.run` for one-off tasks. See
[`examples/stateful_worker/`](examples/stateful_worker/) and ADR-013 in
[`docs/architecture.md`](docs/architecture.md).



```text
docs/                architecture, protocol, limitations, browser matrix
research/            evidence reports R001–R013
packages/            dwi, dwi_annotations, dwi_builder, dwi_core, dwi_protocol,
                     dwi_web, dwi_native
experiments/         M001 proof with raw measurement evidence
examples/            runnable examples
integration_tests/   browser integration tests (protocol end to end)
benchmarks/          methodology and recorded results
```

## Quickstart

Automatic worker example (Dart web):

```bash
cd examples/automatic_worker
dart pub get
dart run dwi_builder:dwi build
dart compile js -O1 -o web/main.dart.js lib/main.dart
python3 -m http.server 8080 --directory web
# open http://localhost:8080/
```

Native example:

```bash
cd examples/fibonacci
dart pub get
dart run bin/main.dart 30
```

Dedicated handle example (worker-local state persists between calls):

```bash
cd examples/stateful_worker
dart pub get
dart run bin/main.dart
```

M001 demo (Flutter Web):

```bash
cd experiments/dart_worker_poc
flutter pub get
dart run tool/build_worker.dart
flutter build web --release
python3 tool/measure_server.py &
# open http://127.0.0.1:8082/?auto=1 for a self-driving run
```

Browser integration test (protocol end to end):

```bash
cd integration_tests/web_backend
dart pub get
dart compile js -O1 -o build/worker.js worker.dart
dart compile js -O1 -o build/client.js test_client.dart
cp index.html build/index.html
python3 serve.py
# open http://127.0.0.1:8090/
```

## Principles

- No shared mutable Dart state across the boundary, by default.
- No browser API leaks into the public API.
- Web JS and Web Wasm are separate targets and documented separately.
- Every concurrency claim ships with a reproducible benchmark.
- Semantic gaps against `dart:isolate` are documented, not emulated deceptively.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and the mandatory engineering rules in
[`AGENTS.md`](AGENTS.md). Security reports: [`SECURITY.md`](SECURITY.md).

## Licence

BSD-3-Clause. See [`LICENSE`](LICENSE).
