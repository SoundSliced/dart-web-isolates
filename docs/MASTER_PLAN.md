# Dart Web Isolates (DWI)

> **Provenance (2026-11-11).** The master plan as re-issued by the original planning
> assistant on 2026-11-11 and saved here unedited apart from this note. It is a
> planning baseline, not evidence of implementation: status is tracked in
> [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) and remaining work in
> [`completion-plan.md`](completion-plan.md).
>
> This text is a **reconstruction**: its author stated that scope and
> architecture are recovered but wording is not guaranteed to match the
> original. Section numbers differ from the original. `AGENTS.md` and
> `docs/upstream-strategy.md` cite the original's §51 (engineering rules), §52
> (compatibility levels) and §53 (no SDK dependency for v1.0); in this text
> §51–§53 are testing, browser compatibility and security. Those citations
> therefore refer to the original numbering, which is not recoverable here.

## Master Research, Architecture & Engineering Plan

61 sections · Research → Architecture → Implementation → Dart/Flutter SDK integration

## Part I — Mission and foundations

### 1. Project vision

Build Dart Web Isolates (DWI), a high-quality open-source concurrency framework for Dart and Flutter, capable of running computationally intensive Dart workloads in genuinely independent execution contexts across supported platforms.

Its central purpose is to address a longstanding limitation of Dart and Flutter Web: the absence of native `dart:isolate` functionality comparable to Dart VM isolates.

The project should become:

- A production-quality Dart/Flutter concurrency package.
- A unified API across native and web platforms.
- A practical alternative to manually implementing JavaScript Web Workers.
- A foundation for experimental WebAssembly worker support.
- A research vehicle for bringing isolate-style concurrency into Dart and Flutter SDKs.

The ultimate ambition is for Dart and Flutter maintainers to consider adopting DWI's architecture, implementation techniques or APIs upstream.

### 2. Core problem

On native Dart platforms, isolates provide independent execution with message passing.

On the web, ordinary asynchronous Dart code does not automatically move CPU-intensive work off the browser's main thread.

Consequently, expensive synchronous computations can block:

- Flutter rendering.
- Animations.
- Pointer and keyboard interactions.
- Scrolling.
- Other main-thread work.

Browser Web Workers provide separate execution contexts, but their programming and deployment models differ from Dart isolates.

DWI must bridge that gap without falsely claiming that Web Workers are identical to native isolates.

### 3. Fundamental engineering principles

The project must follow these principles:

1. Real parallel execution: A parallel API must not silently execute heavy workloads on the browser main thread.
2. Correctness before convenience: Preserve type safety, error propagation and resource cleanup.
3. Minimal developer boilerplate: Worker generation, compilation and deployment should be automated wherever possible.
4. Platform consistency: Maintain a coherent public API despite differences between browser Workers and Dart isolates.
5. Compiler-aware design: Do not pretend arbitrary closures can be transferred without the necessary compiler support.
6. Evidence-based engineering: Support architectural decisions with source references, tests and benchmarks.
7. Upstream readiness: Prefer maintainable designs that Dart and Flutter engineers could reasonably evaluate.

### 4. Scope

DWI covers:

- Native Dart isolates.
- Browser Web Workers.
- Flutter Web integration.
- JavaScript-compiled Dart worker programs.
- Experimental Dart/Wasm worker programs.
- Task execution and scheduling.
- Worker pools.
- Message passing.
- Serialization and transferable data.
- Cancellation and lifecycle management.
- Code generation and compilation tooling.
- Testing, diagnostics and performance measurement.
- Compiler and SDK integration research.

Out of scope for the initial production release are guaranteed arbitrary closure support, universal shared-memory semantics, and undocumented equivalence with every `dart:isolate` capability.

### 5. Success criteria

DWI succeeds at the package level when a developer can write:

```
@DwiTask()
int calculatePrimes(int limit) {
  // CPU-intensive calculation
}
```

and invoke:

```
final result =
    await DwiTasks.calculatePrimes(5_000_000);
```

with the workload executing in a real worker or isolate, not on the Flutter Web UI thread.

A longer-term success criterion is an API resembling:

```
final result = await Dwi.run(
  calculatePrimes,
  5_000_000,
);
```

