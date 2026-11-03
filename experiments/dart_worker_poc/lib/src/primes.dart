/// Prime sieve shared by the main-thread path and the worker entrypoint.
///
/// This file must stay free of Flutter and browser imports so that it can be
/// compiled into both programs.
library;

import 'dart:typed_data';

/// Counts primes up to [limit] and returns the count.
int countPrimes(int limit) {
  final sieve = Uint8List(limit + 1);
  var count = 0;
  for (var i = 2; i <= limit; i++) {
    if (sieve[i] != 0) continue;
    count++;
    for (var j = i * i; j <= limit; j += i) {
      sieve[j] = 1;
    }
  }
  return count;
}
