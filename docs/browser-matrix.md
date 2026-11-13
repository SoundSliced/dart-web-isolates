# Browser Matrix

## Burst, leak and payload range, four engines (tranche A, 2026-11-13)

Harness: `benchmarks/browser_matrix/web/main.dart`, run through
`tooling/hosted_consumer/probe` (three passes, one page load per engine per
pass). Evidence: `audit/evidence/browser-matrix-four-engines-2026-11-13.json`
(every pass, every metric). Sandbox was off, with approval.

| Engine | Version | 1,000-task burst (median ms) | 20×100 leak run, round median (ms) | Sustained 100 (median ms) | Heap at start (MB) |
| --- | --- | --- | --- | --- | --- |
| Chrome | 157.0.8103.78 | 126 | 3.0 | 73 | 110 |
| Safari | 26.5 | 82 | 4.0 | 37 | not exposed |
| Firefox | 160.0 | 74 | 4.0 | 29 | not exposed |
| Edge | 157.0.4341.46 | 100 | 3.0 | 93 | 110 |

Every pass on every engine passed: all 1,000 burst results and all 2,000 leak
results were correct, and the pool stayed at four workers.

Payload copy and transfer (median ms over three passes, `DwiTransferableBytes`
vs copy through `sumTyped`):

| Size | Chrome copy / transfer | Safari | Firefox | Edge |
| --- | --- | --- | --- | --- |
| 1 KiB | 0.3 / 0.3 | 0 / 0 | 0 / 0 | 0.3 / 0.2 |
| 100 KiB | 0.3 / 0.5 | 0 / 1 | 0 / 0 | 0.4 / 0.3 |
| 1 MiB | 1.7 / 1.7 | 1 / 1 | 1 / 1 | 3.2 / 3.4 |
| 8 MiB | 11.1 / 6.3 | 6 / 4 | 9 / 6 | 18.4 / 12.9 |
| 10 MiB | 10.8 / 8.4 | 7 / 5 | 13 / 11 | 18.9 / 16.3 |
| 100 MiB | 130 / 82.5 | 83 / 44 | 154 / 79 | 214 / 172.6 |

Reading and limits:

- Safari and Firefox show 0 ms for sizes up to 100 KiB. Their clocks are too
  coarse for those rows, so sub-millisecond differences are not comparable on
  those engines.
- The 100 MiB case needs `maxPayloadBytes` raised from its 64 MiB default; the
  page sets 128 MiB for the payload phase. The library default is unchanged.
- Heap is read from `performance.memory`, which Chromium exposes and Safari and
  Firefox do not. The leak run compares heap before and after 20 rounds without
  forcing garbage collection, so it is a weak check; it shows no growth beyond
  the payload phase's own allocation, not that no leak exists.
- Three passes is a small sample. Spread is in the evidence file. A longer soak
  is still open.
- Payload timings include the main-thread call and the worker round trip. Worker
  heap is not visible from the page, so no worker-heap figure is reported.

Chrome's single-run `run.dart` output for the extended page is
`audit/evidence/browser-matrix-chrome-extended-2026-11-13.json`. The committed
`browser-matrix-chrome-2026-11-13.json` (three runs, older page) is unchanged.

## Pause, resume and ping (ADR-028, 2026-11-13, checkout only)

`browser_dispatch_control_test.dart` compiles each host and worker separately.
In each cell it holds calls with `Dwi.pause()`, checks that held calls run only
after `resume()` and in order, cancels a held call (it settles with
`DwiCancelledException`), and checks that a running call keeps running while
paused. It also checks that `close()` fails held calls with
`DwiUnsupportedException`, that `close(drain: true)` resumes first and runs
them, and that a synchronous busy loop makes `ping` time out while an
asynchronous one still answers. Every worker is terminated at the end. All
sixteen combinations pass:

| Host / worker | Chrome 157.0.8103.78 | Safari 26.5 | Firefox 160.0 | Edge 157.0.4341.46 |
| --- | --- | --- | --- | --- |
| dart2js / dart2js | pass | pass | pass | pass |
| dart2js / dart2wasm | pass | pass | pass | pass |
| dart2wasm / dart2js | pass | pass | pass | pass |
| dart2wasm / dart2wasm | pass | pass | pass | pass |

The handle contract (`browser_handle_test.dart`, `DwiWorkerHandle.ping`) passes
in all four engines (`handle-matrix-{chrome,safari,firefox,edge}-20261113.json`,
three runs each). Evidence: `audit/evidence/dispatch-control-acceptance-2026-11-13T140346.json`
(`complete: true`, sixteen runs, source digests verified against the working
tree). Source state at the run: ADR-028 implementation, uncommitted, on top of
`7ca355b`. A first attempt (`…T135625.json`) ran inside the sandbox, which
blocks local port binding; it is not evidence and is superseded.

## Cooperative cancellation (ADR-027, 2026-11-13, checkout only)

`browser_cooperative_cancel_test.dart` compiles each host and worker
separately and runs one pooled worker with `cancelGracePeriod: 1 s`. A task
awaiting 20 ms steps is cancelled: the caller settles with
`DwiCancelledException` within 200 ms, the task observes `DwiCancelToken` and
stops, and the same worker serves the next call (one worker created, none
terminated). A synchronous 4 s loop is cancelled: it cannot observe the token,
is terminated near the 1 s mark and replaced, and its worker-local state is
gone. Every worker the page created is terminated at the end. All sixteen
combinations pass:

| Host / worker | Chrome 157.0.8103.78 | Safari 26.5 | Firefox 160.0 | Edge 157.0.4341.46 |
| --- | --- | --- | --- | --- |
| dart2js / dart2js | pass | pass | pass | pass |
| dart2js / dart2wasm | pass | pass | pass | pass |
| dart2wasm / dart2js | pass | pass | pass | pass |
| dart2wasm / dart2wasm | pass | pass | pass | pass |

Native: `packages/dwi_native/test/cooperative_cancel_test.dart`. Evidence:
`audit/evidence/cooperative-cancel-acceptance-2026-11-13T113102.json`. The pool
contract (`browser_lifecycle_test.dart`) was rerun after the change and passes
in all four engines
(`audit/evidence/pool-lifecycle-four-engines-2026-11-13T113102.json`). The
earlier run (`…T111900.json`, same sources) also passed every browser cell; its
native suite exposed a race in the test's marker-file polling, fixed before
the second run.

