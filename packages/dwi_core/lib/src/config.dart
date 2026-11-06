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
    this.queueTimeout = const Duration(seconds: 30),
    this.maxQueuedTasks = 64,
    this.maxPayloadBytes = 64 * 1024 * 1024,
    this.heartbeatInterval = const Duration(seconds: 5),
    this.heartbeatMisses = 2,
    this.channelBufferSize = 64,
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

  /// How long a request may wait for a worker slot before it fails.
  ///
  /// Queue waiting has its own bound, separate from [taskTimeout]: the task
  /// timeout starts only once a worker is executing the request. A queued call
  /// therefore never waits forever behind slow or stuck work.
  final Duration queueTimeout;

  /// Upper bound on queued tasks; exceeding it fails the call.
  final int maxQueuedTasks;

  /// Upper bound on an encoded payload, in bytes.
  final int maxPayloadBytes;

  /// How often an idle worker is pinged (ADR-010 §10.3).
  ///
  /// Only idle workers are pinged: a worker running synchronous CPU code cannot
  /// answer until it finishes, so busy work is bounded by [taskTimeout] instead.
  final Duration heartbeatInterval;

  /// Consecutive unanswered pings after which an idle worker is considered dead.
  final int heartbeatMisses;

  /// Bound on outstanding (unacknowledged) channel sends, per channel and per
  /// direction, and on the receiver-side channel buffer (ADR-014).
  ///
  /// A further send throws [DwiChannelBufferException] instead of growing
  /// memory; a receiver that stops reading delays acknowledgements, so the
  /// sender stalls rather than losing messages.
  final int channelBufferSize;

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
    if (queueTimeout <= Duration.zero) {
      throw ArgumentError.value(
        queueTimeout,
        'queueTimeout',
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
    if (heartbeatInterval <= Duration.zero) {
      throw ArgumentError.value(
        heartbeatInterval,
        'heartbeatInterval',
        'must be positive',
      );
    }
    if (heartbeatMisses < 1) {
      throw ArgumentError.value(
        heartbeatMisses,
        'heartbeatMisses',
        'must be >= 1',
      );
    }
    if (channelBufferSize < 1) {
      throw ArgumentError.value(
        channelBufferSize,
        'channelBufferSize',
        'must be >= 1',
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
