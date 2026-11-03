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
