# dwi_flutter

Flutter-facing helpers for [Dart Web Isolates](https://github.com/SoundSliced/dart-web-isolates).

```dart
import 'package:dwi_flutter/dwi_flutter.dart';

final primes = await computeParallel(DwiTasks.countPrimes, [100000, 200000]);
```

`computeParallel` runs one task per input on the shared DWI pool and returns the
results in input order. It is pure Dart and does not depend on Flutter.

Limits: calls already dispatched when one input fails keep running, because a
generated proxy exposes no cancel token. Web builds need DWI's worker build step
(see the `dwi_builder` README).

See `examples/flutter_counter` and `examples/flutter_jank_demo` in the repository.
