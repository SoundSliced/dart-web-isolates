# ADDENDUM — Zero-Boilerplate Automatic Worker Compilation

> **Provenance (2026-11-11).** The zero-boilerplate addendum as re-issued by the original planning
> assistant on 2026-11-11 and saved here unedited apart from this note. It is a
> planning baseline, not evidence of implementation: status is tracked in
> [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) and remaining work in
> [`completion-plan.md`](completion-plan.md).

Developer experience · Automatic build integration · Compiler research · Runtime-transparent execution

This addendum establishes a major requirement for DWI: developers should not have to understand or manage browser Worker infrastructure to use parallel Dart code.

## 1. Ultimate developer experience

The desired API is:

```
final result = await Dwi.run(
  expensiveCalculation,
  input,
);
```

Or, at the most ambitious level:

```
final result = await Dwi.run(() {
  return expensiveCalculation(input);
});
```

A developer should ideally not have to:

- Create `worker.dart`.
- Write a Worker entrypoint.
- Register functions manually.
- Write JavaScript.
- Compile Worker scripts manually.
- Copy Worker artifacts.
- Configure Worker paths.
- Maintain a manifest.
- Remember additional build commands.

The package should own this infrastructure.

## 2. Automatic Worker pipeline

The intended process is:

Developer Dart source

Task discovery and dependency analysis

Generated worker entrypoint

Automatic JS / Wasm compilation

Flutter Web build artifacts

Runtime worker loader

Parallel task execution

The pipeline should be automatic wherever technically feasible.

## 3. Three levels of automation

DWI must investigate three progressively more ambitious approaches.

### Level A — Build-time automation

The developer writes:

```
@DwiTask()
Result expensiveCalculation(Input input) {
  // ...
}
```

DWI discovers the task, generates the registry, creates the Worker entrypoint, compiles it and packages the artifact.

This is the minimum production-oriented solution.

### Level B — Compile-time function discovery

The developer writes:

```
final result = await Dwi.run(
  expensiveCalculation,
  input,
);
```

The build/compiler tooling identifies the function and includes it in the Worker program without requiring an annotation.

Research must determine whether compiler support is necessary.

### Level C — Closure-based execution

The developer writes:

```
final result = await Dwi.run(() {
  return expensiveCalculation(input);
});
```

Compiler-aware tooling would identify the closure, captured values and reachable dependencies.

This is a research objective, not an assumed package capability.

## 4. True runtime compilation

Investigate whether arbitrary Dart code could be compiled inside the browser after deployment.

Research:

- Browser-hosted Dart compiler feasibility.
- dart2js and dart2wasm architecture.
- Kernel compilation.
- Dynamic module generation.
- Worker construction.
- CSP and `eval` restrictions.
- Application download size.
- Startup latency.
- Browser memory consumption.
- Security implications.
- Tree shaking.

Do not pursue runtime compilation simply because a demonstration can be made to work.

## 5. Runtime compilation decision

Produce:

`research/R013_RUNTIME_WORKER_COMPILATION.md`

Compare:

| Strategy                    | Developer effort    | Production assessment               |
| --------------------------- | ------------------- | ----------------------------------- |
| Manual Worker               | High                | Functional but poor ergonomics      |
| Generated Worker            | Low                 | Practical                           |
| Automatic build integration | Near zero           | Preferred package-level target      |
| Compiler-integrated Worker  | Minimal             | Long-term objective                 |
| True runtime compilation    | Potentially minimal | Experimental; significant drawbacks |

Preferred approach: automatic build-time compilation with runtime-transparent execution.

The reported v0.3 implementation already follows this direction, but full integration into ordinary Flutter commands remains an open objective.

## 6. Automatic Flutter builds

Target:

```
flutter run -d chrome
```

and:

```
flutter build web --release
```

without a separate manual Worker compilation step.

The agent must investigate Flutter tooling capabilities and supported integration points.

If the SDK cannot currently support the required hook, DWI should provide a reliable wrapper while documenting the limitation.

## 7. Generated Worker manifest

DWI may generate a manifest resembling:

```
{
  "protocol": 1,
  "workers": {
    "default": {
      "artifact": "dwi/worker.dart.js",
      "tasks": [
        "calculatePrimes",
        "parseJson"
      ]
    }
  }
}
```

The application developer should not maintain this file.

The manifest must be generated deterministically and kept consistent with compiled artifacts.

## 8. Automatic development workflow

When a developer changes an annotated task, DWI should:

1. Detect the change.
2. Determine whether the Worker dependency graph changed.
3. Regenerate affected code.
4. Recompile affected Worker artifacts.
5. Restart or reload the relevant Worker.
6. Make updated functionality available to the application.

Investigate integration with Flutter hot restart and hot reload.

If seamless reload is impossible, implement a deterministic restart procedure.

## 9. Content-hash caching

A Worker artifact's cache key should account for:

```
Worker source
+ transitive dependencies
+ compiler version
+ DWI version
+ compiler flags
+ relevant build configuration
```

Unchanged artifacts should be reused.

Changed dependencies must invalidate the cache.

A stale Worker executing old application logic is a correctness failure.

