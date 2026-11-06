# DWI 0.5.0 — release notes (prepared, not published)

Status: **prepared, not released.** The packages are still marked `publish_to:
none` and `version: 0.3.0`; publishing requires the decisions listed at the end.
Everything below is implemented, tested and pushed on `main`.

## Highlights

### 1. Long-lived worker handles (`DwiWorker`, ADR-013)

One handle owns one persistent isolate (native) or dedicated Web Worker (web) for
its whole lifetime, independent of the `Dwi.run` pool.

```dart
final worker = await DwiWorker.spawn();
try {
  final first = await worker.run<int>('counter', null);   // 1
  final second = await worker.run<int>('counter', null);  // 2
} finally {
  await worker.close();
}
```

- Worker-local state is retained between calls; two handles never share it.
- Calls run one at a time in FIFO order, bounded by `maxQueuedTasks` and
  `queueTimeout`.
- `close()` settles running and queued calls with `DwiWorkerClosedException`
  and is idempotent; `Dwi.close()` closes owned handles.
- A task timeout, crash, heartbeat failure, malformed message or running
  cancellation moves the handle to `failed`; `restart()` starts fresh state and
  never replays work.
- Transferables keep the ADR-010 ownership rules.

### 2. Channels (DWI-3, ADR-014)

Named duplex channels carry progress updates, multiple results and long-lived
conversations over one handle.

```dart
final progress = await worker.openChannel('progress');
progress.messages.listen((message) { /* updates, partial results, replies */ });
await progress.send({'step': 1});
await progress.sendBytes(DwiTransferableBytes(bytes)); // one-way transfer
await progress.close();
```

Task code finds the same channel by name:

```dart
final channel = DwiWorkerChannels.find('progress');
if (channel != null) await channel.send('half-way');
```

- Single-subscriber streams, FIFO per channel and direction.
- A send completes when the peer enqueues it; the window is bounded by
  `DwiConfig.channelBufferSize` (default 64) and a full receiver rejects with
  `DwiChannelBufferException` — nothing is dropped or buffered without bound.
- Typed `DwiChannelStateException` / `DwiChannelClosedException`; crashes,
  timeouts, cancellation, restart and `close()` settle every stream and pending
  send exactly once.
- **Not** `SendPort`/`ReceivePort` parity: no port objects, broadcast, shared
  memory, cross-channel ordering, or survival across close/restart.

### 3. Protocol v2

Channel message types plus `ready.meta.capabilities =
{protocolVersion: 2, channels: true}`. A per-channel generation prevents a late
reply from reaching a reopened channel name.

**Upgrade action:** rebuild worker artefacts with `dwi build`. A v1 artefact is
rejected with `DwiUnsupportedException` instead of silently lacking channels.

### 4. Browser evidence: four engines

The same handle + channel contract passes three page loads per engine:

| Engine | Version | Result |
| --- | --- | --- |
| Chrome | 156.0.8078.80 | pass, 3/3 |
| Safari | 26.5 | pass, 3/3 |
| Firefox | 159.0 | pass, 3/3 |
| Edge | 156.0.4314.58 | pass, 3/3 |

Evidence: `audit/evidence/handle-matrix-<engine>-20261106.json`. Engine-specific
setup (Firefox sandbox flags, Edge private home and automation flags) is in
`docs/browser-matrix.md`; no engine's result is inferred from another.

### 5. Flutter integration status (unchanged, now measured)

- **Fresh typed-proxy build:** a new app that imports `dwi_tasks.g.dart` still
  fails its first ordinary `flutter build web` (the hook runs after `dart2js`);
  run `dwi build` once first. Reproduce with `tooling/proxy_gate`.
- **Live worker replacement:** a hot reload rebuilds the worker artefact but the
  live page keeps the old worker; a **hot restart or page reload** is required.
  v0.5 performs no automatic replacement (ADR-009 amendment).

## Verification performed

- VM suites: `dwi_annotations` 2, `dwi_core` 32, `dwi_protocol` 14, `dwi_web` 23,
  `dwi_native` 46, `dwi` 17.
- `dwi_builder` suite: 52 passed, 1 skipped (Edge skip only when its binary is
  absent).
- `dart analyze` clean; `git diff --check` clean.
- Four-engine browser contract (above), each engine run separately.

## Known limitations

See `docs/limitations.md`. Release-relevant ones:

- No `dart:isolate` parity and no `SendPort`/`ReceivePort` emulation.
- No dart2wasm worker backend (dart2wasm **host** is measured in Chrome only).
- `flutter run` hot reload does not replace a running worker; `web-server` hot
  reload is unverified here (no Dart Debug Chrome extension).
- On a restricted host Edge needs `CFFIXED_USER_HOME`, a stable home and
  automation flags (harness-provided); Firefox needs its content sandbox
  disabled.
- The browser matrix is run one engine at a time; a single all-engine `dart test`
  invocation is memory-heavy.

## Publishing checklist (blocking)

1. Decide the published version (all pubspecs currently say `0.3.0`).
2. Replace `publish_to: none` with the intended target in each package.
3. Confirm pub.dev credentials and run `dart pub publish --dry-run` per package.
4. Date the `CHANGELOG.md` 0.5.0 section and link these notes.
5. Publish in dependency order: `dwi_annotations` → `dwi_core` →
   `dwi_protocol` → `dwi_native` / `dwi_web` → `dwi_builder` → `dwi`.
   Publishing is irreversible on pub.dev (only retraction is possible).
