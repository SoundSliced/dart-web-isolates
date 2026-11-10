# R016 — DWI-5: compiler-supported function feasibility

Status: research report · 2026-11-10 · Decision: **compiler or SDK cooperation
is required; no public function/closure API is added.**
Environment: Dart 3.13.7 (stable) from the unmodified Flutter 3.47.9 checkout
(`c197ca5199e`), analyzer 14.7.0, Chrome 157.0.8103.50, macOS 26.5.1 arm64.
Evidence:
[`dwi5-analyzer`](../audit/evidence/dwi5-analyzer-2026-11-10.txt),
[`dwi5-compiler-contracts`](../audit/evidence/dwi5-compiler-contracts-2026-11-10.txt),
[`dwi5-transport-and-tree-shaking`](../audit/evidence/dwi5-transport-and-tree-shaking-2026-11-10.txt).
Proposal: [`ADR-019`](../docs/adr-019-dwi5-function-execution.md) (Proposed, not
accepted).

## Plain answer

**No.** A consumer cannot pass a normal Dart function or closure to DWI today
and have it execute in a web worker.

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

This is the same conclusion ADR-002 and limitations §1/§8 already state; DWI-5
now has measured evidence for it rather than only a design argument.

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

Status vocabulary: **pass**, **rejected by design**, **blocked by tooling**,
**unverified**.

| Form | Native VM | dart2js host + JS worker | dart2wasm host + Wasm worker |
| --- | --- | --- | --- |
| 1 static top-level | unverified (no function API; named-task rewrite is the control) | blocked by tooling | blocked by tooling |
| 2 static method | unverified | blocked by tooling | blocked by tooling |
| 3 closure, serializable capture | unverified | blocked by tooling | blocked by tooling |
| 4 closure, non-serializable capture | rejected by design | rejected by design | rejected by design |
| 5 dynamically chosen function | unverified | blocked by tooling | blocked by tooling |
| 6 arbitrary expression body | unverified | blocked by tooling | blocked by tooling |
| Control: named task (`@DwiTask` + proxy) | pass | pass | pass |

Notes on the cells:

- **Native VM.** DWI does not expose a function API. A same-group VM isolate can
  copy a closure and its context (R001 §1), so a native-only function API is
  conceivable, but it is not implemented or tested and would not answer the web
  question. It is marked unverified rather than pass.
- **Web.** Case 4 is rejected by design: the capture cannot cross the boundary
  and a generator can see that from the type. Cases 1–3, 5 and 6 are blocked by
  tooling: there is no supported call-site transform, no extra-entrypoint
  compiler interface, and no function-value transport. See §4.
- **Control.** The named-task path is measured on all three hosts in the DWI
  browser/worker evidence (`docs/browser-matrix.md`,
  `audit/evidence/flutter-wasm-worker-matrix-2026-11-10.txt`). It is the only
  path that passes end to end today.

A second, simpler table describes the current public API:

| Form | Current public API |
| --- | --- |
| all six | does not compile: `Dwi.run`/`Dwi.runFresh` take a task name, not a function |

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
   registry. The blocker is the call-site rewrite: a package cannot rewrite
   `Dwi.run(addOne, 1)` without a source-transform step. A `build_runner`
   builder could do it, but that adds a manual build phase, duplicates DWI's
   generation, and is not implemented or tested; it is not claimed as a
   package-only win. **Blocked by tooling.**
2. **Static method reference.** Same as 1, plus the worker must import the
   declaring library. Static methods have no receiver; instance methods capture
   one and are rejected. **Blocked by tooling.**
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
   runtime. Supporting it needs whole-program data-flow or runtime metadata.
   **Blocked by tooling.**
6. **Arbitrary expression body.** Same lifting problem as 3, plus statement
   semantics. **Blocked by tooling.**

## 6. Decision

**Outcome 2 — compiler or SDK cooperation is required.**

- No public function or closure API is added. The named-task API and generated
  proxies remain the only supported shape.
- The missing contract is a **supported pre-compilation source-generation phase
  with resolved-AST access** that can identify a call site, rewrite it to a
  named task, and emit the worker entrypoint before the application compiles.
  `hook/generate.dart` (dart-lang/sdk#56512) is the closest upstream discussion;
  the `macros` experiment is the other candidate, and it is disabled by default.
- A runtime-only workaround is not acceptable: functions are not cloneable, and
  `Function.toString()` + `eval` is emitted JS, not Dart, and violates CSP and
  the project's security constraints.
- The public API stays unchanged. DWI-5 remains research; the compatibility
  level is not raised.

### What is explicitly not promised

- `Dwi.run(fn)` / `Dwi.run(() { ... })` in any release.
- Function-value transport, or a main-thread fallback when transport fails.
- That a static tear-off API is "just a small change"; it still needs a
  source-transform build phase.
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

# compiler/build surface
.research/flutter-sdk/bin/dart compile --help
.research/flutter-sdk/bin/dart compile js --help
.research/flutter-sdk/bin/dart build --help

# released-SDK fresh-build gate (unmodified 3.47.9)
FLUTTER=.research/flutter-sdk/bin/flutter \
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
- `dart compile` has one entrypoint and one output; `dart build` has only `cli`;
  `macros` is off by default.
- Released 3.47.9 does not order web hooks before the compiler; the named-task
  control passes on the measured hosts (existing evidence).

**Not verified**

- Any execution of forms 1–6 through a DWI function API; none exists.
- Native VM behaviour of a hypothetical function API (unverified, not tested).
- Safari, Firefox and Edge for the transport probe.
- dart2wasm closure representation and any dart2wasm function API path.
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
