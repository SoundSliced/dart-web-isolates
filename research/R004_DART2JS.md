# R004 — dart2js and DDC

Status: research report · Agent: 2 (Web compilers) · Evidence: `dart-lang/sdk`
@ `e21f924582d55790da4fec00ce179db5629ab6c6`, Dart 3.13.5, probes compiled
locally (Chrome for runtime).

## Summary

- dart2js consumes kernel, lowers to its own SSA/IR, then emits JavaScript.
  Reachability is decided by the compiler's "world" model
  (`WorldImpact`), not by textual references; anything not enqueued is removed.
- A Dart closure with captures compiles to a **JS object with fields**; a
  tear-off compiles to a cached JS function registered by name. Neither is
  transferable to another JS realm, and neither carries a serialisable identity.
- `dart:isolate` *compiles* for every web target because each target has a patch
  file full of `UnsupportedError` stubs. Compilation success says nothing about
  runtime support.
- DDC's patch says it plainly: `dart:isolate is not supported on dart4web`.
- Separately compiled entrypoints do not share library code: each is a
  self-contained script (or module for DDC), so two workers cost two copies of
  the Dart runtime.
- Tree shaking is a *threat* to worker generation: a task function referenced
  only from a generated dispatch table is kept, but a function referenced only
  through a string name is not.

## 1. dart2js pipeline

- Compiler entry and phase driver: `pkg/compiler/lib/src/compiler.dart:76`
  (`class Compiler`), `:710` (`runSequentialPhases`), kernel-to-JS path at
  `:328-330`.
- SSA/IR and optimisations: `pkg/compiler/lib/src/ssa/`, `pkg/compiler/lib/src/ir/`.
- JavaScript emission: `pkg/compiler/lib/src/js_emitter/` (`js_emitter.dart`,
  `code_emitter_task.dart`, `program_builder/`, `startup_emitter/`,
  `class_stub_generator.dart`, `runtime_type_generator.dart`).
- Deferred loading (`deferred as`): `pkg/compiler/lib/src/deferred_load/`.
- Reachability: `pkg/compiler/lib/src/universe/world_impact.dart:22`
  (`class WorldImpact`), built from `universe/use.dart` static/dynamic use
  records; the enqueuer turns those into the emitted program.

**Consequence**: whether a function survives compilation is a property of the
whole-program analysis. A name in a string is not a reference.

## 2. What a closure becomes

Probe `.research/probes/closure.dart`:

```dart
int addOne(int x) => x + 1;
void main() {
  final List<int> values = [1, 2, 3];
  final int captured = 7;
  final int Function(int) closure = (int x) => x + captured;
  print([addOne, closure, values].length);
}
```

Compiled with `dart compile js -O0 -o closure_o0.js closure.dart`
(321,097 bytes; the same program at `-O1` is 12,090 bytes). Emitted JavaScript
(lines are from that artefact):

```js
addOne(x) {                                   // :2808
  return x + 1;
}

main_closure: function main_closure(t0) {     // :2814
  this.captured = t0;                         // :2815
}
```

and at the `main` site:

```js
A.print([A.closure__addOne$closure(), new A.main_closure(7), A._setArrayType([1, 2, 3], type$.JSArray_int)].length);  // :2812
```

with a static tear-off registration:

```js
_static_1(A, "closure__addOne$closure", "addOne", 0);   // :3218
```

What this establishes:

1. A captured closure is an ordinary JS object; the captured environment is
   stored in named fields (`captured`). There is no code-plus-scope serialisation
   format and no way for another realm to reconstruct it.
2. A tear-off is a cached, registered closure object tied to the *current*
   program instance (`closureFromTearOff`, `closure_o0.js:716`). The name
   metadata (`"addOne"`) is debug metadata, not a transferable handle.
3. `Function.toString()` on such an object is not source Dart and is not
   re-compilable (the emitted body references runtime helpers such as `A.print`).
4. Closures work across VM isolates only because same-group messages copy the
   object graph (R001), including function objects and their context. That
   mechanism has no browser equivalent.

## 3. `dart:isolate` on web: compile-time success, runtime failure

`sdk/lib/libraries.json` maps `dart:isolate` for each target:

- dart2js: line 607, patch `_internal/js_runtime/lib/isolate_patch.dart`.
- dart2wasm: line 509, patch `_internal/wasm/common/isolate_patch.dart`.
- DDC/`dart4web`: line 796, patch `_internal/js_dev_runtime/patch/isolate_patch.dart`.

All three set `support_conditional_import: false`.

dart2js patch (`sdk/lib/_internal/js_runtime/lib/isolate_patch.dart`):

