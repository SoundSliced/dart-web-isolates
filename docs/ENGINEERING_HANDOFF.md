# DWI Engineering Audit & Continuation Handoff

> **Provenance (2026-11-11).** The engineering handoff as re-issued by the original planning
> assistant on 2026-11-11 and saved here unedited apart from this note. It is a
> planning baseline, not evidence of implementation: status is tracked in
> [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) and remaining work in
> [`completion-plan.md`](completion-plan.md).

Repository verification · Defect recovery · Remaining implementation · AI-agent execution

This document was originally prepared following the reported v0.2 implementation at commit `e105f29`. The subsequent v0.3 report describes additional completed work. Therefore, the next agent must audit the current repository HEAD, not assume that `e105f29` remains the latest implementation.

## 1. Handoff mission

You are taking over development of:

SoundSliced/dart-web-isolates

Your mission is to verify the repository, correct defects, complete unfinished features and advance DWI toward a stable cross-platform concurrency framework.

Do not treat previous agent completion reports as independently verified evidence.

You must preserve working implementations and avoid unnecessary rewrites.

## 2. Reported implementation history

### v0.2 baseline

The earlier agent reported:

- Phase 0 research R001–R010.
- M001 Dart-in-Worker proof of concept.
- Protocol v1.
- Native isolate backend.
- Browser Worker backend.
- Worker pooling.
- Startup and task timeouts.
- Typed errors.
- Conditional-import facade.
- 29 unit tests.
- Browser integration testing.
- Successful Flutter Web release build.
- ADR-001 through ADR-007.

The reported baseline commit was `e105f29`.

### v0.3 continuation

The later agent reported:

- `dwi_annotations` and `@DwiTask`.
- `dwi_builder`.
- Analyzer-based task discovery.
- Generated worker entrypoint.
- Generated typed proxies.
- JavaScript compilation.
- Content-hash caching.
- Generated manifest.
- Build diagnostics DWI001–DWI010.
- `build`, `generate`, `check`, `watch` and `clean` commands.
- `examples/automatic_worker`.
- 61 passing package tests.
- Research R013 and ADR-008.
- A Flutter build wrapper.

These additions must be verified against the actual repository.

## 3. Audit classification

Every implementation claim must receive one status:

| Classification     | Meaning                                                |
| ------------------ | ------------------------------------------------------ |
| VERIFIED           | Reproduced and supported by tests/evidence             |
| PARTIALLY VERIFIED | Works under some conditions but coverage is incomplete |
| INCORRECT          | Source or testing contradicts the claim                |
| OBSOLETE           | Replaced by a newer implementation                     |
| NOT REPRODUCIBLE   | Cannot reproduce the reported result                   |
| NOT TESTED         | Insufficient evidence                                  |

The final audit must not collapse these distinctions into a single pass/fail label.

## 4. Repository integrity audit

Inspect:

```
git status
git log --oneline -20
git branch -a
git tag
git diff --check
```

Verify the working tree, commit history, package versions, generated files, ignored artifacts and absence of committed secrets.

Check that machine-specific SDK paths, caches and temporary research artifacts are not accidentally required for builds.

Deliverable:

`audit/A001_REPOSITORY_INTEGRITY.md`

## 5. Package architecture audit

Review every existing package:

```
dwi
dwi_core
dwi_protocol
dwi_native
dwi_web
dwi_annotations
dwi_builder
```

Check dependency direction, public exports, platform imports, version constraints, naming consistency, error types and duplicated functionality.

Verify that web-only dependencies do not leak into native targets.

Deliverable:

`audit/A002_PACKAGE_AUDIT.md`

## 6. Research verification

Independently check important claims in R001–R013 against the Dart SDK, Flutter SDK, browser APIs and compiler behaviour.

Pay special attention to distinctions between:

- Directly importing a library.
- Compiling that import.
- Executing a supported operation.
- Conditional-import availability.
- Browser capabilities.
- Dart compiler capabilities.

A library compiling successfully does not establish that its runtime operations are supported.

Deliverable:

`audit/A003_RESEARCH_VERIFICATION.md`

## 7. M001 reproduction

Reproduce the original CPU-heavy experiment.

Run identical workloads on the main thread and in a Worker.

Verify:

- Identical results.
- Actual Worker execution.
- Main-thread responsiveness.
- Animation frame behaviour.
- Worker startup and dispatch overhead.
- Error propagation.

Repeat trials and retain raw data.

Deliverable:

`audit/A004_M001_REPRODUCTION.md`

## 8. Protocol audit

Inspect the versioned message protocol and validate:

- Request identifiers.
- Worker readiness.
- Capability reporting.
- Result correlation.
- Error envelopes.
- Unknown task handling.
- Malformed messages.
- Duplicate replies.
- Late replies after timeout.
- Shutdown behaviour.
- Protocol-version mismatches.

