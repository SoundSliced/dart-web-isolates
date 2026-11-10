# Compatibility Matrix

Dart `dart:isolate` feature vs DWI vs the web limitation. **DWI columns describe
v0.3 unless marked proposed.** No cell claims parity.

| `dart:isolate` feature | DWI (native) | DWI (web) | Web limitation | Evidence |
| --- | --- | --- | --- | --- |
| `Isolate.run(fn)` | via registered task | **not supported** | closures are not cloneable; compiler cannot ship them | R001 §1, R004 §2 |
| `Isolate.run(task, input)` (named) | yes | yes | requires precompiled worker registry | ADR-002 |
| `Isolate.run` fresh context per call | yes for `Dwi.run` and `Dwi.runFresh` | only `Dwi.runFresh`; pooled `Dwi.run` may reuse a worker and its state | `Dwi.run` on web is a pool; `Dwi.runFresh` spawns and closes a dedicated context per call | ADR-016, R014, probe in `docs/limitations.md` |
| `Isolate.spawn` | yes — one persistent isolate per handle | yes — one dedicated worker per handle | one task at a time per handle; no heap sharing | ADR-013 |
| Long-lived handle with retained worker-local state | yes (`DwiWorker`) | yes (`DwiWorker`) | state is lost on close, restart, crash or timeout | ADR-013 |
| Restart a failed handle | yes, explicit `restart()` | yes, explicit `restart()` | fresh context and fresh state; no replay | ADR-013 |
| `Isolate.spawnUri` | proposed | not planned | a second program means a second compilation | R002 §4 |
| `SendPort` | proposed | emulated (proposed) | `MessagePort` is transferable once, not cloneable | R001 §3, R003 §5 |
| `ReceivePort` | proposed | emulated (proposed) | routed over one transport with logical IDs | R003 §5 |
| Message = arbitrary object graph | yes (same group copy) | **no** | structured clone loses prototypes and rejects functions | R001 §4, R003 §3 |
| Shared immutable objects | yes (canonical) | no | every message is independent | R001 §2 |
| `TransferableTypedData` | yes (`TransferableTypedData`) | `ArrayBuffer` transfer via `DwiTransferableBytes` | source is detached after transfer (web); native detachment is a DWI flag | R001 §4, R003 §4, ADR-010 §10.2 |
| `Isolate.kill` | yes | `Worker.terminate()` | abrupt; queued and in-flight work lost | R001 §5, R003 §6 |
| Cancel a running task | `Isolate.kill` on a retained handle | `Worker.terminate()` | non-cooperative; no partial result | ADR-010 §10.1 |
| Detect a dead idle worker | port error / explicit state | heartbeat envelope | heartbeat pings idle workers only | ADR-010 §10.3 |
| Observe why a handle stopped (`stopReason`, `stops`) | yes | yes | observation only, one broadcast event per generation; no `onExit`/`onError` parity, no replay | ADR-017 |
| dart2wasm host application | n/a | **supported** since the 2026-11-05 integral-double fix | worker is dart2js; measured in Chrome 156 only | audit/evidence/flutter-run-modes-and-wasm-fix-2026-11-05.txt |
| dart2wasm worker backend | n/a | **experimental slice** (ADR-018); dart2js host + Wasm worker passed the contracts below | three artefacts (`.wasm`, `.mjs` loader, generated bootstrap), module worker, `application/wasm`, opt-in only, no fallback; Flutter hook target selection and a dart2wasm host + Wasm worker are unverified | `audit/evidence/dart2wasm-worker-acceptance-2026-11-10.txt` |
| Pause / resume / ping | yes | **no** | no browser equivalent | R003 §1 |
| `onExit` / `onError` listeners | yes | envelope events | `error` events are coarse; promises rejections vanish | R003 §6 |
| `RemoteError` + stack | yes | `DwiRemoteException` | stack captured by the worker, not the host | R001 §5 |
| Isolate groups / shared heap | yes | **no** | separate realms, separate heaps | R001 §2 |
| Startup cost | low | 7–60 ms measured | script fetch + runtime init | M001, R003 §7 |
| Max concurrency | cores | `hardwareConcurrency` hint | pool must be capped and configurable | R003 §7 |

## Compatibility levels

| Level | Meaning | Status |
| --- | --- | --- |
| DWI-0 | background worker, ad-hoc messaging | demonstrated by M001 |
| DWI-1 | typed named tasks, correlated, typed errors, timeouts | shipped in v0.2 |
| DWI-1.5 | annotation-driven worker generation, typed proxies, automatic compilation, typed payload codecs | shipped in v0.3.1 |
| DWI-1.6 | cancellation, transferable bytes, heartbeat crash detection | shipped in v0.4 (Chrome and Safari measured; Firefox/Edge unverified for this level) |
| DWI-2 | long-lived workers, pooled scheduling | handles shipped for native and web JS (Chrome, Safari, Firefox and Edge verified); `Dwi.run` pool unchanged from v0.3 |
| DWI-3 | port-like messaging | implemented under ADR-014: single-subscriber, named, bounded channels per handle; Chrome, Safari, Firefox and Edge verified |
| DWI-4 | high `dart:isolate` API similarity | research; increment 1 implemented under ADR-016 (`Dwi.runFresh`, fresh context per call) and increment 2 implemented under ADR-017 (`stopReason`/`stops`, no parity claim) |
| DWI-5 | compiler-supported arbitrary functions | research, no design |
| DWI-6 | SDK-integrated web isolate | upstream proposal only |

## Never claim

- “Isolates on web”.
- “Same semantics as `Isolate.run`”.
- That plain `flutter build web` never triggers worker generation; on Flutter
  3.47+ with `dwi_builder` as a dependency it does (ADR-009), and the CLI is the
  fallback elsewhere.
- Any browser support cell that was not measured.
- That a handle preserves state across a restart, a close, a crash or a timeout.
- That channels are `SendPort`/`ReceivePort` parity, broadcast, shared memory,
  or that they survive a restart.
- That one handle runs calls in parallel. It runs one task at a time, in FIFO
  order.
