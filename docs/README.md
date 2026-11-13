# Documentation

Project documentation for DWI. See the master plan for the full intent; this
directory holds the maintained reference material.

| Document | Purpose |
| --- | --- |
| `vision.md` | Problem statement, target developer experience, non-goals. |
| `current-state-2026.md` | Ground truth: what the current Dart/Flutter web toolchain does. |
| `architecture.md` | Architecture and decision record (ADR-001 onward). |
| `api-proposal.md` | Proposed public API and its compatibility levels. |
| `protocol.md` | Wire protocol between host and worker. |
| `dart-isolate-semantics.md` | Which isolate semantics DWI preserves, which it cannot. |
| `serialization.md` | What can cross the boundary, and at what cost. |
| `compiler-strategy.md` | How worker entrypoints are compiled and loaded. |
| `automatic-workers.md` | v0.3 zero-boilerplate workflow, diagnostics, manifest and cache. |
| `compatibility-matrix.md` | Dart isolate feature vs DWI vs web limitation. |
| `browser-matrix.md` | Measured per-engine support and behaviour. |
| `benchmarks.md` | Benchmark methodology and results. |
| `limitations.md` | Known gaps, stated plainly. |
| `upstream-strategy.md` | Path toward Dart/Flutter upstream integration. |
| `MASTER_PLAN.md` | The master plan (reconstructed by its author, 2026-11-11). |
| `ENGINEERING_HANDOFF.md` | Audit and continuation handoff that accompanies the master plan. |
| `ZERO_BOILERPLATE_ADDENDUM.md` | Addendum: automatic worker compilation and the zero-boilerplate goal. |
| `IMPLEMENTATION_STATUS.md` | Every plan objective classified against the repository. |
| `completion-plan.md` | Ordered tranches that finish what the status leaves open. |
| `upstream/flutter-web-hook-ordering.md` | Prepared proposal: order web build hooks before Dart compilation. |
| `prior-art.md` | Existing packages and what to reuse or avoid. |

Research evidence lives in `../research/`; findings that shaped a decision are
linked from `architecture.md`.
