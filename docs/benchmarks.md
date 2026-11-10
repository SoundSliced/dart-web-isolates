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
Safari 26.5 was measured with the same harness; its numbers are in
`docs/browser-matrix.md` §2 and are never copied into this Chrome table.
Firefox and Edge were not measured for this benchmark and stay **unverified**
(`docs/browser-matrix.md` records the exact status of each).

### v0.5 handle lifecycle matrix (2026-11-05)

Harness: `../packages/dwi_builder/test/browser_handle_test.dart` (committed).
It drives the public `DwiWorker` API — state retention, isolation, FIFO, queue
bounds and deadline, close, timeout, cancellation, transferables, startup and
runtime failures, heartbeat, malformed message, restart, repeated spawn/close and
interleaved `Dwi.run` calls. Three page loads per engine, one shared assertion
list, one retry on a transport failure.

| Engine | Version | Result |
| --- | --- | --- |
| Chrome | 156.0.8078.80 (headless) | **pass**, 3/3 |
| Safari | 26.5 (`safaridriver`) | **pass**, 3/3 |
| Firefox | 159.0 (WebDriver BiDi) | **pass**, 3/3 |
| Edge | 156.0.4314.58 | **pass**, 3/3 |

This matrix measures behaviour, not speed; it produces no timing table. Evidence:
`../audit/evidence/handle-matrix-<engine>-20261106.json`.

### Dedicated handles vs the pool — native VM (2026-11-05)

Harness: `../benchmarks/native_handle` (committed). Environment: macOS arm64
26.5.1, Apple M2, 8 cores, Dart 3.13.5. Three runs; each row is the median of
the three per-run medians (per-run range in parentheses).

| Measurement | Median (range) |
| --- | --- |
| `DwiWorker.spawn()` → ready | 145 µs (123–185) |
| Handle dispatch, 100 calls | 32 µs/call (27–50) |
| Pool `Dwi.run`, 100 calls | 103 µs/call (95–109) |
| Cached primes 100k, one handle | 46 µs/call (44–49) |
| Cached primes 100k, `Dwi.run` | 616 µs/call (607–631) |
| `close()` | 12 µs (12–13) |
| `restart()` after a failure | 107 µs (104–110) |
| RSS with four live handles | +16 KiB measured (16–131 KiB) |

Interpretation:

- Spawn is sub-millisecond at the median; the first spawn in each run reached
  10–12 ms, which is lazy Dart runtime/library initialisation, not the steady
  state.
- The same trivial task costs about 3× less through a handle because the pool
  starts an isolate per call. Both are microsecond-scale dispatches.
- The retained-state workload is the measured case for handles: a sieve cached
  inside the context turns ~616 µs into ~46 µs per call. That is why `Dwi.run`
  remains the default for one-off work and a handle is for repeated work.
- Close and restart are sub-millisecond.
- Memory is reported as process RSS, whose granularity is ~16 KiB. The deltas
  (16–131 KiB for four handles, 16–32 KiB retained after close) are too coarse
  for a per-handle claim; no such claim is made.
- These are VM numbers only. The Chrome suite proves handle behaviour, not these
  timings; web startup cost remains the numbers in the v0.4 section.

Full harness: `../benchmarks/native_handle/`.

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

### JS vs Wasm worker — Chrome 157 headless (2026-11-10)

Harness: `../benchmarks/wasm_worker/` (committed, reproducible). Environment:
macOS arm64 26.5.1, Apple M2 (8 cores), Dart 3.13.5, Chrome 157.0.8103.50
headless. Same task code, one dart2js host bundle, one page load per backend;
distributions are inside the page. Full data:
`../audit/evidence/wasm-worker-benchmark-2026-11-10.json`.

| Measurement (median, p95) | dart2js worker | dart2wasm worker |
| --- | --- | --- |
| Build (in-process) | 2,377 ms | 2,206 ms |
| Worker artefact bytes | 312,509 | 99,859 |
| Cold start | 8.3 ms, 15.6 | 10.6 ms, 104.6 |
| Warm dispatch | 0.1 ms, 0.2 | 0.1 ms, 0.2 |
| Sieve 2,000,000 | 29.4 ms, 41.7 | 7.5 ms, 19.5 |
| Sieve 10,000,000 in worker | 151.8 ms, 158.4 | 68.8 ms, 69.3 |
| Main thread, same 10,000,000 sieve | 161.0 ms, 162.3 | 185.3 ms, 211.4 |
| UI ticks during worker sieve | 9 | 4 |
| UI ticks during main-thread sieve | 0 | 0 |
| 1 KiB copy | 0.2 ms, 72.9 | 0.2 ms, 101.3 |
| 1 MiB copy | 1.3 ms, 1.8 | 0.8 ms, 1.1 |
| 1 MiB transfer | 0.3 ms, 5.6 | 0.4 ms, 6.1 |
| Heap used at end | ~53.9 MB | ~53.8 MB |

Interpretation:

- The Wasm worker artefact is ~68% smaller (99,859 vs 312,509 bytes) for this
  task set; the host bundle was identical (145,428 bytes).
- Cold start and warm dispatch are indistinguishable at this precision. One
  cold-start outlier (104.6 ms) was measured for Wasm; it is reported, not
  smoothed away.
- The Wasm worker was faster on this CPU workload (2,000,000 sieve: 7.5 vs
  29.4 ms median; 10,000,000: 68.8 vs 151.8 ms). This is one workload on one
  engine and is not a general superiority claim.
- Both backends keep the UI thread responsive: the worker run left the 16 ms
  timer ticking (4–9 ticks), while the same sieve on the main thread produced
  zero ticks. The worker number is only meaningful next to that control.
- Copied 1 MiB payloads were comparable (0.8 ms Wasm vs 1.3 ms JS median);
  transferable 1 MiB stayed sub-millisecond at the median with occasional
  multi-millisecond outliers in both backends. Sender detachment was true in
  every run.
- Heap use is a single coarse figure from `performance.memory`, identical within
  noise; it is not a per-worker memory measurement.

Not measured: Firefox, Safari and Edge benchmarks; startup percentiles above
p95; long soak; Wasm host + Wasm worker separately (the host here is dart2js).
