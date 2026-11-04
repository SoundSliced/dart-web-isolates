# R013 — Automatic Worker Compilation

> **Correction (2026-11-03, v0.3 audit).** Flutter 3.47.6 does expose web build
> hooks (`BuildHooks(platform: HookPlatform.web)` in `flutter_tools`), they run
> on `flutter build web` and `flutter run -d web-server`, and a hook can invoke
> `DwiBuilder` directly. The §4.3 conclusion below ("no web build hook") is
> superseded by ADR-009. The rest of this report remains valid.
>
> **Fresh-build ordering (2026-11-04).** A clean-room Flutter 3.47.6 app with no
> generated proxies failed its first `flutter build web`: `dart2js` started
> concurrently with `build_hooks` and could not resolve
> `lib/dwi_tasks.g.dart`, which the hook wrote seconds later. The hook
> generates and packages correctly, and a second build succeeds. A hook cannot
> guarantee that generated sources exist before application compilation, so
> DWI requires one `dwi build` (or a rerun) before the first Flutter build.
> See `audit/evidence/flutter-fresh-build-ordering-2026-11-04.txt`.

Status: decision report for v0.3. Evidence is R001–R010, the local Dart/Flutter
SDK, and the probes recorded in §6. No claim here is based on “it is well known
that”.

Environment: Dart 3.13.5 (stable, 2026-09-29), Flutter `3.47-candidate.0`
(engine `692136cb6582dbfc5af3fb33c2515a069f2f66d0`), macOS arm64. SDK sources
cited from the local clone at `.research/dart-sdk` (gitignored; revision is the
one shipped with the SDK).

## 1. The question

The v0.2 developer experience requires four manual artefacts and two commands:

```text
lib/worker.dart                 # hand-written second entrypoint
Dwi.registerTask(...)           # hand-maintained registry
dart compile js ...             # manual compilation
Dwi.configure(workerScript: …)  # manual path
```

Can DWI remove all of it, up to and including:

```dart
final result = await Dwi.run(expensiveCalculation, input);
```

and, if not, what is the strongest automation the current toolchain supports?

## 2. Strategies under comparison

| Letter | Strategy | What the developer writes | Who produces the worker |
| --- | --- | --- | --- |
| A0 | Manual worker | task body, worker `main()`, registry, build command, path | developer |
| A1 | Build-time generated worker (annotation) | `@DwiTask()` on a top-level function | DWI generator + compiler CLI |
| A2 | Build-hook worker | same as A1 | DWI hooked into the application build |
| A3 | Compiler-integrated worker | ordinary function call, no annotation | Dart/Flutter compiler |
| A4 | Runtime compilation | ordinary closure/function value | a Dart compiler shipped to the browser |

The addendum's Levels A, B and C map to A1/A2, A3/A2 with function discovery,
and A3 with a runtime-like API respectively. A4 is the genuine runtime-
compilation question and is treated separately.

## 3. Comparison

| Strategy | Boilerplate | Performance | Size | Security | Production viability | DX |
| --- | --- | --- | --- | --- | --- | --- |
| A0 manual worker | high | good | good | good | good | poor |
| A1 generated worker | low | good | good | good | **preferred** | good |
| A2 build-hook worker | near zero | good | good | good | blocked on a Flutter hook | excellent |
| A3 compiler-integrated | zero | excellent potential | excellent potential | good | requires SDK change | ultimate target |
| A4 runtime compilation | zero | research-dependent | potentially poor | complex (eval/CSP) | experimental | excellent but unsafe to promise |

A1 is the minimum acceptable production solution and is implementable today.
A2 is the target experience, but this SDK exposes no web build hook (§4.3). A3
requires compiler cooperation that does not exist (§4.4). A4 is technically
dubious and is rejected for v0.x (§4.5).

## 4. Findings

### 4.1 A worker is a second compilation

