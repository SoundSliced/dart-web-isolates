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
cancellation. Use generated task proxies in Flutter web; the examples below
use native manual registration.

## Basic example

Runs a typed batch with `computeParallel` and returns the results in input order.


```dart
import 'package:dwi/dwi.dart';
import 'package:dwi_flutter/dwi_flutter.dart';

int doubleInput(Object? input) => (input as int) * 2;

Future<void> main() async {
  Dwi.registerTask('double', doubleInput);
  try {
    final result = await computeParallel(
      (int input) => Dwi.run<int>('double', input),
      [1, 2, 3],
    );
    print(result); // [2, 4, 6]
  } finally {
    await Dwi.close();
  }
}
```

## Advanced example

Configures the pool, keeps results in input order, returns an empty list for
empty input, and handles a typed worker error from a failed batch.


```dart
import 'package:dwi/dwi.dart';
import 'package:dwi_flutter/dwi_flutter.dart';

int square(Object? input) {
  final value = input as int;
  if (value < 0) throw ArgumentError.value(value, 'input');
  return value * value;
}

Future<void> main() async {
  Dwi.registerTask('square', square);
  await Dwi.configure(const DwiConfig(maxWorkers: 2));
  Future<int> runSquare(int value) => Dwi.run<int>('square', value);
  try {
    print(await computeParallel(runSquare, [3, 1, 2]));
    print(await computeParallel(runSquare, <int>[]));
    await computeParallel(runSquare, [3, -1, 2]);
  } on DwiException catch (error) {
    print('Batch failed: $error');
  } finally {
    await Dwi.close(drain: true);
  }
}
```

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)

## Bounded batches

`computeParallelBounded` runs at most `concurrency` calls from one batch at a
time (default 4, the `DwiConfig.maxWorkers` default; a value below 1 throws
`ArgumentError`). Results follow input order. The first failure stops new calls,
the already admitted calls are observed, and the first error is rethrown.
Plain futures cannot be cancelled, so admitted calls keep running. The limit
applies to one batch only; other work still competes for the global pool.

```dart
final squares = await computeParallelBounded(
  DwiTasks.sumTo,
  List<int>.generate(1000, (i) => i),
  concurrency: 8,
);
```

`computeParallel` keeps its eager behaviour: it submits every input at once
(ADR-025). Use `computeParallelBounded` for large batches (ADR-034).
