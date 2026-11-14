# Tooling

Development-time tools. None of these ship in a user's dependency graph.

| Tool | Purpose | Status |
| --- | --- | --- |
| `proxy_gate/` | Reproduce the fresh typed-proxy Flutter ordering gap (first build fails, second succeeds) and fail if Flutter ever orders it correctly. | Implemented |
| `tree_shaking_probe/` | Build the generator's registry for annotated shapes and check dart2js output at `-O1`, `-O2` and `-O4` keeps every annotated shape and drops an unreferenced one. | Implemented (completion-plan tranche A8) |
| `hosted_consumer/` | Drive the four supported engines against a served directory (the probe used by the browser matrix). | Implemented |
| `dwi5_probe/` | DWI-5 function-reference probes (static identity, analyzer forms). | Research probe |
| `data_asset_gate/` | Data-asset build gate evidence for Flutter web. | Research probe |

Code generation lives in `packages/dwi_builder`. Benchmarks live in `benchmarks/`
and `benchmarks/browser_matrix`. The earlier `worker_compiler/`, `code_generator/`
and `benchmark_runner/` entries were never populated and were removed from this
table on 2026-11-14.

Rules:

- Generated output must be deterministic; a tool that emits timestamps or
  unstable ordering is a bug.
- Tools must fail loudly: a missing worker artefact is an error, not a silent
  fallback to main-thread execution.
- Every tool documents its inputs, outputs and exit codes in its own README.
