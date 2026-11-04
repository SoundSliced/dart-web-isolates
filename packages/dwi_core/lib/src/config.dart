import 'exceptions.dart';

/// Configuration shared by every DWI backend.
///
/// Timeouts are mandatory: a worker that never becomes ready, or a task that
/// never returns, must fail instead of hanging (docs/protocol.md).
class DwiConfig {
  const DwiConfig({
    this.workerScript = defaultWorkerScript,
    this.maxWorkers = 4,
    this.taskTimeout = const Duration(seconds: 30),
    this.startupTimeout = const Duration(seconds: 10),
    this.maxQueuedTasks = 64,
    this.maxPayloadBytes = 64 * 1024 * 1024,
  });

  /// Conventional served path for the generated worker.
  ///
  /// This must match `dwi_builder`'s default. Override [workerScript] when the
  /// generated artefact is served from a different path.
  static const String defaultWorkerScript = 'dwi/worker.dart.js';

  /// Path to the compiled worker entrypoint. Ignored on native.
  ///
  /// Defaults to [defaultWorkerScript] so generated workers need no manual
  /// path configuration. Set an empty string to force a startup error.
  final String? workerScript;

  /// Upper bound on concurrently live workers.
  final int maxWorkers;

  /// How long a single task may run before the worker is terminated.
  final Duration taskTimeout;

  /// How long a worker may take to send `ready`.
  final Duration startupTimeout;

  /// Upper bound on queued tasks; exceeding it fails the call.
  final int maxQueuedTasks;

  /// Upper bound on an encoded payload, in bytes.
  final int maxPayloadBytes;

  /// Returns a copy with validated values or throws [ArgumentError].
  DwiConfig validated() {
    if (maxWorkers < 1) {
      throw ArgumentError.value(maxWorkers, 'maxWorkers', 'must be >= 1');
    }
    if (maxQueuedTasks < 0) {
      throw ArgumentError.value(
        maxQueuedTasks,
        'maxQueuedTasks',
        'must be >= 0',
      );
    }
    if (taskTimeout <= Duration.zero) {
      throw ArgumentError.value(taskTimeout, 'taskTimeout', 'must be positive');
    }
    if (startupTimeout <= Duration.zero) {
      throw ArgumentError.value(
        startupTimeout,
        'startupTimeout',
        'must be positive',
      );
    }
    if (maxPayloadBytes <= 0) {
      throw ArgumentError.value(
        maxPayloadBytes,
        'maxPayloadBytes',
        'must be positive',
      );
    }
    return this;
  }

  /// Throws [DwiStartupException] when a worker is required but no script is set.
  void requireWorkerScript() {
    final script = workerScript;
    if (script == null || script.trim().isEmpty) {
      throw const DwiStartupException(
        'workerScript is not configured; call Dwi.configure first',
      );
    }
  }
}
