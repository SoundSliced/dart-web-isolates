# R001 — Dart Isolate Architecture (VM)

Status: research report · Agent: 1 (Dart Runtime) · Evidence base: `dart-lang/sdk`
@ `e21f924582d55790da4fec00ce179db5629ab6c6` (shallow sparse clone in
`.research/dart-sdk`), Dart 3.13.5.

Every claim below cites the file and line in that commit. Anything the clone or
the available tooling cannot settle is marked **UNRESOLVED**.

## Summary

- `Isolate.run` is **not** a VM primitive. It is a small Dart-level wrapper in
  `sdk/lib/isolate/isolate.dart:253` that spawns an isolate, sends a closure via
  `SendPort`, and waits on a `RawReceivePort` for result, error or exit
  (`isolate.dart:253-315`).
- Isolates in the same **isolate group** share a heap; isolates in different
  groups do not. Messages within a group are copied with
  `CopyMutableObjectGraph`; messages across groups go through the snapshot
  serializer. This distinction is invisible to Dart code but central to cost.
- Ports are global, process-wide identifiers (`PortMap`, `runtime/vm/port.h:34`).
  A `SendPort` is a `Capability` (`isolate.dart:849`) and is the only way to
  address another isolate.
- Only deeply immutable objects can be shared across isolates
  (`runtime/vm/object_graph_copy.h:15`); everything else is copied. There is no
  shared mutable Dart state, by construction.
- Error propagation is port-based, not exception-propagation: an isolate sends
  `(error, stack)` to the `onError` port and terminates; the receiver wraps it
  in `RemoteError` when the payload is a pair of strings.
- A browser worker cannot reproduce the isolate-group model: workers have
  separate heaps and no shared object store, and `postMessage` is a structured
  clone, not a Dart graph serializer. This is a semantic gap, not an
  implementation detail.

## 1. API surface and where each operation is implemented

`sdk/lib/isolate/isolate.dart` declares:

| Member | Location | Implementation |
| --- | --- | --- |
| `Isolate.run<R>` | `isolate.dart:253` | Dart code in the same file; builds on `Isolate.spawn` |
| `Isolate.spawn<T>` | `isolate.dart:461` | `external` (VM patch) |
| `Isolate.spawnUri` | `isolate.dart:549` | `external` (VM patch) |
| `Isolate.current`, `spawn`, `kill`, listeners | `isolate.dart:329-560` | VM patch `sdk/lib/_internal/vm/lib/isolate_patch.dart` |
| `SendPort` | `isolate.dart:849` | `abstract interface class SendPort implements Capability` |
| `ReceivePort` | `isolate.dart:931` | `abstract interface class ReceivePort implements Stream<dynamic>` |
| `RawReceivePort` | `isolate.dart:992` | `abstract interface class` |
| `TransferableTypedData` | `isolate.dart:1065` | `external factory`; cross-isolate single-use resource |

### `Isolate.run` line by line

`isolate.dart:253-315`:

1. Creates a `Completer<R>` and a `RawReceivePort` (`:257-258`).
2. Installs a handler that distinguishes three cases (`:259-286`):
   - `null` → the isolate exited without sending a result → `RemoteError`
     ("Computation ended without result").
   - `List` of length 2 → `[error, stack]`; a typed `StackTrace` means the error
     came from the `onError` listener, two strings mean an uncaught asynchronous
     error (`:270-284`).
   - `List` of length 1 → the successful result.
3. Calls `Isolate.spawn(_RemoteRunner._remoteExecute, _RemoteRunner<R>(computation, resultPort.sendPort), onError: …, onExit: …, errorsAreFatal: true)` (`:287-297`).
4. Closes the port and fails the future if the send fails asynchronously
   (`:298-310`).

Two consequences matter for DWI:

- **The closure is shipped, not the function alone.** `_RemoteRunner` carries the
  computation, which means `Isolate.run` already relies on the VM being able to
  send a closure between isolates in the same group. Any web design that cannot
  serialise closures cannot match this API exactly.
- **`run` is built on `spawn`.** There is no separate fast path; startup cost is
  spawn cost.

## 2. Isolate groups and heap ownership

`IsolateGroup` is declared at `runtime/vm/isolate.h:321`. It owns:

- `std::unique_ptr<Heap> heap_` (`isolate.h:971`, accessor `heap()` at `:346`,
  setter at `:905`),
- `ObjectStore* object_store_` (constructor `:324`),
- the class table (`:442`),
- `IsolateGroupSource` (`:336`), i.e. the shared kernel/script source.

`Isolate` itself (`isolate.h:1060`) has no heap member; it reaches the heap
through its group. Spawned isolates that join an existing group therefore share
the heap and the object store, while isolates in a different group do not.
`CanShareObjectAcrossIsolates` (`runtime/vm/object_graph_copy.h:15`) permits
sharing only for **deeply immutable** objects.

This is precisely the property a browser cannot provide: two workers, or a
worker and the page, never share a heap or an object store. Wasm shared memory
(see R005) shares bytes, not a Dart object graph.

## 3. Ports

- `PortMap` is the VM-wide registry (`runtime/vm/port.h:34`): `CreatePort`,
  `ClosePort`, `GetIsolate`, `PortExists`, `IsReceiverInThisIsolateGroupOrClosed`
  (`port.h:37-75`). Port IDs are process-global.
- `SendPort.send` is the only cross-isolate send (`isolate.dart:908`); a
  `SendPort` implements `Capability` (`isolate.dart:849`), so possessing it is
  the authority to send.
- `ReceivePort` is a `Stream` facade over `RawReceivePort`
  (`sdk/lib/_internal/vm/lib/isolate_patch.dart:17-74`); the raw port is what the
  message handler actually enqueues onto.
