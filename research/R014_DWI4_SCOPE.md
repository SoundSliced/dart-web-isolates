# R014 — DWI-4 scope: `dart:isolate` API similarity

Status: research, 2026-11-08. DWI-4 is a compatibility level, not a parity
claim. This report compares the **current** (0.5.3 plus `DwiWorker.using`) public
API with `dart:isolate`, identifies each gap, and selects one narrow increment.
No cell below claims `dart:isolate` parity, closure execution, or a Wasm worker.

Evidence used:

- `packages/dwi_native/lib/src/native_backend.dart:122` — `Dwi.run` spawns an
  isolate per call.
- `packages/dwi_web/lib/src/web_backend.dart:341-352` — the web backend keeps
  idle worker slots and reuses them (`_idleSlot`, `_release`).
- `docs/architecture.md` ADR-013 (handles), ADR-014 (channels), ADR-015
  (scoped helper).
- Published-consumer probe, 2026-11-08: a hosted `dwi: ^0.5.3` Flutter Web app
  called `Dwi.run<int>('tick', 0)` twice in Chromium 156 and logged
  `pooled tick1=1`, `pooled tick2=2`; the worker-local counter advanced, so the
  second pooled call reused the first call's worker.
- Repository sources for errors, transferables and limitations
  (`docs/limitations.md`, `packages/dwi_core/lib/src/exceptions.dart`).

## Comparison

Columns: **native** and **web** are the current public behaviour; **gap** is the
semantic difference from `dart:isolate`; **package-only?** says whether the gap
could close without compiler or SDK changes; **evidence** is what decides it;
**value / risk** is the user value and compatibility risk of closing it.

| Concept | Current native | Current web | Exact gap vs `dart:isolate` | Package-only? | Evidence needed / held | Value | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Spawning | `DwiWorker.spawn()` starts one dedicated isolate per handle | `DwiWorker.spawn()` starts one dedicated `Worker` per handle | `Isolate.spawn(entry, message)` chooses the entry point by function; DWI chooses a task name from a compiled registry | No — function values need compiler support (DWI-5) | Code (`native_backend.dart:218`); R004 §2 | High (closures) | High; not this increment |
| One-shot execution | `Dwi.run` starts a **fresh isolate per call** (no state in or out) | `Dwi.run` acquires a **pooled worker that is reused**; worker-local state can persist between calls | `Isolate.run` always executes in a fresh isolate; web `Dwi.run` can observe earlier state | **Yes** — a dedicated handle per call already exists | Probe above (`1` then `2`); `web_backend.dart:341-352`; `native_backend.dart:122` | High: predictable one-shot semantics, no cross-call state leak | Low: additive API; startup cost per call |
| Messages and ports | Tasks return values; `DwiWorker.openChannel(name)` | Same API over `Worker`/`MessagePort` | No `SendPort`/`ReceivePort` objects, no transferable port, no broadcast, one subscriber per channel | Emulation only; ADR-014 forbids a parity claim | ADR-014; `docs/limitations.md` §3 | Medium | High: port-shaped API would invite false parity claims |
| Ordering | One task at a time per handle in FIFO order; `Dwi.run` calls are unordered | Same; channels are FIFO per direction | `dart:isolate` guarantees FIFO between a specific port pair only; it has no cross-port or cross-task ordering either. DWI matches that narrower guarantee but channels add no total order | Partly (total ordering could be added) | ADR-013 Decision 3; ADR-014 | Low | Medium: ordering promises are hard to keep and expensive |
| Cancellation | `runCancellable`; running cancel kills the isolate and fails the handle | Running cancel terminates the worker and fails the handle | `dart:isolate` has no cancellation; `Isolate.kill` is the analogue and DWI's `close()`/running cancel maps to it | n/a (DWI is already additive) | ADR-010 §10.1 | Already shipped | — |
| Errors | Remote and local failures arrive as `DwiRemoteException` (with remote type/stack); healthy failures fail only the call | Same mapping from `error` envelopes | `dart:isolate` delivers an `onError` event with `RemoteError` and a remote stack; DWI converts to a typed exception and never surfaces the raw error object | Partly — an error stream could expose raw events | `exceptions.dart`; `docs/limitations.md` §6 | Low–medium | Medium: a second error channel duplicates typed errors |
| Shutdown | `close()` is immediate, idempotent, cancels queued/running work | Same (`Worker.terminate`) | No `Isolate.exit(message)` graceful exit, no exit message, no drain variant | No graceful exit message; drain could be package-level but is out of scope | ADR-013 Decision 4; `docs/limitations.md` §4 | Low | Medium (hangs without cooperative tasks) |
| Transferable data | `DwiTransferableBytes` is DWI bookkeeping; payload crosses as a copied isolate message | `ArrayBuffer` is transferred with `postMessage`, source detached | Native `TransferableTypedData` really moves ownership; DWI's native path only marks the wrapper | Possibly (native backend could use `TransferableTypedData`) | ADR-010 §10.2; R001 §4 | Medium (native perf) | Medium: backend change, not an API-similarity win |
| Isolate-local state | Persists across calls on one handle; fresh per `Dwi.run` call | Persists across calls on one handle **and** across pooled `Dwi.run` calls | `Isolate.run` never retains state; `Isolate.spawn` entry state persists per isolate. DWI handles match `spawn`; web `Dwi.run` does not match `run` | **Yes** (same fix as one-shot execution) | Probe above | High | Low |
| Closure execution | Not supported: work is a registered named task | Not supported | `Isolate.run(() => fn(x))` cannot be expressed; this is the largest `dart:isolate` similarity gap | No — needs compiler cooperation (DWI-5) | `docs/limitations.md` §1; R004 §2 | Very high | Very high; explicitly excluded |
| Lifecycle observation | `state` getter and typed errors; no exit stream | Same | `Isolate` exposes `onExit`/`onError` streams; DWI has no stream and no distinction between caller close and a crash beyond the state at sampling time | Yes (backend close/failure hooks exist in part) | `native_worker_handle.dart:1021`, `web_worker_handle.dart:817` call `_onClosed` on close | Medium | Low–medium |

## Selected DWI-4 increment

**One-shot fresh-context execution: `Dwi.runFresh<R>(task, [input])`.**

- It is the one gap above that is high value, low risk, package-only, and
  provable on both backends today: `DwiWorker.spawn` + one `run` + `close`
  already provides it (ADR-013, ADR-015).
- It makes the web path match the native path and `Isolate.run`'s fresh-context
  guarantee: no worker-local state enters or leaves a call, and two calls never
  share a context.
- It does **not** touch `Dwi.run` semantics, `DwiWorker`, channels, errors, or
  transferables. Existing callers are unaffected.
- It does **not** make `Dwi.runFresh` equal to `Isolate.run(fn)`: the task is
  still selected by name. Closure execution stays DWI-5 and is not promised.

Costs, stated in the ADR: startup is paid per call (7–60 ms measured on web,
R003 §7), so `Dwi.runFresh` is for callers who need isolation from pooled state,
not a replacement for the pool.

Deferred increments, in rough order of next value: lifecycle observation
(`onExit`-like), native `TransferableTypedData`, and an error-event stream. Each
needs its own ADR and evidence; none is promised by this report.