The ultimate SDK-level objective is to investigate web support for patterns such as:

```
final result = await Isolate.run(() {
  return expensiveCalculation();
});
```

These represent progressively more ambitious compatibility levels, not promises that all three are currently feasible.

## Part II — Repository and package architecture

### 6. Repository structure

The proposed monorepo is:

```
dart-web-isolates/
├── README.md
├── AGENTS.md
├── CHANGELOG.md
├── LICENSE
├── docs/
│   ├── MASTER_PLAN.md
│   ├── architecture.md
│   ├── api-proposal.md
│   ├── compatibility-matrix.md
│   ├── compiler-strategy.md
│   ├── limitations.md
│   ├── security.md
│   └── upstream-strategy.md
├── research/
├── adr/
├── packages/
│   ├── dwi/
│   ├── dwi_core/
│   ├── dwi_protocol/
│   ├── dwi_native/
│   ├── dwi_web/
│   ├── dwi_annotations/
│   └── dwi_builder/
├── examples/
├── experiments/
├── benchmarks/
├── tools/
└── .github/
```

Additional packages, such as `dwi_flutter`, should be introduced only when a clear architectural boundary justifies them.

### 7. Package responsibilities

| Package                | Responsibility                                                  |
| ---------------------- | --------------------------------------------------------------- |
| `dwi`                  | Main public API and platform-independent facade                 |
| `dwi_core`             | Common interfaces, lifecycle models, configuration and errors   |
| `dwi_protocol`         | Versioned worker communication protocol                         |
| `dwi_native`           | Dart VM isolate backend                                         |
| `dwi_web`              | Browser Web Worker backend                                      |
| `dwi_annotations`      | Task declarations and metadata                                  |
| `dwi_builder`          | Task discovery, generation, compilation and artifact management |
| `dwi_flutter` (future) | Flutter-specific integration and diagnostics                    |

Each package must have clear dependency boundaries and independent tests.

### 8. Platform architecture

Conceptual architecture; the Wasm backend remains a future research and implementation objective.

### 9. Public API design

The API should evolve in stages:

Level A — Named tasks

```
await Dwi.runTask('calculatePrimes', input);
```

Level A1 — Generated typed proxies

```
await DwiTasks.calculatePrimes(input);
```

Level B — Function references

```
await Dwi.run(calculatePrimes, input);
```

Level C — Closures

```
await Dwi.run(() => calculatePrimes(input));
```

Level D — SDK compatibility

```
await Isolate.run(() => calculatePrimes(input));
```

Level A1 is the current reported implementation direction. Levels B–D require separate feasibility research.

### 10. Compatibility contract

Define and document which capabilities are:

- Fully supported.
- Supported with semantic differences.
- Experimental.
- Not supported.
- Dependent on SDK/compiler changes.

The compatibility matrix must cover native Dart, Flutter native, Dart Web JavaScript, Flutter Web JavaScript, and Dart/Wasm.

## Part III — Phase 0: foundational research

### 11. Dart SDK investigation

Study the implementation of:

- `dart:isolate`.
- `Isolate.spawn`.
- `Isolate.run`.
- `SendPort` and `ReceivePort`.
- `TransferableTypedData`.
- Isolate lifecycle and error semantics.
- Platform-specific patches and stubs.

Use pinned Dart SDK revisions and file/line references.

### 12. Dart compiler investigation

Research:

- Dart VM compilation.
- dart2js.
- Dart Development Compiler (DDC).
- dart2wasm.
- Kernel intermediate representation.
- Tree shaking.
- Closure representation.
- Function tear-offs.
- Entry-point generation.
- Dependency discovery.

Determine which features are achievable entirely within a package and which require compiler modifications.

### 13. Flutter investigation

Study:

- Flutter Web build tooling.
- `flutter run`.
- `flutter build web`.
- `compute()`.
- Debug versus release compilation.
- Flutter's renderer and event-loop constraints.
- Hot reload and hot restart.
- Build extensibility and asset deployment.

The goal is to integrate workers without requiring users to maintain parallel build systems.

### 14. Browser Worker investigation

Research:

- Dedicated Web Workers.
- Worker construction and lifecycle.
- `postMessage`.
- Structured cloning.
- Transferable objects.
- Module versus classic Workers.
- Worker error handling.
- Worker script URLs.
- Cross-origin restrictions.
- Content Security Policy.
- Browser support differences.

