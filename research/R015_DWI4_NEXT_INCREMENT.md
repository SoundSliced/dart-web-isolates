# R015 — DWI-4 next increment: candidate comparison

Status: research, 2026-11-08. The 0.6.0 release gate is prepared and pushed
(not published). R014 selected and shipped `Dwi.runFresh`; this report compares
the three deferred candidates and selects exactly one to design, without
implementing it. It makes no `dart:isolate` parity claim.

Evidence used (all from this checkout):

- `packages/dwi_core/lib/src/worker_handle.dart` — `DwiWorkerState` and the
  handle contract.
- `packages/dwi_core/lib/src/exceptions.dart` — the typed error hierarchy.
- `packages/dwi_web/lib/src/web_worker_handle.dart` — `_fail`, `close`,
  `_startHeartbeat`.
- `packages/dwi_native/lib/src/native_worker_handle.dart` — `_fail`, `close`,
  `addOnExitListener`, `_onMessage`.
- `packages/dwi_native/lib/src/native_backend.dart:51-66` and
  `packages/dwi_core/lib/src/transferable_bytes.dart` — native transfer path.
- `docs/architecture.md` ADR-013 (handles), ADR-014 (channels), ADR-015
  (scoped helper), ADR-016 (`runFresh`); `docs/limitations.md`.

## What the current surface does and does not tell a caller

`DwiWorkerState` has six values; only two are terminal: `closed` (explicit
`close()`) and `failed` (everything else). A call that is running when the
context stops settles with a cause-specific exception:

| Event | Handle state afterwards | Error delivered to the affected call |
| --- | --- | --- |
| explicit `close()` | `closed` | `DwiWorkerClosedException` |
| task timeout | `failed` | `DwiTimeoutException` |
| cancelling a running call | `failed` | `DwiCancelledException` |
| crash / heartbeat loss / malformed message | `failed` | `DwiWorkerFailedException` |

An idle failure is detected on both backends: the web handle pings an idle
worker and fails the handle after `heartbeatMisses`
(`web_worker_handle.dart:696-720`), and the native handle listens for isolate
exit (`native_worker_handle.dart:784,822`). But the public surface has no
callback or stream: if no call is pending, nothing is delivered, and after the
fact `state == failed` cannot distinguish timeout from cancellation from crash.
That is the information gap this report evaluates.

## Candidate 1 — Handle termination observation

**Consumer use case.** A long-lived handle backing an editor or a compute
session. The app wants to log or report *why* the context stopped, and replace
it when it crashed rather than when the user closed it. Today it must wrap every
call in `try`/`catch` and still cannot observe an idle crash or a timeout that
happened between calls.

**Native/web feasibility.** Package-only. Both backends already funnel every
terminal transition through one method (`close()` and `_fail`), so a reason can
be recorded there. No browser API is exposed; no protocol change.

**Semantic limits.** One final reason, not a lifecycle event log. It is not
`Isolate.onExit`/`onError`: there is no exit message, no replay, and timeout and
cancellation are DWI concepts that `dart:isolate` does not have. A failed
*startup* never yields a handle, so it remains the thrown
`DwiStartupException` from `spawn`, not an event. A queued-call timeout does not
fail the handle and must not produce a termination event.

**Minimal API proposal.**

```dart
enum DwiWorkerStop {
  callerClosed,
  crashed,
  timedOut,
  cancelled,
  protocolViolation,
}

abstract interface class DwiWorker {
  /// Latest terminal reason for the current context, or null while active.
  DwiWorkerStop? get stopReason;

  /// Broadcast; one event per terminal transition. Stays open across restart.
  Stream<DwiWorkerStop> get stops;
}
```

**Failure rules.** `close()` → `callerClosed`; context death → `crashed`;
running-call timeout → `timedOut`; running-call cancellation → `cancelled`;
malformed/protocol failure → `protocolViolation`. A `close()` after a failure
does not overwrite `stopReason` or emit a second event. `restart()` clears
`stopReason`; the next terminal transition emits once. The stream never carries
an error and closes when the handle can no longer restart (final `closed`) or
when `Dwi.close()` tears it down.

