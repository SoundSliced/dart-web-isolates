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

Flutter examples (ADR-025, run on Flutter 3.50.0 / Dart 3.14.0):

| Example | Shows |
| --- | --- |
| `flutter_counter/` | `computeParallel` over a DWI task, in a Flutter web app. |
| `flutter_jank_demo/` | Frame gaps while the same work runs on the main thread, with `computeParallel`, and with Flutter's `compute()`. |

Both Flutter examples write their result to `document.title` for the browser
probe. They keep the title `pending` until the run finishes, because Flutter
otherwise replaces the placeholder with the app title. The visible heading names
the app.

Each example has its own `README.md` with run instructions and states which
backend (native isolate / JS worker / Wasm worker) it exercises.
