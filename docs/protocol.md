# DWI Protocol v1

Status: specification for the v0.2/v0.3 implementation; wire version unchanged. Wire changes require a version
bump and an ADR.

## Transport

A dedicated worker receives `postMessage` values that are structured-cloneable.
Every message is a plain object:

```text
{
  "v": 1,
  "type": "<message type>",
  "id": <int|null>,
  "task": "<task name|null>",
  "payload": <cloneable value|null>,
  "error": { ... } | null,
  "meta": { "workerId": "<string>", "ts": <epoch ms> }
}
```

Rules:

- `v` is mandatory on every message. A receiver that sees an unknown major
  version replies with `error {code: "protocol", fatal: true}` and stops.
- `id` is a monotonically increasing positive integer chosen by the host and
  echoed by the worker. `0` and `null` are reserved for worker-initiated
  messages (`ready`, `heartbeat`, `closed`).
- `payload` must be structured-cloneable (see `serialization.md`). Binary data
  may be transferred; the sender must drop its reference afterwards.
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

## Error object

```text
{
  "code": "remote" | "timeout" | "protocol" | "unknown-task" | "serialization" | "internal",
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
- The worker advertises `protocolVersion` in `ready.meta.capabilities`; the host
  refuses to continue on a mismatch.

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
- The protocol is transport-agnostic in principle, but v1 assumes
  `postMessage` semantics (structured clone, one sender/receiver pair).
