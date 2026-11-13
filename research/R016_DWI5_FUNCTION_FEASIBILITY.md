# R016 — DWI-5: compiler-supported function feasibility

Status: research report, updated 2026-11-11. **ADR-020 implements only registered
static-function selection; arbitrary closures remain research.**
Environment: Dart 3.13.7 (stable) from the unmodified Flutter 3.47.9 checkout
(`c197ca5199e`), analyzer 14.7.0, Chrome 157.0.8103.50, macOS 26.5.1 arm64.
Evidence:
[`dwi5-analyzer`](../audit/evidence/dwi5-analyzer-2026-11-10.txt),
[`dwi5-compiler-contracts`](../audit/evidence/dwi5-compiler-contracts-2026-11-10.txt),
[`dwi5-transport-and-tree-shaking`](../audit/evidence/dwi5-transport-and-tree-shaking-2026-11-10.txt).
Proposal: [`ADR-019`](../docs/adr-019-dwi5-function-execution.md) (Proposed, not
accepted). Follow-up static-identity evidence:
[`dwi5-static-identity`](../audit/evidence/dwi5-static-identity-2026-11-10.txt).
Re-run matrix and compatibility assessment:
[`dwi5-matrix-rerun`](../audit/evidence/dwi5-matrix-rerun-2026-11-10.txt).
End-to-end registered-static prototype:
[`dwi5-static-registry`](../audit/evidence/dwi5-static-registry-2026-11-11.txt).
Production acceptance:
[`dwi5-static-acceptance`](../audit/evidence/dwi5-static-acceptance-2026-11-13T012032.json).

## Plain answer

**Registered static tasks: yes, through generated `DwiFunctions`. Arbitrary
functions or closures: no.** The checkout implements ADR-020; this is not in
published 0.8.1 and does not raise DWI-5 or DWI-6.

- The public API has no function overload; `Dwi.run` takes a task name (or
  `runFresh` a task name). `Dwi.run(addOne, 1)` does not compile.
- A function value cannot be sent to a worker. Chrome 157 throws
  `DataCloneError` for a function, a tear-off-like function, a function inside
  an object, and `Worker.postMessage({fn: ...})`. Only the object without the
  function clones.
- No supported compiler/build phase can turn the call site into a second
  entrypoint. `dart compile` takes one `<dart entry point>`; `dart build` exposes
  only `cli`; the `macros` experiment is off by default.
- The existing named-task path (annotation → generated static registry → second
  compilation → worker) works on native, dart2js + JS worker, and dart2wasm +
  Wasm worker. It is the control, not the function API.
- `DwiFunctions.run(task, input)` and `run0(task)` select existing generated
  typed proxies by registered tear-off equality. No function is transported,
  no body is lifted, and no function-call rewrite is required for this subset.
  Public class static methods are discovered directly.

The corrected prototype exposed Wasm-host result decoding failures when using
raw `Dwi.run<int>`. The production adapter reuses typed proxies and their
existing number/collection decoders instead of weakening validation.

## 1. What "support" would have to mean

For every form, "support" would require all of the following, not just a
compiling call site:

| Requirement | Concrete obligation |
| --- | --- |
| Worker code | a second entrypoint, compiled ahead of time, holding a **static** Dart reference to the body (a name alone is tree-shaken) |
| Target identity | the target function or body is identified at build time; a runtime function object has no portable identity |
| Captured inputs | captured values are encoded with the DWI codecs; non-serializable captures are rejected before compilation, not guessed at runtime |
| Return and errors | the declared return type is decoded; worker exceptions arrive as `DwiRemoteException` with the worker stack |
| Async | the call is a `Future`, with the same timeout rules as named tasks |
| Cancellation | `terminate()` semantics; no cooperative cancellation of an in-flight expression |
| Native/web consistency | the accepted form runs on both, or the difference is documented per host |
| First build | generated sources exist before the first ordinary Flutter compile, or the documented pre-build step is required |
| Diagnostics | rejected forms produce a typed, deterministic error naming the reason |

A static tear-off rewritten to an annotated named task is useful, but it is not
proof of arbitrary closure support. The six forms are separated below for that
reason.

## 2. The six forms