## 10. Lazy Worker startup

Compilation occurs before deployment, but Worker instances need not start until required.

Conceptually:

```
final result =
    await DwiTasks.calculatePrimes(5_000_000);
```

At runtime, DWI checks whether an appropriate Worker is available, starts one if necessary, dispatches the task and returns the result.

The pool may retain the Worker for subsequent requests.

## 11. Worker bundling strategies

Evaluate three approaches.

### Universal Worker

One compiled Worker contains multiple tasks.

Advantages include simpler deployment and shared pooling.

Potential disadvantages include larger bundles and unnecessary code loading.

### Per-task Workers

Each task has a separate Worker artifact.

Advantages include more granular loading and isolation.

Disadvantages include increased compilation, artifact management and startup overhead.

### Chunked Workers

Tasks are grouped by functionality or dependencies.

For example:

```
DWI runtime
├── compute worker
├── media worker
└── data-processing worker
```

The architecture should be selected using measurements rather than assumptions.

## 12. Dependency discovery

Given:

```
@DwiTask()
Result analyse(Input input) {
  return helperA(helperB(input));
}
```

DWI must include the required functions, imports and transitive dependencies.

Developers should not manually maintain dependency lists.

The generated Worker must use the same relevant application logic as the source task.

## 13. Build-time diagnostics

Invalid tasks should produce useful errors.

For example:

```
DWI001:
Task `processDocument` uses an unsupported
browser-specific object.

lib/tasks.dart:83

Unsupported type:
HTMLElement

Pass transferable data instead.
```

Prefer early diagnostics over obscure runtime failures.

Diagnostics should identify the source location, reason and corrective action.

## 14. Zero-boilerplate success criterion

A complete application-level usage pattern should eventually be as simple as:

```
Future<void> process() async {
  final result = await Dwi.run(
    expensiveCalculation,
    input,
  );

  print(result);
}
```

DWI owns:

- Task discovery.
- Worker generation.
- Worker compilation.
- Worker packaging.
- Worker loading.
- Worker startup.
- Protocol communication.
- Serialization.
- Dispatch.
- Error propagation.
- Reuse.
- Shutdown.

The public API should not expose this complexity unnecessarily.

## 15. Ultimate Dart SDK goal

Investigate compiler-assisted support for:

```
await Isolate.run(() {
  return expensiveCalculation();
});
```

On native Dart, this would use the existing isolate implementation.

On web, an experimental compiler/runtime integration could identify the isolate boundary and produce a Worker-compatible executable.

The feasibility of closure capture, communication and semantic compatibility must be established before making upstream claims.

## 16. Revised priority roadmap

The addendum changes the order of implementation priorities:

| Stage                  | Objective                                      |
| ---------------------- | ---------------------------------------------- |
| Audit                  | Verify current code and repair defects         |
| v0.3                   | Generated registry and typed proxies           |
| v0.3.x                 | Automatic Worker generation and compilation    |
| Zero-manual-build gate | Reduce or eliminate separate build steps       |
| v0.4                   | Transferables, cancellation and pool hardening |
| v0.5                   | Long-lived Workers, ports and streams          |
| v0.6                   | Wasm Worker backend                            |
| v0.7                   | Flutter integration                            |
| v0.8                   | Compiler integration research                  |
| v0.9                   | Experimental `dart:isolate` compatibility      |
| v1.0                   | Stable production API                          |

The zero-manual-build objective may require tooling work that continues beyond v0.3.x. The roadmap must distinguish a working wrapper from genuine integration into standard Flutter commands.

## 17. Mandatory product principle

Complex internally, simple externally.

DWI may contain compilers, generated code, registries, protocols, serializers, worker pools and artifact managers.

The developer should ideally see only ordinary Dart functions and a simple, strongly typed API.

This is one of DWI's most important potential differentiators.

## Instructions for the next AI agent

The three documents above should be treated together as the project's planning baseline.

However, the receiving agent must first inspect the current repository because the implementation has advanced beyond the original v0.2 handoff. The reported v0.3 pipeline already includes annotations, generated proxies, compilation and caching.

The next agent should therefore:

1. Reconcile the master plan with actual repository files and commits.
2. Mark every objective as complete, partial, unimplemented, experimental or blocked.
3. Verify the reported v0.3 functionality and correct defects.
4. Continue improving automatic Flutter build integration.
5. Implement v0.4 and later milestones in dependency order.
6. Maintain an updated master plan and implementation status document.
7. Preserve the long-term goal of making DWI useful enough for serious Dart/Flutter upstream consideration.

Recommended canonical location in the repository:

```
dart-web-isolates/
├── AGENTS.md
└── docs/
    ├── MASTER_PLAN.md
    ├── ENGINEERING_HANDOFF.md
    ├── ZERO_BOILERPLATE_ADDENDUM.md
    └── IMPLEMENTATION_STATUS.md
```

These are recommended filenames, not verified existing files. The first three should contain the documents above, while `IMPLEMENTATION_STATUS.md` should be maintained from actual code and test evidence.

The next agent's first responsibility is to distinguish what was planned, what was reported, and what is independently verified.
