# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `DwiWorker.using` (ADR-015): a scoped helper that spawns one dedicated
  handle, awaits the callback's `FutureOr<R>` value, and closes that handle on
  every path. Spawn failures propagate unchanged; a callback error is rethrown
  with its original stack even when cleanup also fails (the cleanup error is
  reported to the current zone); closing inside the callback is allowed because
  `close()` is idempotent. The helper does not wait for unawaited work — on exit
  `close()` cancels it. `examples/scoped_worker/` shows the shape.
- `Dwi.runFresh` (ADR-016, DWI-4 increment 1): runs exactly one task in a fresh
  dedicated context and closes it before completing, so no worker-local state is
  shared between calls on either backend. Composed from `DwiWorker.using`; no
  backend or protocol change. `Dwi.run` keeps its pooled semantics.
- No backend or protocol change. Not published: consumers receive this only in
  the next release.

## [0.5.3] - 2026-11-08

Dependency and metadata patch for `dwi_builder` and `dwi_native`. No public DWI
API, handle, channel or protocol changes.

### Changed

- `dwi_builder` now depends on `analyzer: ^14.0.0` (resolved to 14.7.0), two
  majors ahead of the previous `^10.1.0`, which restores the pub.dev
  dependency-freshness points. Discovery was ported to the analyzer 14 API:
  AST `NamedExpression` is now `NamedArgument`, and
  `AnalysisContextCollection` no longer accepts `excludedPaths` (analyzer 14
  deprecates it in favour of `analysis_options.yaml` excludes; discovery already
  filters excluded files before handing paths to the analyzer). Discovery
  results, generated output, diagnostics and the public API are unchanged, and
  the builder suite passes against 14.7.0.
- The other six packages are version-bumped only.

### Fixed

- `dwi_native`'s description was 48 characters, below the 50-character minimum
  pub.dev analysis enforces; it is now 73. Metadata only; no code changes.

## [0.5.2] - 2026-11-07

Example-only patch. No public API, protocol or behavioural changes.

### Added

- `example/` in every package, so the pub.dev Example tab shows working usage
  of `dwi`, the annotation, the builder, the core abstractions, both backends
  and the wire protocol. This also completes the pub.dev points: the missing
  `0/10: Package has an example` was the only deduction at 0.5.1.

## [0.5.1] - 2026-11-07

Discovery-only patch. No public API, protocol or behavioural changes; the
`0.5.0` artefacts are otherwise identical.

### Changed

- All seven packages declare pub.dev `topics` (`isolate`, `concurrency`,
  `web-worker`, `wasm`) so they are reachable from topic listings rather than
  only by exact name.

### Fixed

- The repository URL was unreachable while
  `https://github.com/SoundSliced/dart-web-isolates` was private, which made
  pub.dev report `Repository URL doesn't exist` in the pub points analysis and
  left every package page with a dead source link. The repository is now public
  and the analysis re-runs against it with this release.

## [0.5.0] - 2026-11-06

Long-lived worker handles under ADR-013. All additive: `Dwi.run` keeps its
signature, pool behaviour and semantics.

### Added

- `DwiWorker.spawn()` with `run<R>`, `runCancellable<R>`, `state`, `isUsable`,
  `restart()` and `close()`. One handle owns one persistent isolate (native) or
  one dedicated Web Worker (web), independent of the `Dwi.run` pool.
- Worker-local state is retained between calls on one handle; separate handles
  have separate state. Losing the handle (close, timeout, crash, heartbeat
  failure, running cancellation) loses that state; `restart()` starts fresh and
  never replays work.
- `DwiWorkerState` (`created`, `starting`, `ready`, `closing`, `closed`,
  `failed`) and typed errors `DwiWorkerClosedException`,
  `DwiWorkerFailedException`, `DwiWorkerStateException`.
- `DwiBackend.spawnHandle()` for backends; backends track live handles so
  `Dwi.close()` releases them.
- Contract tests across native, the `dwi` facade, and Chrome, Safari and Firefox
  (three page loads per engine from one shared assertion list), including
  timeout, crash, malformed message, heartbeat, cancellation, queue bounds and
  queue deadline, and restart settlement. All four engines now have a measured
  result: Chrome, Safari, Firefox and Edge pass three page loads each
  (`docs/browser-matrix.md`).
- `examples/stateful_worker/` and a committed native benchmark comparing handles
  with `Dwi.run` for retained-state work (`benchmarks/native_handle/`).