Ensure invalid messages cannot leave pending operations permanently unresolved.

Deliverable:

`audit/A005_PROTOCOL_AUDIT.md`

## 9. Worker-pool audit

Test:

- Initial worker creation.
- Pool sizing.
- Task routing.
- Queue ordering.
- Worker reuse.
- Concurrent requests.
- Worker crashes.
- Worker replacement.
- Startup timeouts.
- Task timeouts.
- Shutdown.
- Resource cleanup.

Run sequential and concurrent stress tests with representative workloads of 1, 10, 100 and 1,000 tasks.

Investigate leaks involving `Completer` objects, event listeners, timers, pending maps and orphaned Workers.

## 10. Native backend audit

Verify that native execution uses actual Dart isolates.

Test:

- Successful results.
- Remote exceptions.
- Large payloads.
- Concurrent calls.
- Timeouts.
- Shutdown.
- Resource cleanup.
- Repeated initialization.

Document semantic differences between native and web implementations.

## 11. Web backend audit

Verify that the browser backend creates genuine Workers and does not silently run expensive work on the main thread.

Test Worker loading failures, missing scripts, wrong script paths, protocol errors and browser termination behaviour.

Check that failures are surfaced clearly to application code.

## 12. Generated task discovery audit

Inspect how `dwi_builder` identifies `@DwiTask` declarations.

Test:

- Multiple annotated functions.
- Tasks in separate libraries.
- Duplicate task names.
- Imported helpers.
- Async functions.
- Nullable inputs/results.
- Unsupported generic signatures.
- Invalid or inaccessible declarations.
- Task naming collisions.

Do not assume that passing a simple prime-number example proves general discovery correctness.

## 13. Generated proxy audit

Verify generated method signatures match their source tasks.

For example:

```
@DwiTask()
Future<int> calculate(int value) async {
  return value * 2;
}
```

should generate a usable typed asynchronous proxy without incorrectly wrapping or losing result types.

Test generated code with the analyzer and compiler, not merely text comparisons.

## 14. Tree-shaking audit

Verify that registered worker functions and their dependencies survive optimized compilation.

Test changes to:

- The annotated function.
- An imported helper.
- A transitive dependency.
- Compiler flags.
- Package versions.

A successful worker build with missing or stale functionality is a release-blocking defect.

## 15. Build and cache audit

Verify:

- Deterministic generation.
- Correct cache invalidation.
- Hash coverage.
- Manifest accuracy.
- Atomic artifact replacement.
- Recovery from interrupted compilation.
- Stale artifact detection.
- Missing artifact detection.
- Compiler failure handling.
- Reproducible clean builds.

Test compilation from a new checkout without relying on previous generated outputs.

## 16. Flutter build integration audit

Inspect the wrapper:

```
dart run dwi_builder:dwi build --flutter-build -- --release
```

Verify that it:

- Generates worker sources.
- Compiles the worker.
- Invokes Flutter with the intended arguments.
- Places worker artifacts correctly.
- Fails when worker compilation fails.
- Handles base paths and output directories.
- Does not leave stale files after a failed build.

Document that a wrapper is not identical to native `flutter build web` integration.

## 17. Clean external consumer test

Create a completely separate Flutter project that consumes DWI through its intended dependency mechanism.

The application must not depend on internal repository paths, hidden generated files or local caches.

Test a full install, generation, compilation, deployment and runtime execution cycle.

This is a mandatory milestone for package readiness.

## 18. Continuous integration

Establish or verify CI for:

- Formatting.
- Static analysis.
- Unit tests.
- Native integration tests.
- Web compilation.
- Browser integration tests.
- Flutter Web builds.
- Generated artifact checks.

Every supported platform must have a clearly defined validation strategy.

## 19. Audit exit gate

Produce:

`AUDIT_SUMMARY.md`

Include:

- Current commit.
- Environment.
- Verified functionality.
- Failed tests.
- Discovered defects.
- Corrective commits.
- Unsupported behaviour.
- Remaining risks.
- Recommended next milestone.

Classify the repository as healthy, healthy with fixes required, or requiring architectural rework.

Do not proceed to new features while release-blocking baseline defects remain.

## 20. Generated registry and typed proxy completion

If any v0.3 capability remains incomplete, finish it before advancing.

The expected workflow is:

```
@DwiTask()
int calculatePrimes(int limit) {
  // ...
}
```

with generated invocation:

```
final count =
    await DwiTasks.calculatePrimes(5_000_000);
```

Generated code must be deterministic, type-safe and tree-shaking compatible.

## 21. Automatic worker entrypoint

