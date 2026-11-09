# scoped_worker

`DwiWorker.using` spawns a dedicated handle, runs one callback with it, and
closes the handle when the callback returns or throws (ADR-015). It is sugar
over `spawn()` plus `try`/`finally`; worker-local state still persists between
calls inside the scope.

```dart
final values = await DwiWorker.using((worker) async {
  final first = await worker.run<int>('counter');  // 1
  final second = await worker.run<int>('counter'); // 2
  return (first, second);
});
```

Run it on the VM:

```bash
dart pub get
dart run bin/main.dart
```

The helper does not await work the callback forgot to await: `close()` cancels
active calls and channels. Await what you need before returning.

For a single call that must not touch pooled state, `Dwi.runFresh` applies the
same ownership rule (ADR-016):

```dart
final value = await Dwi.runFresh<int>('counter'); // fresh context, always 1
```
