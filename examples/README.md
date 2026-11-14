# Examples

Runnable demonstrations of the public API. Examples are user-facing: they show
the recommended way to use DWI and must not reach into implementation details.

| Example | Shows |
| --- | --- |
| `fibonacci/` | Minimal `Dwi.run` CPU task. |
| `automatic_worker/` | Zero-boilerplate `@DwiTask` discovery, worker generation and compilation. |
| `stateful_worker/` | Dedicated `DwiWorker` handle and worker-local state that persists between calls. |
| `scoped_worker/` | `DwiWorker.using` scope ownership and `Dwi.runFresh` fresh-context calls. |
| `stop_observer/` | `DwiWorker.stopReason` / `stops` termination observation (ADR-017). |
| `worker_link/` | `DwiWorker.link`: two handles exchanging messages through a relayed link (ADR-023). |
| `dispatch_control/` | `Dwi.pause`/`resume` and `DwiWorker.ping` (ADR-028). |
| `cooperative_cancel/` | `DwiCancelToken` and `DwiConfig.cancelGracePeriod`: a task that stops cleanly when cancelled (ADR-027). |

Removed on 2026-11-14 (ADR-025 O2): `json_parser/`, `image_processing/` and
`worker_pool/`. They were empty. The pool is covered by package tests.

Not yet present: `flutter_counter/` and `flutter_jank_demo/` (ADR-025). They
will be added as runnable Flutter examples of `dwi_flutter`'s `computeParallel`
when they can be run and measured; until then they are not presented as
runnable. The Flutter Web build path is covered by `integration_tests/` and
ADR-009.

Each example has its own `README.md` with run instructions and states which
backend (native isolate / JS worker / Wasm worker) it exercises.