### 15. WebAssembly investigation

Research:

- Dart/Wasm output.
- Wasm module instantiation inside Workers.
- Browser Wasm capabilities.
- JavaScript interoperation.
- Separate Wasm instances.
- Shared memory.
- WebAssembly threads.
- Cross-origin isolation requirements.

Do not assume WebAssembly threading is equivalent to Dart isolate support.

### 16. Prior-art investigation

Compare existing approaches, including:

- Squadron.
- Spawn.
- Isoworker.
- Flutter web-worker packages.
- Existing Dart isolate abstractions.
- JavaScript worker-pool libraries.

Evaluate APIs, generated code, worker lifecycle, scheduling, portability, maintenance and limitations.

The goal is to reuse good architectural ideas without copying unsupported assumptions.

### 17. Research deliverables

Produce research reports R001–R010 covering the SDK, compilers, Flutter, browser Workers, Wasm, serialization, security, build integration, prior art and upstream feasibility.

Every major claim must distinguish verified evidence from hypotheses and unresolved questions.

## Part IV — Proof of concept

### 18. M001: Dart code executing in a browser Worker

Create the smallest reproducible proof that:

1. A Dart program is compiled for browser execution.
2. The compiled program loads inside a Web Worker.
3. The Worker receives a message.
4. It performs CPU-intensive work.
5. It returns a result.
6. The browser main thread remains responsive.

This is the project's foundational technical milestone.

### 19. Flutter demonstration

Build a Flutter Web application with two execution modes:

- Main-thread computation.
- Web Worker computation.

Both must execute the same algorithm with the same inputs and produce the same result.

### 20. Performance measurement

Measure:

- Execution time.
- Worker startup time.
- Frames rendered during computation.
- Dropped frames.
- Main-thread responsiveness.
- Message transfer overhead.

Repeat measurements and retain raw evidence.

### 21. Proof-of-concept exit gate

M001 passes only when real Worker execution is independently demonstrated, results are correct, and UI responsiveness improves under an appropriate CPU-heavy workload.

Passing M001 does not establish general isolate compatibility.

## Part V — Protocol and runtime

### 22. Versioned worker protocol

Design a structured protocol with message categories such as:

```
READY
REQUEST
RESULT
ERROR
CAPABILITIES
SHUTDOWN
```

Later protocol revisions may add cancellation, progress, streaming, heartbeats and worker diagnostics.

### 23. Task identity and correlation

Every request must have a unique identifier within its relevant session or worker context.

The runtime must correlate replies with pending tasks and handle late, duplicate or unknown responses safely.

### 24. Error propagation

Preserve useful information about remote failures:

- Error type or category.
- Message.
- Remote stack trace where available.
- Task identifier.
- Worker identifier.
- Whether the failure is recoverable.

Never silently swallow worker errors.

### 25. Native backend

Implement the native backend using real Dart isolates.

Provide consistent execution, timeout, error and lifecycle behaviour through the shared DWI abstraction.

### 26. Browser backend

Implement the web backend using real browser Workers.

Responsibilities include Worker construction, initialization, dispatch, result handling, failure handling, cleanup and capability reporting.

### 27. Worker pools

Support reuse of long-lived Workers rather than creating a new Worker for every task.

Investigate:

- Configurable pool size.
- Task queues.
- Scheduling policies.
- Worker replacement.
- Idle termination.
- Queue limits.
- Backpressure.

### 28. Timeouts and cancellation

Distinguish timeout from cancellation.

A timeout indicates a deadline was exceeded; cancellation expresses an intent to stop work.

Cancellation should support queued tasks and cooperative running tasks where possible. Terminating a Worker must be treated as a disruptive fallback when it may also affect other tasks.

### 29. Worker lifecycle

Define states such as:

```
CREATED
STARTING
READY
BUSY
IDLE
STOPPING
STOPPED
FAILED
```

Transitions must be testable and deterministic.

### 30. Port-like messaging

Investigate logical send and receive ports over Worker messaging.

A DWI port abstraction should not claim to be identical to native `SendPort` or `ReceivePort` unless the relevant semantics have been proven.

