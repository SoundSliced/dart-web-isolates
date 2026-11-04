# Packages

Dart packages are versioned independently and keep their own `CHANGELOG.md`.
No package may depend on a browser-only API outside `dwi_web`.

| Package | Responsibility |
| --- | --- |
| `dwi` | Public developer-facing API (`Dwi.run`, generated `DwiTasks` proxies, later `spawn`). Hides platform selection and re-exports `@DwiTask`. |
| `dwi_core` | Platform-independent abstractions: worker handle, task, result, error, capability, pool scheduler. No `dart:html`, no `package:web`, no `dart:isolate`. |
| `dwi_web` | Browser implementation: worker creation, messaging, lifecycle, transferables, capability detection, plus the generated-worker runtime. |
| `dwi_native` | Adapter over real Dart isolates (`Isolate.run`/`spawn`) so the same API is honest on native. |
| `dwi_protocol` | Versioned message envelope, task correlation, error payloads. Pure Dart, shared by host and worker. |
| `dwi_builder` | Analyzer-based CLI that discovers `@DwiTask` functions, generates worker entrypoints/proxies/manifests, and compiles with `dart compile js`. |
| `dwi_annotations` | The `@DwiTask` marker shared by user code and the builder. |

Planned dependency direction:

```text
dwi ──► dwi_core ──► dwi_protocol
 │          ▲
 ├──► dwi_native
 ├──► dwi_web
 └──► dwi_annotations

dwi_builder ──► dwi_annotations (discovery/codegen)
     │
     └──► .dwi/generated_worker.dart ──► dwi_web/dwi_worker.dart ──► dwi_protocol
```

Generated files (`.dwi/`, `lib/dwi_tasks.g.dart`, `web/dwi/`) are build output,
not source. No application runtime depends on `dwi_builder`.
