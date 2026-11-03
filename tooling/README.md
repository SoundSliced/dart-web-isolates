# Tooling

Development-time tools. None of these ship in a user's dependency graph.

| Tool | Purpose | Status |
| --- | --- | --- |
| `worker_compiler/` | Compile Dart worker entrypoints (`dart compile js`, later `dart compile wasm`) and place artefacts where the app serves them. | Planned |
| `code_generator/` | Generate deterministic worker registries, dispatch tables and serialization bindings from `@DwiTask` declarations. | Planned |
| `benchmark_runner/` | Run the benchmark matrix (main thread / worker / Wasm worker / native isolate) and emit comparable results. | Planned |

Rules:

- Generated output must be deterministic; a tool that emits timestamps or
  unstable ordering is a bug.
- Tools must fail loudly: a missing worker artefact is an error, not a silent
  fallback to main-thread execution.
- Every tool documents its inputs, outputs and exit codes in its own README.
