# Research

Evidence base for DWI. Every claim in these reports must cite a repository,
file, symbol and version (or commit), or a reproducible probe committed to the
repository. Research agents do not modify the Dart or Flutter SDKs.

## Reports

| ID | Report | Subject |
| --- | --- | --- |
| R001 | `R001_DART_ISOLATE_ARCHITECTURE.md` | VM isolate implementation, ports, message serialization |
| R002 | `R002_DART_WEB_LIMITATIONS.md` | Why `dart:isolate` is unavailable on web; web stubs |
| R003 | `R003_WEB_WORKERS.md` | Worker, SharedWorker, MessageChannel, structured clone, transferables |
| R004 | `R004_DART2JS.md` | dart2js/DDC pipeline, tree shaking, closure representation |
| R005 | `R005_DART2WASM.md` | dart2wasm, WasmGC, threads, worker loading |
| R006 | `R006_MESSAGE_SERIALIZATION.md` | Dart VM serialization vs structured clone |
| R007 | `R007_WORKER_COMPILATION.md` | Compiling secondary Dart entrypoints for workers |
| R008 | `R008_BROWSER_COMPATIBILITY.md` | Per-engine worker/Wasm/CSP support |
| R009 | `R009_EXISTING_PACKAGES.md` | Prior art and its limitations |
| R010 | `R010_UPSTREAM_DART_ISSUES.md` | Relevant Dart/Flutter issues and design discussions |
| R013 | `R013_RUNTIME_WORKER_COMPILATION.md` | Automatic worker compilation strategies and the v0.3 decision |
| R014 | `R014_DWI4_SCOPE.md` | DWI-4 scope: `dart:isolate` API comparison and the selected increment |
| R015 | `R015_DWI4_NEXT_INCREMENT.md` | DWI-4 next increment: termination observation, native transfer, error stream; selects lifecycle observation |

## Notes directories

- `dart_sdk/` — notes on isolate, ports, serialization and web libraries.
- `flutter/` — `compute()`, foundation, web engine and build tooling.
- `dart2js/`, `ddc/`, `dart2wasm/` — compiler pipeline observations and probes.
- `web_workers/` — browser worker API experiments.
- `wasm_threads/` — Wasm threads and shared-memory research.

SDK clones used for citation live in the gitignored `.research/` directory and
are never committed.
