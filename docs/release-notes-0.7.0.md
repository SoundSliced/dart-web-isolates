# DWI 0.7.0 — release notes (prepared, not published)

Status: **prepared for release review; not uploaded.** All seven packages move
to `0.7.0` together. This is a minor, additive release over published `0.6.0`;
no protocol change.

| Package | Version | Upload order |
| --- | --- | --- |
| `dwi_annotations` | 0.7.0 | 1 |
| `dwi_core` | 0.7.0 | 2 |
| `dwi_protocol` | 0.7.0 | 3 |
| `dwi_native` | 0.7.0 | 4 |
| `dwi_web` | 0.7.0 | 5 |
| `dwi_builder` | 0.7.0 | 6 |
| `dwi` | 0.7.0 | 7 |

Upload in that order: each package's `^0.7.0` constraints must already be
satisfiable on pub.dev. `dwi` depends on `dwi_annotations`, `dwi_core`,
`dwi_native` and `dwi_web`; `dwi_builder` depends on `dwi_annotations`;
`dwi_native` and `dwi_web` depend on `dwi_core`, and `dwi_web` also on
`dwi_protocol`.

## Highlights

### 1. Handle termination observation (`DwiWorker.stopReason`, `stops`, ADR-017)

```dart
final worker = await DwiWorker.spawn();
final subscription = worker.stops.listen((reason) => log('$reason'));
// ...
print(worker.stopReason); // null while healthy
await worker.close();
// callerClosed is delivered before the stream closes
```

- `DwiWorkerStop` has five reasons: `callerClosed`, `crashed`, `timedOut`,
  `cancelled`, `protocolViolation`.
- An idle crash that no call observed is now visible.
- One broadcast event per context generation; no replay. The first terminal
  cause wins. A queued-call timeout, a full queue, an unknown task, a call-local
  serialization failure and a task-level remote error emit nothing.
- `restart()` clears `stopReason` when the replacement starts. A failed restart
  throws the startup error and emits nothing.
- Observation only: existing typed call, channel and startup errors keep their
  contracts. No new error type and no protocol message.

### 2. Prompt close with paused observers

`close()` queues the final stop event and stream completion instead of awaiting
subscriber processing. A paused or slow listener can no longer hold worker
teardown after the context is released; it still receives the event before
`done` when it resumes, or it can cancel. This covers `Dwi.close()`, a
failed-then-closed handle and repeated close.

## Compatibility

- Additive public API in `dwi_core` and `dwi`; `dwi_native` and `dwi_web`
  implement it.
- No protocol or channel change. No existing API removed or renamed.
- Not `dart:isolate` `onExit`/`onError` parity: DWI's timeout, cancellation and
  restart generation have no `dart:isolate` equivalent.
- `dwi_annotations` and `dwi_protocol` have no API change but participate in the
  lockstep release. `dwi_builder` has no public change beyond its dependency
  constraint.

## Verification

- `dart analyze --fatal-infos`: zero issues in `dwi_core`, `dwi_native`,
  `dwi_web`, `dwi` and `dwi_builder`.
- `dart test`: `dwi_core` 32, `dwi_native` 62, `dwi_web` 23, `dwi` 38, all pass.
- `dwi_builder` non-browser suite: 47/47. Browser harnesses are run one engine
  at a time to avoid the documented parallel-suite contention.
- ADR-017 browser matrix (`browser_handle_test.dart`): three page loads pass in
  Chrome 157.0.8103.38, Safari 26.5, Firefox 159.0.1 and Edge 157.0.4341.42.
  Firefox requires disabling every per-process sandbox switch its build exposes
  under this host.
- Published-consumer fixture: the hosted `0.6.0` regression still passes in all
  four engines at the site root and `/sub/app/`. It cannot verify `0.7.0` until
  this release is published.
- Checkout consumer: `examples/stop_observer/` prints the public reason and
  stream event.
- `dart pub publish --dry-run` for all seven packages: see the release review.

## Remaining limits

- A released package cannot be exercised by the hosted fixture until after
  upload; the checkout example is the pre-release evidence.
- Firefox under this host needs the sandbox switches listed above; that is an
  automation environment requirement, not a browser capability claim.
- No `dart:isolate` parity claim. No dart2wasm worker backend; the existing
  dart2wasm **host** result is separate.
