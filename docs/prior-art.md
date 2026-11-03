# Prior Art

Decision-oriented summary of existing Dart/Flutter concurrency packages. Full
evidence, versions and quoted claims: [`../research/R009_EXISTING_PACKAGES.md`](../research/R009_EXISTING_PACKAGES.md).
Metadata queried from pub.dev on 2026-11-03.

## Landscape

| Package | Latest | Scope | Web workers | Wasm | Model |
| --- | --- | --- | --- | --- | --- |
| `squadron` | 7.4.4 | worker pools, typed proxies | claimed (JS & Wasm) | claimed | generated service proxies |
| `squadron_builder` | 9.3.2 | code generator for squadron | n/a | n/a | build-time generation |
| `isolate_manager` | 6.3.2 | isolates + web workers | claimed | claimed | annotated functions → generated JS workers |
| `worker_bee` | 0.3.15 | Amplify-internal runtime | yes | unknown | generated worker runtime |
| `worker_manager` | 7.2.9 | VM isolate pool | no | no | isolate pool, cancellation |
| `flutter_isolate` | 2.1.0 | native isolates with plugins | no | no | VM isolate |
| `dart_worker` | 0.0.8 | unrelated (HTTP RPC) | no | no | name collision |

## What to reuse

1. **Generated worker entrypoints** — every web-capable package does it. Closures
   cannot cross realms (R004), so generation is not a limitation to work around;
   it is the mechanism.
2. **Typed proxies over the generated registry** — squadron's approach hides
   stringly-typed dispatch and gives compile-time safety.
3. **Persistent pools with a work queue** — startup cost dominates otherwise.
4. **Cooperative cancellation** — `worker_manager`'s "gentle" cancellation is the
   only variant that keeps the worker alive; abrupt termination should be the
   escalation, not the default.
5. **Dedicated channels for long-lived workers** — transfer a `MessageChannel`
   port instead of routing every message through one handler.

## What to avoid

1. **Silent fallback to the main thread.** `isolate_manager` advertises exactly
   this. It makes a failed worker indistinguishable from a fast one, destroys
   benchmark validity, and violates AGENTS.md rules 12 and 17.
2. **`ImType`-style wrapper proliferation** as the only way to send data.
   A single documented encoding (structured-cloneable primitives, typed data,
   transferables) with generated codecs is smaller and clearer.
3. **Claiming Wasm support without a tested loader path.** `.wasm` + `.mjs` is a
   different loading model, not a compiler flag.
4. **Letting browser types into the public API** — breaks native compilation and
   ties users to `package:web`.
5. **Unbounded task queues and worker leaks** — the most common production
   failure for pool libraries.

## The gap DWI targets

None of the existing packages offer:

- an isolate-shaped API (`run`/`spawn`/ports) with an explicit semantic-difference
  table instead of “works everywhere” marketing;
- runtime-selected task execution (all require generation);
- a documented, versioned wire protocol with typed remote errors;
- separate, honest JS and Wasm backends with per-browser evidence.

DWI therefore competes on **semantics and tooling honesty**, not on being the
first to call `Worker` from Dart.
