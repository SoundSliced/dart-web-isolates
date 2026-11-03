# Packages

Dart packages are versioned independently and keep their own `CHANGELOG.md`.
No package may depend on a browser-only API outside `dwi_web`.

| Package | Responsibility |
| --- | --- |
| `dwi` | Public developer-facing API (`Dwi.run`, `Dwi.runTask`, later `spawn`). Hides platform selection. |
| `dwi_core` | Platform-independent abstractions: worker handle, task, result, error, capability, pool scheduler. No `dart:html`, no `package:web`, no `dart:isolate`. |
| `dwi_web` | Browser implementation: worker creation, messaging, lifecycle, transferables, capability detection. |
| `dwi_native` | Adapter over real Dart isolates (`Isolate.run`/`spawn`) so the same API is honest on native. |
| `dwi_protocol` | Versioned message envelope, task correlation, error payloads. Pure Dart, shared by host and worker. |
| `dwi_builder` | build_runner builder that discovers annotated task functions and generates worker entrypoints. |
| `dwi_annotations` | `@DwiTask` / `@WorkerEntrypoint` annotations shared by user code and the builder. |

Planned dependency direction:

```text
dwi ──► dwi_core ──► dwi_protocol
 │          ▲
 ├──► dwi_native
 └──► dwi_web

dwi_annotations ◄── user code
dwi_builder ──► generated worker entrypoint ──► dwi_protocol
```