| # | Form | Example | What a package can see today | What is missing |
| --- | --- | --- | --- | --- |
| 1 | Static top-level reference | `Dwi.run(addOne, 1)` | analyzer resolves `TopLevelFunctionElement addOne`; no captures | a supported call-site rewrite and a worker entrypoint for that target |
| 2 | Static method reference | `Dwi.run(MathOps.twice, 2)` | analyzer resolves `MethodElement twice (static: true)` | the same rewrite; the worker must import the declaring library |
| 3 | Closure with serializable captures | `Dwi.run((x) => x + offset, 3)` | analyzer exposes the closure body and `offset: int`; rejects an object capture by type | lifting the body into a worker-safe library without changing lexical semantics |
| 4 | Closure with non-serializable captures | `Dwi.run((x) => x + connection.hashCode, 4)` | analyzer reports `connection: Connection (UNSUPPORTED)` | nothing to add except a deterministic rejection if an API ever exists |
| 5 | Dynamically chosen function | `final f = flag ? addOne : twice; Dwi.run(f, 5)` | analyzer sees a local `int Function(int)`, not one target; candidate functions appear only in the initializer | whole-program data-flow or runtime function metadata; neither is supported |
| 6 | Arbitrary expression body | `Dwi.run(() { ... }, 6)` | analyzer sees a block body and its captures | the same lifting problem as 3 plus statement semantics (`return`, `break`, local mutation, exception stacks) |

The instance tear-off control (`Dwi.run(ops.triple, 7)`) resolves the method but
not a static target: the receiver is a runtime object. An API would have to
reject it or capture the receiver and its whole object graph.

## 3. Decision table — six forms across the tested hosts

Re-run 2026-11-11 through the production generated adapter. All four web
host/worker pairs below pass in Chrome 157, Safari 26.5, Firefox 159 and Edge 157.
Native acceptance is `packages/dwi_builder/test/native_static_registry_test.dart`.
The original prototype did not test a Wasm host or real class static method;
its differently prefixed tokens and delayed timer did not establish isolation
or CPU responsiveness. Historical evidence is retained with corrections.

Status vocabulary: **pass**, **rejected by design**, **blocked by tooling**,
**unverified**.

| Form | Native VM | JS/JS | JS/Wasm | Wasm/JS | Wasm/Wasm |
| --- | --- | --- | --- | --- | --- |
| 1 registered top-level | pass | pass | pass | pass | pass |
| 2 registered public class static method | pass | pass | pass | pass | pass |
| 3 closure, serializable capture | rejected by subset API | blocked by tooling; rejected by subset API | same | same | same |
| 4 closure, non-serializable capture | rejected by design | rejected by design | rejected by design | rejected by design | rejected by design |
| 5 dynamically chosen function | pass, registered subset only | pass, registered subset only | same | same | same |
| 6 arbitrary expression body | rejected by subset API | blocked by tooling; rejected by subset API | same | same | same |
| Named-task typed-proxy control | pass, existing regression | pass | pass | pass | pass |

Notes on the cells:

- **Native VM.** Generated proxies register implementations in the existing
  isolate backend. The test verifies typed results and independent state,
  rejects unknown functions before registration, and covers close/reuse.
- **Web.** Tests observe `DedicatedWorkerGlobalScope` in the worker and `Window`
  on the host. Worker-local state starts at 0 while host state remains 1000.
  Typed results, remote errors, timeout and missing-worker startup errors pass.
  This does not claim CPU responsiveness or quantify performance.
- **Rejected forms.** Lookup produces `DwiUnknownTaskException`, including for
  closures with serializable captures. It does not inspect captures or claim
  capture-specific diagnostics. General closure lowering is unimplemented.

A second, simpler table describes the current public API:

| Form | Current public API |
| --- | --- |
| 1, 2, registered subset of 5 | generated `DwiFunctions.run` / `run0` |
| 3, 4, 6, unregistered subset of 5 | typed rejection; no local execution |
| `Dwi.run(fn)` / `Dwi.runFresh(fn)` | does not compile; these remain name-based |

## 4. Measured evidence

### 4.1 Analyzer discovery

