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

### v0.4 runtime suite — Chrome 156 headless (2026-11-04)

Harness: `benchmarks/browser_matrix` (committed, reproducible). Environment:
macOS arm64 26.5.1, Apple M2, 8 GiB RAM, Dart 3.13.5, Chrome 156.0.8078.80
headless. Three runs, each run's medians taken inside the page.

| Measurement | Median (min–max) |
| --- | --- |
| Cold start (first call after configure) | 33 ms (26–35) |
| Warm dispatch round trip | 0.2 ms (0.101–0.2) |
| 64 KiB copy / transfer | 0.3 ms / 0.3 ms |
| 1 MiB copy / transfer | 1.5 ms (1.199–1.599) / 1.0 ms (0.9–1.099) |
| 8 MiB copy / transfer | 10.0 ms (9.3–10.1) / 6.399 ms (6.0–6.599) |
| Queued cancellation | 0.1 ms (0.1–0.101) |
| Running cancellation | 0.199 ms (0.101–0.2) |
| 100 tasks / 4 workers, bounded queue | 66 ms (43–97), 100/100 settled |
| Dead idle worker → next call succeeds | 11 ms (10–13) |
| UI ticks during 300 ms worker CPU / same work on main thread | 29 / 0 |

Interpretation:

- Transfer wins at size (about 36% faster at 8 MiB) and is noise at 64 KiB.
  Copying is never faster, so the wrapper's ownership rules cost nothing here.
- Running cancellation is cheap because it terminates the worker rather than
  waiting for it to notice.
- Heartbeat detection replaces a dead idle worker well inside `taskTimeout`.
- The UI-isolate control measurement (0 ticks for the same work on the main
  thread) is what makes the worker number meaningful.

Full data: `../audit/evidence/browser-matrix-chrome-2026-11-04.json`.
Safari, Firefox and Edge were not measured and stay **unverified**
(`docs/browser-matrix.md` records the exact blocker for each).

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