The developer must not manually maintain a Worker main function or task registry.

DWI owns the generated entrypoint, protocol initialization and dispatch infrastructure.

## 22. Automatic worker compilation

Worker compilation should be integrated as closely as possible with normal Flutter workflows.

If the installed Flutter SDK lacks an appropriate hook, retain the wrapper while researching alternatives.

The limitation must be documented rather than concealed.

## 23. Long-lived workers

Introduce or complete an API for reusable worker instances.

Conceptually:

```
final worker = await DwiWorker.spawn(/* config */);

try {
  final result = await worker.runTask(/* task */);
} finally {
  await worker.close();
}
```

The exact API should follow the repository's existing abstractions.

## 24. Port-like messaging

Investigate `DwiSendPort` and `DwiReceivePort`.

Use logical identifiers for Workers, ports and channels.

Document how their semantics differ from native isolate ports.

## 25. Streams

Support asynchronous streams for long-running operations.

Ensure subscriptions, cancellation and Worker shutdown do not leak resources.

## 26. Cancellation

Define task states:

```
QUEUED
RUNNING
COMPLETED
FAILED
CANCELLED
TIMED_OUT
```

Support cancellation of queued tasks and cooperative cancellation of running tasks where feasible.

Worker termination may be necessary for non-cooperative computation, but its impact on other in-flight tasks must be explicit.

## 27. Transferable binary data

Investigate efficient movement of `ArrayBuffer`, typed data and other transferable objects.

Provide an ergonomic Dart abstraction with documented ownership semantics.

Benchmark transfer versus copying.

## 28. Serialization

Define a supported type matrix.

Investigate primitive types, lists, maps, typed data, enums, records and generated DTOs.

Unsupported objects should fail predictably, preferably during generation or compilation when possible.

## 29. Serialization versioning

Maintain protocol and payload compatibility as the package evolves.

Introduce schema metadata only where justified by concrete requirements.

## 30. Worker-pool scheduling

Evaluate:

- FIFO.
- Round-robin.
- Least-loaded scheduling.
- Priority queues.
- Adaptive pool sizing.

Do not select a strategy solely because it appears sophisticated. Use benchmarks and workload evidence.

## 31. Backpressure

Prevent unbounded task queues and memory growth.

Support explicit capacity limits and documented overload behaviour.

## 32. Worker crash recovery

Test forced Worker failures.

Verify in-flight task handling, queued task preservation or failure, worker replacement and restoration of pool capacity.

## 33. Browser matrix

Test Chrome, Firefox, Safari and Edge.

Where feasible, test mobile browsers.

Record exact versions, execution environments and results.

Unavailable browsers remain unverified.

## 34. Content Security Policy

Test production-relevant CSP configurations.

Avoid unnecessary dependence on `unsafe-eval` or Blob URLs.

Document deployment requirements and failures.

## 35. Dart/Wasm backend

Develop a separate Wasm Worker proof of concept.

Start with independent Wasm instances and message passing before attempting shared-memory designs.

## 36. Wasm proof of concept

Demonstrate Dart/Wasm code executing in a Worker and returning results to a Dart/Flutter Web application.

Measure startup, transfer and execution overhead.

## 37. Wasm architecture decision

Produce an ADR comparing separate instances, shared memory and WebAssembly threads.

Select the architecture based on feasibility, compatibility and performance.

## 38. Backend selection

Support explicit selection among available native, JavaScript Worker and Wasm Worker backends.

Do not silently substitute main-thread execution.

## 39. Flutter integration package

Consider `dwi_flutter` once Flutter-specific responsibilities justify a separate package.

Investigate ergonomic APIs and Flutter-aware diagnostics.

## 40. Flutter responsiveness demonstration

Maintain a reproducible demonstration comparing main-thread computation and DWI execution.

Include Flutter Web's ordinary `compute()` behaviour where relevant.

## 41. Diagnostics

Expose optional metrics for Worker state, task timing, queue depth, startup, transfer size and failures.

Keep production overhead low.

## 42. Compiler research

Investigate how Dart compiler infrastructure represents closures, captured variables, reachable dependencies and worker entrypoints.

Do not implement arbitrary closure execution through fragile source-text rewriting.

## 43. Closure feasibility decision

Produce:

`research/R012_CLOSURE_FEASIBILITY.md`

Conclude whether the desired API is package-feasible, compiler-dependent or currently impractical.

## 44. Dart SDK experimental fork

Only after the package architecture is mature, create a focused experimental SDK branch.

The objective is to identify the minimum compiler/runtime changes required for improved Worker integration.

## 45. SDK design questions

Answer:

