# Serialization

What DWI can send, what it refuses, and what it costs. Evidence: R001 (VM),
R003 (structured clone), R006 (comparison).

## Accepted by default

| Type | Wire form | Notes |
| --- | --- | --- |
| `null`, `bool`, `int`, `double`, `String` | themselves | `int`/`double` distinction follows JS numbers on web |
| `List` of accepted values | JS array | element types are erased; only `dynamic`/`Object?` element types build |
| `Map` with `String` keys | plain object | non-string keys are rejected; only `dynamic`/`Object?` key and value types build |
| `Set` of accepted values | JS array | arrives as a list; only `dynamic`/`Object?` element types build |
| `Uint8List`, `Int32List`, … | typed array | accepted by the payload validator; transfer is v0.4 |
| `ByteBuffer` | `ArrayBuffer` | transfer is v0.4 |

Nested combinations of the above are allowed. Cycles are allowed only if the
encoding is structured clone (it supports cycles); JSON codecs must reject them.

**Typed collections are a build error in v0.3.** Dart's web compilers erase
element types when a value passes through `jsify`/`dartify`: `List<int>` arrives
as `List<dynamic>` and `Map<String, int>` arrives as `Map<Object?, Object?>`.
A type-directed collection codec is planned for v0.4; until then use
`List<dynamic>`/`Map<Object?, Object?>` and decode inside the task.

## Not supported (no codec in v0.3)

- Custom classes and enums: rejected at build time and by the payload validator.
  They do not survive `jsify` with their Dart type; a typed proxy would receive
  an empty or plain JS object.
- `DateTime`: send `millisecondsSinceEpoch` as an `int`.
- `BigInt`, records: encode explicitly as primitives or collections.
- Functions, closures, tear-offs and `Symbol`.

## Rejected

- Functions, closures, tear-offs, `Symbol`.
- Any object with a non-cloneable field, including a class instance or an enum
  (rejected before a worker is acquired, not silently converted).
- Payloads above `DwiConfig.maxPayloadBytes`: the host enforces an approximate
  budget before sending and includes the limit in request metadata so the worker
  rejects oversized results. The budget counts strings by UTF-16 code units and
  is a resource guard, not an exact wire size.
- `SendPort`/`ReceivePort` (no web representation).

Rejections throw `DwiSerializationException` *before* a worker is started or a
message is sent, so a failure never depends on remote behaviour.

## Transfer policy

```dart
await Dwi.run('hash', DwiTransferableBytes(bytes)); // proposed helper
```

- Transfer is opt-in and single-use, mirroring `TransferableTypedData`.
- After a transfer, the sender's buffer is detached; reading it is a bug and the
  API documents it.
- A copy is the default because it is safer; transfer is chosen by the caller for
  large payloads with a before/after benchmark.

## Error payloads

Errors always cross as the protocol's `error` object, never as a thrown object
from another realm:

```text
{ code, message, remoteType, remoteStack, fatal, taskId }
```

The host maps it to `DwiRemoteException`. `remoteStack` is captured by the worker
runtime; it is a string, and it is never treated as executable.

## Cost model

- Copy: memory proportional to payload size, twice (encode + decode) for custom
  codecs; once for structured clone of plain values.
- Transfer: O(1) ownership move for `ArrayBuffer`.
- JSON encoding of large objects is the slow path; prefer typed arrays for binary
  payloads.

Benchmarks for 1 KB → 100 MB are in `benchmarks/` (planned; M001 measured only
the transfer path in the capability harness: 4 MiB in 0.6 ms round trip).

## Non-goals

- Preserving object identity across messages.
- Automatically discovering custom codecs.
- A binary protocol; v1 is structured clone with a JSON-shaped envelope.
