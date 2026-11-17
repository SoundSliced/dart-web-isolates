# dwi_native

Run work in Dart isolates through the native DWI backend.

Apps that also target the browser should use [dwi](https://pub.dev/packages/dwi)
for platform selection. To use the backend directly add `dwi_native` and
`dwi_core`, register a task in a `DwiTaskRegistry`, then pass it to
`NativeBackend`. Await the result and close the backend in `finally`.

The [dwi](https://pub.dev/packages/dwi) guide covers channels, cancellation,
stop events, restart and draining through the app-facing API.

## Basic example

Runs one task on a Dart isolate through the native backend, then prints the
backend capabilities.


```dart
/// Runs a task on a real Dart isolate through the native backend directly.
///
/// Application code usually uses `package:dwi`, which picks this backend on
/// native platforms; using it directly is useful in tests and tools.

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';

Future<void> main() async {
  final registry = DwiTaskRegistry()
    ..register('sum', (input) {
      final limit = input! as int;
      var total = 0;
      for (var i = 1; i <= limit; i++) {
        total += i;
      }
      return total;
    });

  final backend = NativeBackend(registry);
  try {
    final sum = await backend.run('sum', 1000);
    print('sum(1000) = $sum');

    final capabilities = await backend.capabilities();
    print(
      'backend: ${capabilities.backend.name}, '
      'protocol: v${capabilities.protocolVersion}, '
      'cancellation: ${capabilities.cancellation.name}',
    );
  } finally {
    await backend.close();
  }
}
```

## Advanced example

Configures the backend, opens a dedicated handle for several calls, pings it,
and closes the handle before the backend.


```dart
import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';

int _total = 0;

int accumulate(Object? input) => _total += input as int;

Future<void> main() async {
  final registry = DwiTaskRegistry()..register('accumulate', accumulate);
  final backend = NativeBackend(registry);
  try {
    await backend.configure(const DwiConfig(maxWorkers: 2));
    final worker = await backend.spawnHandle();
    try {
      print(await worker.run('accumulate', 2)); // 2
      print(await worker.run('accumulate', 3)); // 5
      print(await worker.ping());
    } finally {
      await worker.close();
    }
  } finally {
    await backend.close();
  }
}
```

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