## Pool idle retirement and draining (ADR-024, 2026-11-13, checkout only)

`browser_pool_lifecycle_test.dart` compiles each host and worker separately
and checks, with `idleTimeout` set: an idle pooled worker is terminated and the
next call starts a fresh one; a busy worker is never retired; a steady stream
of calls inside the timeout starts no new worker; `Dwi.close(drain: true)`
refuses new calls, lets the two started calls finish (400 ms and 250 ms) and
then closes; a plain `close()` still cuts a running call with a typed error;
and the page ends with every worker it created terminated. All sixteen
combinations pass:

| Host / worker | Chrome 157.0.8103.78 | Safari 26.5 | Firefox 160.0 | Edge 157.0.4341.46 |
| --- | --- | --- | --- | --- |
| dart2js / dart2js | pass | pass | pass | pass |
| dart2js / dart2wasm | pass | pass | pass | pass |
| dart2wasm / dart2js | pass | pass | pass | pass |
| dart2wasm / dart2wasm | pass | pass | pass | pass |

Native: `packages/dwi/test/close_drain_test.dart`. Evidence:
`audit/evidence/pool-idle-drain-acceptance-2026-11-13T104143.json`. The
existing pool contract (`browser_lifecycle_test.dart`) was rerun after the
change and passes in all four engines
(`audit/evidence/pool-lifecycle-four-engines-2026-11-13T104143.json`).

## Worker links (ADR-023, 2026-11-13, checkout only)

`browser_worker_link_test.dart` compiles each host and worker separately and,
with `channelBufferSize: 4`, connects two handles with `DwiWorker.link`: 200
ordered messages, 150 messages to a reader that pauses every 25, request and
reply, names released after close, closing the producer mid-stream (consumer
keeps three messages, `done` reports `DwiWorkerClosedException`, consumer
stays usable), same-handle and duplicate-name rejection, and every worker the
page created terminated. All sixteen combinations pass:

| Host / worker | Chrome 157.0.8103.78 | Safari 26.5 | Firefox 160.0 | Edge 157.0.4341.46 |
| --- | --- | --- | --- | --- |
| dart2js / dart2js | pass | pass | pass | pass |
| dart2js / dart2wasm | pass | pass | pass | pass |
| dart2wasm / dart2js | pass | pass | pass | pass |
| dart2wasm / dart2wasm | pass | pass | pass | pass |

Native: `native_worker_link_test.dart`. Evidence: `audit/evidence/worker-link-acceptance-2026-11-13T100732.json`. The handle and
channel contract (`browser_handle_test.dart`) was rerun after the
acknowledge-on-consume change and passes in all four engines
(`audit/evidence/handle-matrix-*-20261113.json`). An earlier run
(`worker-link-acceptance-2026-11-13T094901.json`, incomplete) failed only
where Safari ended its WebDriver session; kept as history.

## Stream tasks (ADR-022, since 0.9.0, 2026-11-13)

`browser_stream_tasks_test.dart` compiles each host and worker separately and,
with `channelBufferSize: 4`, checks ordered items, 300 items read slowly,
converted input and items, an error after two items, cancellation of an
infinite stream followed by a new one, zero-input nullable items,
`DwiFunctions.stream`/`stream0`, both misuse errors, items produced in
`DedicatedWorkerGlobalScope`, and that all 12 workers the page created were
terminated. All sixteen combinations pass:

| Host / worker | Chrome 157.0.8103.78 | Safari 26.5 | Firefox 160.0 | Edge 157.0.4341.46 |
| --- | --- | --- | --- | --- |
| dart2js / dart2js | pass | pass | pass | pass |
| dart2js / dart2wasm | pass | pass | pass | pass |
| dart2wasm / dart2js | pass | pass | pass | pass |
| dart2wasm / dart2wasm | pass | pass | pass | pass |

Native: `native_stream_tasks_test.dart`. Evidence:
`audit/evidence/stream-tasks-acceptance-2026-11-13T012032.json`. An earlier run
(`stream-tasks-acceptance-2026-11-13T011146.json`, incomplete) passed fifteen
cells; in the sixteenth, Safari ended its WebDriver session and then refused new
ones until Remote Automation was re-enabled — an automation failure, not a DWI
result, kept as history.

## Payload types (ADR-021, since 0.9.0, rerun 2026-11-13)

`browser_payload_types_test.dart` compiles each host and worker separately and
round-trips enums, `DateTime` (local and UTC, to the microsecond), `Duration`,
`BigInt`, `Uri`, records (including a one-field record and named fields), a
`@DwiPayload` class with a nullable field, a recursive `@DwiPayload` tree,
nested `Map<String, List<(Color, Duration)>>`, and a zero-input record result.
It also checks that a wrong enum name and a wrong record arity sent by name
fail with a typed error, and that a converted value was rebuilt in
`DedicatedWorkerGlobalScope`. All sixteen combinations pass:

| Host / worker | Chrome 157.0.8103.78 | Safari 26.5 | Firefox 160.0 | Edge 157.0.4341.46 |
| --- | --- | --- | --- | --- |
| dart2js / dart2js | pass | pass | pass | pass |
| dart2js / dart2wasm | pass | pass | pass | pass |
| dart2wasm / dart2js | pass | pass | pass | pass |
| dart2wasm / dart2wasm | pass | pass | pass | pass |

Native round trip: `native_payload_types_test.dart`. Evidence:
`audit/evidence/payload-types-acceptance-2026-11-13T012032.json` (rerun after ADR-022). The
first run, `payload-types-acceptance-2026-11-13T003805.json`, also passed all
sixteen cells; Firefox updated itself from 159.0.1 to 160.0 during it.

## Registered-static adapters (ADR-020, since 0.9.0, rerun 2026-11-13)

`browser_static_registry_test.dart` compiles each host and worker separately.
All sixteen combinations below pass through production generated adapters,
rerun after the ADR-021 generator change:

