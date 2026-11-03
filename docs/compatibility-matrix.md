# Compatibility Matrix

Dart `dart:isolate` feature vs DWI vs the web limitation. **DWI columns describe
v0.2 unless marked proposed.** No cell claims parity.

| `dart:isolate` feature | DWI (native) | DWI (web) | Web limitation | Evidence |
| --- | --- | --- | --- | --- |
| `Isolate.run(fn)` | via registered task | **not supported** | closures are not cloneable; compiler cannot ship them | R001 §1, R004 §2 |
| `Isolate.run(task, input)` (named) | yes | yes | requires precompiled worker registry | ADR-002 |
| `Isolate.spawn` | proposed | proposed | one worker per handle; no heap sharing | R001 §2, ADR-003 |
| `Isolate.spawnUri` | proposed | not planned | a second program means a second compilation | R002 §4 |
| `SendPort` | proposed | emulated (proposed) | `MessagePort` is transferable once, not cloneable | R001 §3, R003 §5 |
| `ReceivePort` | proposed | emulated (proposed) | routed over one transport with logical IDs | R003 §5 |
| Message = arbitrary object graph | yes (same group copy) | **no** | structured clone loses prototypes and rejects functions | R001 §4, R003 §3 |
| Shared immutable objects | yes (canonical) | no | every message is independent | R001 §2 |
| `TransferableTypedData` | yes | `ArrayBuffer` transfer | source is detached after transfer | R001 §4, R003 §4 |
| `Isolate.kill` | yes | `Worker.terminate()` | abrupt; queued and in-flight work lost | R001 §5, R003 §6 |
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
| DWI-1 | typed named tasks, correlated, typed errors, timeouts | v0.2 target |
| DWI-2 | long-lived workers, pooled scheduling | proposed |
| DWI-3 | port-like messaging | proposed |
| DWI-4 | high `dart:isolate` API similarity | research |
| DWI-5 | compiler-supported arbitrary functions | research, no design |
| DWI-6 | SDK-integrated web isolate | upstream proposal only |

## Never claim

- “Isolates on web”.
- “Same semantics as `Isolate.run`”.
- “Automatic worker compilation” before it exists.
- Any browser support cell that was not measured.
