# Examples

Runnable demonstrations of the public API. Examples are user-facing: they show
the recommended way to use DWI and must not reach into implementation details.

| Example | Shows |
| --- | --- |
| `fibonacci/` | Minimal `Dwi.run` CPU task. |
| `json_parser/` | Large payload transfer and parsing off the main thread. |
| `image_processing/` | Typed-data transfer to a worker. |
| `worker_pool/` | Several tasks scheduled across a pool. |
| `flutter_counter/` | Flutter integration with UI remaining responsive. |
| `flutter_jank_demo/` | Measured frame-drop comparison, main thread vs worker. |

Each example has its own `README.md` with run instructions and states which
backend (native isolate / JS worker / Wasm worker) it exercises.
