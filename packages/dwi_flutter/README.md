# dwi_flutter

Run a batch of typed DWI tasks from Flutter and collect results in input order.

Add `dwi_flutter` and set up an annotated task following the
[dwi quick start](https://pub.dev/packages/dwi). Then call:

```dart
final values = await computeParallel(DwiTasks.sumTo, [10, 20, 30]);
```

Import `package:dwi_flutter/dwi_flutter.dart` and the app's generated
`dwi_tasks.g.dart`. DWI settings govern worker concurrency. An empty
input gives an empty list. A failed call fails the batch while dispatched
calls continue. Use individual cancellable worker calls when you need
cancellation.

The basic example runs a typed batch in a native process. The advanced
example configures the pool and handles a typed worker error. Both are
standalone and use native manual registration. Use generated task proxies
in Flutter web.

[Advanced example source](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi_flutter/example/dwi_flutter_advanced.dart)

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
