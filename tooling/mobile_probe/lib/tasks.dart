import 'package:dwi_annotations/dwi_annotations.dart';

/// Counts primes up to [limit] with a sieve.
@DwiTask()
int countPrimes(int limit) {
  final composite = List<bool>.filled(limit + 1, false);
  var count = 0;
  for (var i = 2; i <= limit; i++) {
    if (composite[i]) continue;
    count++;
    for (var j = i * i; j <= limit; j += i) {
      composite[j] = true;
    }
  }
  return count;
}

/// Joins a label and a count (a task with two parameters, ADR-029).
@DwiTask()
String joinParts(int count, String label) => '$label$count';

/// A future-returning task with an encoded result.
@DwiTask()
Future<List<int>> spread(int start, int count) async =>
    List<int>.generate(count, (index) => start + index);

/// A stream task (ADR-022).
@DwiTask()
Stream<int> countBetween(int from, int to) async* {
  for (var value = from; value <= to; value++) {
    yield value;
  }
}

/// Not annotated: discovered from its `DwiFunctions` call site (ADR-030).
int twiceByReference(int value) => value * 2;