- DWI-3 channels (ADR-014): `DwiWorker.openChannel(name)` returns a named duplex
  `DwiChannel` with a single-subscription `messages` stream, `send`, `sendBytes`
  and `close`. Task code inside the worker finds the same channel with
  `DwiWorkerChannels.find(name)`. Delivery is FIFO per channel, sends complete
  when the peer enqueues them, and the acknowledgement window is bounded by
  `DwiConfig.channelBufferSize` (default 64): a full receiver rejects a send with
  `DwiChannelBufferException` instead of dropping or buffering without bound.
  Typed `DwiChannelStateException` and `DwiChannelClosedException` cover misuse;
  channels never survive `close()` or `restart()`.
- Channel coverage: `dwi_core` endpoint semantics, `dwi_web` dispatcher, real
  `dwi_native` isolate round trips incl. transfers, crash, restart and close, and
  the browser handle matrix in Chrome, Safari, Firefox and Edge.

### Changed

- Web dedicated handles fail on a non-object inbound message instead of leaving
  the call to time out.
- Protocol v2 adds the channel message types and advertises
  `ready.meta.capabilities = {protocolVersion: 2, channels: true}`. Existing
  worker artefacts must be rebuilt (`dwi build`); a v1 artefact is rejected with
  `DwiUnsupportedException` rather than silently lacking channels.
- Channel messages carry a per-channel generation, so closing and reopening a
  name cannot route a late reply into the new channel.

### Documentation

- Release notes for 0.5.0: `docs/release-notes-0.5.0.md` (prepared; packages are
  not published yet).
- ADR-013 in `docs/architecture.md`; `docs/api-proposal.md`,
  `docs/compatibility-matrix.md`, `docs/limitations.md` and
  `docs/benchmarks.md` updated for the handle contract and measurements.
- Fresh typed-proxy build ordering re-measured on Flutter 3.47.6 with a writable
  SDK; `tooling/proxy_gate` reproduces the first-build failure and the
  succeeding second build, so the limitation cannot silently go stale
  (`audit/evidence/flutter-fresh-build-gate-2026-11-05.txt`).
- Worker replacement during development re-measured: a hot reload rebuilds the
  worker artefact but the live page keeps running the old worker; a hot restart
  or page reload is required. v0.5 does not replace a running worker
  automatically (ADR-009 amendment,
  `audit/evidence/flutter-worker-replacement-2026-11-05.txt`).
- ADR-014 defines DWI-3 channels; `docs/protocol.md` is protocol v2,
  `docs/api-proposal.md` carries the channel surface, and `docs/limitations.md`
  and `docs/compatibility-matrix.md` record what channels are not
  (`SendPort`/`ReceivePort` parity, broadcast, cross-channel ordering).

## [0.4.0] - unreleased

Cancellation, transferable bytes and crash detection, under ADR-010. All
additive: `Dwi.run` keeps its signature and semantics.

### Added

- `Dwi.runCancellable<R>(task, input)` returning `DwiCancellableTask<R>`
  (`result`, `cancel()`, `isDone`). Queued cancellation removes the waiter;
  running cancellation terminates the web worker or kills the native isolate.
  `DwiCancelledException` is delivered through `result` only, and `cancel()`
  never throws (ADR-010 §10.1).
- `DwiTransferableBytes`: binary payloads move instead of copying, for arguments
  and for values returned by the worker. Views that do not span their buffer are
  copied to exact size at construction; a successful send detaches the sender
  and a second send throws `DwiSerializationException` (ADR-010 §10.2).
- Heartbeat-based crash detection: idle workers are pinged, a worker that misses
  `DwiConfig.heartbeatMisses` consecutive pings is replaced lazily, and startup
  retries stay bounded (ADR-010 §10.3).
- `DwiConfig.heartbeatInterval` (5 s) and `DwiConfig.heartbeatMisses` (2).
- `DwiCapabilities.cancellation` (`none`/`queued`/`running`) and
  `transferables: true` on web.
- `dwi_builder` accepts `DwiTransferableBytes` as a task parameter and result.
- Committed browser harness `benchmarks/browser_matrix` with methodology, and
  Chrome evidence in `audit/evidence/browser-matrix-chrome-2026-11-04.json`.

### Changed

- The native backend now keeps an `Isolate.spawn` handle per call so a task can
  be cancelled and a timeout can kill the isolate instead of abandoning it.
- Web capability reporting: `transferables` is `true` (it was `false` while the
  copy-only path was the only one).

### Fixed