1. Can Worker entrypoints be emitted automatically?
2. Can compiler-known function references be exported?
3. How are dependencies and tree shaking handled?
4. Can isolate-style ports be mapped to Worker messages?
5. What belongs in the compiler versus runtime?
6. What semantic differences are unavoidable?
7. How does dart2js participate?
8. How does dart2wasm participate?
9. How are debugging and source maps supported?
10. How can Flutter build tooling integrate the result?

## 46. Experimental `Isolate.run`

Investigate web support for an `Isolate.run`-like API only after compiler feasibility has been established.

Treat this as a research prototype, not a production promise.

## 47. Flutter SDK experimental fork

Investigate whether Flutter Web's `compute()` could eventually use a Worker-backed implementation.

Preserve public semantics where possible and document deviations.

## 48. Performance suite

Build reproducible benchmarks for mathematical workloads, sorting, JSON, compression, hashing, image processing and binary transfers.

Measure wall time, startup, dispatch, memory, throughput and UI responsiveness.

## 49. Message-size benchmarks

Test representative payload sizes from kilobytes through tens of megabytes.

Compare copying and transferable data.

## 50. Worker-count benchmarks

Measure different pool sizes, including 1, 2, 4 and 8 Workers where hardware permits.

Avoid assuming more Workers always improve throughput.

## 51. Memory and leak testing

Run sustained workloads with thousands of tasks, repeated errors, timeouts, cancellations and pool restarts.

Look for unbounded heap growth and resource leaks.

## 52. Security review

Repeat security review after major architecture changes.

Focus on task dispatch, Worker URLs, malformed payloads, CSP, generated code and resource exhaustion.

## 53. Documentation

Maintain:

```
README.md
docs/architecture.md
docs/limitations.md
docs/browser-matrix.md
docs/serialization.md
docs/compiler-strategy.md
docs/upstream-strategy.md
CHANGELOG.md
```

The README must not claim capabilities that have not been implemented and verified.

## 54. Examples

Provide working examples for basic tasks, CPU-heavy tasks, binary transfers, pools, cancellation, streaming, Flutter integration and Wasm.

Examples should exercise public APIs, not internal shortcuts.

## 55. Release gates

| Release | Mandatory capabilities                                           |
| ------- | ---------------------------------------------------------------- |
| v0.3    | Registry, typed proxies, generation, compilation, tests          |
| v0.4    | Transferables, cancellation, pool hardening, backpressure        |
| v0.5    | Long-lived Workers, ports, streams, diagnostics                  |
| v0.6    | Wasm Worker backend and browser evidence                         |
| v0.7    | Flutter integration and examples                                 |
| v0.8    | Compiler experiments and automatic build improvements            |
| v0.9    | SDK isolate-compatibility experiment                             |
| v1.0    | Stable supported API, tests, documentation and release readiness |

Upstream adoption is not a prerequisite for a useful v1.0 package.

## 56. Agent workflow

Use:

```
Research → Evidence → ADR → Review
    → Implementation → Tests
    → Benchmarks → Documentation → Merge
```

Assign specialist agents according to the work.

The coordinator maintains architectural consistency and obtains human approval for major breaking changes.

## 57. Agent rules

Agents must inspect before modifying, preserve useful work, cite SDK evidence, add regression tests, keep commits focused and distinguish verified functionality from speculation.

They must not fabricate compatibility results, suppress failing tests or silently fall back to main-thread execution.

## 58. Defect correction procedure

For every bug:

```
Reproduce
   ↓
Write failing test
   ↓
Identify root cause
   ↓
Implement minimal fix
   ↓
Pass regression test
   ↓
Check related edge cases
   ↓
Document
```

## 59. Architectural stop conditions

Escalate for review when a finding would require:

- Breaking public API redesign.
- Incompatible protocol changes.
- Unsupported compiler internals.
- A fundamentally different Wasm architecture.
- Security compromises.
- Premature SDK forks.
- Significant maintenance debt.

## 60. Final deliverables

Prepare:

```
FINAL_IMPLEMENTATION_REPORT.md
FINAL_ARCHITECTURE.md
FINAL_BROWSER_MATRIX.md
FINAL_BENCHMARK_REPORT.md
FINAL_SECURITY_REVIEW.md
FINAL_SDK_FEASIBILITY_REPORT.md
UPSTREAM_PROPOSAL.md
```

Every master-plan objective must be classified as complete, complete with limitations, deferred, superseded or infeasible, with evidence.

## 61. Immediate instruction to the receiving agent

Begin with a comprehensive audit of the current repository HEAD.

Do not repeat already completed v0.3 work without identifying a real defect.

First verify the baseline, fix failures and confirm reproducibility.

Then advance through the remaining milestones in dependency order.

The objective is not to maximize checked boxes. It is to deliver a trustworthy concurrency framework whose behaviour can be independently demonstrated.
