# Critical Review — 2026-11-03

Two adversarial reviews of the architecture (`architecture.md`), the API
(`api-proposal.md`) and the protocol (`protocol.md`). Objections are recorded as
raised; **Open** means unresolved and blocking for a 1.0 claim, not necessarily
for v0.2.

## Security review (Agent 11)

| # | Objection | Status |
| --- | --- | --- |
| S1 | CSP: the worker URL must satisfy `worker-src`; a strict policy can block the backend entirely. The API must surface this as a typed startup error, not a hang. | Mitigated by `DwiStartupException` + `startupTimeout`; CSP behaviour per engine unverified. |
| S2 | `task` must never become code. If a future generator emits `Function('...')` or maps names to imports dynamically, it becomes an injection surface. | Protocol forbids it (security rule 1). Generator must be reviewed again when it exists. |
| S3 | Untrusted payloads: same-origin does not mean trusted. A compromised page can send arbitrary structures. Dispatch must validate shape, cap size and cap queue depth. | Specified; **Open** until implemented and tested. |
| S4 | Resource exhaustion: unbounded in-flight requests or 100 MB payloads can freeze the worker and the host. | Limits are specified, defaults not yet chosen; **Open**. |
| S5 | Worker leak: page teardown, route changes, hot restart and failed startups can leave workers alive. | Lifecycle requires termination on timeout and explicit close; **Open** for Flutter hot-restart and page unload. |
| S6 | Cross-origin isolation: any future shared-memory path requires COOP/COEP and changes deployment. Must remain opt-in and never required by the JS backend. | Recorded in ADR-007; shared memory is out of scope. |
| S7 | Error text and stack traces cross a boundary; they must be treated as data, never injected into HTML or logs without escaping. | Documented; implementation must not render HTML from them. |
| S8 | Generated code must be deterministic and reviewed; generated entrypoints are executable code in the user's app. | AGENTS.md rule 11; generator review is a precondition for v0.3. |
| S9 | Blob/data URL workers under a permissive policy can bypass origin assumptions. DWI should require a real served URL. | ADR-006 and R003 §2; enforced by configuration (workerScript is a path). |
| S10 | Denial of service through a task that never returns: `terminate()` is the only reliable stop and it kills queued work too. | Accepted and documented; cancellation is cooperative where possible. |

## Upstream-maintainer review (Agent 12)

The reviewer was instructed to behave as a skeptical Dart SDK maintainer.

| # | Objection | Response recorded |
| --- | --- | --- |
| M1 | Why does this belong in the SDK rather than a package? | It does not, yet. DWI starts as a package; ADR-001 forbids SDK work before evidence. This is a precondition, not an answer for a later proposal. |
| M2 | Closures are the whole point of `Isolate.run`; named tasks are a worse API. | True. R004 §2 shows closures cannot cross realms without compiler support. The project states this instead of hiding it; the closure path is DWI-5, explicitly research. |
| M3 | The build burden is high: users must compile and serve a second artefact. | Acknowledged. `flutter build web` has no hook (R002 §4). Tooling can automate the compile, but not remove the artefact. This is a real adoption cost. |
| M4 | Semantics differ from `dart:isolate` in ways users will trip over: no ports, no shared immutable data, terminate-only kill, startup cost. | Enumerated in `compatibility-matrix.md`; API avoids the word “isolate” in the released surface. |
| M5 | Maintenance: browser matrix, compiler changes, generator, protocol versions. | Scope is deliberately small: one backend, one protocol version, no SDK forks. Still a multi-year maintenance commitment if it succeeds. |
| M6 | Browser compatibility is unproven outside Chrome. | Correct, and recorded as a limitation. No compatibility claim is made beyond measured cells. |
| M7 | Why not use existing packages (`squadron`, `isolate_manager`)? | They solve generated-service or annotated-function concurrency. DWI targets a smaller, more explicit protocol and a native/web-unified API with documented limits (R009). The overlap is real. |
| M8 | A protocol version and error envelope add ceremony for simple use cases. | Accepted trade-off; `Dwi.run` hides it. Ceremony is what makes failures and timeouts observable. |
| M9 | Wasm is where the platform is going; a JS-only package may age badly. | Wasm is a separate backend in the design (ADR-006, R005). Not shipped in v0.2. |
| M10 | Changing Flutter's `compute()` would be a semantic and performance change that maintainers would resist. | Not proposed for v0.2. Any `compute()` discussion requires its own proposal and must not promise parity. |

## Open items that gate a 1.0 claim

1. S3/S4/S5 implemented and tested (payload limits, queue limits, leak tests).
2. Browser matrix filled for Firefox, Safari and Edge.
3. A tested cooperative cancellation path.
4. A documented, measured answer to “why not just use the main thread for small
   tasks?” — pool sizing and startup amortisation.
5. Decision on whether the generated-registry path survives tree shaking
   (R004 unresolved item).

## Status on 2026-11-11

The table above is kept as raised. Current state of the open items:

| Item | State | Evidence |
| --- | --- | --- |
| S3 payload and dispatch validation | closed | `packages/dwi_web/test/payload_test.dart`, `worker_dispatcher_test.dart`, lifecycle case `f` |
| S4 resource exhaustion | closed | `maxPayloadBytes`, `maxQueuedTasks`, `queueTimeout`; lifecycle cases `b`, `c`, `k` in four engines |
| S5 worker leaks | closed for pool and handles (termination on timeout, close and failed startup, four engines); page unload relies on the browser ending dedicated workers with their document and is not separately measured | `audit/evidence/pool-lifecycle-four-engines-2026-11-13T104143.json`, idle retirement and drain: `pool-idle-drain-acceptance-2026-11-13T104143.json` |
| Gate 2 browser matrix | closed for desktop engines; mobile unverified | `docs/browser-matrix.md` |
| Gate 3 cooperative cancellation | open | `docs/completion-plan.md` tranche D |
| Gate 4 pool-sizing guidance | open | tranche A10 |
| Gate 5 tree shaking for every shape | open | tranche A8 |

## What this review changed

- Added mandatory startup/task timeouts and typed startup errors.
- Made payload/queue limits a protocol requirement rather than a tuning detail.
- Added the “no Blob/data URL worker” stance.
- Kept `Dwi.run(fn)` out of the public API.
