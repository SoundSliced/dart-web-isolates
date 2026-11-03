# R006 — Message Serialization

Status: coordinator synthesis of R001 (VM) and R003 (browser), plus the probes.
This report does not add new claims without a citation; see those reports for
source locations.

## The two serializers are not analogues

| Aspect | Dart VM (R001) | Browser structured clone (R003) |
| --- | --- | --- |
| Entry point | `WriteMessage(same_group, obj, …)` — `runtime/vm/message_snapshot.h:16` | `postMessage(message, [options])` — `package:web` `html.dart:12826` |
| Same-heap case | `CopyMutableObjectGraph` (`message_snapshot.cc:3396`), shares deeply immutable objects | no equivalent; every clone is independent |
| Object model | full Dart object graph, including functions/closure contexts | JS cloneable types only |
| Custom classes | preserved (same group) or serialised (across groups) | become plain objects; prototype lost |
| Functions | copyable within an isolate group | `DataCloneError` |
| Ports | `SendPort` copyable into any message (`kSendPortCid`) | `MessagePort` transferable **once** |
| Bulk bytes | `TransferableTypedData` (single-use, `isolate.dart:1057-1075`) | `ArrayBuffer` transfer (detaches source) |
| Errors | typed `RemoteError` with stack trace | `Error` cloneable; stack string survives engine-dependent |
| Identity/canonicalisation | canonical objects preserved (`message_snapshot.cc:2086`) | no identity across realms |

## What DWI can encode safely

Tier 1 — always safe, no codec needed:

- `null`, `bool`, `int`, `double`, `String`
- `List`/`Map` built from the above (become JS array/object; Dart type information
  is lost, so the receiving side must know the expected shape)
- `Uint8List` and other typed-data views
- `ByteBuffer`

Tier 2 — requires explicit handling:

- `DateTime` → send epoch milliseconds; do not rely on `Date` clone semantics
  across Dart and JS.
- `BigInt` → supported by structured clone (`BigInt`), but Dart `int` on web is
  a JS number; do not mix.
- `Map`/`Set` → structured clone preserves JS `Map`/`Set`, but a Dart `Map`
  compiles to a JS object literal on dart2js; specify the wire representation.
- `ArrayBuffer` transfer → ownership moves; the sender must drop its reference
  (mirrors `TransferableTypedData`).

Tier 3 — must be generated or rejected:

- custom Dart classes → generated `toWire`/`fromWire` codecs, or rejection with a
  typed error.
- closures, tear-offs, arbitrary functions → reject; select by task ID instead
  (R004/R007).
- objects with cycles → allowed only if the codec supports them; structured clone
  handles cycles, a naive JSON codec does not.
- `SendPort`/`ReceivePort` → model as routed logical IDs; optionally back a
  channel with a transferred `MessagePort`.

## Error envelope

Dart's `RemoteError` carries a message and a stack trace string
(`isolate.dart:270-284`). The browser gives an `error` event for uncaught worker
failures and nothing reliable for rejected promises. Therefore the wire protocol
must carry:

```text
errorType        String   (Dart runtime type name, best effort)
message          String
remoteStackTrace String
workerId         String
taskId           int
timestamp        int (epoch ms)
```

This is a protocol requirement, not an optimisation: without it errors vanish
(AGENTS.md rule 12).

## Cost model

- Copying dominates for large payloads; transfer avoids the copy but detaches
  the source.
- Structured clone of a typed array is a memory copy; transfer is zero-copy
  (MDN, transferable objects).
- Dart-object encoding (JSON or generated) adds a serialise/deserialise pass on
  top of the clone. For binary workloads, prefer typed arrays and transfer.
- `TransferableTypedData` in the VM is the same idea with a single-use rule;
  exposing a DWI transferable type keeps semantics familiar.

## Non-goals

- No attempt to reproduce VM canonicalisation or object identity.
- No implicit sharing of mutable objects (violates AGENTS.md rule 10).
- No “send anything” promise; unsupported types fail loudly at the boundary.

## Verification status

- **Verified**: all VM and browser statements are cited in R001/R003.
- **Unverified**: exact `Error.stack` preservation per engine; performance of
  each encoding path (to be measured in M001/benchmarks).
