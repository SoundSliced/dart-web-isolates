/// Declares worker tasks with `@DwiTask`.
///
/// The annotation is a marker only: it has no runtime behaviour. `dwi_builder`
/// discovers these functions, generates the worker entrypoint and emits typed
/// caller proxies, so no worker `main()` or registry is written by hand.
library;

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
