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

/// How much [summarise] reports. Enums cross the worker boundary (ADR-021).
enum Detail {
  /// The count only.
  brief,

  /// The count and the limit it was computed for.
  full,
}

/// Takes several values as one record: the typed way to hand a task what a
/// closure would have captured (ADR-021).
@DwiTask()
String summarise((int limit, Detail detail) request) {
  final count = calculatePrimes(request.$1);
  return switch (request.$2) {
    Detail.brief => '$count primes',
    Detail.full => '$count primes up to ${request.$1}',
  };
}

/// Reports progress while counting primes in chunks (ADR-022).
///
/// Each item is the number of primes found so far; the last one is the total.
@DwiTask()
Stream<int> primeProgress(int limit) async* {
  const steps = 4;
  for (var step = 1; step <= steps; step++) {
    yield calculatePrimes(limit * step ~/ steps);
  }
}

/// A directly discoverable class static task (ADR-020).
abstract final class Greetings {
  /// Builds a greeting in the worker.
  @DwiTask()
  static String describe(String name) => 'Hello, $name!';
}
