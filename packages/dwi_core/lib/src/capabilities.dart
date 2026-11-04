/// Which concurrency mechanism a backend uses.
enum DwiBackendKind {
  isolate,
  worker,
  unsupported,
}

/// How much cancellation a backend actually implements (ADR-010 §10.1).
enum DwiCancellation {
  /// Cancellation is not supported at all.
  none,

  /// Only a call that has not started yet can be cancelled.
  queued,

  /// A queued or a running call can be cancelled; running cancellation
  /// terminates the worker or isolate.
  running,
}

/// Runtime capabilities reported by the selected backend.
class DwiCapabilities {
  const DwiCapabilities({
    required this.backend,
    required this.protocolVersion,
    this.transferables = false,
    this.workerCount = 0,
    this.cancellation = DwiCancellation.none,
  });

  final DwiBackendKind backend;
  final int protocolVersion;
  final bool transferables;
  final int workerCount;

  /// The cancellation contract this backend honours.
  final DwiCancellation cancellation;

  Map<String, Object?> toMap() => <String, Object?>{
        'backend': backend.name,
        'protocolVersion': protocolVersion,
        'transferables': transferables,
        'workerCount': workerCount,
        'cancellation': cancellation.name,
      };
}