| Host / worker | Chrome 157.0.8103.78 | Safari 26.5 | Firefox 160.0 | Edge 157.0.4341.46 |
| --- | --- | --- | --- | --- |
| dart2js / dart2js | pass | pass | pass | pass |
| dart2js / dart2wasm | pass | pass | pass | pass |
| dart2wasm / dart2js | pass | pass | pass | pass |
| dart2wasm / dart2wasm | pass | pass | pass | pass |

Evidence: `audit/evidence/dwi5-static-acceptance-2026-11-13T012032.json` (browsers) and
`audit/evidence/dwi5-static-native-2026-11-13T011146.json` (native), both
stamped with the hashes of the implementation, annotation and test sources.
Earlier runs are kept as history: `dwi5-static-acceptance-2026-11-13T003805.json`
(after ADR-021), `dwi5-static-acceptance-2026-11-11T212830.json`
(before ADR-021) and `dwi5-static-acceptance-2026-11-11.json` (Edge
157.0.4341.42, before the ADR-020 audit corrections).
The fixture observes DedicatedWorkerGlobalScope and independent task state,
executes real class static methods, repeatedly selects both registered targets,
checks typed numbers/nullable collections, rejects four unsupported function
forms, and covers remote errors, timeout and missing-worker startup failure.
It closes DWI resources on every path. No timer-based responsiveness claim or
arbitrary-function compatibility claim is made. Native acceptance is separate
in `native_static_registry_test.dart`. SDK details are in the evidence file.

Reproduce from `packages/dwi_builder`:

```sh
PUB_CACHE=../../.research/pub-cache \
  ../../.research/dart-sdk-dev/dart-sdk/bin/dart test \
  test/native_static_registry_test.dart test/browser_static_registry_test.dart \
  -r expanded
```

Measured results for the browser capabilities DWI depends on. Every cell is a
measurement or an explicit `unverified`/`blocked`; nothing is inferred from
another engine (AGENTS.md rule 8).

Four harnesses exist and they measure different things. A result from one
harness never fills a cell in another, and a result from one engine never fills
another engine's cell.

| Harness | What it measures | Engines with a measured result | Last run |
| --- | --- | --- | --- |
| Browser capability probe (static page, `.research/browser_matrix/`, gitignored) | raw browser features: worker startup, structured clone, transfer, module workers, dart2wasm-in-worker, SAB | Chrome 156 | 2026-11-03 |
| v0.4 runtime benchmark (`benchmarks/browser_matrix`, committed) | `Dwi.run` pool timings: cold start, dispatch, copy vs transfer, cancellation, sustained load, dead-worker recovery, UI responsiveness | Chrome 156, Safari 26.5 | 2026-11-04 / 2026-11-05 |
| v0.5 handle lifecycle matrix (`packages/dwi_builder/test/browser_handle_test.dart`, committed) | the public `DwiWorker` handle contract at the DWI API level, including ADR-016's `runFresh` vs pooled-state case and ADR-017's termination observation | Chrome 156/157.0.8103.38, Safari 26.5, Firefox 159.0/159.0.1, Edge 156.0.4314.58/157.0.4341.42 for the earlier cases; ADR-017 cases pass in Chrome 157.0.8103.38, Safari 26.5, Firefox 159.0.1 and Edge 157.0.4341.42 (§7) | 2026-11-05/06 and 2026-11-09 |
| Published-consumer regression fixture (`tooling/hosted_consumer/run.sh`, committed) | published `^0.6.0` resolution from pub.dev (no path overrides), generated typed proxy, `runFresh`/`using`/explicit handle, channel exchange, typed remote error then success, worker asset fetch, first-build gate, at the site root and under `/sub/app/` | Chrome 157.0.8103.38, Safari 26.5, Firefox 159.0.1, Edge 157.0.4341.42 | 2026-11-08 |
| Compiler matrix (Flutter application host) | a Flutter web app calling `Dwi.run` with a dart2js worker, built with dart2js and with dart2wasm | Chrome 156 | 2026-11-05 |

## 1. Browser capability probe — Chrome 156 only (2026-11-03)

**Scope of this section: Chrome 156 headless.** This probe has not been run in
Safari, Firefox or Edge, so those cells do not exist for it. The later sections
report different harnesses and do not extend this one.

Method: static harness served from `http://127.0.0.1:8765`
(`.research/browser_matrix/`, gitignored); results POSTed by the page and stored
per user-agent. Harness source: `index.html`, `harness.js`, `worker.js`,
`module_worker.mjs`, plus a trivial dart2wasm module (`hello.wasm` + `hello.mjs`,
compiled with Dart 3.13.5). macOS arm64.

| Capability | Result | Detail |
| --- | --- | --- |
| Dedicated `Worker` | pass | page → worker ready handshake |
| Worker startup latency | 59.6 ms | construct → `ready` message; first worker only |
| Structured clone, nested | pass | `Array`, `Map`, `Date`, `Uint8Array` all survive |
| Function clone | `DataCloneError` | `structuredClone({fn})` throws |
| `ArrayBuffer` transfer | pass | sender buffer detached (`byteLength === 0`), receiver sees 4 MiB |
| Transfer round trip (4 MiB) | 0.6 ms | message + ack |
| `MessageChannel` port transfer | pass | `port2` transferred to worker without error |
| `worker.terminate()` | pass | no error, worker gone |
| Module worker (`type: 'module'`) | pass | startup 6.3 ms |
| dart2wasm in worker (WasmGC + `js-string`) | pass | `compileStreaming` + `instantiate` + `invokeMain` succeeded |
| `navigator.hardwareConcurrency` | 8 | machine reports 8 logical cores |
| Pool: 8 workers spawned | pass | all reached `ready` |
| `crossOriginIsolated` | false | page served without COOP/COEP |
| `SharedArrayBuffer` | unavailable | `typeof SharedArrayBuffer === 'undefined'` under non-isolated context |
| CPU baseline in worker | 20.8 ms | sieve to 2,000,000 → 148,933 primes |

What this establishes (Chrome only):

1. A dedicated worker can start in ~60 ms on this machine and is worth pooling
   for repeated tasks.
2. The core transfer path works: typed data can move without a copy and the
   sender loses ownership.
3. Module workers plus dart2wasm output instantiate successfully in a worker,
   including the `js-string` builtins the compiler requires.
4. `SharedArrayBuffer` is unavailable without cross-origin isolation, exactly as
   the spec requires; the JS backend must not depend on it.

