# Cooperative cancellation

A task reads `DwiCancelToken.current` between steps and stops when the caller
cancels (ADR-027). Cancellation reaches the task only when
`DwiConfig.cancelGracePeriod` is set; a task that does not stop within that
period is terminated, as without it.

```sh
dart pub get
dart run bin/main.dart
```

Expected output (the step number varies):

```
host: cancel() -> true
host: result settled with DwiCancelledException
worker: stopped cleanly at step 10
```

The same task code works in a browser worker: the pooled worker is kept when
the task stops within the grace period. Web task libraries import
`DwiCancelToken` from `package:dwi_core/dwi_worker.dart`, because
`package:dwi/dwi.dart` cannot be compiled into a web worker.
