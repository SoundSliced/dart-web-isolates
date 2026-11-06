# DWI Protocol v2

Status: v0.2–v0.5 surface plus DWI-3 channels (ADR-014). v2 adds the channel
message types and the `capabilities` object in `ready`. Wire changes require a
version bump and an ADR.

## Transport

A dedicated worker receives `postMessage` values that are structured-cloneable.
Every message is a plain object:

```text
{
  "v": 2,
  "type": "<message type>",
  "id": <int|null>,
  "task": "<task name|null>",
  "payload": <cloneable value|null>,
  "error": { ... } | null,
  "meta": { "workerId": "<string>", "channel": "<name>", "gen": <int>, "seq": <int> }
}
```

Rules:

- `v` is mandatory on every message. A receiver that sees an unknown major
  version replies with `error {code: "protocol", fatal: true}` and stops.
- `v`, `id` and `error.taskId` may arrive as an integral `double`, for example
  across a dart2wasm/dart2js boundary where `dartify()` surfaces a JS number as
  `double`. Receivers coerce integral values and still reject fractional ones;
  they never coerce a value to a different integer.
- `id` is a monotonically increasing positive integer chosen by the host and
  echoed by the worker. `0` and `null` are reserved for worker-initiated
  messages (`ready`, `heartbeat`, `closed`).
- `payload` must be structured-cloneable (see `serialization.md`). Binary data
  may be transferred; the sender must drop its reference afterwards.
- Channel messages carry `meta.channel` (name), `meta.gen` (the generation the
  host assigned when it opened the channel) and `meta.seq` (the per-channel send
  sequence). `gen` makes a late message for a closed channel distinguishable from
  a message for a channel that later reused the name.
- Unknown fields are ignored. Unknown `type` values produce a non-fatal `error`.

## Message types

| Type | Direction | Meaning | Required fields |
| --- | --- | --- | --- |
| `ready` | worker → host | runtime initialised, task registry available | `v`, `meta.capabilities` |
| `request` | host → worker | run `task` with `payload` | `id`, `task`, `payload` |
| `result` | worker → host | successful completion | `id`, `payload` |
| `error` | both | failed request or protocol violation | `id` (or 0), `error` |
| `cancel` | host → worker | cooperative cancellation request | `id` |
| `cancelled` | worker → host | task acknowledged cancellation | `id` |
| `heartbeat` | both | liveness check | `id` optional |
| `shutdown` | host → worker | stop accepting work, exit after queue drains | — |
| `closed` | worker → host | runtime is exiting | — |
| `channelOpen` | host → worker | open a named channel | `meta.channel`, `meta.gen`, `meta.bufferSize` |
| `channelOpened` | worker → host | channel accepted or refused | `meta.channel`, `meta.gen`, `meta.opened` (bool) |
| `channelMessage` | both | one channel message | `meta.channel`, `meta.gen`, `meta.seq`, `payload` |
| `channelAck` | both | the peer enqueued a message | `meta.channel`, `meta.gen`, `meta.seq` |
| `channelClose` | both | close a channel | `meta.channel`, `meta.gen` |
| `channelClosed` | both | close acknowledged | `meta.channel`, `meta.gen` |

## Channels (v2)

- A channel exists on both sides only after the host sent `channelOpen` with a
  fresh `gen` and the worker replied `channelOpened` with `opened: true`. The
  worker registers it in `DwiWorkerChannels` under the name.
- The worker accepts a `channelMessage` only when its receive buffer has room.
  An accepted message is acknowledged immediately with `channelAck`, which is
  what settles the sender's `send`. When the buffer is full the worker sends an
  `error` with `code: "channel"`, `meta.channel`, `meta.gen` and `meta.seq`; the
  sender fails that send with `DwiChannelBufferException` and nothing is lost or
  reordered.
- `gen` is checked on every channel message on both sides. A message with a gen
  different from the live channel of that name is ignored, so closing and
  reopening a name cannot route a stale reply into the new channel.
- A malformed channel message (no name/gen/seq, unexpected type) is a protocol
  violation: the host fails the handle.
- Channels never survive a reconnect or `DwiWorker.restart()`.
- Protocol v2 is required. A v1 worker asset does not implement these types; the
  host rejects `openChannel` with `DwiUnsupportedException` and `Dwi.run` fails
  on the version mismatch. Rebuild workers with `dwi build`.

## Error object

```text
{
  "code": "remote" | "timeout" | "protocol" | "unknown-task" | "serialization" | "internal" | "channel",
  "message": "<human readable>",
  "remoteType": "<Dart type name or empty>",
  "remoteStack": "<captured stack or empty>",
  "fatal": <bool>,
  "taskId": <int|null>
}
```

- `fatal: true` means the worker is no longer usable; the host must terminate it.
- `remoteStack` is produced by the worker's own error handler. An uncaught error
  inside a task must be caught by the dispatcher and converted into this object;
  letting it escape to the browser is a protocol violation.
- The host must never execute or interpolate `message`/`remoteStack` as code.

## Lifecycle

```text
host                          worker
 │  new Worker(url)             │
 │                             │  compile/init
 │◄──────────── ready ──────────│
 │──── request {id:1} ────────►│
 │◄──────────── result {id:1} ──│
 │──── request {id:2} ────────►│
 │◄──────────── error  {id:2} ──│
 │──── shutdown ──────────────►│
 │◄──────────── closed ─────────│
```

- A worker that does not send `ready` within `startupTimeout` is terminated and
  the caller gets `DwiStartupException`.
- A request that exceeds `taskTimeout` causes termination (there is no reliable
  way to pre-empt synchronous code) and `DwiTimeoutException`.
- Out-of-order completion is expected; correlation is by `id`.
- Multiple in-flight requests are allowed up to a configurable limit; beyond
  that the host queues them.

## Versioning

- Additive message types and optional fields: minor change, same `v`.
- Removing/renaming fields, changing semantics of `id` or `error.code`: major
  bump, new `v`.
- The worker advertises
  `ready.meta.capabilities = {protocolVersion: 2, channels: true}`; the host
  refuses channels (and a mismatched version) rather than silently degrading.

## Security requirements

1. `task` is matched against a fixed registry; it is never used to construct a
   function name, import path or `eval`.
2. Payloads are validated before dispatch (type check at the registry boundary).
3. A worker must enforce a maximum in-flight queue and a maximum payload size;
   exceeding either yields a non-fatal `error`.
4. Messages from `event.data` are treated as untrusted input even though the
   worker is same-origin.
5. The host must terminate workers on page unload where the environment allows
   it; otherwise the browser reclaims them.

## Compatibility notes

- The VM backend does not use this protocol internally; it maps the same public
  exceptions. A future VM implementation could adopt the envelope for parity.
- The protocol is transport-agnostic in principle, but v2 assumes
  `postMessage` semantics (structured clone, one sender/receiver pair).
- The native backend does not use envelopes internally; it carries the same
  channel operations as list messages (`channelOpen`, `channelMessage`,
  `channelAck`, `channelClose`, `channelClosed`, `channelError`) with the same
  name, generation and sequence fields.