## 2. v0.4 runtime benchmark — Chrome 156 and Safari 26.5

**Scope of this section: the `Dwi.run` pool in Chrome 156 and Safari 26.5.**
Firefox and Edge have no cell in this harness.

The pool **contract** (as opposed to these timings) is measured separately in
all four engines by `packages/dwi_builder/test/browser_lifecycle_test.dart`:
timeout, queue overflow, queue deadline, close, concurrent startup, oversized
payload, missing worker, queued/running/startup cancellation, transfer and
dead-worker replacement pass in Chrome 157.0.8103.78, Safari 26.5, Firefox
159.0.1 and Edge 157.0.4341.46 (2026-11-11,
`audit/evidence/pool-lifecycle-four-engines-2026-11-11T220557.json`; rerun
with Firefox 160.0 after ADR-024 on 2026-11-13,
`…2026-11-13T104143.json`). The run
before it (`…T214451.json`, incomplete) is the record of the Safari failure that
exposed the startup-cancellation defect.

Measured with `benchmarks/browser_matrix` (committed harness, see its README for
methodology). One page load = one run; medians are inside a run and each cell is
the median (min–max) over three runs. Dart 3.13.5, macOS arm64 26.5.1, Apple M2,
8 GiB RAM. Chrome 156.0.8078.80 measured 2026-11-04; Safari 26.5 measured
2026-11-05.

| Engine | Version | Status |
| --- | --- | --- |
| Chrome | 156.0.8078.80 (headless) | **measured**, 3/3 runs clean |
| Safari | 26.5 (safaridriver) | **measured**, 3/3 runs clean |
| Firefox | 159.0 | **unverified for this harness** — not run |
| Edge | 156.0.4314.58 | **unverified for this harness** — not run |

| Measurement | Chrome 156 median (min–max) | Safari 26.5 median (min–max) |
| --- | --- | --- |
| Cold start (first call, worker spawn + ready) | 33 ms (26–35) | 30 ms (14–33) |
| Warm dispatch (round trip) | 0.2 ms (0.101–0.2) | 0.0 ms (below the 1 ms resolution) |
| 64 KiB copy / transfer | 0.3 ms / 0.3 ms | 0.0 ms / 0.0 ms |
| 1 MiB copy / transfer | 1.5 ms (1.199–1.599) / 1.0 ms (0.9–1.099) | 1.0 ms / 1.0 ms |
| 8 MiB copy / transfer | 10.0 ms (9.3–10.1) / 6.399 ms (6.0–6.599) | 6.0 ms (5–6) / 4.0 ms (3–5) |
| Queued cancellation | 0.1 ms (0.1–0.101) | 0.0 ms |
| Running cancellation | 0.199 ms (0.101–0.2) | 0.0 ms |
| 100 tasks through 4 workers | 66 ms (43–97), 100/100 settled | 35 ms (28–62), 100/100 settled |
| Dead idle worker → next call | 11 ms (10–13) | 47 ms (33–58) |
| UI timer ticks during 300 ms worker CPU | 29 | 25 |
| UI timer ticks during 300 ms main-thread CPU | 0 | 0 |

Values under one millisecond are reported as `0.0` because the harness records
milliseconds; that is a resolution floor, not a zero cost. Every cell above is
that engine's own run — no engine's numbers are copied into another's.

What this establishes, per engine:

1. Worker round trips are sub-millisecond once warm on both engines; cold start
   is tens of milliseconds, so pooling matters for bursty workloads.
2. Transfer is never slower than copy on either engine and wins at size: at
   8 MiB it is ~36% faster in Chrome and ~33% faster in Safari on this machine.
   At 64 KiB the difference is below the measurement floor.
3. Cancellation is cheap on both engines because running cancellation terminates
   the worker instead of waiting for it.
4. A silently dead idle worker is replaced in ~11 ms (Chrome) and ~47 ms
   (Safari), both well below `taskTimeout`.
5. Running CPU work in a worker keeps the page's event loop alive on both
   engines (25–29 ticks vs 0 for the same work on the main thread).

Full data: `audit/evidence/browser-matrix-chrome-2026-11-04.json` and
`audit/evidence/browser-matrix-safari-2026-11-05.json`.

**Firefox and Edge are unverified for this benchmark** (AGENTS.md rule 8): the
harness was not run there, so their cells stay empty.

### §2 re-run on the project toolchain (Dart 3.15.0-133.0.dev, 2026-11-13)

The same harness, same machine and same protocol, re-run end to end on the
project toolchain after 2026-11-13. Environment: macOS arm64 26.5.1, Apple M2,
8 GiB RAM, Dart 3.15.0-133.0.dev, **Chrome 157.0.8103.78** headless and Safari
26.5 (safaridriver). Three runs each, both clean (0 failed runs).

| Measurement | Chrome 157.0.8103.78 median (min–max) | Safari 26.5 median (min–max) |
| --- | --- | --- |
| Cold start (first call, worker spawn + ready) | 71 ms (62–110) | 37 ms (29–44) |
| Warm dispatch (round trip) | 0.101 ms (0.1005–0.199) | 0.0 ms (below the 1 ms resolution) |
| 64 KiB copy / transfer | 0.799 ms (0.3–0.799) / 0.699 ms (0.601–1.1) | 0.0 ms (0–1) / 1.0 ms (0–1) |
| 1 MiB copy / transfer | 3.601 ms (1.9–5.2) / 0.901 ms (0.801–1.699) | 1.0 ms / 1.0 ms |
| 8 MiB copy / transfer | 10.3 ms (9.101–14.9) / 7.0 ms (6.5–9.3) | 6.0 ms / 4.0 ms |
| Queued cancellation | 0.1 ms (0.1–0.199) | 0.0 ms |
| Running cancellation | 0.1 ms (0.1–0.199) | 0.0 ms (0–1) |
| 100 tasks through 4 workers | 130 ms (106–135), 100/100 settled | 40 ms (29–43), 100/100 settled |
| Dead idle worker → next call | 26 ms (15–35) | 27 ms (26–35) |
| UI timer ticks during 300 ms worker CPU | 29 | 25 |
| UI timer ticks during 300 ms main-thread CPU | 0 | 0 |