- A **dart2wasm application can now host DWI**. `flutter build web --wasm`
  packaged the worker correctly, but the app failed at the first envelope with
  `message.v must be an int` because an integral JS number can arrive as
  `double` across the wasm/JS boundary. `DwiEnvelope.fromMap` now coerces
  integral doubles for `v`, `id` and `error.taskId` and still rejects
  fractional numbers; measured in Chrome 156 on Flutter 3.47.6 stable.
- `dart compile js` companion files (`<temp>.deps`, `<temp>.map`) no longer leak
  next to the published worker or into `build/web`.
- Worker artefacts and generated files are published atomically, and builds for
  one project are serialized, so an overlapping CLI and Flutter hook build
  cannot lose the last valid artefact or publish stale outputs.

### Known limitations measured in this release

- **Flutter hot reload does not replace a running worker**: it rebuilds the
  artefact on disk, but the page keeps its existing `Worker`. Hot restart
  reloads the page and picks the new worker up, and in release mode neither key
  reloads the page at all. Measured on Flutter 3.47.6 stable with `-d chrome`
  and `-d web-server`; see `docs/limitations.md` §16.

## [0.3.1] - unreleased

Correctness and lifecycle pass over the automatic-worker pipeline. No public
Dart API was removed; `DwiConfig.queueTimeout` is additive (ADR-012).

### Added

- Generated proxies register their own native implementations, so
  `DwiTasks.foo(input)` runs on an isolate on the VM with no manual
  `Dwi.registerTask` (ADR-011).
- Generated, type-directed payload codecs for input (worker side) and result
  (proxy side): nullable and nested `List`/`Set`/`Map<String, V>`, typed data,
  and precise `DwiSerializationException` paths. Typed collections now
  round-trip in Chrome and on native.
- `DwiConfig.queueTimeout`: queue waiting is bounded separately from
  `taskTimeout` and `startupTimeout` (ADR-012).
- Manifest `artifactDigest`; `dwi check` rejects missing, truncated or corrupt
  worker artefacts and `dwi build` rebuilds them.
- Browser regression tests (Chrome via CDP) for collection conversion and for
  pool recovery after timeout, queue overflow, close, oversized payload and
  startup failure.
- Tests for generated native dispatch, imported-type compilation, artifact
  corruption, failed-compilation preservation, compiler-identity hashing,
  package-resolution invalidation, and watch over dependencies outside
  `--include`.

### Fixed

- `Uint8List`/imported and qualified types produced invalid generated source;
  types are now captured from the analyzer's resolved element model with
  deterministic, qualified imports.
- Generated proxies no longer raise `DwiUnknownTaskException` on the VM.
- Worker `close()` settles queued and in-flight requests promptly and is
  idempotent; a closed pool can be reconfigured and reused.
- `messageerror` is handled; terminated workers settle their pending requests;
  repeated startup failures are capped instead of restarting in a loop.
- Native task failures are delivered as `DwiRemoteException` with remote type
  and stack instead of leaking the remote error object.
- The worker hash now covers the selected compiler's identity, the DWI runtime
  and generator sources, and `package_config.json`; the watcher follows the
  dependency closure and rebuilds when inputs change during a build.
- Compilation publishes by rename, so a failed compile never overwrites a
  previously valid artefact.

### Known limitations

- Flutter 3.47.6 runs web build hooks concurrently with `dart2js`. A fresh
  project with no `lib/dwi_tasks.g.dart` can fail its first
  `flutter build web` before the hook writes the proxy; generate once with
  `dart run dwi_builder:dwi build` (or `dwi build --flutter-build`) first.
  Evidence: `audit/evidence/flutter-fresh-build-ordering-2026-11-04.txt`.

## [0.3.0] - unreleased

### Added

- `dwi_annotations` with the `@DwiTask({String? name})` marker.
- `dwi_builder` Flutter web build hook (`hook/build.dart`, ADR-009). With
  `dwi_builder` as a normal dependency, `flutter run -d chrome` and
  `flutter build web` generate and compile the worker automatically; no separate
  DWI command is required. Tested on Flutter 3.47.6.
- `dwi_builder`: analyzer-based discovery of annotated top-level functions,
  deterministic worker/proxy/manifest generation, `dart compile js`
  compilation, SHA-256 content-hash caching, and the
  `build`/`generate`/`check`/`watch`/`clean` CLI.
- `dwi_web` worker runtime (`DwiWorkerRuntime`, `DwiWorkerDispatcher`,
  `DwiWorkerTask`) for generated entrypoints, with VM-testable protocol
  dispatch.
- Typed generated proxies (`DwiTasks.calculatePrimes(input)`) and a generated
  worker manifest.
