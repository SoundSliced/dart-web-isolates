# Serialization

What DWI can send, what it refuses, and what it costs. Evidence: R001 (VM),
R003 (structured clone), R006 (comparison).

## Accepted by default

| Type | Wire form | Notes |
| --- | --- | --- |
| `null`, `bool`, `int`, `double`, `String` | themselves | `int`/`double` distinction follows JS numbers on web |
| `List` of accepted values | JS array | element types are not preserved |
| `Map` with `String` keys | plain object | non-string keys are rejected on web |
| `Uint8List`, `Int32List`, … | typed array | can be transferred |
| `ByteBuffer` | `ArrayBuffer` | transfer detaches the sender's buffer |

Nested combinations of the above are allowed. Cycles are allowed only if the
encoding is structured clone (it supports cycles); JSON codecs must reject them.

## Requires an explicit codec

- Custom classes: implement a codec and register it in the worker entrypoint.
  Decoding validates shape; prototypes are restored by the codec, not by clone.
- `DateTime`: encode as epoch milliseconds, decode explicitly.
- `BigInt`: cloneable, but Dart `int` on web is a JS number; mixing them is an
  error.
- Records and enums: encode explicitly; nothing is automatic in v0.2.

## Rejected

- Functions, closures, tear-offs, `Symbol`.
- Any object with a non-cloneable field, including a class instance without a
  codec (rejected at the host boundary, not silently converted).
- Buffers above the configured payload limit.
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
