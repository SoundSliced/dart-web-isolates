import 'dart:async';

/// Runs [task] once for every element of [inputs] and completes with the
/// results in input order (ADR-025).
///
/// [task] is normally a generated typed proxy, so the input and output types
/// are checked at compile time. Concurrency is bounded by the DWI pool, not by
/// this function.
///
/// The call fails with the first error. Calls already dispatched keep running
/// and their results are discarded: a generated proxy exposes no cancel token,
/// so this function cannot stop them.
Future<List<O>> computeParallel<I, O>(
  Future<O> Function(I input) task,
  List<I> inputs,
) {
  if (inputs.isEmpty) return Future<List<O>>.value(<O>[]);
  // Future.sync turns a synchronous throw from [task] into a failed future,
  // so one bad input cannot throw out of this function before the others start.
  return Future.wait<O>(
    inputs.map((input) => Future<O>.sync(() => task(input))),
    eagerError: true,
  );
}

/// Runs [task] once for every element of [inputs] with at most [concurrency]
/// calls in flight from this batch, and completes with the results in input
/// order (ADR-034).
///
/// A new call is admitted as an earlier one completes. The first failure stops
/// admission of new calls; every admitted call is still observed until it
/// completes, and the first error is rethrown. A synchronous throw from [task]
/// becomes a failed call. An empty [inputs] completes with an empty list and
/// never calls [task].
///
/// The limit applies to this batch only. Other batches and unrelated work
/// still compete for the global DWI pool. Plain futures cannot be cancelled,
/// so calls already admitted keep running after a failure.
///
/// Throws [ArgumentError] synchronously when [concurrency] is less than 1.
Future<List<O>> computeParallelBounded<I, O>(
  Future<O> Function(I input) task,
  List<I> inputs, {
  int concurrency = 4,
}) {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'must be at least 1');
  }
  if (inputs.isEmpty) return Future<List<O>>.value(<O>[]);

  final results = List<O?>.filled(inputs.length, null);
  final completer = Completer<List<O>>();
  var next = 0;
  var inFlight = 0;
  var failed = false;

  void settle() {
    if (completer.isCompleted || failed) return;
    if (next == inputs.length && inFlight == 0) {
      completer.complete(results.cast<O>());
    }
  }

  void admit() {
    while (!failed && inFlight < concurrency && next < inputs.length) {
      final index = next++;
      inFlight++;
      Future<O>.sync(() => task(inputs[index])).then(
        (value) {
          results[index] = value;
          inFlight--;
          admit();
          settle();
        },
        onError: (Object error, StackTrace stack) {
          inFlight--;
          if (!failed) {
            failed = true;
            completer.completeError(error, stack);
          }
        },
      );
    }
    settle();
  }

  admit();
  return completer.future;
}
