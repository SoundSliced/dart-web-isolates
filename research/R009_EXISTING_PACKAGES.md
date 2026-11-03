# R009 — Existing Packages and Prior Art

Status: research report · Agent: 6 (Prior art) · Evidence: pub.dev package
metadata (queried 2026-11-03) and READMEs fetched from the projects' repositories
on the same date. README statements are **claims by their authors**, not verified
behaviour, unless marked otherwise.

Versions and dates below are the latest published versions at query time.

## Summary

- The space is active, not empty. Three projects matter most:
  `squadron` (worker pools + code generation, claims JS and Wasm support),
  `isolate_manager` (long-lived isolates, web workers via a generator, claims
  Wasm), and `worker_bee` (Amplify-internal, explicitly not for external use).
- All of them solve the same first problem the same way: **generate a worker
  entrypoint at build time and address tasks by name**, because closures cannot
  cross the boundary.
- None of them implement a `dart:isolate`-shaped port model, and none can accept
  an arbitrary function or closure at runtime.
- `worker_manager` (7.2.9) is isolate-pool management for the VM; its README does
  not claim web worker support.
- Maintenance risk is real: the most ambitious projects are single-maintainer,
  and `worker_bee` states it has no plans to support external use.

## Package-by-package

### `squadron` 7.4.4 (published 2026-09-22)

- Repository: https://github.com/d-markey/squadron. SDK `^3.4.0`.
- Claimed: “Works everywhere: Desktop, Server, Mobile, and Browser (JS & WASM)”;
  persistent worker pools; automatic code generation for type-safe boundaries;
  `Stream` returns.
- Mechanism (per README): annotate a service with `@SquadronService`, run
  `squadron_builder`, get `FooWorker` / `FooWorkerPool` proxies. Calls are
  marshalled to a generated worker entrypoint.
- Strength: pool + streaming + typed proxies is the most complete developer
  experience in the ecosystem.
- Limitation relative to DWI's goal: the unit of work is a *service method*, not
  a function value; each service is a generated contract, so arbitrary functions
  are out. Browser support is claimed for JS and Wasm; the exact Wasm loading
  path was not inspected (mark UNVERIFIED).
- Reusable: pool scheduling, typed proxy generation, `Stream` support.

### `squadron_builder` 9.3.2 (published 2026-08-25)

- Repository: https://github.com/d-markey/squadron_builder. SDK `^3.9.0`.
- The code generator behind `squadron`. It is the clearest existing example of
  “generate worker entrypoints from annotated Dart code”.
- Reusable: annotation discovery and deterministic generation. Its existence
  confirms that generated entrypoints are the accepted solution, not a hack.

### `isolate_manager` 6.3.2 (published 2026-04-12)

- Repository: https://github.com/lamnhan066/isolate_manager. SDK `>=3.7.0`.
- Claimed: isolate manager for one-off and long-lived isolates; web support “via
  JavaScript Workers”; WASM support; built-in type/exception safety; `ImType`
  wrappers for web transfer; “Graceful Fallback: Defaults to Future/Stream if Web
  Workers are unavailable”; “Codeless Web Workers: Generate necessary JavaScript
  worker files without build_runner”.
- Mechanism (per README): annotate functions (`@isolateManagerWorker`,
  `@isolateManagerSharedWorker`, `@isolateManagerCustomWorker`), run a generator,
  which emits JS worker files. Functions used on web must not depend on
  Flutter-specific libraries such as `dart:ui`.
- Limitation: the generator writes JavaScript worker files; the function set is
  fixed at generation time; payloads need `ImType` wrappers because structured
  clone loses Dart types.
- **Red flag for DWI**: “graceful fallback” to `Future`/`Stream` when workers
  are unavailable changes execution semantics silently from the caller's point
  of view. DWI's AGENTS.md rule 12/17 forbids that: fail or degrade *explicitly*.

### `worker_bee` 0.3.15 (published 2026-09-25)

- Repository: https://github.com/aws-amplify/amplify-flutter (package path
  `packages/worker_bee/worker_bee`). SDK `^3.11.0`.
- README: “experimental multiplatform concurrency solution used internally in
  Amplify client libraries. There are currently no plans to support this for
  external use.”
- Value to DWI: a real production user of web workers inside Flutter, with
  generated worker code. Not a dependency candidate. Its internal design is worth
  reading but was not audited here (UNVERIFIED).

### `worker_manager` 7.2.9 (published 2026-04-13)

