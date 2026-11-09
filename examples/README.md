# Examples

Runnable demonstrations of the public API. Examples are user-facing: they show
the recommended way to use DWI and must not reach into implementation details.

| Example | Shows |
| --- | --- |
| `fibonacci/` | Minimal `Dwi.run` CPU task. |
| `automatic_worker/` | Zero-boilerplate `@DwiTask` discovery, worker generation and compilation. |
| `stateful_worker/` | Dedicated `DwiWorker` handle and worker-local state that persists between calls. |
| `scoped_worker/` | `DwiWorker.using` scope ownership and `Dwi.runFresh` fresh-context calls. |

Earlier revisions of this index listed `json_parser/`, `image_processing/`,
`worker_pool/`, `flutter_counter/` and `flutter_jank_demo/`. They are **not in
the tree** and must not be presented as runnable; the Flutter Web path is
covered by `integration_tests/` and ADR-009 instead.

Each example has its own `README.md` with run instructions and states which
backend (native isolate / JS worker / Wasm worker) it exercises.
