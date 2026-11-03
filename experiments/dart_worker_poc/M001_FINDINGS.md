# M001 Findings — Dart in a Worker

**Verdict: PASS WITH LIMITATIONS**

Date: 2026-11-03 · Machine: macOS arm64, 8 logical cores · Dart 3.13.5 ·
Flutter 3.47.6 (stable) · Chrome 156 headless.

## Question

Can a Flutter Web application execute CPU-bound Dart code in a browser Web
Worker while the Flutter UI keeps rendering, and can the result and an error be
returned correctly?

## Method

The POC (`README.md` in this directory) runs two identical workloads:

- 40 passes of a prime sieve to 5,000,000 (`countPrimes`), returning the count.
- Mode A: on the page's main thread.
- Mode B: in a dedicated Web Worker started from `worker.dart.js`, compiled with
  `dart compile js -O1`.

The page renders a continuous animation and counts frames with a `Ticker`.
`framesDuring` is the ticker delta over the task window; `droppedFrames` is
`floor(taskMs / 16.67) - framesDuring`, clamped at zero. `worstFrameMs` comes from
`SchedulerBinding.addTimingsCallback`.

`?auto=1` drives both modes plus an error probe without user input and POSTs
results to a local recorder. Raw JSON for every run is in `evidence/`.

## Measurements

| Run | Mode | Task (ms) | Frames during | Dropped (60 Hz) | Startup (ms) | Message RTT (ms) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | main | 618.3 | 0 | 37 | — | — |
| 1 | worker | 692.0 | 42 | 0 | 14.5 | 677.5 |
| 2 | main | 615.9 | 0 | 36 | — | — |
| 2 | worker | 714.7 | 43 | 0 | 13.3 | 701.4 |
| 3 | main | 612.7 | 0 | 36 | — | — |
| 3 | worker | 680.1 | 41 | 0 | 7.3 | 672.8 |
| 4 | main | 620.4 | 0 | 37 | — | — |
| 4 | worker | 733.6 | 44 | 0 | 13.5 | 720.1 |

All runs returned the same prime count: **348,513**.

Error probe (run 4): sent `{"op":"nope"}`; the worker replied with a typed
envelope `{"type":"error","message":"unknown operation: nope"}`;
`propagated: true`.

Worker `taskMs` is page-observed wall time (startup + send + compute + receive).
Compute-only time is approximately `messageMs` (672–720 ms); it is slightly
higher than the main-thread time because the worker was compiled at `-O1` while
the Flutter bundle is release-optimised, and because of the message boundary.

## Acceptance criteria from the plan (§19)

| Criterion | Result |
| --- | --- |
| Worker runs compiled Dart | **pass** — `worker.dart.js` built by `dart compile js` |
| Worker uses a genuinely separate browser thread | **pass** — dedicated `Worker`, private global scope |
| Flutter UI remains responsive | **pass** — 41–44 frames rendered during a ~0.7 s task |
| Result returns correctly | **pass** — identical 348,513 on all runs |
| Worker errors propagate | **pass** — typed error envelope observed (run 4) |
| Chrome works | **pass** — every run |
| Firefox works | **not verified** — Firefox 159 installed; the sandbox blocks profile creation (`Could not find profile folder` for every profile path) |
| Safari works where supported | **not verified** — `safaridriver` responds: “You must enable 'Allow remote automation' in the Developer section of Safari Settings” |
| Edge works | **not verified** — `brew install --cask` blocked: Homebrew Cellar/locks are not writable; the Edge `.pkg` needs an installer with admin rights |
| Tests demonstrate concurrency | **partial** — reproducible measurement harness and raw evidence, no unit test suite yet |
| Benchmark shows measurable responsiveness improvement | **pass** — 36–37 dropped frames vs 0 |

Because three of the required engines were not exercised, the verdict is
**PASS WITH LIMITATIONS**, not PASS.

## Limitations, stated plainly

1. **Engine coverage.** Only Chrome 156 was measured. Firefox, Safari and Edge
   remain unverified; no claim is made about them (AGENTS.md rule 8).
2. **Work is precompiled and selected by name.** The call is
   `{op: 'primes', n, rounds}` against a fixed dispatch table. Arbitrary
   functions and closures are not supported and cannot be, as shipped
   (R004 §2). This is compatibility level DWI-0/1, not level 3/4.
3. **Manual build step.** `flutter build web` compiles one entrypoint; the worker
   is compiled by `tool/build_worker.dart`. There is no integration hook yet
   (R002 §4, R007).
4. **Startup cost is real but small here.** 7–15 ms after the initial script
   fetch; a larger worker program will cost more. Pooling is required before
   promising low-latency repeated tasks.
5. **`worstFrameMs` understates a full block.** A blocked main thread emits no
   frame timings, so the reported 5–8 ms "worst frame" is not the stall. The
   honest metric is `droppedFrames` (derived from wall time) and
   `framesDuring` (ticker delta).
6. **Only the JS backend.** No `dart2wasm` worker was built in M001 (R005
   describes the loader path).
7. **Error coverage is one path.** Unknown-operation errors are verified;
   uncaught exceptions, worker crash, startup timeout and termination-in-flight
   are implemented but not yet exercised end-to-end.
8. **Headless Chrome needed `--no-sandbox`** in this development sandbox. That
   is a harness workaround, not a deployment recommendation, and it may affect
   timing slightly.
9. **Cache caveat.** Early runs measured a cached bundle; all reported runs use
   a cache-busted worker URL and a fresh browser profile.

## What M001 establishes for the architecture

- A dedicated worker + separate compilation + message protocol is sufficient to
  keep Flutter rendering during CPU work.
- Worker startup (~10 ms warm, ~50–60 ms cold in the capability harness) is
  cheap enough to pool but too expensive to pay per task.
- Frame accounting must be designed from the start: frame timings alone cannot
  describe a main-thread stall.
- The error envelope is necessary and works.

## Next steps (Phase 4 gate)

1. Proceed to the architecture phase: ADR, API proposal, protocol spec.
2. Keep the public API at "named task" level until compiler work exists.
3. Close the browser gap in a normal user session (Firefox, Safari, Edge).
4. Add unit tests for the protocol and a worker lifecycle/crash test before any
   package release.

## Reproducing

```bash
cd experiments/dart_worker_poc
flutter pub get
dart run tool/build_worker.dart
flutter build web --release
python3 tool/measure_server.py &
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --no-sandbox --disable-gpu \
  --user-data-dir="$TMPDIR/chrome-m001" "http://127.0.0.1:8082/?auto=1"
# results/run-<timestamp>.json
```