Full data: `audit/evidence/browser-matrix-chrome-2026-11-13.json` and
`audit/evidence/browser-matrix-safari-2026-11-13.json`.

How to read this against the 2026-11-04/05 table above, which was Dart 3.13.5:

- Chrome moved **two** variables at once (Dart 3.13.5 → 3.15.0-133.0.dev and
  Chrome 156.0.8078.80 → 157.0.8103.78). Cold start 33 → 71 ms and the 100-task
  burst 66 → 130 ms therefore cannot be attributed to the compiler; no run
  isolates them. Safari moved only the Dart version, and its cells are
  unchanged within the harness resolution (cold start 30 → 37 ms, 8 MiB copy
  6.0 → 6.0 ms, 8 MiB transfer 4.0 → 4.0 ms).
- The qualitative results reproduce on both engines: transfer never loses to
  copy and still wins at 8 MiB (Chrome ~32%, Safari ~33%), cancellation stays at
  the measurement floor, a dead idle worker is replaced in 26–27 ms, and worker
  CPU keeps 25–29 UI ticks against 0 for the same work on the main thread.
- Safari's dead-worker figure moved 47 ms → 27 ms. Both are well below
  `taskTimeout`; the harness reports one figure per run and the spread is
  (26–35) against (33–58), so this is a narrower distribution, not a speedup
  claim.

## 3. v0.5 handle lifecycle matrix (DWI API level)

**Scope of this section: the public `DwiWorker` handle contract, one engine per
row, three page loads per engine.** This is not the capability probe (§1) and not
the pool benchmark (§2).

Harness: `packages/dwi_builder/test/browser_handle_test.dart` (committed). One
shared assertion list (`_expectContract`) runs unchanged in every engine, so a
result is comparable across engines by construction. Each engine gets three page
loads; a transport-level failure is retried once before it is recorded. The page
drives only the public `package:dwi` API against a generated worker artefact in
one page load and covers:

- state retention across calls, and isolation between two handles;
- FIFO execution of queued calls, one at a time;
- bounded queue (`maxQueuedTasks` → `DwiUnsupportedException`) and the
  caller-local queue deadline (`queueTimeout` → `DwiTimeoutException`);
- close during a running call and with a queued call, idempotent close, and
  `Dwi.close()` closing a live handle;
- task timeout, restart with fresh state, and rejection of `restart()` in other
  states;
- queued cancellation keeps the context; running cancellation fails the handle;
- transferables (argument and result, sender detached);
- startup failure (missing worker script), idle crash detected by heartbeat,
  crash with a call pending, and a malformed non-object message;
- repeated spawn/close cycles with `Dwi.run` calls interleaved.

| Engine | Version | Automation | Status |
| --- | --- | --- | --- |
| Chrome | 156.0.8078.80 (headless) | CDP, private profile | **pass**, 3/3 runs, 2026-11-05/06 |
| Safari | 26.5 | `safaridriver` (WebDriver) | **pass**, 3/3 runs, 2026-11-05/06 |
| Firefox | 159.0 (headless) | WebDriver BiDi (`--remote-debugging-port`, `/session`) | **pass**, 3/3 runs, 2026-11-05/06 |
| Edge | 156.0.4314.58 | CDP, private profile | **pass**, 3/3 runs, 2026-11-06 |

No result is copied between engines. A blocked engine keeps its exact reason
instead of being omitted or guessed.

Evidence (one JSON file per engine, written by the harness with
`DWI_EVIDENCE_DIR`):

- `audit/evidence/handle-matrix-chrome-20261106.json`
- `audit/evidence/handle-matrix-safari-20261106.json`
- `audit/evidence/handle-matrix-firefox-20261106.json`
- `audit/evidence/handle-matrix-edge-20261106.json` (`status: blocked`)

Environment for all three measured engines: macOS 26.5.1 (25F80), arm64 (Apple
M2, 8 logical cores), Dart 3.13.5. Flutter was not used for this harness; it
compiles the page with `dart compile js`.

Engine-specific notes (setup facts, not results):

- Chrome runs headless with `--no-sandbox` on this machine.
- Safari needs “Allow Remote Automation” in Safari → Develop; without it the
  session is refused and the harness records `blocked` with that message.
- Firefox's own content-process sandbox cannot initialise inside this host's
  restricted session (`sandbox_init() failed with error "Operation not
  permitted"`), so the harness launches Firefox with
  `MOZ_DISABLE_CONTENT_SANDBOX=1` (plus the GMP and RDD equivalents). Firefox
  also needs a Firefox profile root it can write; the harness passes a private
  `--profile` directory.