- Ports may be sent inside messages (`kSendPortCid`,
  `runtime/vm/message_snapshot.cc:3079`), which is how a child isolate gets a
  channel back to its parent.

Web analogue: `MessagePort`/`MessageChannel` can be transferred once
(`message_snapshot` has no equivalent; see R003). A `SendPort` is a capability
that can be copied into any message repeatedly; a `MessagePort` is a transferable
endpoint with no clone semantics.

## 4. Message serialization

The entry point is:

```c++
std::unique_ptr<Message> WriteMessage(bool same_group, const Object& obj,
                                      Dart_Port dest_port,
                                      Message::Priority priority);
```

`runtime/vm/message_snapshot.h:16`, implemented at
`runtime/vm/message_snapshot.cc:3389`.

Two regimes:

- **Same group** (`same_group == true`): `CopyMutableObjectGraph(obj)`
  (`message_snapshot.cc:3396`). This makes a transitive copy while sharing
  deeply immutable objects (`object_graph_copy.h:15-30`). No re-parsing of a
  snapshot format is involved; objects are re-created in the target heap.
- **Across groups** (`same_group == false`): the full serializer writes a
  snapshot; the receiver deserialises it (`ReadMessage`,
  `message_snapshot.h:25`). Canonical objects are preserved by
  canonicalisation phases (`message_snapshot.cc:2086`, `:2185`).

Special-cased payloads include `SendPort` (`kSendPortCid`,
`message_snapshot.cc:3079`, `:3158`) and `TransferableTypedData`
(`kTransferableTypedDataCid`, `:3083`, `:3164`). The latter avoids copying:

`TransferableTypedData` is a "cross-isolate single-use resource"
(`isolate.dart:1057-1075`): `fromList` builds it, `materialize()` yields a
`ByteBuffer`, and the resource cannot be used twice. That is the VM's analogue
of a browser transferable `ArrayBuffer` — but at the granularity of a typed-data
payload, not an arbitrary graph.

Nothing in this path can serialise arbitrary closures across **groups**; closures
work in `Isolate.run` only because the spawned isolate is in the same group and
the graph copy preserves function objects and their captured context.

## 5. Errors and termination

- `Isolate.spawn(..., onError:, onExit:, errorsAreFatal:)`
  (`isolate.dart:461`) routes failures through ports.
- An uncaught error is delivered to `onError` as two strings (error text, stack
  text); `Isolate.run` converts them to `RemoteError` and attaches
  `RemoteError.stackTrace` (`isolate.dart:270-284`).
- An isolate that exits without sending anything reaches the `onExit` port as
  `null`, which `Isolate.run` maps to "Computation ended without result".
- `Isolate.kill` is a VM-patched external (`isolate.dart:560+`), i.e. immediate
  cancellation, not cooperative.

DWI consequence: browser workers give you an `error` event only for uncaught
errors that escape the worker's top-level handler, and `terminate()` is the only
kill. To match Dart's semantics the worker runtime must catch everything itself
and emit typed error envelopes (see R003).

## 6. What a worker backend can and cannot reproduce

| Property | VM | Browser worker | Notes |
| --- | --- | --- | --- |
| Separate execution thread | yes | yes (dedicated worker) | the one property that maps cleanly |
| No shared mutable Dart state | yes | yes, for a different reason | separate JS realms, not isolate groups |
| Send values | copy / transfer | structured clone / transfer | different type universe |
| Send closures | yes, same group | no (compiler problem, R004) | the fundamental gap |
| Send `SendPort` repeatedly | yes | no; `MessagePort` is transferable once | affects port-style APIs |
| Shared immutable data | yes (canonical objects) | only by copy | cost difference |
| `TransferableTypedData` | yes | `ArrayBuffer` transfer | closest match |
| Kill | `Isolate.kill` | `Worker.terminate()` | both abrupt |
| Error + stack | port + `RemoteError` | `error` event / custom envelope | needs a protocol |
| Startup cost | spawn | worker script fetch + instantiate | usually higher |

## 7. Constraints for the DWI design (no decisions)

1. A `run(closure)` API cannot be implemented faithfully by shipping the
   closure; it requires either a generated entrypoint (function selected by ID)
   or a compiler feature (R004/R007).
2. Anything described as a `SendPort` must be modelled as a capability that can
   be referenced by ID and routed, not as a single-use `MessagePort`.
3. `Isolate.kill` semantics can be approximated only by `terminate()`; there is
   no pause/resume.
4. `RemoteError`-style typed errors are constructible, but only from information
   the worker runtime captures itself.
5. Sharing immutable data is a copy in the browser; benchmarks must measure it.

## Unresolved

- Whether `Isolate.run` in the VM has a fast path that avoids a full spawn when
  the computation is trivial (no evidence found in `isolate.dart`; treat as no).
- Exact cost of `CopyMutableObjectGraph` versus cross-group serialisation for
  realistic payloads (needs a VM benchmark; out of scope for M001).
- Whether `spawnUri` has any web-relevant analogue beyond loading a second
  worker script (design question, not a source question).

## Verification status

- **Verified**: all line citations above; `Isolate.run` implementation; port
  registry; isolate-group heap ownership; `CopyMutableObjectGraph` use for
  same-group messages; `TransferableTypedData` single-use semantics.
- **Unverified**: performance claims; closure serialisation across groups.
- **Could not determine from this clone**: VM-side `spawn` implementation
  details beyond its externals, because `runtime/vm/isolate.cc` was read only
  selectively; a deeper pass is deferred until a concrete design question needs
  it.
