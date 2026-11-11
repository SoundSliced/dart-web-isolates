# ADR-019 — DWI-5 function execution requires a compiler/build contract (PROPOSED)

Status: **Proposed, not accepted.** This is a proposal for review; it does not
change the public API. Evidence: `research/R016_DWI5_FUNCTION_FEASIBILITY.md`.

## Context

DWI-5 asks whether a consumer can pass a normal Dart function or closure to DWI
and have it execute in a web worker, instead of selecting a precompiled named
task. Native isolates can copy some closures within a group; browser workers
cannot receive a function through structured cloning. DWI currently compiles a
worker with a static task registry and exposes named tasks plus generated typed
proxies.

The feasibility work measured, on Dart 3.13.7 / Flutter 3.47.9 and Chrome 157:

- The analyzer resolves static top-level and static-method references, exposes
  inline closure bodies and their captures, and cannot resolve a dynamically
  chosen function to one target.
- Chrome rejects a function value in `structuredClone` and
  `Worker.postMessage` with `DataCloneError`.
- dart2js emits a closure as an object with fields and a tear-off as a cached
  closure object; neither has a portable identity.
- A function referenced only by a name is tree-shaken; a static reference
  survives.
- `dart compile` has one entrypoint and one output. `dart build` has only `cli`.
  The `macros` experiment is disabled by default. There is no supported phase
  that rewrites a call site into a worker entrypoint.
- On released Flutter 3.47.9 a fresh typed-proxy app still fails its first
  ordinary `flutter build web` because web hooks are not ordered before the
  compiler.

## Decision

1. **Do not add a public function or closure API.** Keep the named-task API,
   `@DwiTask` discovery, generated proxies and generated worker as the supported
   surface. DWI-5 stays research; the compatibility level is not raised.
2. **Require a compiler/build contract before any such API.** The minimum
   missing contract is a supported pre-compilation source-generation phase with
   resolved-AST access that can (a) identify a call site's target and captures,
   (b) rewrite the call site to a named task invocation, and (c) emit the worker
   entrypoint before the application compiles. `hook/generate.dart`
   (dart-lang/sdk#56512) is the closest upstream discussion; `macros` is the
   other candidate and is not usable from a package today.
3. **Reject non-serializable captures and unresolved dynamic targets
   deterministically** if such an API is ever added. Never serialize an
   arbitrary object graph by guessing, never run the function on the main
   thread, and never use `Function.toString()` plus `eval`.
4. **Keep the documented pre-build step** until a released SDK supplies the
   generated-source ordering contract. A function API does not remove the need
   for a second compilation or for generated sources.

## Consequences

- The public API is unchanged. `Dwi.run` and `Dwi.runFresh` keep taking a task
  name; `DwiTasks` proxies remain the typed call shape.
- README, limitations §1/§8, the compatibility matrix (DWI-5) and the API
  proposal continue to state that function values and closures are unsupported.
  R016 is the measured reference behind that statement.
- Any future API must be prototyped against all six forms in R016 §2, not only
  the static cases, and must produce a matrix across native VM, dart2js + JS
  worker and dart2wasm + Wasm worker.
- A restricted static-tear-off API is not adopted here. A `build_runner`
  source-rewriting builder is technically conceivable for cases 1–2, but it
  adds a manual build phase, duplicates DWI's generation, does not cover
  closures, and is not demonstrated. It would need its own ADR and evidence.

## Follow-up: registered static function identity

A later probe (`audit/evidence/dwi5-static-identity-2026-11-10.txt`) maps
registered top-level and static-method tear-offs to task IDs by Dart map key.
The same runtime choice among those registered functions works on the VM,
dart2js and a dart2wasm host in Chrome 157. Thus an explicit generated caller
registry may cover forms 1, 2 and part of form 5 without transmitting a function
or rewriting each call site. This is not an end-to-end DWI worker test, cannot
identify an arbitrary unregistered function, and does not cover dart2wasm
worker execution. It does not alter this ADR's decision for the full six-form
API. If pursued, it needs a separate ADR, worker test and precise registration
contract.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| Send the function value at runtime | structured clone rejects functions; no portable identity |
| `Function.toString()` + `eval` / `new Function` | emitted JS is not Dart; CSP and security; violates AGENTS.md rule 17 |
| Blob worker with inlined source | CSP, no closures, still cannot carry captures |
| Run the function on the main thread as a fallback | forbidden by the project's no-fallback rule; hides the concurrency difference |
| `build_runner`-only static rewrite | manual build step, static forms only, not demonstrated; not a DWI-5 answer |
| Wait for macros | disabled by default, no shipped package/analyzer macro API |

## What would change this decision

1. A supported source-generation phase (macro or `hook/generate.dart`) that runs
   before analysis/compilation with resolved AST and deterministic output.
2. A compiler interface that accepts additional entrypoints, or a compilable
   function-body unit.
3. An official structured-cloneable function representation.

Until one exists, the project keeps named tasks and says so plainly.

## Evidence

- `audit/evidence/dwi5-analyzer-2026-11-10.txt`
- `audit/evidence/dwi5-compiler-contracts-2026-11-10.txt`
- `audit/evidence/dwi5-transport-and-tree-shaking-2026-11-10.txt`
- `tooling/dwi5_probe/`
- `docs/limitations.md` §1, §8; `docs/compatibility-matrix.md` DWI-5
- `docs/architecture.md` ADR-002, ADR-008, ADR-009
- `audit/evidence/flutter-web-hook-ordering-3.47.9-2026-11-10.txt`
