# Dart Web Isolates (DWI)

**Background parallel execution for Dart and Flutter Web, with the same
programming model on native.**

Dart web applications have no `dart:isolate`. `Isolate.run`, `Isolate.spawn`,
`SendPort` and `ReceivePort` are unavailable under `dart2js`, `DDC` and
`dart2wasm`, and Flutter's `compute()` therefore runs on the main thread on web.
DWI investigates closing that gap with browser Web Workers, a versioned message
protocol, and — where it is honest to do so — an isolate-shaped API.

> **Status: research proven, packages at 0.2.0, not published.** DWI is not an
> isolate implementation and does not claim semantic parity with `dart:isolate`.
> Read [`docs/limitations.md`](docs/limitations.md) and
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
**Verdict: PASS WITH LIMITATIONS** — Chrome measured; Firefox, Safari and Edge
not verified (see [`docs/browser-matrix.md`](docs/browser-matrix.md)).

## Packages

| Package | What it does | Status |
| --- | --- | --- |
| `dwi` | Public API: `Dwi.configure`, `Dwi.run`, `Dwi.capabilities` | implemented, 6 tests |
| `dwi_core` | Config, capabilities, task registry, exceptions, backend interface | implemented, 9 tests |
| `dwi_protocol` | Protocol v1 envelopes, error payloads, validation | implemented, 8 tests |
| `dwi_native` | Isolate backend | implemented, 6 tests |
| `dwi_web` | Pooled Web Worker backend with timeouts and typed errors | implemented, browser-tested |

```dart
Dwi.registerTask('primes', (input) => countPrimes(input! as int));
await Dwi.configure(const DwiConfig(workerScript: 'dwi/worker.dart.js'));
final count = await Dwi.run<int>('primes', 5000000);
```

On native the same call runs on an isolate. On web it needs a compiled worker
entrypoint; there is no main-thread fallback. Closures are not supported and
cannot be until the compiler can help (see
[`docs/compiler-strategy.md`](docs/compiler-strategy.md)).

## Repository layout

```text
docs/                architecture, protocol, limitations, browser matrix
research/            evidence reports R001–R010
packages/            dwi, dwi_core, dwi_protocol, dwi_web, dwi_native
experiments/         M001 proof with raw measurement evidence
examples/            runnable examples
integration_tests/   browser integration tests (protocol end to end)
benchmarks/          methodology and recorded results
```

## Quickstart

Native example:

```bash
cd examples/fibonacci
dart pub get
dart run bin/main.dart 30
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
