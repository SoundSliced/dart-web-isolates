# Serialization

What DWI can send, what it refuses, and what it costs. Evidence: R001 (VM),
R003 (structured clone), R006 (comparison).

## Raw web values

Name-based calls such as `Dwi.run('name', value)` pass wire values directly.

| Type | Wire form | Notes |
| --- | --- | --- |
| `null`, `bool`, `int`, `double`, `String` | JS primitives | raw numbers follow JS `Number` semantics |
| `List` of accepted values | JS array | element types are erased |
| `Map` with `String` keys | plain object | generic types are erased |
| `Set` of accepted values | JS array | arrives as a list |
| `Uint8List`, `Int32List`, and other supported typed lists | typed array | copied by default |
| `ByteData`, `ByteBuffer` | `DataView`, `ArrayBuffer` | copied by default |

Nested values must be acyclic. Raw collection cycles produce a
`DwiSerializationException` with the path where the cycle was found. For
integer precision across JS and Wasm, stay within the JS safe integer range
(−(2⁵³ − 1) through 2⁵³ − 1), or use generated `BigInt` arguments or decimal
strings to carry larger exact integers.

## Converted by generated code (ADR-021, since 0.9.0)

These apply to `@DwiTask` signatures, where the generator knows the static
type. They are converted to the accepted forms above before sending and rebuilt
on arrival.

| Type | Wire form | Notes |
| --- | --- | --- |
| `List<T>`, `Set<T>`, `Map<String, V>` | arrays and objects | generated code rebuilds supported element and value types |
| public enum | constant name | an unknown name is a `DwiSerializationException` |
| `DateTime` | `[microsecondsSinceEpoch, isUtc]` | instant and `isUtc` preserved |
| `Duration` | microseconds | |
| `BigInt`, `Uri` | string | |
| record | list: positional, then named sorted by name | arity is checked |
| `@DwiPayload` class | map of constructor parameters | rebuilt through the unnamed constructor |

A payload class crosses as its constructor parameters. The receiver constructs
a new instance with the declared type. Use acyclic values with generated codecs.

## Not supported

- Classes without `@DwiPayload`, and generic, abstract or private payload
  classes: rejected at build time (`DWI001`) and by the payload validator.
- The bare `Record` and `Enum` types, and maps with non-`String` keys.
- Functions, closures, tear-offs and `Symbol`.

Raw web calls also reject unencoded class and enum instances and native
`SendPort`/`ReceivePort` values.

## Web task payload budget

`DwiConfig.maxPayloadBytes` defaults to 64 MiB (67,108,864 bytes). It applies
separately to the encoded input and the encoded result of each web task call.
The host checks the input before sending it. Oversized inputs and results
produce `DwiSerializationException`.

The estimate adds eight bytes per visited value, one unit per UTF-16 code
unit in strings and map keys, and the byte length of buffers or typed data.
You can configure a larger budget before using the pool:

```dart
await Dwi.configure(const DwiConfig(maxPayloadBytes: 128 * 1024 * 1024));
```

The browser still needs enough memory to encode, clone and decode each message.
For larger data, send chunks or transfer byte buffers. Transferable bytes also
count toward the configured budget. Native task calls use the Dart VM's
isolate sendability rules.

## Transfer policy

```dart
await Dwi.run('hash', DwiTransferableBytes(bytes));
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
- Converting classes that do not opt in with `@DwiPayload`.
- A binary protocol; v1 is structured clone with a JSON-shaped envelope.
