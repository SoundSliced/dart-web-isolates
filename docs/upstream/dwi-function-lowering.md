# DWI function lowering and SDK integration: gated research contract

Status: research/proposal only, 2026-11-11. No SDK changes, compiler fork,
upstream posting or arbitrary-function implementation is authorized.
ADR-020's registered-static adapter is independent of these open questions.

## What is established

- Production static adapters select existing typed proxies, without rewriting
  application source or sending functions. Native and sixteen browser/compiler
  cases pass; see [acceptance evidence](../../audit/evidence/dwi5-static-acceptance-2026-11-13T012032.json)
  and the native test.
- R016 records analyzer visibility of the six function forms and the released
  build-ordering gap. These are repository measurements, not a claim about a
  newly checked upstream release.
- The analyzer probe enumerates some captures but does not lift bodies.
  Inspection of `tooling/dwi5_probe/bin/analyze_forms.dart` shows its type
  heuristic accepts records and non-String-keyed maps, unlike the production
  DWI codecs; some checks use names without library identity. Its capture walk
  does not prove mutation, alias or nested-scope equivalence.

Consequently, do not promote the probe's "serializable" label into a production
guarantee. No new closure transform has been executed or benchmarked here.

## Separate the missing contracts

| Contract | Static subset | General closure / integration question |
| --- | --- | --- |
| Secondary entrypoint and assets | existing builder and explicit pre-build | can SDK/Flutter own this supported pipeline and deployment contract? |
| Generated sources before host compile | explicit pre-build remains required | which supported pre-compilation hook guarantees ordering and invalidation? |
| Code/body lowering | not needed; static reference exists | who preserves resolved lexical semantics and emits worker-safe code? |
| Runtime function selection | closed generated registry | how are newly created/unregistered functions represented without transporting code? |
| Captured environment | no closure environment | which copied/transferable values, snapshot moment and aliases are supported? |

These are not interchangeable asks. Fixing generated-source ordering does not
provide closure lowering, and compiling a Wasm worker does not provide SDK
integration or shared-state semantics.

## P4: smallest sound closure research step

**Decision: no-go for a general public closure API.** A limited explicit
analyzer-based pre-build experiment is conceivable, but is not demonstrated
and would need a separate approved ADR and tests before implementation.
Do not claim package-level source generation is impossible merely because an
automatic SDK transformation hook is absent.

A future experiment should begin with a concrete function returning a supported
type and read-only scalar captures. Proposed lowerable input:

```dart
final offset = 3;
// Hypothetical syntax only; not a supported DWI call.
submit((int value) => value + offset, 4);
```

Its worker entrypoint must statically reference generated code and receive an
explicit encoded environment. It must not import host UI code, stringify the
function, use eval, invoke it locally, or infer capture safety from type names.

Before any "pass", specify and differentially test:

| Semantic obligation | Minimal counterexample / acceptance condition |
| --- | --- |
| Capture timing | reassign offset after submission; define the exact snapshot instant |
| Mutable aliases | two captures referencing one list; either preserve the documented copied graph or reject it explicitly |
| Closure-local mutation | modify a captured local inside the body; host state must not be shared |
| Nested scopes | inner closure captures outer parameters and locals; no missing or spurious capture |
| Lexical bindings | same spelling from different libraries, private helpers, extensions and typedefs resolve identically |
| Receiver state | explicit/implicit `this` and instance tear-offs rejected until a receiver contract exists |
| Generic context | free type parameters rejected unless concretization is proven |
| Control flow | block return, loops, break/continue, try/finally and exceptions preserve behavior |
| Async suspension | await points and thrown futures preserve results, cleanup and supported errors |
| Payload restrictions | records, non-String map keys, custom objects, functions and DOM objects use production rejection rules |
| Dependencies | worker-safe import closure is checked after lowering, without importing the entire host application |
| Diagnostics | stable code, source span, offending capture and reason, before compilation |
| Rebuild behavior | identical inputs yield identical bytes; body/import/capture changes invalidate the build |

Run local reference and generated code separately on VM, dart2js and dart2wasm.
Then run the lowered task in actual workers, with realm/state assertions and
engine-specific evidence. Separate form 3 (expression with captures) from form
6 (block/control-flow body). A body that computes the same happy-path answer
but changes scope, capture timing or exception behavior does not pass.

**Stop conditions:** unresolved binding, unsupported capture/alias, dependence
on unavailable pre-compilation ordering, nondeterministic output, or any local
fallback. Record the cell as blocked and reduce it to the smallest unsupported
compiler/build contract; do not broaden a public API around the gap.

## P5: DWI-6 integration requirements matrix

This is a proposal checklist, not an implementation or an upstream commitment.
No new GitHub issue/PR has been created or posted.

| Area | Package evidence / current boundary | Upstream acceptance requirement |
| --- | --- | --- |
| API ownership | named APIs and ADR-020 generated subset only | maintainer-sponsored specification for accepted/rejected forms and Dart/Flutter ownership |
| JS and Wasm lowering | independent worker compilation; no closure lowering | maintained compiler contract and target-specific conformance tests |
| Build ordering | explicit pre-build; ordering repro already prepared | supported generation-before-analysis/compilation dependencies, including clean builds |
| Incremental/debug workflow | deterministic generation and cache tests; page reload | defined incremental invalidation, debug entrypoints, stack mapping and tooling lifecycle |
| Artifacts/deployment | ADR-018 content-addressed Wasm generations | stable asset/URL contract, base-path behavior, retention and stale-client failures |
| Browser restrictions | MIME, CSP and same-origin contracts documented | per-engine test ownership; unsupported deployments fail explicitly |
| Payload semantics | copied/explicitly transferred data, typed codecs | accepted capture graph, snapshot/alias semantics and precise rejection |
| Runtime lifecycle | typed startup/remote/timeout failures and cleanup | specified spawn owner, cancellation/termination, teardown and exactly-once settlement |
| Compatibility | no `dart:isolate` parity claim | explicit native differences, no deceptive unsupported behavior |
| Release maintenance | package tests and recorded environments | SDK/Flutter release gates, CI owners, regression triage and maintainer sponsorship |

Recommended order: discuss secondary-entrypoint/assets and source-ordering
contracts using existing reproductions; pursue lowering as a separately owned
compiler discussion. SDK integration may begin with a deliberately restricted
model, but the DWI-6 row cannot become "implemented" until an actual supported
SDK-integrated runtime and its acceptance evidence exist.

## Verification and unresolved questions

**Verified:** inspected generator/discovery/probe source; production static
acceptance on native and four engines, with separate JS/Wasm hosts and workers;
existing documented ordering and transport evidence.

**Not verified:** any lowered closure, its lexical/capture equivalence,
source-map quality, bundle cost, hot reload or a newly released upstream hook.
The differential cases above are requirements, not executed results.

**Unresolved:** supported AST/transform hook ownership, compiler representation
of closures, snapshot/alias policy, upstream API agreement and maintainer
sponsorship. These require explicit future decisions, not guesses.