`tooling/dwi5_probe/run.sh` analyzes six call sites with analyzer 14.7.0 and
prints classification, resolved element, static-target flag and captures.

| Call | Classification | Resolved target | Captures |
| --- | --- | --- | --- |
| `addOne` | static-top-level-function | `TopLevelFunctionElement addOne` | none |
| `MathOps.twice` | static-method | `MethodElement twice (static: true)` | none |
| `(x) => x + offset` | inline-closure | inline expression body | `offset: int (serializable)` |
| `(x) => x + connection.hashCode` | inline-closure | inline expression body | `connection: Connection (UNSUPPORTED)` |
| `chosen` | dynamic-function-value | `LocalVariableElement chosen` | none; target not statically identifiable |
| `() { ... }` | inline-block-body | inline block body | `offset: int (serializable)` |
| `ops.triple` | instance-method-tearoff | `MethodElement triple (static: false)` | receiver `ops: MathOps` |

Discovery is **not** the blocker for the statically written forms. Resolution is
only the first requirement in §1; it does not lift a body, generate code, or
execute anything.

The probe's capture/type classification is a research heuristic, not a sound
production codec validator: it accepts records and non-String map keys that
DWI's production codecs reject, compares some types by name, and does not
establish aliasing, mutation or nested-scope semantics. Those limitations are
part of the stop/go analysis in `docs/upstream/dwi-function-lowering.md`.

### 4.2 Compiler and build contracts

- `dart compile --help`: `js`, `jit-snapshot`, `kernel`, `exe`, `aot-snapshot`,
  `wasm`. `dart compile js` usage is `dart compile js [arguments] <dart entry
  point>` with one `-o` output. Source: `pkg/dartdev/lib/src/commands/
  compile.dart:109` (`CompileJSCommand`), `:309` (`args.rest[0]`), `:315`
  (output file).
- `dart build --help`: only `cli`. `pkg/dartdev/lib/src/commands/build.dart:35`
  adds only `BuildCliSubcommand`. There is no web build phase and no
  source-transformation phase.
- `macros` exists as a front-end experiment but is off:
  `pkg/front_end/lib/src/api_prototype/experimental_flags_generated.dart:230-235`
  (`isEnabledByDefault: false`). No `package:macros` implementation or analyzer
  macro API ships in this SDK.
- Reachability is whole-program:
  `pkg/compiler/lib/src/universe/world_impact.dart:22` (`class WorldImpact`).
  A string name does not keep a function alive.
- The Flutter web compiler still does not depend on the web hooks target:
  `flutter_tools/lib/src/build_system/targets/web.dart:143` lists only
  `WebEntrypointTarget` and `GenerateLocalizationsTarget`; `:604` places
  `LinkHooks(platform: HookPlatform.web, ...)` in the release bundle, after
  compilation. The fresh-build gate was re-run on released 3.47.9 on
  2026-11-10: the first ordinary `flutter build web --release` exits 1 on the
  missing `lib/dwi_tasks.g.dart`; the second succeeds. Patched 3.47.9 passes the
  first command.

Consequence: a function API cannot rely on generated sources existing before
compilation on a released SDK, and it has no compiler interface through which
to ask for a second entrypoint.

### 4.3 Function transport

Chrome 157 headless, local page:

```text
structuredClone(function)          DataCloneError: ... () => 1 could not be cloned.
structuredClone(tearoff-like)      DataCloneError: ... function log() { [native code] } could not be cloned.
structuredClone({f:function})      DataCloneError: ... () => 1 could not be cloned.
structuredClone({x:1})             ok
Worker.postMessage({fn:function})  DataCloneError: ... () => 1 could not be cloned.
```

The browser messaging primitive rejects the function before any DWI code runs.
Only Chrome was measured this round; Safari, Firefox and Edge were not run.

### 4.4 What dart2js emits

`dart compile js -O0` of a captured closure and a tear-off (321,005 bytes):

```text
:2815  this.captured = t0;
:3209  t1 = this.captured;
:2812  A.print([A.closure__addOne$closure(), new A.main_closure(7)].length);
:2814  main_closure: function main_closure(t0) {
:716   closureFromTearOff(parameters) {
:3231  _inheritMany(A.Closure, [A.TearOffClosure, A.main_closure]);
```

