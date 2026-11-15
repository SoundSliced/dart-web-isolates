/// Which concurrency mechanism a backend uses.
enum DwiBackendKind {
  /// A Dart isolate backend (native Dart VM and Flutter native).
  isolate,

  /// A Web Worker backend (Dart Web JavaScript and Dart/Wasm workers).
  worker,

  /// No backend is available on this platform.
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
  /// Creates a capabilities snapshot. Backends fill it in; applications only read it.
  const DwiCapabilities({
    required this.backend,
    required this.protocolVersion,
    this.transferables = false,
    this.workerCount = 0,
    this.cancellation = DwiCancellation.none,
    this.workerBackend,
  });

  /// The concurrency mechanism in use.
  final DwiBackendKind backend;

  /// The wire protocol version this build speaks.
  final int protocolVersion;

  /// Whether transferable bytes are supported by the backend.
  final bool transferables;

  /// The number of workers the backend may use.
  final int workerCount;

  /// The cancellation contract this backend honours.
  final DwiCancellation cancellation;

  /// Observed worker compiler (`dart2js` or `dart2wasm`), when a worker
  /// reported it. This is the worker's `ready` value, not the requested
  /// configuration (ADR-018).
  final String? workerBackend;

  /// Returns the capabilities as plain values, for logs and diagnostics.
  Map<String, Object?> toMap() => <String, Object?>{
    'backend': backend.name,
    'protocolVersion': protocolVersion,
    'transferables': transferables,
    'workerCount': workerCount,
    'cancellation': cancellation.name,
    if (workerBackend != null) 'workerBackend': workerBackend,
  };
}