### 31. Streaming and progress

Support long-running tasks that emit progress or multiple results.

Provide a Dart-friendly `Stream<T>` interface where appropriate, with proper cancellation and cleanup.

## Part VI — Serialization and data movement

### 32. Serialization contract

Define supported payload types and their behaviour across platforms.

Start with primitives, lists, maps and typed binary data, then investigate generated DTO serialization, records, enums and more complex structures.

### 33. Typed serialization

Prefer generated serializers and strongly typed task boundaries.

Avoid depending on arbitrary runtime reflection.

Unsupported types must produce clear errors.

### 34. Transferable data

Research and implement efficient movement of large binary payloads using browser transfer mechanisms where supported.

Clearly document ownership transfer and buffer detachment semantics.

### 35. Large payload performance

Benchmark representative sizes such as 1 KB, 100 KB, 1 MB, 10 MB and 100 MB.

Compare copying and transfer mechanisms, accounting for browser memory limits.

### 36. Protocol evolution

Design version negotiation and compatibility handling so future versions can add functionality without silently misinterpreting messages.

## Part VII — Code generation and compilation

### 37. Task annotations

Provide a public task declaration API:

```
@DwiTask()
Result process(Input input) {
  // ...
}
```

Annotations should describe tasks, not require developers to manually manage Worker infrastructure.

### 38. Static task discovery

Use Dart analyzer/compiler-aware tooling to discover supported task declarations and validate their signatures.

Avoid fragile string matching or runtime reflection.

### 39. Generated task registry

Generate a deterministic mapping between task identifiers and callable functions.

The generated registry must preserve reachable worker functions under tree shaking.

### 40. Generated typed proxies

Generate ergonomic APIs that preserve task input and output types.

For example:

```
final result = await DwiTasks.process(input);
```

Generated APIs must correctly represent synchronous and asynchronous task results.

### 41. Worker entrypoint generation

Automatically generate the Dart Worker entrypoint, including initialization, protocol dispatch, error handling and task registration.

Users should not manually write `worker.dart`.

### 42. Automatic compilation

Investigate how to automatically compile worker entrypoints during the normal Dart/Flutter build process.

The preferred solution is build-time generation and compilation with no manual worker command.

Where SDK integration is unavailable, provide a reliable wrapper and document the limitation.

### 43. Build caching

Cache generated artifacts using a content hash that accounts for relevant source, transitive dependencies, compiler configuration and toolchain versions.

Cache hits must never conceal changed worker behaviour.

### 44. Development workflow

Support watching task sources, regeneration, recompilation and Worker restart during development.

Research integration with Flutter's hot reload and hot restart behaviour.

### 45. Compiler-assisted APIs

Investigate annotation-free function references and closure-based execution.

Do not claim these work merely because a generated proxy can invoke a precompiled named task.

## Part VIII — Wasm and Flutter integration

### 46. Dart/Wasm Worker backend

Create a separate proof of concept for executing Dart/Wasm workloads inside browser Workers.

Start with independent Wasm instances and message passing.

### 47. Wasm architecture decisions

Compare:

- Separate Wasm instances.
- Shared Wasm memory.
- WebAssembly threads.
- Compiler-assisted isolate implementations.

Document browser and deployment requirements.

### 48. Backend selection

Provide explicit capability detection and backend selection.

A requested parallel backend must fail clearly if unavailable, unless the caller explicitly opts into a fallback policy.

### 49. Flutter integration

Investigate a Flutter-specific integration layer exposing ergonomic APIs and diagnostics.

A possible experimental API is:

```
computeParallel(...)
```

It must be clearly distinguished from Flutter's official `compute()`.

### 50. Flutter development experience

Aim for:

```
flutter run -d chrome
flutter build web --release
```

without developers manually creating, compiling, copying or configuring worker artifacts.

This is a major product objective, even if achieving it fully requires Flutter tooling changes.

## Part IX — Quality and production readiness

### 51. Cross-platform testing

Build automated test suites covering:

- Dart VM.
- Flutter native.
- Browser JavaScript.
- Flutter Web.
- Dart/Wasm where supported.

Test success, errors, timeouts, cancellation, concurrency and cleanup.

### 52. Browser compatibility

Verify Chrome, Firefox, Safari and Edge.