A closure is a JS object with fields; a tear-off is a cached closure object tied
to the current program instance. There is no serialisable name-plus-environment
format.

### 4.5 Tree shaking

`dart compile js -O1`, with the distinctive constant `987654321` in the task
body:

```text
name-only registry:     99,701 bytes, grep 987654321 -> 0 hits
static-reference map:  107,385 bytes, grep 987654321 -> 1 hit
```

The string `dropped` remains as data; its function body does not. A generated
worker must hold a static Dart reference (the existing behavior at
`packages/dwi_builder/lib/src/generator.dart:53`, `:73`).

### 4.6 Worker dependency closure

`dwi_builder` walks imports and exports and fails with `DWI002` when a task
library reaches Flutter, `dart:ui`, `dart:io`, `dart:html` or `dart:isolate`
(`packages/dwi_builder/lib/src/discovery.dart:899`, `:924`). A lifted closure
would get that guarantee only after the generator knows which libraries the body
references; a closure can capture a Flutter or DOM object, and no supported
transform re-homes the body into a worker-safe library.

## 5. Case-by-case decision

1. **Static top-level reference.** The analyzer names the target and there are no
   captures, so the required worker code is exactly the existing generated
   registry. An **automatic** `Dwi.run(addOne, 1)` call-site rewrite still lacks
   a supported source-transform step. The narrower generated `DwiFunctions`
   adapter is implemented under ADR-020 without that rewrite and passes
   native and every measured web compiler pair.
2. **Static method reference.** Same as 1, plus the worker must import the
   declaring library. Static methods have no receiver; instance methods capture
   one and are rejected. Public non-generic class static methods are discovered
   and tested directly under ADR-020; no top-level wrapper is needed.
3. **Closure with serializable captures.** The analyzer can list captures and
   reject unsupported types. Lifting the body is a source transformation with
   semantic obligations (lexical scope, `this`, type parameters, nested
   closures, local mutation). No supported transform exists and none was
   prototyped. **Blocked by tooling.**
4. **Closure with non-serializable captures.** Must be rejected deterministically
   with a diagnostic; never serialized by guessing. The analyzer can see the
   offending capture. **Rejected by design.**
5. **Dynamically chosen function.** The analyzer sees a function-typed local, not
   one target. Candidates in the initializer are not proof of the value at
   runtime. A follow-up probe shows that a generated caller registry can map a
   runtime choice **among registered static tear-offs** to task IDs by function
   identity on the VM, dart2js and dart2wasm (Chrome). This needs neither
   whole-program data flow nor function transport. The production adapter
   exercises both registered choices and repeated tear-off evaluation on native
   and all measured web compiler pairs. Unregistered or freshly created
   function values still have no task ID and are rejected before startup.
6. **Arbitrary expression body.** Same lifting problem as 3, plus statement
   semantics. **Blocked by tooling.**

## 6. Decision

**Outcome 2 — compiler or SDK cooperation is required.**

ADR-020 narrows this decision: forms 1, 2 and the registered-static subset of
form 5 are implemented through generated typed adapters. This does not
establish automatic first-build generation, arbitrary-function execution or
closure lifting. Forms 3 and 6 still require a demonstrated semantic-preserving
transform and pre-compilation build contract; form 4 remains rejected.

- The only added generated API is registered-static selection. No closure API
  or changes to name-based `Dwi.run`/`Dwi.runFresh` are made.
