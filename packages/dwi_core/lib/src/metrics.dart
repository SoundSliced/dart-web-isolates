/// Call metrics, reported when `DwiConfig.metrics` is enabled (ADR-026 G1).
///
/// A snapshot: read with `Dwi.metrics()`. Counters are cumulative from the
/// first call made with metrics enabled. Only `Dwi.run` calls are counted;
/// `runCancellable`, `runStream`, `runFresh` and handle calls are not.
final class DwiMetrics {
  const DwiMetrics({
    required this.callsStarted,
    required this.callsCompleted,
    required this.callsFailed,
    required this.totalCallTime,
    required this.maxCallTime,
    required this.transferableBytes,
  });

  /// Calls that reached `Dwi.run` while metrics were enabled.
  final int callsStarted;

  /// Calls that returned a result.
  final int callsCompleted;

  /// Calls that settled with an error, including a wrong result type.
  final int callsFailed;

  /// Sum of call durations. A duration runs from the call to its settlement,
  /// so it includes time held while paused (ADR-028) and time queued for a
  /// worker. Startup time is not included.
  final Duration totalCallTime;

  /// The longest single call duration seen.
  final Duration maxCallTime;

  /// Bytes sent as `DwiTransferableBytes`. Copied inputs are not counted,
  /// because their size is not known without serialising them.
  final int transferableBytes;

  /// Calls started and not yet settled.
  int get callsRunning => callsStarted - callsCompleted - callsFailed;

  @override
  String toString() =>
      'DwiMetrics(started: $callsStarted, completed: $callsCompleted, '
      'failed: $callsFailed, totalCallTime: $totalCallTime, '
      'maxCallTime: $maxCallTime, transferableBytes: $transferableBytes)';
}

/// One worker in a [DwiPoolState] snapshot.
final class DwiPoolWorker {
  const DwiPoolWorker({
    required this.id,
    required this.busy,
    required this.failed,
  });

  /// Stable within one backend; not reused while the backend is open.
  final int id;

  /// Whether the worker is executing a call right now.
  final bool busy;

  /// Whether the worker has failed and will not accept further calls.
  final bool failed;

  @override
  String toString() => 'DwiPoolWorker(id: $id, busy: $busy, failed: $failed)';
}

/// What the pool looks like right now (ADR-026 G2). A snapshot, not a stream.
///
/// The shared pool on web has slots and a queue. The native backend runs each
/// `Dwi.run` call in its own isolate with no queue, so its [workers] are the
/// calls currently running and [queued] is always 0.
final class DwiPoolState {
  const DwiPoolState({
    required this.maxWorkers,
    required this.queued,
    required this.workers,
  });

  /// The configured upper bound on live workers.
  final int maxWorkers;

  /// Calls waiting for a worker and not yet timed out.
  final int queued;

  /// The live workers, in creation order.
  final List<DwiPoolWorker> workers;

  @override
  String toString() =>
      'DwiPoolState(maxWorkers: $maxWorkers, queued: $queued, '
      'workers: $workers)';
}

/// Implemented by a backend that can report its pool state (ADR-026 G2).
///
/// Optional: a backend without it reports an empty pool.
abstract interface class DwiPoolInspector {
  /// The pool state at the moment of the call.
  DwiPoolState poolState();
}