- Edge is located through `DWI_EDGE_BINARY` when it is not in `/Applications`.
  On this machine it was unpacked from the official 415 MiB `.pkg` with
  `xar -xf` plus `cpio` (only `Microsoft Edge.app`), which needs ~1.2 GiB free.
  Four environment workarounds live in the harness, not in DWI: Edge gets a
  private home through `CFFIXED_USER_HOME`/`HOME` (its path service aborts on
  this session's read-only `~/Library/Application Support`), its Keychain
  request is replaced by `--use-mock-keychain`, Edge 157's async keychain
  provider is disabled with
  `--disable-features=UseKeychainKeyProvider,msEdgeUpdater,EdgeUpdater` so it
  cannot bypass that mock and trigger the “Microsoft Edge Safe Storage” prompt,
  and the standard automation flags suppress its first-run updater, which
  otherwise outlived the page-target wait. With those, Edge runs the same
  contract unmodified.

  The harness builds these flags in `chromiumLaunchArguments()` and
  `browser_launch_args_test.dart` guards them. Any other Edge automation on
  this machine (Playwright `channel: "msedge"`, Selenium, Puppeteer) needs the
  same mock-keychain pair; without `--use-mock-keychain` and the
  `UseKeychainKeyProvider` disable, macOS may ask to unlock “Microsoft Edge
  Safe Storage”. Click **Cancel** in that dialog — “Reset To Defaults” replaces
  the login keychain.

## 4. Compiler matrix (Flutter application host)

**Scope of this section: a Flutter web application hosting DWI, measured in
Chrome 156 only, with Flutter 3.47.6 stable.** The worker is a dart2js artefact
in both rows; DWI has no wasm worker backend.

| App (host) compiler | Worker compiler | Result |
| --- | --- | --- |
| dart2js (`flutter build web --release`) | dart2js | **pass** — `DWI_RUN value=v1 backend=worker` |
| dart2wasm (`flutter build web --wasm --release`) | dart2js | **pass since 2026-11-05** — `DWI_RUN value=v1 backend=worker`; before the integral-double fix the app failed with `message.v must be an int` |

The wasm row is measured on Flutter 3.47.6 stable / Chrome 156 only. Evidence:
`audit/evidence/flutter-run-modes-and-wasm-fix-2026-11-05.txt` (fix and re-run)
and `audit/evidence/flutter-run-hot-restart-and-wasm-2026-11-05.txt` (original
failure). Firefox, Safari and Edge were not measured for either compiler.

## 5. Published-consumer regression fixture

**Scope of this section: the published 0.7.0 packages resolved from pub.dev, not
the checkout.** The fixture accepts `DWI_HOSTED_VERSION` (default `0.7.0`). The
page needs 0.7.0 or later because it exercises `stopReason`/`stops`; the earlier
0.6.0 page did not.

Harness: `tooling/hosted_consumer/run.sh` (committed). It creates a throwaway
Flutter Web app, sets an isolated `PUB_CACHE`, writes only hosted `^0.7.0`
constraints (no `pubspec_overrides.yaml`, no `path` entries), and asserts every
`dwi*` package in `pubspec.lock` is `source: hosted` at `https://pub.dev`.
It then builds the app for the site root and with `--base-href /sub/app/` and
drives the four engines through the same page.

The page checks: generated typed proxy, `Dwi.runFresh` fresh state (`[1, 1]`),
one `DwiWorker.using` scope retaining state (`[1, 2]`), an explicit
`spawn`/`close` handle retaining state, termination observation
(`stopReason` null before close and `callerClosed` after, `stops` emitting
`callerClosed`), channel exchange (`ping` → `echo:ping`), a typed
`DwiRemoteException` followed by another successful call, and a fetch of
`dwi/worker.dart.js` at the deployment mount. The first-build gate is asserted,
not assumed: the generated-proxy app fails its first ordinary build (exit 1 on
the missing `dwi_tasks.g.dart`), the fixture runs
`dart run dwi_builder:dwi build`, the next build succeeds; a separate proxy-free
app builds on its first ordinary command.

| Engine | Version | Site root | `/sub/app/` |
| --- | --- | --- | --- |
| Chrome | 157.0.8103.38 | **pass** | **pass** |
| Safari | 26.5 | **pass** | **pass** |
| Firefox | 159.0.1 | **pass** | **pass** |
| Edge | 157.0.4341.42 | **pass** | **pass** |

Measured 2026-11-09 on macOS arm64 with Flutter 3.47.6 / Dart 3.13.5. One page
load per engine per mount; the fixture validates the payload and exits non-zero
on any mismatch. The post-publish run against 0.7.0 returned `fresh [1,1]`,
`scoped [1,2]`, `handle [1,2]`, `stopBefore true`, `stopReason callerClosed`,
`stopEvents callerClosed`, `channel echo:ping`, `remote DwiRemoteException`,
`afterError ok` and a non-zero worker asset size on every engine at both mounts.
Reproduce with `FLUTTER=/path/to/flutter ./tooling/hosted_consumer/run.sh`;
results (`root.json`, `sub.json`) are written under `WORK_DIR`.

## 6. Checkout-consumer scoped-helper matrix (ADR-015 / ADR-016)

**Scope of this section: the checkout packages.** This is separate evidence from
§5: it builds the worker and page from this checkout, so it also catches
regressions before a release. Since 0.6.0 the APIs it exercises are published,
but the two evidence sets still come from different sources.

Harness: `packages/dwi_builder/test/browser_scoped_test.dart` (committed). It
builds a generated worker from the checkout, compiles the page with
`dart compile js`, and runs the same assertions in every engine:

1. two `Dwi.runFresh` calls observe fresh worker-local state (`[1, 1]`);
2. two calls in one `DwiWorker.using` scope retain state (`[1, 2]`);
3. a callback failure (`StateError`) and a remote task failure
   (`DwiRemoteException`) each leave the owned handle `closed`;
4. a spawn failure (`DwiStartupException`) does not invoke the callback;
5. a timeout (`DwiTimeoutException`) and a running cancellation
   (`DwiCancelledException`) each leave the owned handle `closed`;
6. `Dwi.run`, handle state and channel exchange remain green.

Native coverage is the VM suites `packages/dwi/test/worker_scope_test.dart` and
`packages/dwi/test/run_fresh_test.dart` (20 tests, all passing). This harness is
the browser-side evidence and does not stand in for the native run.

| Engine | Version | Runs | Status |
| --- | --- | --- | --- |
| Chrome | 157.0.8103.38 | 2/2 | **pass** |
| Safari | 26.5 | 2/2 | **pass** |
| Firefox | 159.0.1 | 2/2 | **pass** |
| Edge | 157.0.4341.42 | 2/2 | **pass** |

Measured 2026-11-08 on macOS arm64 with Dart 3.13.5. Evidence:
`audit/evidence/scoped-matrix-<engine>-20261109.json`. Reproduce one engine at a
time:

```bash
cd packages/dwi_builder
DWI_EVIDENCE_DIR=../../audit/evidence \
  dart test test/browser_scoped_test.dart \
  --plain-name "scoped helper contract in chrome"
```

Repeat the last line for `safari`, `firefox` and `edge`.

## 7. Handle termination observation (ADR-017, 2026-11-08)

**Scope of this section: the checkout packages, browser JS only.** Cases N–Z in
`packages/dwi_builder/test/browser_handle_test.dart` exercise
`DwiWorker.stopReason`/`stops`: ready-is-silent, explicit close, idle crash,
running timeout, running cancellation, malformed inbound message, call-local
failures emitting nothing, restart, close-during-restart, `Dwi.close()` ownership,
a throwing listener, and a paused listener that must not hold `close()`.
Native coverage is the VM suite, not this section.

| Engine | Version | Page loads | Status |
| --- | --- | --- | --- |
| Chrome | 157.0.8103.38 | 3/3 | **pass** |
| Safari | 26.5 | 3/3 | **pass** |
| Firefox | 159.0.1 | 3/3 | **pass** |
| Edge | 157.0.4341.42 | 3/3 | **pass** |

Measured 2026-11-09 on macOS arm64 26.5.1 with Dart 3.13.5, after the prompt-close
fix (a paused listener must not hold `close()`). Evidence:
`.research/browser_evidence/handle-matrix-<engine>-20261109.json` (gitignored;
the filename uses the harness's UTC date stamp).

Firefox required disabling every per-process sandbox switch exposed by this
build (`MOZ_DISABLE_CONTENT_SANDBOX`, `MOZ_DISABLE_GMP_SANDBOX`,
`MOZ_DISABLE_GPU_SANDBOX`, `MOZ_DISABLE_RDD_SANDBOX`,
`MOZ_DISABLE_SOCKET_PROCESS_SANDBOX`, `MOZ_DISABLE_UTILITY_SANDBOX`); without
them the host refused `sandbox_init()` and the BiDi endpoint never came up. The
earlier blocked cell is superseded by this three-load pass.

Reproduce one engine at a time:

```bash
cd packages/dwi_builder
DWI_EVIDENCE_DIR=../../.research/browser_evidence \
  dart test test/browser_handle_test.dart \
  --plain-name "handle lifecycle contract in chrome"
```

Repeat for `safari`, `firefox` and `edge`.

Browser test files now run sequentially through
`packages/dwi_builder/dart_test.yaml`, because Safari permits one WebDriver
session at a time. The scoped and handle Safari suites passed together under
this setting. Independent test processes can still contend for the same
browser; run one test process at a time when recording matrix evidence.

## What remains unverified

- The capability probe (§1) has only ever run in Chrome.
- The v0.4 runtime benchmark (§2) has no Firefox or Edge cell.
- The compiler matrix (§4) is Chrome-only, and there is no dart2wasm **worker**
  backend to measure.
- CSP `worker-src` behaviour per engine.
- Wasm threads / `crossOriginIsolated` with COOP/COEP.
- Practical maximum workers under memory pressure (only 8 measured).

## Reproducing

```bash
# §2 v0.4 runtime benchmark (one page load per run)
cd benchmarks/browser_matrix
dart pub get
dart run run.dart --engine=chrome --runs=3
dart run run.dart --engine=safari --runs=3

# §3 v0.5 handle matrix (three page loads per engine)
cd packages/dwi_builder
DWI_EVIDENCE_DIR=../../audit/evidence \
  dart test test/browser_handle_test.dart \
  --plain-name "handle lifecycle contract in chrome"
DWI_EVIDENCE_DIR=../../audit/evidence \
  dart test test/browser_handle_test.dart \
  --plain-name "handle lifecycle contract in safari"
DWI_FIREFOX_BINARY="/path/to/Firefox.app/Contents/MacOS/firefox" \
  DWI_EVIDENCE_DIR=../../audit/evidence \
  dart test test/browser_handle_test.dart \
  --plain-name "handle lifecycle contract in firefox"
DWI_EDGE_BINARY="/path/to/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  DWI_EVIDENCE_DIR=../../audit/evidence \
  dart test test/browser_handle_test.dart \
  --plain-name "handle lifecycle contract in edge"
```

An engine without a binary is skipped with an exact reason, never silently
passed. `DWI_FIREFOX_BINARY` and `DWI_EDGE_BINARY` exist because the measurement
machine runs those browsers from a temporary unpacked location; a normal install
in `/Applications` is discovered automatically.

Run the commands one engine at a time for evidence. A single `dart test`
invocation that drives all four is far heavier: on a memory-constrained host the
last engine can starve (this machine reached ~7.1 GiB of 7.7 GiB swap and a
compiler/browser run stalled while a Safari instance held sixteen processes).
That is a host limit, not an engine result, and it is why each engine's cell
comes from its own invocation.

## 7. dart2wasm worker backend (ADR-018, experimental)

**Scope of this section: a dart2js host with a worker compiled by
`dart compile wasm`, using the ADR-018 opt-in. It is not a support claim and
not a Flutter result.** Environment: macOS 26.5.1, Dart 3.13.5, Chrome
157.0.8103.50, Edge 157.0.4341.42, Firefox 159.0.1, Safari 26.5. Engines were
run sequentially. Evidence: `audit/evidence/dart2wasm-worker-acceptance-2026-11-10.txt`.

| Contract | Chrome 157 | Edge 157 | Firefox 159 | Safari 26.5 | At `/sub/app/` |
| --- | --- | --- | --- | --- | --- |
| typed proxy, async task, typed list | pass | pass | pass | pass | pass |
| typed remote error, then valid work | pass | pass | pass | pass | — |
| task timeout, then valid work | pass | pass | pass | pass | — |
| main-thread timer ticks during CPU work | pass (21–23) | pass (23) | pass (23) | pass (21) | — |
| state retained across repeated calls | pass | pass | pass | pass | — |
| idle crash observed, restart, fresh state | pass | pass | pass | pass | — |
| channels: echo, announce, duplicate, bounded, reopen | pass | pass | pass | pass | — |
| transferable bytes, sender detached | pass | pass | pass | pass | — |
| close with running work and paused stops listener | pass (0–4 ms) | pass | pass | pass | — |
| queue timeout, then running call completes | pass | pass | pass | pass | pass |
| cancel running call, restart, prompt close | pass | pass | pass | pass | — |
| missing bootstrap → typed startup failure | pass | pass | pass | pass | — |
| missing module → in-band typed startup failure | pass | pass | pass | pass | — |
| corrupt module → typed startup failure | pass | pass | pass | pass | pass |
| requested/observed backend mismatch → typed failure | pass | pass | pass | pass | — |

Engine-specific startup-failure detail is recorded in the evidence file: the
typed outcome is identical, but message text (and Safari's loader frame) differs
per engine. A dart2wasm **host** with a dart2wasm worker is **not measured**;
the host in every row is dart2js.

### Deployment constraints (same engines)

Evidence: `audit/evidence/dart2wasm-worker-deployment-2026-11-10.txt`.

| Configuration | Chrome 157 | Edge 157 | Firefox 159 | Safari 26.5 |
| --- | --- | --- | --- | --- |
| correct MIME, `/` and `/sub/app/` | pass | pass | pass | pass |
| dart2js worker control | pass | pass | pass | pass |
| wrong `.wasm` MIME | typed failure | typed failure | typed failure | typed failure |
| missing or corrupt module | typed failure | typed failure | typed failure | typed failure |
| CSP without `'wasm-unsafe-eval'` | typed failure | typed failure | typed failure | typed failure |
| CSP with `'wasm-unsafe-eval'` | pass | pass | pass | pass |
| CSP `worker-src 'none'` | typed failure | typed failure | typed failure | typed failure |
| cross-origin worker entry | typed failure | typed failure | typed failure | typed failure |

`.wasm` must be `application/wasm`, `.mjs` a JavaScript MIME, the worker entry
and its generation must be same-origin with the page, and a CSP needs
`worker-src` plus `'wasm-unsafe-eval'`. Non-root bases need no rebuild.
Missing, wrong-MIME or blocked assets never fall back to JS or the main thread.

The dependency build hook and the CLI now read the same `dwi.yaml` target, so a
Flutter workflow can request the Wasm backend without the hook replacing it with
JS. The Flutter dart2wasm-host combination and benchmarks remain unmeasured.

## 8. Flutter host × worker compiler matrix (2026-11-10)

**Scope: a clean Flutter 3.47.6 Web consumer with the ADR-018 opt-in Wasm
worker, built by the Flutter hook from `dwi.yaml`.** Environment: macOS 26.5.1,
Dart 3.13.5, Chrome 157.0.8103.50, Edge 157.0.4341.42, Firefox 159.0.1,
Safari 26.5. The installed Flutter cache is read-only here, so a writable shadow
SDK root was used and builds ran with `--no-pub`; no SDK source was modified.
Flutter's fresh-project typed-proxy ordering limitation still applies: proxies
were generated once before the first Flutter build, so these are not
first-build passes. Evidence:
`audit/evidence/flutter-wasm-worker-matrix-2026-11-10.txt`.

| Host compiler | Worker compiler | Base | Chrome | Edge | Firefox | Safari |
| --- | --- | --- | --- | --- | --- | --- |
| dart2wasm | dart2wasm | `/` | pass | pass | pass | pass |
| dart2wasm | dart2wasm | `/sub/app/` | pass | pass | pass | pass |
| dart2js | dart2wasm | `/` | pass | pass | pass | pass |
| dart2js | dart2wasm | `/sub/app/` | pass | pass | pass | pass |
| dart2wasm | dart2js (control) | `/` | pass | pass | pass | pass |

The contract in every cell: typed proxy task, unknown task, state across calls,
cancellation and stop reason, restart, crash detection, channel echo and
worker-initiated send, transferable bytes with sender detachment, timeout then
recovery, and prompt close with a paused stops listener. Capability reporting
matched the requested backend (`dart2wasm` for the Wasm-worker rows, `dart2js`
for the control).

Hook behaviour in the same fixture: `target: wasm` made the hook build the Wasm
worker; a task edit changed the generation and the next Flutter build rebuilt
it; switching `dwi.yaml` between js and wasm switched the manifest and artefact
set, and `dwi check` passed after each. A target is never silently replaced.

A dart2wasm host receives a worker's channel `gen` as `double`; the host now
normalizes integral doubles, which is why channels pass in this matrix.

Not measured: `flutter run -d chrome`, hot restart, debug/profile wasm builds,
and performance (benchmarks are separate).

## 9. Cached bootstrap and generation retention (2026-11-10)

**Scope: a client that keeps an older `worker.boot.mjs` while the deployment
moves on. This is the contract ADR-018 was amended for; it is not a parity
claim.** Environment: macOS 26.5.1, Dart 3.13.5, Chrome 157.0.8103.50, Edge
157.0.4341.42, Firefox 159.0.1, Safari 26.5. Engines run sequentially.
Evidence: `audit/evidence/cached-bootstrap-reproduction-2026-11-10.txt`,
`audit/evidence/cached-bootstrap-deployment-2026-11-10.txt`,
`audit/evidence/flutter-production-cache-2026-11-10.txt`.

Harness: `packages/dwi_builder/test/cached_bootstrap_test.dart` (committed). It
builds A, saves the exact `worker.boot.mjs` bytes, builds B, C and D, and serves
the saved bootstrap against a deployment that retains every generation. It is
deterministic: it substitutes the cached response instead of relying on HTTP
cache heuristics, and records every request with its status.

| Case | Chrome 157 | Edge 157 | Firefox 159 | Safari 26.5 |
| --- | --- | --- | --- | --- |
| cached A bootstrap, A retained, at `/` | pass ([A]) | pass ([A]) | pass ([A]) | pass ([A]) |
| cached A bootstrap, A retained, at `/sub/app/` | pass ([A]) | pass ([A]) | pass ([A]) | pass ([A]) |
| cached A bootstrap, A removed, at `/` and sub | typed `DwiStartupException` | typed | typed | typed |

The removal case never requests a later generation's files; the failure is the
missing generation, not a mixed load. Before the retention amendment the same
retained case failed in every engine with a 404 for `gen-A/worker.mjs`.

Live rebuild with deployment headers (`worker.boot.mjs` `no-cache`, `gen-*`
`immutable`) passes in Chrome, Edge, Firefox and Safari across three successive
deployments: `packages/dwi_builder/test/browser_wasm_publication_test.dart`.

Flutter 3.47.6 production build, measured in Chrome 157, Edge 157, Firefox 159
and Safari 26.5: the generated `flutter_service_worker.js` is the same
self-unregistering stub in every engine, with no `RESOURCES` map and no cache,
and `navigator.serviceWorker.controller` stayed `null`. Flutter caches nothing
here; the deployment headers decide the outcome. With immutable generations a
cached client keeps working across A, B and C; with uncached generations but
retained generations it also keeps working; once maintenance deletes the
generation the cached bootstrap names, a reload or a later spawn fails with a
typed startup error. Every engine requested only generation A and never a later
one. Details and request logs in
`audit/evidence/flutter-production-cache-2026-11-10.txt` and
`audit/evidence/flutter-production-cache-four-engines-2026-11-10.txt`.

Not measured: browser cache eviction or revalidation timing; a dart2wasm host in
the cached-bootstrap fixture (it uses a dart2js host).
