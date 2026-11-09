# Browser Matrix

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
  Three environment workarounds live in the harness, not in DWI: Edge gets a
  private home through `CFFIXED_USER_HOME`/`HOME` (its path service aborts on
  this session's read-only `~/Library/Application Support`), its Keychain
  request is replaced by `--use-mock-keychain` (the real Keychain cannot store
  the safe-storage key here), and the standard automation flags suppress its
  first-run updater, which otherwise outlived the page-target wait. With those,
  Edge runs the same contract unmodified.

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

Run one engine (and one browser harness) at a time. A single parallel
`dart test` starts several browser matrices at once and can exhaust each test's
12-minute budget even when every engine passes in isolation; contention is not a
result and must not be recorded as one.

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
