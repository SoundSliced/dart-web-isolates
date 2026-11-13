# Dispatch control and ping

`Dwi.pause()` holds new `Dwi.run`, `runCancellable` and `runFresh` calls
(generated proxies included) until `Dwi.resume()`; calls already running keep
going. `DwiWorker.ping()` measures a round trip to a dedicated worker and
times out while a synchronous task holds its event loop (ADR-028). Runs on the
native backend; the same API works in the browser.

```sh
dart pub get
dart run bin/main.dart
```

Expected output (timings vary):

```
paused: true, 3 calls held
[resized a.png, resized b.png, resized c.png]
idle ping: 180 µs
busy ping: no answer within 100 ms (synchronous work)
worker still usable: true
```
