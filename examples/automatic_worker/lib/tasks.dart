import 'package:dwi_annotations/dwi_annotations.dart';

/// Counts primes up to [limit] with a sieve.
///
/// The worker entrypoint and its registry are generated; this function is the
/// only worker-specific code a developer writes.
@DwiTask()
int calculatePrimes(int limit) {
  if (limit < 2) return 0;
  final sieve = List<bool>.filled(limit + 1, false);
  var count = 0;
  for (var i = 2; i <= limit; i++) {
    if (sieve[i]) continue;
    count++;
    for (var j = i * i; j <= limit; j += i) {
      sieve[j] = true;
    }
  }
  return count;
}

/// A second task showing a renamed task and a String payload.
@DwiTask(name: 'greeting')
String describe(String name) => 'Hello, $name!';
