# dart:isolate Semantics in DWI

What DWI preserves, what it changes, and why. Read with
`compatibility-matrix.md`.

## Preserved by design

1. **No shared mutable state.** A worker cannot observe the host's objects and
   vice versa. Payloads are copied or ownership-transferred.
2. **Message-based communication.** There is no RPC that exposes an object
   reference; results are values.
3. **Independent failure domains.** A worker crash fails its tasks; it does not
   corrupt the host heap.
4. **Explicit lifecycle.** A handle exists, is used, and is closed; workers are
   never left running implicitly (AGENTS.md rule 13).
5. **Typed errors with remote context.** Failures cross as data, including a
   captured remote stack.

## Changed or absent

| Semantics | DWI behaviour | Why |
| --- | --- | --- |
| Function values | rejected | not cloneable (R004) |
| Object identity across messages | not preserved | structured clone creates new objects |
| Class prototypes | lost unless a codec restores them | structured clone semantics |
| Shared immutable objects | copied | no shared heap or canonicalisation |
| Ports | later emulation with logical IDs | `MessagePort` is one-shot |
| Pause/resume | absent | no browser primitive |
| Graceful exit with message | absent | `terminate()` is abrupt |
| Spawn cost | higher and variable | script fetch + runtime init |
| Concurrency model | one JS thread per worker | browser scheduling, not VM scheduler |

## Ordering and concurrency guarantees

- Messages from one host to one worker are delivered in send order.
- Tasks may complete out of order; correlation is by `id`.
- A worker executes one task at a time in v0.2. Concurrency comes from multiple
  workers, not from interleaving inside a worker.
- There is no fairness guarantee between queued tasks.

## What “isolate-like” means here

The developer-visible model is: independent execution, message passing, no
shared objects, typed failures, explicit lifetime. That is the isolate
*philosophy*; it is not the isolate *implementation*. DWI never claims the
latter.

## Migration guidance

| If you use… | On web, change to… |
| --- | --- |
| `Isolate.run(() => work(x))` | register `work` as a task; `Dwi.run('work', x)` |
| `Isolate.spawn(entry, port)` | a long-lived worker handle (proposed) with request/response |
| `SendPort` streams | task results plus progress messages (proposed) |
| `TransferableTypedData` | transfer a `ByteBuffer`/typed array |
| `Isolate.kill` | cancellation if cooperative, close/terminate otherwise |

Native code can keep using DWI with the same named-task API, or stay on
`dart:isolate` directly; DWI does not require migration on native.