Where practical, test mobile browsers and constrained devices.

Do not mark an untested platform as supported.

### 53. Security

Review:

- Worker script loading.
- CSP requirements.
- Cross-origin restrictions.
- Task dispatch validation.
- Malformed messages.
- Resource exhaustion.
- Serialization boundaries.
- Generated code safety.

### 54. Benchmarks

Create reproducible benchmarks for:

- CPU-intensive mathematics.
- Sorting.
- JSON processing.
- Hashing.
- Compression.
- Image processing.
- Binary data transfer.
- Worker startup and dispatch latency.

Compare against appropriate native and browser baselines.

### 55. Diagnostics and observability

Expose optional metrics for Worker count, queue depth, startup time, task duration, transfer size, errors, timeouts and cancellations.

Diagnostics should not impose substantial production overhead when disabled.

### 56. Documentation and examples

Maintain a clear README, API reference, architecture guide, compatibility matrix, limitations guide, troubleshooting instructions, and realistic examples.

Document what DWI cannot do as carefully as what it can.

## Part X — AI engineering organization and upstream strategy

### 57. Multi-agent engineering team

Use a coordinated AI engineering workflow with specialist roles:

1. Dart runtime researcher.
2. Dart compiler researcher.
3. WebAssembly researcher.
4. Browser Worker specialist.
5. Flutter integration specialist.
6. Prior-art researcher.
7. System architect.
8. Implementation engineer.
9. Test engineer.
10. Performance engineer.
11. Security reviewer.
12. Dart/Flutter upstream reviewer.

A coordinator agent manages dependencies, integrates findings, requests architectural decisions and maintains the master plan.

Specialists should be available for direct consultation when their findings require clarification.

### 58. Agent workflow and governance

For architecture-sensitive work, follow:

```
Research
   ↓
Evidence
   ↓
Design proposal / ADR
   ↓
Adversarial review
   ↓
Human approval where necessary
   ↓
Implementation
   ↓
Tests
   ↓
Benchmarks
   ↓
Documentation
   ↓
Merge
```

Use `AGENTS.md` to enforce coding standards, evidence requirements, testing rules and handoff procedures.

### 59. Release roadmap

| Version | Primary milestone                                               |
| ------- | --------------------------------------------------------------- |
| v0.1    | Browser Worker proof of concept                                 |
| v0.2    | Protocol, native/web backends and foundational runtime          |
| v0.3    | Generated registry, typed proxies and automatic Worker pipeline |
| v0.4    | Transferables, cancellation and hardened worker pools           |
| v0.5    | Long-lived workers, ports, streams and diagnostics              |
| v0.6    | Dart/Wasm Worker backend                                        |
| v0.7    | Flutter integration and production examples                     |
| v0.8    | Compiler integration experiments and closure feasibility        |
| v0.9    | Experimental SDK isolate compatibility                          |
| v1.0    | Stable, documented and production-ready supported API           |

Release versions are planning targets, not evidence of implementation completion.

### 60. SDK and Flutter upstream strategy

After the package proves its value, prepare experimental branches and proposals addressing:

- Automatic Worker entrypoint emission.
- Compiler-known function references.
- Closure capture and serialization.
- Port semantics.
- Browser runtime integration.
- Dart/Wasm compilation.
- Debugging and source maps.
- Flutter `compute()` behaviour.
- Build tooling.
- Compatibility with existing Dart programs.

Submit focused proposals supported by working prototypes, benchmarks, limitations and compatibility analysis.

The objective is not necessarily to merge DWI wholesale. It is to make its technical findings useful to Dart and Flutter maintainers.

### 61. Final definition of success

The project is successful when it delivers:

- Genuine parallel execution.
- A consistent, ergonomic Dart API.
- Automatic Worker generation and compilation wherever feasible.
- Strong typing and predictable errors.
- Reliable resource management.
- Tested browser and native support.
- Clear performance evidence.
- Production documentation.
- Honest compatibility boundaries.
- A credible pathway toward Dart and Flutter SDK adoption.

The final project must distinguish implemented, implemented with limitations, experimental, SDK-dependent, and not feasible objectives.

The guiding rule is:

Make it work. Prove it works. Try to break it. Benchmark it. Document it. Then extend it.