`flutter build web` passes a single `target` to the compiler
(`packages/flutter_tools/lib/src/web/compile.dart`, R002 §3). Each
`dart compile js` invocation emits a self-contained script including the Dart
runtime; there is no shared-runtime mode between independent entrypoints
(R004 §5, R007). Therefore any automatic solution must generate and compile a
separate artefact. It cannot “reuse the app bundle” without also shipping the UI
program and a dispatch protocol inside the worker (R007 rejected approaches).

### 4.2 Static references are required to survive tree shaking

Reachability is a whole-program property (`pkg/compiler/lib/src/universe/
world_impact.dart`, R004 §6). A task name in a string does not keep a function
alive. A generated map of static references does:

```dart
final Map<String, DwiWorkerTask> tasks = <String, DwiWorkerTask>{
  'calculatePrimes': (Object? input) => tasksLibrary.calculatePrimes(input! as int),
};
```

The map is reachable from the generated worker `main()`, so the functions are
retained. The generator must emit real Dart references, never names alone.

### 4.3 There is no Flutter web build hook in this SDK

Verified from the local toolchain:

- `dart build --help` lists exactly one subcommand: `cli`
  (`dart build cli --help` consists of build options; there is no `web`).
- `dart compile --help` lists `js`, `jit-snapshot`, `kernel`, `exe`,
  `aot-snapshot`, `wasm` — no multi-entrypoint or “extra entrypoint” option.
- Build hooks (`hook/build.dart`) exist for native/code assets: the SDK's
  `dart:ffi` documentation refers to “a code asset registered with `assetId` in
  a build hook” (`sdk/lib/ffi/dynamic_library.dart:35`). They are not a web
  entrypoint mechanism.
- `flutter_tools` compiles one web target and has no extension point for a
  second one (R002 §3–4).

Consequence: A2 cannot be implemented honestly in v0.3. DWI can provide a
single wrapper command that performs generation, compilation and then the
Flutter build, but it cannot claim that plain `flutter build web` triggers the
worker build. That limitation is documented in `docs/limitations.md`.

### 4.4 Compile-time function discovery (Level B)

Dart's experimental `macros` flag exists in the front end
(`pkg/front_end/lib/src/api_prototype/experimental_flags_generated.dart:230`)
but is **disabled by default** (`isEnabledByDefault: false`), and this SDK ships
no `pkg/macros` implementation or analyzer macro API. It is not a supported
mechanism on which a package can depend. No compiler metadata channel exists
for “compile this function into a worker” (R004 §6). Identifying a function at
the source/AST level is possible — that is what A1 does — but mapping an
arbitrary function value at runtime to a worker task is not.

### 4.5 Runtime compilation (Level C/A4)

To compile arbitrary Dart in the browser, the browser would need a Dart
compiler. This SDK ships compilers as VM snapshots/executables
(`dart compile`), not as a browser-loadable module; `dart2js` and `dart2wasm`
are not designed to run inside a page. Even if a compiler were shipped:

- it is large (the front end plus code generator), delaying startup;
- it needs `eval`/`new Function` or a Wasm code-generation path, which typical
  CSP policies block (R003 §2); Blob workers need explicit `worker-src`;
- it would have to resolve packages and tree-shake at runtime, duplicating the
  build;
- it would execute code that arrived as data, widening the attack surface;
- a function value is a compiled JS object, not source; `Function.toString()`
  on dart2js output is not re-compilable Dart (R004 §2);
- closures capture environments as JS objects, and functions cannot be
  structured-cloned (R003 §3).

No evidence supports A4 as a production architecture. It remains a research
question only.

### 4.6 What automatic generation can still give the developer

A1 removes every manual artefact:

```text
@DwiTask()                       discovered by the analyzer
        │
        ▼
.dwi/generated_worker.dart       deterministic, static references
        │
        ▼
dart compile js                  invoked by the DWI build command
        │
        ▼
web/dwi/worker.dart.js           copied by flutter build web
        │
        ▼
web/dwi/manifest.json            generated, never hand-maintained
```

The developer does not write a worker `main()`, a registry, a manifest, a path,
or a compile command. They do run one DWI command (or use the watch mode during
development) because of §4.3.

