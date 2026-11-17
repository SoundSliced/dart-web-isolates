# dwi_annotations

Declare tasks and transferable payload shapes for the DWI generator.

Add `dwi_annotations` as an app dependency and set up
[dwi_builder](https://pub.dev/packages/dwi_builder). Put annotated
declarations in `lib/` so the builder can discover them.

```dart
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int doubleIt(int value) => value * 2;
```

Run `dart run dwi_builder:dwi build`; then import `dwi_tasks.g.dart` and
call `await DwiTasks.doubleIt(21)`.

Tasks are public top-level functions or eligible public static methods.
Use zero arguments or one required positional argument. Use a record to
group several inputs. `@DwiTask(name: '...')` changes the runtime task name.
Annotations mark declarations for generation.

`@DwiPayload` marks a class that crosses the worker boundary. Payload classes
need a public unnamed constructor and a matching public field or getter for
each constructor parameter. The generator reconstructs the value on the
receiving side.

## Basic example

Declarations are marked for generation. The annotated functions below still run
as plain Dart when called directly, which is how this program prints them.


```dart
/// Declares worker tasks with `@DwiTask`.
///
/// The annotation is a marker only: it has no runtime behaviour. `dwi_builder`
/// discovers these functions, generates the worker entrypoint and emits typed
/// caller proxies, so no worker `main()` or registry is written by hand.

import 'package:dwi_annotations/dwi_annotations.dart';

/// Uses the function name, `countPrimes`, as the task name:
/// `Dwi.run('countPrimes', 1000)`.
@DwiTask()
int countPrimes(int limit) {
  var count = 0;
  for (var n = 2; n <= limit; n++) {
    if (_isPrime(n)) count++;
  }
  return count;
}

/// Overrides the task name: `Dwi.run('wordCount', 'some text')`.
@DwiTask(name: 'wordCount')
int countWords(String text) =>
    text.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;

/// A task may also be asynchronous, and may take no input.
@DwiTask()
Future<int> answer() async => 42;

bool _isPrime(int n) {
  for (var d = 2; d * d <= n; d++) {
    if (n % d == 0) return false;
  }
  return true;
}

Future<void> main() async {
  // Calling the functions directly shows what the worker will compute. Inside
  // a DWI worker they are invoked with the task input instead.
  print('primes below 100: ${countPrimes(100)}');
  print('words: ${countWords('dwi runs work in dedicated workers')}');
  print('answer: ${await answer()}');
}
```

## Advanced example

Shows a record input, a `@DwiPayload` class and a static stream task.


```dart
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiPayload()
class Range {
  const Range(this.start, this.end);
  final int start;
  final int end;
}

class RangeTasks {
  @DwiTask()
  static Stream<int> count(Range range) async* {
    for (var value = range.start; value <= range.end; value++) {
      yield value;
    }
  }
}

@DwiTask()
int area((int, int) size) => size.$1 * size.$2;

Future<void> main() async {
  print(area((3, 4)));
  await for (final value in RangeTasks.count(const Range(1, 3))) {
    print(value);
  }
}
```

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