- The missing contract is a **supported pre-compilation source-generation phase
  with resolved-AST access** that can identify a call site, rewrite it to a
  named task, and emit the worker entrypoint before the application compiles.
  `hook/generate.dart` (dart-lang/sdk#56512) is the closest upstream discussion;
  the `macros` experiment is the other candidate, and it is disabled by default.
- A runtime-only workaround is not acceptable: functions are not cloneable, and
  `Function.toString()` + `eval` is emitted JS, not Dart, and violates CSP and
  the project's security constraints.
- Existing named APIs stay unchanged. DWI-5 remains research; the compatibility
  level is not raised.

### What is explicitly not promised

- `Dwi.run(fn)` / `Dwi.run(() { ... })` in any release.
- Function-value transport, or a main-thread fallback when transport fails.
- That arbitrary closures can use the registered-static path, or that its
  explicit pre-build fixes released-SDK ordering.
- That analyzer discovery implies execution.

### What would change this decision

1. A supported source-generation phase (macro or `hook/generate.dart`) that runs
   before analysis/compilation with resolved AST and deterministic output.
2. A compiler interface that accepts additional entrypoints or a function-body
   unit.
3. An official, structured-cloneable function representation (not present, and
   not expected).

## 7. Costs and constraints for any future API

- A worker remains a second compilation with its own runtime copy (R007); the
  measured worker outputs are ~100 KB or more before task code.
- The released-SDK first-build gap remains: generated sources need the
  documented one-time `dart run dwi_builder:dwi build`, or a patched SDK
  (undecided upstream).
- Every accepted form needs a build-time diagnostic for rejected captures and
  dynamic targets; silent main-thread execution is forbidden.

## 8. Verification commands

```bash
# analyzer discovery (six forms + controls)
tooling/dwi5_probe/run.sh

# registered static identity (VM, dart2js, dart2wasm in Chrome)
tooling/dwi5_probe/run_static_identity.sh
tooling/dwi5_probe/run_static_identity_wasm.sh

# production static adapters (VM and four host/worker pairs, four engines)
cd packages/dwi_builder
PUB_CACHE=../../.research/pub-cache \
  $HOME/Development/flutter/bin/dart test \
    test/native_static_registry_test.dart \
    test/browser_static_registry_test.dart -r expanded

# compiler/build surface
$HOME/Development/flutter/bin/dart compile --help
$HOME/Development/flutter/bin/dart compile js --help
$HOME/Development/flutter/bin/dart build --help

# released-SDK fresh-build gate (unmodified 3.47.9)
FLUTTER=$HOME/Development/flutter/bin/flutter \
  PUB_CACHE=.research/pub-cache \
  WORK_DIR=.scratch/proxy-gate-check \
  tooling/proxy_gate/run.sh
```

## 9. What was verified, what was not, what could not be determined

**Verified**

- The analyzer resolves cases 1, 2, the capture lists of 3/4/6, and the absence
  of a single target in case 5, on Dart 3.13.7 / analyzer 14.7.0.
- Chrome 157 rejects function values through `structuredClone` and
  `Worker.postMessage`.
- dart2js emits a closure as an object with fields and a tear-off as a cached
  closure object.
- A name-only function is tree-shaken at `-O1`; a static reference survives.
- Registered top-level and static-method tear-offs map to task IDs by Dart map
  key on the VM, dart2js (`-O1`) and dart2wasm (Chrome 157). The runtime choice
  among those registered functions is therefore identifiable without sending a
  function to a worker.
- Production generated adapters execute top-level/static methods and both
  runtime-selected registered candidates on native and all four JS/Wasm
  host-worker pairs in Chrome, Safari, Firefox and Edge. Actual execution realm,
  independent state, typed numbers/collections, rejection, remote errors,
  timeouts and startup failures are tested. No CPU-responsiveness claim is made.
- `dart compile` has one entrypoint and one output; `dart build` has only `cli`;
  `macros` is off by default.
- Released 3.47.9 does not order web hooks before the compiler; the named-task
  control passes on the measured hosts (existing evidence).

**Not verified**

- Arbitrary-function/closure execution through any DWI API; only the
  registered-static subset is implemented.
- Safari, Firefox and Edge for the transport probe, and the dart2wasm identity
  probe outside Chrome.
- dart2wasm closure representation, and dart2wasm worker execution of closures
  or any non-registered function form.
- Deferred-loading or minification effects beyond the `-O1` tree-shaking probe.
- Semantic equivalence of any lifted closure (return/break/this/mutation/
  exceptions/type parameters).

**Could not be determined**

- Whether a future `hook/generate.dart` will expose resolved-AST call-site
  rewriting, or only file generation.
- Whether a macro implementation will ship enabled by default and with the
  analyzer API a generator would need.
- Whether upstream would accept a compiler entrypoint contract for worker
  generation.
