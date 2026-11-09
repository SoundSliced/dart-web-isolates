# DWI 0.6.0 — release notes (prepared, not published)

Status: **published to pub.dev on 2026-11-08.** All seven packages uploaded in
the dependency order below at `0.6.0`. This is a minor release; the new public
APIs do not exist in `0.5.3`.

| Package | Version | Upload order |
| --- | --- | --- |
| `dwi_annotations` | 0.6.0 | 1 |
| `dwi_core` | 0.6.0 | 2 |
| `dwi_protocol` | 0.6.0 | 3 |
| `dwi_native` | 0.6.0 | 4 |
| `dwi_web` | 0.6.0 | 5 |
| `dwi_builder` | 0.6.0 | 6 |
| `dwi` | 0.6.0 | 7 |

Upload in that order: each package's `^0.6.0` constraints must already be
satisfiable on pub.dev. `dwi` depends on `dwi_annotations`, `dwi_core`,
`dwi_native` and `dwi_web`; `dwi_builder` depends on `dwi_annotations`;
`dwi_native` and `dwi_web` depend on `dwi_core`, and `dwi_web` also on
`dwi_protocol`.

## Highlights

### 1. Scoped worker lifetime helper (`DwiWorker.using`, ADR-015)

One handle, owned by the helper, for one block of work:

```dart
final values = await DwiWorker.using((worker) async {
  final first = await worker.run<int>('counter');   // 1
  final second = await worker.run<int>('counter');  // 2
  return (first, second);
});
```

The callback receives a live handle, its `FutureOr<R>` result is awaited, and
the handle is closed on every path. Spawn failures propagate unchanged without
entering the callback. Unawaited work is not tracked and may be cancelled at
scope exit. Closing the handle inside the callback is allowed because `close()`
is idempotent.

If the callback and `close()` both fail, the callback error remains the returned
future's error (same object) and the cleanup failure is appended to its stack
trace. It is not swallowed, does not replace the callback error, and is not
reported as an uncaught zone error.

### 2. Fresh-context one-shot call (`Dwi.runFresh`, ADR-016)

```dart
final value = await Dwi.runFresh<int>('primes', 5000000);
```

`Dwi.run` is a pool; on web it may reuse an idle worker, so worker-local state
can persist between calls. `runFresh` spawns one dedicated context, runs exactly
one task and closes it before completing, so two calls never share a context on
native or web. Startup is paid per call. This is the first DWI-4 increment and
is **not** `dart:isolate` parity or `Isolate.run(fn)`; closures remain open.

## Compatibility

No protocol or backend change. `Dwi.run`, `DwiWorker` handles, channels,
cancellation, transferables and typed errors keep their contracts. The only
behaviour correction is the double-failure path described above.

## Verification

- `dart analyze`: zero issues in every package.
- Per-package `dart test` suites pass.
- Checkout browser matrix (`packages/dwi_builder/test/browser_scoped_test.dart`):
  Chrome 157.0.8103.38, Safari 26.5, Firefox 159.0.1 and Edge 157.0.4341.42,
  2/2 runs each.
- Published-consumer regression fixture
  (`tooling/hosted_consumer/run.sh`): exits 0 on the same four engines at the
  site root and under `/sub/app/` against the published **0.6.0** packages
  (hosted resolution, no path overrides). The page observes `runFresh [1,1]`,
  one `using` scope `[1,2]`, an explicit handle `[1,2]`, channel `echo:ping`,
  a typed `DwiRemoteException` followed by success, and the worker asset fetch.
- `dart pub publish --dry-run` for all seven packages: see the release review.

## Known limits

See `docs/limitations.md` and `docs/compatibility-matrix.md`. In particular:
`runFresh` still selects by task name; there is no closure execution (DWI-5),
no Wasm worker backend, no `SenderPort`/`ReceivePort` parity, and no graceful
drain.
