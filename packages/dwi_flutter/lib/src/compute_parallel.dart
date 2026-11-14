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