**Test plan.** VM: each reason; queued timeout emits nothing; a late subscriber
reads `stopReason`; restart clears and re-emits; close-after-failure does not
duplicate; stream closes at final close. Browser: the same, plus an idle
heartbeat crash in all four engines. Existing typed call errors must be
unchanged.

**Value / risk.** Medium value, low risk, additive. It answers a question the
current API cannot, and it uses the backend hooks that already exist. The main
cost is defining restart and stream-lifetime semantics precisely.

## Candidate 2 — Native transfer performance and ownership (`TransferableTypedData`)

**Consumer use case.** A native app that repeatedly ships multi-megabyte
buffers wants to know whether `DwiTransferableBytes` moves or copies on native.

**Current evidence.** The native backend already wraps bytes in
`TransferableTypedData.fromList` (`native_backend.dart:55-56`;
`native_worker_handle.dart:18-19`). The source explicitly notes that
`fromList` *may copy*, so the sender's memory stays valid and `isDetached` is
DWI bookkeeping (`transferable_bytes.dart`; `native_backend.dart:51-53`). On web
the `ArrayBuffer` is genuinely detached. So the asymmetry is real, but it is a
cost/ownership question, not missing functionality.

**Native/web feasibility.** Native only. It cannot be closed on web (already
detached) and it cannot be closed at all without a public API that transfers
without copying; the public `TransferableTypedData` surface is the only option.

**Semantic limits.** No API-similarity win and no new consumer capability. Any
change would be a backend optimisation and would need a reproducible
before/after benchmark (AGENTS.md rule 15), plus a decision on whether the
asymmetry should be documented rather than changed.

**Minimal API proposal.** None until a benchmark shows a material gap. The
increment, if any, is internal.

**Test plan (if selected later).** A native benchmark for 1 KiB, 1 MiB and
8 MiB send + echo, copied vs current path, with peak allocation and elapsed
time; ownership assertions that the sender's memory is invalidated only when
the implementation says it is.

**Value / risk.** Low value today, medium risk from expectation changes around
ownership. Deferred until a consumer reports the cost.

## Candidate 3 — Error-event stream

**Consumer use case.** Centralised logging of every DWI failure, including
failures that happen while no call is pending.

**What is unavailable today.** Typed call errors already carry task, remote
type and remote stack. Channel errors carry their own state. The only extra
information is an idle failure with no caller — which Candidate 1 already
reports as `crashed`. A separate error stream would therefore duplicate the
typed errors and create a second error channel that can itself be unhandled.

**Native/web feasibility.** Package-only, but semantically weak: a broadcast
stream cannot tell a caller which call an error belongs to beyond what the call
already gives it.

**Semantic limits.** Not `Isolate.onError` parity (no raw `RemoteError`), and
it would compete with the existing typed errors for the same events.

**Minimal API proposal.** Deferred. If lifecycle observation later needs the
concrete error object, add an `Object? lastError` snapshot to the selected
increment instead of a second stream.

**Test plan.** n/a unless selected.

**Value / risk.** Low value, medium risk of duplicated error paths. Not
selected.

## Selected increment

**Candidate 1 — handle termination observation (`stopReason` + `stops`).** It
is the only candidate that supplies information the current public surface
cannot produce, it is package-only on both backends, it reuses terminal
transitions that already exist, and it adds no second error channel. R014's
ordering (lifecycle first) agrees.

Selection is recorded as ADR-017. It is **accepted for design, not
implemented**; no code, protocol or public surface change is made by this
report.

## Tracks kept explicitly open

- **dart2wasm worker backend.** The dart2wasm *host* result in
  `docs/browser-matrix.md` §4 does not establish a wasm worker. §1 shows a
  trivial wasm module in a worker; DWI's worker runtime compiled to wasm is
  unmeasured and unbuilt.
- **Compiler-supported arbitrary functions (DWI-5).** Still the largest gap;
  needs compiler cooperation, not a package increment.
- **Upstream Flutter build ordering and live worker replacement.** The
  first-build limitation is asserted by `tooling/hosted_consumer/`; live
  replacement of a running worker across hot reload/restart remains upstream.

## What this report did not establish

- No end-to-end probe of the proposed lifecycle API; it is a design.
- No benchmark for native transfer cost.
- No consumer survey beyond the stated use cases.
