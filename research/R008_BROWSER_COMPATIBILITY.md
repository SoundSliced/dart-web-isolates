# R008 — Browser Compatibility

Status: framework + spec-derived constraints. **No engine was measured yet** in
this report; cells that require a measurement are `pending (M001)`. This file is
updated after the M001 browser runs, and the measured result lives in
`docs/browser-matrix.md`.

Method for every cell:

1. Load a page that constructs the feature (worker, transferable, wasm module)
   from a same-origin served file.
2. Record: success/failure, error name, timing, and the browser + version string.
3. Never infer one engine's result from another (AGENTS.md rule 8).
4. A feature that cannot be tested is `not run`, never `pass`.

## Dimensions

| Dimension | Why it matters | Evidence source |
| --- | --- | --- |
| Dedicated `Worker` | the backend itself | MDN / spec (R003 §1) |
| Module worker (`type: 'module'`) | required for the Wasm loader | spec + measurement |
| Structured clone of nested arrays/maps | request/response payloads | MDN (R003 §3) |
| `DataCloneError` for functions | proves the closure limit | measurement |
| `ArrayBuffer` transfer + detach | zero-copy path | MDN (R003 §4) |
| `MessageChannel` port transfer | port model upgrade | measurement |
| `SharedArrayBuffer` / `crossOriginIsolated` | Wasm threads, headers | MDN (R003 §5) |
| WasmGC | dart2wasm output | measurement |
| `js-string` builtins | dart2wasm loader imports | R005 §2 |
| CSP `worker-src` behaviour | deployment | measurement |
| `hardwareConcurrency` | pool sizing | MDN (R003 §7) |
| Max practical workers | pool safety | measurement |
| Worker startup latency | design decision (pool vs per-call) | measurement |

## Matrix (to be filled by measurements)

| Capability | Chrome | Safari | Firefox | Edge |
| --- | --- | --- | --- | --- |
| Dedicated worker | pending | pending | pending | pending |
| Module worker | pending | pending | pending | pending |
| Structured clone (nested) | pending | pending | pending | pending |
| `DataCloneError` on function | pending | pending | pending | pending |
| Transferable `ArrayBuffer` | pending | pending | pending | pending |
| `MessageChannel` transfer | pending | pending | pending | pending |
| `SharedArrayBuffer` (isolated) | pending | pending | pending | pending |
| WasmGC module instantiation | pending | pending | pending | pending |
| `js-string` builtins | pending | pending | pending | pending |
| CSP `worker-src` blocks load | pending | pending | pending | pending |
| `hardwareConcurrency` value | pending | pending | pending | pending |
| Practical max workers | pending | pending | pending | pending |
| Startup latency (ms) | pending | pending | pending | pending |

## Spec-derived constraints that hold regardless of engine

- Worker scripts are same-origin or CORS-enabled; failures surface as `error`
  events (MDN, Worker).
- `SharedArrayBuffer` needs a secure context and cross-origin isolation
  (MDN, SharedArrayBuffer).
- Structured clone cannot carry functions or preserve prototypes
  (MDN, structured clone algorithm).
- Transferring an `ArrayBuffer` detaches the source (MDN, transferable objects).

## Known risk areas to test explicitly in M001

1. **Safari/iOS**: worker availability in private browsing, memory pressure,
   `hardwareConcurrency` reporting, module workers, WasmGC version support.
2. **Firefox**: CSP `worker-src` reporting, Wasm `js-string` builtins.
3. **Chrome/Edge**: reference behaviour, but still measured, not assumed.
4. **CSP**: a `worker-src 'self'` policy with the worker under `dwi/` must load;
   a `blob:` worker under a strict policy must fail with an observable error.
5. **COOP/COEP**: only required for shared memory; the JS backend must work
   without them.

## Support statement policy

DWI will publish a matrix only with cells that were measured on the named
browser and version. Anything else is “unverified”. This is a hard rule from
`AGENTS.md` (rules 7 and 8).

## Verification status

- **Verified**: spec-derived constraints, cited above.
- **Unverified**: every engine cell in the matrix.
- **Not run**: all measurements; M001 owns them.
