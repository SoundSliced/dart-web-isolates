# Benchmarks

Methodology and recorded results. A benchmark without a machine, browser and
commit is not a result.

## Recorded so far

### M001 — main thread vs worker (Chrome 156 headless, macOS arm64, 8 cores)

Workload: 40 × sieve to 5,000,000. Dart 3.13.5, Flutter 3.47.6.

| Run | Main thread (ms) | Frames during | Dropped | Worker wall (ms) | Frames during | Dropped |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 618.3 | 0 | 37 | 692.0 | 42 | 0 |
| 2 | 615.9 | 0 | 36 | 714.7 | 43 | 0 |
| 3 | 612.7 | 0 | 36 | 680.1 | 41 | 0 |
| 4 | 620.4 | 0 | 37 | 733.6 | 44 | 0 |

Full JSON: `../experiments/dart_worker_poc/evidence/`.

Interpretation:

- The worker keeps the UI rendering while executing the same work.
- Worker wall time includes startup (7–15 ms) and messaging; compute-only time is
  the message round trip.
- Dropped frames are derived from wall time at 60 Hz because a fully blocked main
  thread emits no frame timings.

### Browser capability harness — Chrome 156

Worker startup 59.6 ms cold, 6.3 ms module-worker start; 4 MiB transfer round
trip 0.6 ms; 2,000,000 sieve in a worker 20.8 ms. See
`../docs/browser-matrix.md`.

## Planned suites

| Suite | Workloads | Status |
| --- | --- | --- |
| `native_isolate/` | same tasks via `Isolate.run` | planned |
| `web_main_thread/` | main-thread baseline | M001 covers one workload |
| `web_worker/` | JS worker backend | M001 covers one workload |
| `wasm_worker/` | dart2wasm worker | blocked on loader work |
| Messaging | 1 KB, 100 KB, 1 MB, 10 MB, 100 MB, copy vs transfer | planned |
| Lifecycle | startup, shutdown, pool warmup, dispatch | harness data exists for startup |

## Rules

1. Report median and spread over ≥3 runs; never a single run.
2. Name machine, OS, browser version, Dart/Flutter version and commit.
3. `not run` is not zero. Unsupported platforms are excluded, not scored.
4. Concurrency claims need a frame/latency measurement, not only wall time.
5. Optimisations require before/after numbers in the same environment.

## Improving the M001 measurement

- Use a visible (non-headless) browser for frame timing validation.
- Add a worker pool mode to separate startup cost from dispatch cost.
- Record memory where the browser exposes it.
- Run the same workload on Firefox/Safari/Edge once those environments exist.
