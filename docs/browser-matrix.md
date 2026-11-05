# Browser Matrix

Measured results for the browser capabilities DWI depends on. Every cell is a
measurement or an explicit `unverified`/`blocked`; nothing is inferred from
another engine.

Method: static harness served from `http://127.0.0.1:8765`
(`.research/browser_matrix/`, gitignored), results POSTed by the page and stored
per user-agent. Harness source: `index.html`, `harness.js`, `worker.js`,
`module_worker.mjs`, plus a trivial dart2wasm module (`hello.wasm` + `hello.mjs`,
compiled with Dart 3.13.5).

Last run: 2026-11-03, macOS arm64.

## Environment status

| Browser | Version | Status | Note |
| --- | --- | --- | --- |
| Chrome | 156.0.0.0 (headless) | **measured** | requires `--no-sandbox` in this sandbox; GPU disabled |
| Firefox | 159.0 | **blocked** | binary runs (`--version`), but page load fails with `Could not find profile folder`; no usable profile could be created in the sandbox |
| Safari | 26.5 | **not run** | `safaridriver` present; Safari automation is not enabled in this environment |
| Edge | — | **not installed** | `brew install --cask` blocked: Homebrew Cellar/locks are not writable; downloading the Edge `.pkg` requires an installer with admin rights |

Consequence: the matrix is **Chrome-only evidence**. Any claim about Firefox,
Safari or Edge remains unverified (AGENTS.md rule 8).

## Measurements — Chrome 156 headless

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

## What this establishes

1. A dedicated worker can start in ~60 ms on this machine and is worth pooling
   for repeated tasks (compare: task dispatch afterwards).
2. The core transfer path works: typed data can move without a copy and the
   sender loses ownership.
3. Module workers plus dart2wasm output instantiate successfully in a worker,
   including the `js-string` builtins the compiler requires.
4. `SharedArrayBuffer` is unavailable without cross-origin isolation, exactly as
   the spec requires; the JS backend must not depend on it.
5. Chrome's behaviour says nothing about Firefox/Safari/Edge. Their cells remain
   open.

## v0.4 runtime matrix (DWI API level)

Measured 2026-11-04 with `benchmarks/browser_matrix` (committed harness, see its
README for methodology). One page load = one run; medians are inside a run and
the table reports median (min–max) over three runs. Dart 3.13.5, macOS arm64
26.5.1, Apple M2, 8 GiB RAM.

| Engine | Version | Status |
| --- | --- | --- |
| Chrome | 156.0.8078.80 (headless) | **measured**, 3/3 runs clean |
| Safari | 26.5 | **unverified** — `benchmarks/browser_matrix/run.dart --engine=safari` is implemented and reaches `safaridriver`, but session creation is refused: "You must enable 'Allow remote automation' in the Developer section of Safari Settings". Re-checked 2026-11-04 after adding the driver; still refused, so nothing is recorded and the column stays empty |
| Firefox | — | **unverified** — not installed |
| Edge | — | **unverified** — not installed |

Feature and performance cells for Chrome 156 only:

| Measurement | Chrome 156 median (min–max) | Cell for Safari / Firefox / Edge |
| --- | --- | --- |
| Cold start (first call, worker spawn + ready) | 33 ms (26–35) | unverified |
| Warm dispatch (round trip) | 0.2 ms (0.101–0.2) | unverified |
| 64 KiB copy / transfer | 0.3 ms / 0.3 ms | unverified |
| 1 MiB copy / transfer | 1.5 ms (1.199–1.599) / 1.0 ms (0.9–1.099) | unverified |
| 8 MiB copy / transfer | 10.0 ms (9.3–10.1) / 6.399 ms (6.0–6.599) | unverified |
| Queued cancellation | 0.1 ms (0.1–0.101) | unverified |
| Running cancellation | 0.199 ms (0.101–0.2) | unverified |
| 100 tasks through 4 workers | 66 ms (43–97), 100/100 settled, results correct | unverified |
| Dead idle worker → next call | 11 ms (10–13) after heartbeat detection | unverified |
| UI timer ticks during 300 ms worker CPU | 29 | unverified |
| UI timer ticks during 300 ms main-thread CPU | 0 | unverified |

What this establishes, for Chrome only:

1. Worker round trips cost sub-millisecond time once warm; cold start is tens of
   milliseconds, so pooling matters for bursty workloads.
2. Transferring is never slower than copying and sells its cost at size: at
   8 MiB it is ~36% faster on this machine, at 64 KiB the difference is noise.
3. Cancellation is cheap on both paths because running cancellation terminates
   the worker instead of waiting for it.
4. A silently dead idle worker is replaced in ~11 ms, well below `taskTimeout`.
5. Running CPU work in a worker keeps the page's event loop alive (29 ticks vs
   0 for the same work on the main thread).

Full data: `audit/evidence/browser-matrix-chrome-2026-11-04.json`.

**These numbers are Chrome's.** They say nothing about Safari, Firefox or Edge
(AGENTS.md rule 8), whose cells stay unverified until the harness is run there.

### Compiler matrix (Chrome 156, Flutter 3.47.6 stable)

| App compiler | Worker | Result |
| --- | --- | --- |
| dart2js (`flutter build web --release`) | dart2js | **pass** — `DWI_RUN value=v1 backend=worker` |
| dart2wasm (`flutter build web --wasm --release`) | dart2js | **fail** — `DwiProtocolException: message.v must be an int`; the worker is fetched and packaged, the wasm host cannot decode the envelope |

The wasm row is a DWI limitation, not a Flutter or packaging failure: the build
succeeds and the identical app on dart2js runs the task. Evidence:
`audit/evidence/flutter-run-hot-restart-and-wasm-2026-11-05.txt`. Firefox,
Safari and Edge were not measured for either compiler.

## Open items

- Firefox headless profile creation (blocked in this sandbox; needs a normal
  user session or a writable Firefox profile).
- Safari automation (needs `safaridriver --enable` / Develop menu permission).
- Edge installation (needs an installer with admin rights).
- CSP `worker-src` behaviour per engine (not measured).
- Wasm threads / `crossOriginIsolated` with COOP/COEP (not measured).
- Practical maximum workers under memory pressure (only 8 measured).

## Reproducing

```bash
# gitignored harness
python3 .research/browser_matrix/serve.py &
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --no-sandbox --disable-gpu \
  --user-data-dir="$TMPDIR/chrome-dwi" http://127.0.0.1:8765/index.html
# results land in .research/browser_matrix/results/<user-agent>.json
```