Typed generated proxies give a call shape close to the target without
pretending to support closures:

```dart
await DwiTasks.calculatePrimes(5_000_000);
```

This is the honest A1 ceiling. `Dwi.run(calculatePrimes, input)` and
`Dwi.run(() { ... })` require A3 and are not promised before compiler support
exists (ADR-002).

## 5. Decision gate

| Criterion | A1 generated | A2 build hook | A3 compiler | A4 runtime |
| --- | --- | --- | --- | --- |
| Works on Dart 3.13.5 today | yes | no hook | no | no |
| No manual worker file | yes | yes | yes | yes |
| Deterministic output | yes | yes | compiler-dependent | no |
| Tree-shaking safe | yes (static refs) | yes | yes | unknown |
| Browser size | one extra bundle | one extra bundle | smallest potential | potentially very large |
| CSP-compatible | yes | yes | yes | often no |
| Honest to ship | yes | no (no hook) | no (no SDK change) | no |

**Recommendation: A1 — automatic build-time generation and compilation with
runtime-transparent execution.**

Concretely:

1. `@DwiTask()` annotation on top-level functions.
2. Analyzer-based discovery; no source-text regular expressions.
3. Deterministic generated worker entrypoint with static references.
4. Generated typed proxies for callers.
5. Generated manifest (protocol, tasks, artefact, content hash).
6. Content-addressed cache: generated source + reachable dependencies + Dart
   version + DWI version + compiler options → SHA-256; skip compilation when
   unchanged.
7. Lazy worker startup and the existing pool/lifecycle rules.
8. One universal worker bundle initially. Multiple/chunked workers are a
   benchmark-driven decision, not a default; the current worker bundle is small
   compared with the Flutter app and one bundle keeps pooling simple.
9. A single `dwi build` command, plus `dwi watch` for development and
   `--flutter-build` to run the Flutter build after the worker step.
10. Build-time diagnostics (DWI001–DWI006) instead of opaque worker failures.
11. No runtime compilation, no function-value API, no closure claim.

This gives most of A3's developer experience without shipping a compiler in the
browser or forking the SDK.

## 6. Probes and verification

Verified in this repository for v0.3:

- The generator discovers annotated functions with `package:analyzer`’s
  resolved AST, including annotation arguments, parameter/return types and
  enclosing library.
- Generated worker entrypoints contain static references and compile with
  `dart compile js`.
- Generated proxies compile against `package:dwi` and route through
  `Dwi.run`.
- Repeated generation is byte-identical; the cache skips an unchanged worker
  compile.
- Build-time diagnostics fail on an unsupported signature, a duplicate task
  name, and a non-transferable `Function` parameter.
- `examples/automatic_worker` runs in Chrome: generated typed proxies dispatched
  two tasks through the generated worker and displayed a worker-computed
  result. This is a real browser execution, not only a compile.

Not verified, and not claimed:

- Firefox, Safari and Edge execution of generated artefacts; only Chrome was
  measured here and in M001 (`docs/browser-matrix.md`).
- Wasm worker generation (`dart compile wasm` + module worker) — v0.6.
- Flutter tool integration (no hook exists in this SDK).
- Hot reload of an already-running worker. Reload/restart semantics are
  documented; a page reload is required for a new worker script in general.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| Analyzer API drift | Pin `analyzer` and keep discovery behind a small interface; tests cover AST shapes. |
| Generated registry tree-shaken | Static references; compile probe in tests. |
| Stale artefact served | Hash in the manifest, `dwi check`, and a typed startup failure; never main-thread fallback. |
| Task library pulls Flutter/DOM into the worker | Transitive import check (DWI002) before compilation. |
| Cache hides a dependency change | Hash includes the transitive library closure, not just task files. |
| Users expect closures | Documented limitation and a typed error; ADR-002 remains in force. |
| Flutter build integration gap | Wrapper command documented; upstream proposal tracked in `docs/upstream-strategy.md`. |