- Build-time diagnostics `DWI001`–`DWI010` for unsupported signatures,
  duplicate tasks, non-transferable types, non-worker-safe imports and
  compilation failures.
- `examples/automatic_worker`, verified in Chrome.
- `research/R013_RUNTIME_WORKER_COMPILATION.md`, ADR-008 and
  `docs/automatic-workers.md`.
- 20 `dwi_builder` tests, 8 worker-runtime tests, and facade/annotation tests.

### Changed

- `DwiConfig.workerScript` now defaults to `dwi/worker.dart.js`, matching the
  generated artefact; explicit configuration is optional.
- The `DwiTask` typedef is renamed `DwiTaskFunction`; `@DwiTask` is now the
  annotation exported by `package:dwi/dwi.dart`.
- `package:dwi` depends on and re-exports `dwi_annotations`.
- All packages now declare version `0.3.0`.

### Fixed

- Worker-pool callers queued behind a task no longer starve when a worker times
  out, fails to start, or crashes. Termination and failure now hand capacity to
  waiting callers and spawn replacement workers.
- A synchronous `postMessage` failure (for example `DataCloneError`) no longer
  leaves a worker slot permanently busy.
- Non-cloneable payloads (closures, class instances, enums, non-String map keys)
  now fail with `DwiSerializationException` in both directions instead of being
  silently delivered as `{}`.
- `WebBackend.capabilities()` reports `transferables: false`; v0.3 does not
  implement transfer semantics.
- Discovery rejects types that cannot round-trip in v0.3 (`List<int>`,
  `Map<String,int>`, `Set<int>`, classes, enums, `DateTime`, unknown interface
  types) instead of generating a proxy that fails at runtime.
- `dwi build --no-compile` no longer prints a manifest path as if a manifest had
  been written. Documentation now states that the manifest is a compilation
  output.

- `DwiConfig.maxPayloadBytes` is now enforced approximately by the host before
  sending and by the worker for results; oversized payloads fail with
  `DwiSerializationException` instead of crossing the boundary.

### Known limitations (v0.3)

- Plain `flutter build web` now triggers worker generation and compilation when
  `dwi_builder` is a normal dependency and Flutter exposes web build hooks
  (measured on Flutter 3.47.6). Older Flutter versions still need
  `dwi build`/`dwi build --flutter-build`.
- No closures, function tear-offs, `Dwi.run(fn)` or runtime compilation.
- No Wasm worker generation, hot reload of a running worker, or Flutter
  `compute()` integration.
- Only Chrome has been measured.

## [Unreleased]

### Added

- Repository scaffolding, governance documents and the engineering rules in
  `AGENTS.md`.
- Phase 0 evidence base: `docs/current-state-2026.md`, `docs/prior-art.md` and
  research reports R001–R010, grounded in `dart-lang/sdk` @ `e21f9245`, the local
  Flutter SDK, `package:web` 1.1.2, MDN sources and reproducible probes.
- `experiments/dart_worker_poc` (M001): Flutter Web demo comparing CPU work on
  the main thread against a Web Worker, with ticker-based frame measurement,
  headless `?auto=1` mode, raw evidence JSON and an error-propagation probe.
- `M001_FINDINGS.md` with the verdict **PASS WITH LIMITATIONS** (Chrome measured;
  Firefox/Safari/Edge unverified).
- `docs/architecture.md` (ADR-001…007), `docs/api-proposal.md`,
  `docs/protocol.md`, `docs/critical-review.md`, `docs/limitations.md`,
  `docs/compatibility-matrix.md`, `docs/dart-isolate-semantics.md`,
  `docs/serialization.md`, `docs/compiler-strategy.md`,
  `docs/upstream-strategy.md`, `docs/benchmarks.md` and
  `docs/browser-matrix.md`.
- Packages `dwi_protocol`, `dwi_core`, `dwi_native`, `dwi_web` and `dwi`:
  versioned envelopes, typed errors, task registry, isolate backend, pooled
  worker backend with startup/task timeouts, and a conditional-import facade.
- Unit tests for protocol, core, native and facade (29 tests), plus a browser
  integration test that exercises the protocol end to end.
- `examples/fibonacci` and a measured benchmark table.

### Known limitations

- Only Chrome 156 has been measured; Firefox, Safari and Edge remain unverified.
- Named precompiled tasks only; no closures or arbitrary functions.
- JS backend only; no Wasm worker.
- Worker compilation is a separate build step.
- `dart2wasm`, ports, cancellation and pooling policies are proposed, not
  shipped.

<!-- Packages are versioned independently and keep their own CHANGELOG.md. -->