- Repository: https://github.com/dsrenesanse/worker_manager. SDK `>=2.19.0 <4.0.0`.
- Claimed: isolate pool management, reusable isolates, cancellation
  (`Cancelable`), gentle cooperative cancellation, `executeWithPort` for progress
  messages. README requires functions to be static/global/lambdas.
- Web: the README does not claim web worker support. Treat as VM-only.
- Reusable: `Cancelable`, gentle cancellation, port-based progress.

### `flutter_isolate` 2.1.0 (published 2024-09-18)

- Repository: https://github.com/rmawatson/flutter_isolate. SDK `>=2.12.0`.
- Isolates with Flutter plugin support on native platforms; no web worker claim.
- Status: last release 2024; not a model for web.

### `dart_worker` 0.0.8 (published 2015-02-24)

- Repository: https://github.com/hutchgrant/dart-worker. SDK `<2.0.0`.
- Unrelated: an HTTP RPC server, not a browser worker package. Excluded from
  comparison (name collision only).

### `web_worker`, `wasm_worker`

- No packages with these names were returned by the pub.dev API at query time
  (empty/404 responses). Treat as non-existent.

### Not on pub.dev but relevant

- **comlink** (JS): proxy-based RPC over `postMessage`; the best-known API design
  for hiding message plumbing. Not usable directly from Dart, but its proxy idea
  maps to generated typed clients.
- **threads.js** (JS): worker pool + transferable handling; useful scheduling
  reference.

## Cross-cutting analysis

| Question | squadron | isolate_manager | worker_bee | worker_manager | DWI target |
| --- | --- | --- | --- | --- | --- |
| Web workers | claimed (JS & Wasm) | claimed (JS; Wasm claimed) | yes (internal) | no | yes |
| Wasm | claimed | claimed | unknown | no | later, separate backend |
| Compilation model | code generation | generator emits JS | generated | n/a | generate + compile |
| Arbitrary functions | no (service methods) | no (annotated functions) | no | VM only | research only |
| Serialization | generated proxies | `ImType` wrappers | generated | isolate messages | explicit envelope |
| Pools | yes | long-lived isolates | unknown | yes | planned |
| Cancellation | unknown | unknown | unknown | yes (gentle) | planned |
| Silent fallback | no | **yes** | unknown | n/a | forbidden |

## Reusable ideas

1. **Generated entrypoints are the norm.** Every web-capable package generates
   worker code; none ships closures.
2. **Typed proxies beat stringly-typed dispatch** (squadron). DWI should generate
   typed task references once the registry exists.
3. **Pools are table stakes** (squadron, worker_manager).
4. **Cooperative cancellation** (worker_manager's `executeGentle`) is the only
   cancellation that does not throw away a worker.
5. **`MessageChannel`-style dedicated channels** are a good upgrade path for
   long-lived workers.

## Mistakes to avoid

1. **Silent fallback to the main thread** when workers are unavailable. It hides
   the failure the user is trying to avoid and makes benchmarks meaningless.
2. **Stringly-typed task dispatch without validation** — an untrusted message
   must not select an arbitrary operation (SECURITY.md).
3. **Leaking `package:web` types into the public API**, which welds user code to
   the browser and breaks native compilation.
4. **One worker per call**: startup dominates and the runtime is copied per
   worker.
5. **Claiming Wasm support without testing the loader path**; loading `.mjs` +
   `.wasm` is materially different from loading a classic worker script.
6. **Ignoring Flutter web constraints**: worker code cannot use `dart:ui`, and
   the worker artefact is not part of `flutter build web`'s single-entrypoint
   compilation (R002).

## Gap analysis — what none of them do

- A `dart:isolate`-shaped API with ports and `Isolate.run`-like ergonomics that
  is honest about web limits.
- Runtime-selected tasks (level 3/4 in the master plan); all require generation.
- A portable error model that preserves remote stack traces across realms.
- A documented semantic-difference table rather than “works everywhere” claims.

DWI's differentiator is therefore **semantic honesty plus automated compilation**,
not merely “workers on web”.

## Verification status

- **Verified**: package names, latest versions, publish dates, repository URLs,
  SDK constraints (pub.dev API, 2026-11-03); README claims quoted above.
- **Unverified**: internal mechanisms of squadron/worker_bee beyond their
  READMEs; actual Wasm support in squadron and isolate_manager; benchmark
  performance of any package.
- **Could not determine**: whether any of these projects have unpublished
  `dart:isolate`-compatibility work.
