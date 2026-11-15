# DWI 1.0 benchmark report

Every number here comes from a file named in the text. Nothing is estimated. The
platform is the same for every row: macOS 26.5.1, Apple M2 (arm64), 8 cores,
Chrome 157.0.8103.78, Safari 26.5, Firefox 160.0, Edge 157.0.4341.60, unless a
row says otherwise.

## 1. Pool sizing (guidance)

200 tasks of 5 ms each, makespan median of three passes, `maxWorkers` 1, 2, 4, 8.
Every result was correct.

| maxWorkers | Chrome (ms) | Safari (ms) | Firefox (ms) | Edge (ms) |
| --- | --- | --- | --- | --- |
| 1 | 1002 | 1001 | 1008 | 1001 |
| 2 | 501 | 501 | 506 | 500 |
| 4 | 252 | 257 | 258 | 253 |
| 8 | 147 | 145 | 142 | 132 |

Guidance, for CPU-bound tasks on this machine:

- Speedup is close to linear up to four workers, and eight workers gave 6.8 to
  7.6 times the single-worker time. That is below the core count of eight, so
  expect less than linear beyond about half the cores.
- The library default is `maxWorkers = 4`. It is not derived from the core count,
  and these measurements do not justify changing it.
- An application that wants more throughput can set `maxWorkers` to
  `navigator.hardwareConcurrency` and measure its own tasks.
- Not measured: pools larger than the core count, the main thread's
  responsiveness with a full pool, and machines with other core counts.

Source: `docs/browser-matrix.md` (pool sizing), `audit/evidence/browser-matrix-extended-four-engines-2026-11-14.json`.

## 2. Workloads: DWI worker versus main thread

Median milliseconds, DWI (including the copy of input and result) versus the main
thread, same deterministic input, checksums equal on every pass and engine.

| Workload (input) | Chrome | Safari | Firefox | Edge |
| --- | --- | --- | --- | --- |
| Sort (256 KiB) | 28 / 20.4 | 36 / 25 | 31 / 25 | 34.8 / 30.3 |
| JSON parse and walk (about 2,000 objects) | 1.2 / 1 | 3 / 2 | 1 / 1 | 1.2 / 1 |
| Adler-32 (256 KiB) | 1.2 / 1.1 | 3 / 2 | 1 / 1 | 1.3 / 1.5 |
| Run-length size (256 KiB) | 0.5 / 0.4 | 1 / 0 | 0 / 0 | 0.9 / 0.8 |
| 3×3 box blur (512×512) | 3.3 / 3.1 | 3 / 3 | 4 / 4 | 6.6 / 8.5 |

Limits: the run-length workload is RLE, not DEFLATE or gzip, so no compressor was
measured. Timers in Safari and Firefox round to whole milliseconds at this size.
Edge's blur row shows DWI below the main thread; that gap is within timer noise.
Input sizes other than those listed were not measured.

Source: `docs/browser-matrix.md` (workloads).

## 3. Payload range and large calls

Payloads from 1 KiB to 100 MiB were run through the worker in all four engines.
Every pass returned correct results. The default `maxPayloadBytes` is 64 MiB
(`packages/dwi_core/lib/src/config.dart`); the benchmark page raises it for its own
100 MiB case.

Source: `audit/evidence/browser-matrix-extended-four-engines-2026-11-14.json`.

## 4. Burst and sustained load

- A 1,000-task burst completed in all four engines, every result correct.
- A 20×100 leak run completed in all four engines, every result correct. Heap
  growth was measured only in Chromium (`performance.memory`).

Source: `docs/browser-matrix.md` (burst, leak and payload range).

## 5. Wasm worker versus JS worker (ADR-018, ADR-026 G7)

One run, Chrome 157.0.8103.78 only. Not a cross-engine result.

| Measurement | JS worker | Wasm worker |
| --- | --- | --- |
| Cold start | 12.3 ms | 16.6 ms |
| Warm dispatch | 0.10 ms | 0.10 ms |
| Prime sieve, round trip | 54.2 ms | 7.1 ms |
| Worker CPU with UI ticks | 183.6 ms | 63.8 ms |
| 1 KiB copy | 0.1 ms | 0.1 ms |
| 1 MiB transfer | 0.6 ms | 0.1 ms |

The decision that followed: one Wasm instance per worker stays. Shared memory and
threads were not adopted (`docs/wasm-worker-comparison.md`).

Source: `audit/evidence/wasm-worker-benchmark-2026-11-13.json`.

## 6. Scheduling policies

FIFO, least-loaded, round-robin and priority were compared with a benchmark.
FIFO stays the policy; no other policy was added.

Source: `audit/evidence/scheduling-policies-2026-11-13.json`.

## 7. Worker strategies (ADR-026 G6)

Median makespan over three passes, Chrome, Safari and Firefox (Edge in the same
file). The first three rows use 200 units of work; the last uses 50, so it is not
directly comparable.

| Strategy | Units | Calls | Chrome (ms) | Safari (ms) |
| --- | --- | --- | --- | --- |
| Pool, one call per unit | 200 | 200 | 126.6 | 137 |
| Pool, four chunks | 200 | 4 | 100.2 | 101 |
| One worker, one call | 200 | 1 | 400 | 401 |
| Fresh worker per task | 50 | 50 | 283.2 | 351 |

Source: `audit/evidence/worker-strategies-and-protocol-check-2026-11-14.json`.
The same file records the G3 check: a worker reporting protocol 9 against a host
speaking 2 was refused at start with a typed error.

## 8. Flutter web (ADR-025)

Median longest frame gap over three passes, the same workload in each mode
(`examples/flutter_jank_demo`). Safari's first pass recorded a 0 ms gap and a
2,982 ms total for `computeParallel`; it is kept in the evidence, not removed.

| Mode | Chrome (ms) | Safari (ms) | Firefox (ms) | Edge (ms) |
| --- | --- | --- | --- | --- |
| Main thread | 93 | 129 | 232 | 97 |
| `computeParallel` (DWI) | 18 | 19 | 20 | 25 |
| Flutter `compute()` | 70 | 102 | 222 | 100 |

On web, Flutter's `compute()` blocked frames for almost as long as its work, which
is the behaviour the upstream proposal addresses (`docs/UPSTREAM_PROPOSAL.md`).
Source: `audit/evidence/flutter-jank-demo-four-engines-2026-11-14.json`.

## Not measured

- Mobile devices and browsers.
- Operating systems other than macOS arm64.
- Flutter native.
- Compression libraries (only RLE was measured).
- Heap growth outside Chromium.

## Conclusion for 1.0

The benchmarks support the guidance in section 1, the workload comparison in
section 2, and the decision in section 5. They do not support performance claims
for any other platform.
