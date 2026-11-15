# DWI 1.0 security review

Scope: the objections S1–S9 raised in `docs/critical-review.md` (2026-11-03), and
the security-relevant surfaces of the 1.0 candidate: the worker URL, the protocol
envelope, payload validation, resource limits, lifecycle cleanup, generated code
and error text.

Who reviewed: the maintainer's project agents, by reading source and running the
tests named below. **No external security audit has been performed.** A 1.0 claim
does not replace one.

## Objections and their state

| # | Objection | State at 1.0 | Evidence |
| --- | --- | --- | --- |
| S1 | A strict CSP can block the worker; the failure must be typed, not a hang. | Closed. `DwiStartupException` and `startupTimeout`; strict same-origin CSP measured in four engines, three passes each, with an inline-script control blocked in every engine. | `audit/evidence/browser-matrix-csp-2026-11-14.json`; `docs/browser-matrix.md` (strict CSP section) |
| S2 | A generator must never emit dynamic code or map names to imports at run time. | Closed by construction. Generated code uses static references and typed proxies; no `Function(...)` or `eval` in any package `lib/`. Tasks are looked up by name in a generated table. | `packages/dwi_builder/test/generator_test.dart`; source search of `packages/*/lib` |
| S3 | Payloads from the page must be validated, size-capped and queue-capped in the worker. | Closed. Shape and size checks in the worker dispatcher; `maxPayloadBytes` and `maxQueuedTasks` are enforced. | `packages/dwi_web/test/payload_test.dart`, `worker_dispatcher_test.dart`; lifecycle cases in `browser_lifecycle_test.dart` |
| S4 | Unbounded in-flight calls or very large payloads can freeze the worker and the host. | Closed. Defaults are chosen (`maxPayloadBytes` 64 MiB, `maxQueuedTasks`, `queueTimeout`); payloads up to 100 MiB were measured in four engines. | `docs/browser-matrix.md` (payload range); `packages/dwi_core/lib/src/config.dart` |
| S5 | Workers can outlive their page or a failed start. | Closed for the pool and handles: termination on timeout, close, failed startup and restart, in four engines. Page unload is not measured separately; the browser ends dedicated workers with their document. | `audit/evidence/pool-lifecycle-four-engines-2026-11-13T113102.json` (latest run); `browser_lifecycle_test.dart` |
| S6 | Shared memory would need cross-origin isolation; it must stay opt-in. | Closed. Shared memory is out of scope (ADR-007); the JS backend does not require COOP or COEP. | `docs/architecture.md` ADR-007 |
| S7 | Error text and stack traces crossing the boundary are data, not HTML. | Closed by inspection. The library never renders error text as HTML (no `innerHTML`, `outerHTML` or `insertAdjacentHTML` in `packages/*/lib`). Applications that render them must escape them. | source search of `packages/*/lib`; `docs/troubleshooting.md` |
| S8 | Generated worker entrypoints are executable code and must be deterministic. | Closed. The generator is deterministic: same input, byte-identical output. | `packages/dwi_builder/test/generator_test.dart` (deterministic order), `hash_test.dart` |
| S9 | A `blob:` or `data:` worker bypasses the origin assumptions. | Closed 2026-11-15. The library never creates blob workers, and `DwiConfig.requireWorkerScript` now refuses `blob:`, `data:` and `javascript:` worker URLs with a typed startup error. | `packages/dwi_core/test/worker_script_test.dart`; ADR-006 |

## Other surfaces

- **Protocol.** Protocol version 2 is checked at startup. A worker that reports a
  different version, or none, fails the start (`dwi_web` protocol check, ADR-026 G3).
  Malformed messages, unknown message types and version mismatches are tested
  (`dwi_protocol` tests).
- **Late and duplicate replies.** A late reply after cancellation is measured in
  four engines. A duplicate reply cannot be produced through the public API on any
  backend, so it is not tested and is recorded as a limitation.
- **Dependencies.** Discovery rejects imports of forbidden libraries in worker code
  (`dart:io`, `dart:html`, `dart:ui`, `dart:ffi`, `dart:isolate`, Flutter) with diagnostics; the check is in
  `packages/dwi_builder/lib/src/discovery.dart`.
- **Supply chain.** The packages declare their dependencies in `pubspec.yaml`
  with `^` constraints. The lockfiles are committed for the examples and
  packages. No dependency has been audited beyond its own published quality.

## Open risks accepted for 1.0

- No external audit. A 1.0 release is not a security certification.
- Page unload cleanup of dedicated workers is relied on from the browser, not
  measured (S5).
- Mobile browsers and other operating systems are not measured (see
  `docs/compatibility-matrix.md`).
- The `workerScript` URL is checked for its scheme only. A same-origin URL that
  points to attacker-controlled content is outside DWI's control; the application
  owns its served files.

## Verified, not verified, could not determine

- **Verified:** each objective above, against the named source files and tests.
- **Not verified:** page unload cleanup; behaviour on mobile and non-macOS systems;
  any external attack. Could not determine: whether the browsers' own worker
  isolation changes in future releases.
