# Benchmarks

Benchmark sources. Results are committed under `results/` together with the
machine, browser versions and commit that produced them; methodology lives in
`docs/benchmarks.md`.

## Suites

| Directory | Measures |
| --- | --- |
| `native_isolate/` | Baseline: `Isolate.run` and long-lived isolate on the VM. |
| `web_main_thread/` | Baseline: the same work on the browser main thread. |
| `web_worker/` | Dart compiled with dart2js, executed in a Web Worker. |
| `wasm_worker/` | Dart compiled with dart2wasm, executed in a Web Worker (when supported). |

## Workloads

CPU: fibonacci, prime sieve, JSON parse/transform, sorting, hashing, image
transform. Messaging: 1 KB, 100 KB, 1 MB, 10 MB, 100 MB. Lifecycle: worker
startup, shutdown, pool warmup, dispatch latency. Flutter: frame time, dropped
frames, input latency.

## Reporting rules

- Never report a single run. Report distribution (median and spread) over
  repeated runs.
- Never compare across machines without saying so.
- A benchmark that cannot run on a platform is reported as "not run", not as
  zero.
