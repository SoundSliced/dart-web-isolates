# JS vs dart2wasm worker benchmark

Reproducible comparison of the two worker backends on the same machine, task
code and host bundle. It is a measurement, not a superiority claim: results are
per workload and must be read with the recorded versions.

## What it measures

| Metric | How |
| --- | --- |
| Build time | in-process `DwiBuilder.build()` for `target=js` and `target=wasm` |
| Worker bytes | the files recorded in the worker manifest (sum) |
| Host bytes | one `dart compile js -O2` of the same page for both backends |
| Cold start | 10 × `DwiWorker.spawn()` including `ready`, then close |
| Warm dispatch | 50 sequential `noop` calls on one handle, after 5 warmups |
| CPU work | 5 × prime sieve to 2,000,000, round trip |
| UI responsiveness | 3 × sieve to 10,000,000 in the worker and the same work on the main thread, with a 16 ms timer; the main-thread run is the control |
| Small payload | 1 KiB typed array × 10, copied |
| Large payload | 1 MiB typed array × 5, copied |
| Transferable | 1 MiB `DwiTransferableBytes` × 5; sender detachment is checked |
| Memory | `performance.memory.usedJSHeapSize` once at the end (coarse, Chrome-only) |

Every metric is a distribution; the report records min, median, p95 and max,
plus the commit, machine, browser and Dart versions.

## Running it

```bash
cd benchmarks/wasm_worker
dart pub get
dart run run.dart
```

The runner creates a throwaway app in the system temp directory, builds the
worker for both targets, compiles one dart2js host, serves `web/` on a loopback
port and loads each target in headless Chrome. It writes
`audit/evidence/wasm-worker-benchmark-<date>.json`.

A target that cannot run is reported as "not run" with the reason, never as
zero. The harness drives the public `package:dwi` API only.