| Member | Line | Behaviour |
| --- | --- | --- |
| `Isolate.current` | 16 | `throw UnsupportedError("Isolate.current")` |
| `Isolate.spawn` | 45-54 | `throw UnsupportedError("Isolate.spawn")` |
| `Isolate.spawnUri` | 58-73 | `throw UnsupportedError("Isolate.spawnUri")` |
| `Isolate.kill` / listeners | 78-127 | `UnsupportedError` |
| `RawReceivePort` constructor | 163 | `UnsupportedError('new RawReceivePort')` |
| `ReceivePort.listen` / `sendPort` | 151-156 | `UnsupportedError` |
| `TransferableTypedData.fromList` | 179 | `UnsupportedError` |

The coordinator's probe confirms the behaviour in Chrome (dart2js, Dart 3.13.5):

```text
Isolate.current -> UnsupportedError: Unsupported operation: Isolate.current
Isolate.run     -> UnsupportedError: Unsupported operation: new RawReceivePort
Isolate.spawn   -> UnsupportedError: Unsupported operation: Isolate.spawn
ReceivePort     -> constructed (_ReceivePortImpl)
```

`Isolate.run` is plain Dart built on `Isolate.spawn` and `RawReceivePort`
(see R001), so it fails at the first `RawReceivePort` construction. `ReceivePort`
constructing without throwing is a quirk of the patch, not support: its stream
never delivers anything.

DDC (`sdk/lib/_internal/js_dev_runtime/patch/isolate_patch.dart`): the class is
patched at line 13, every member forwards to `_unsupported()`, and
`_unsupported()` throws `UnsupportedError('dart:isolate is not supported on dart4web')`
(line 149).

## 4. DDC differences that matter

- Module-per-library output rather than one merged script
  (`pkg/dev_compiler/lib/src/compiler/`, `lib/src/kernel/`), loaded by the dev
  server; output is ES modules.
- The isolate patch is explicit rather than incidental: no ports at all.
- A worker could in principle load DDC modules as a module worker, but the
  runtime expects the DDC bootstrap/loader, which a worker does not have by
  default. **UNRESOLVED**: whether DDC output can be loaded in a worker without
  the dev server. Treat "DDC in a worker" as an experiment, not a plan.

## 5. Compiling a secondary entrypoint

`dart compile js -o out.js entry.dart` produces a self-contained script:

- The Dart runtime (`dart:` core libraries, type system helpers, tear-off
  infrastructure) is emitted into every output. Measured with this SDK:
  - trivial isolate probe: 155,687 characters at `-O1`;
  - trivial closure probe: 12,090 characters at `-O1`, 321,097 at `-O0`
    (unminified names inflate size substantially).
- There is no shared-library mechanism between two independent compilations:
  two workers = two complete copies of the runtime in memory.
- `deferred as` can split *one* compilation, but the deferred part is loaded by
  the same program instance; it is not a second entrypoint.
- No CLI flag for multiple entrypoints in one invocation was found in the
  compiler sources inspected. `--dump-info` exists for size analysis only.

**Consequence for DWI tooling** (R007): a worker build step is literally
"run the Dart compiler again with a different entrypoint", plus a copy step into
a served directory. Automating it is straightforward; making the two outputs
share code is not.

## 6. Implications for worker generation and function passing

| Goal | Feasible with dart2js today | Why |
| --- | --- | --- |
| Precompiled worker entrypoint | yes | `dart compile js -o worker.js worker.dart` |
| Registry of named task functions | yes | generated static references keep them alive |
| Send a top-level function reference to a worker | no | function objects are not cloneable |
| Send a closure with captures | no | closure is a heap object in this realm (R004 §2) |
| Select a function by string ID | yes | dispatch table generated in the worker |
| Automatic discovery of annotated functions | requires generator + build step | no compiler metadata channel found |

The only honest way to offer `run(function, arg)` on web is to generate a
registry in the *same compilation* as the worker and pass an ID at runtime
(compatibility level DWI-1 in the master plan, not level 3/4).

## Unresolved

- Exact tree-shaking rules for functions referenced only from a generated
  `Map<String, Function>`: a static reference in generated Dart should retain
  them, but this was not tested end to end (needs a probe with a generated
  registry; planned in M001/Phase 4).
- Whether `dart compile js` can emit an ES module in the current SDK
  (`--module-format`?), which would simplify module-worker loading.
- DDC worker loading, as noted above.

## Verification status

- **Verified**: pipeline locations; closure and tear-off representation in
  emitted JS; isolate patch line-by-line; runtime throws in Chrome; compile
  output sizes for the two probes; single-entrypoint compilation.
- **Unverified**: tree shaking of a generated registry; DDC-in-worker; any
  undocumented multi-entrypoint support.
