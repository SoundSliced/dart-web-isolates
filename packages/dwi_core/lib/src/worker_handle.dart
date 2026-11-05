import 'cancellable_task.dart';

/// Lifecycle state of a [DwiWorkerHandle] (ADR-013).
///
/// Transitions:
///
/// ```text
/// created → starting → ready → closing → closed
///              │         │
///              └→ failed ←┘
///                   │
///             explicit restart
///                   ↓
///                starting
/// ```
enum DwiWorkerState {
  /// Created but no execution context has been requested yet.
  created,

  /// An isolate or worker is starting and has not announced readiness.
  starting,

  /// The execution context is healthy and accepts calls.
  ready,

  /// [DwiWorkerHandle.close] is settling callers and terminating the context.
  closing,

  /// The context was terminated by [DwiWorkerHandle.close].
  closed,

  /// The context died or was terminated by a failure. Call
  /// [DwiWorkerHandle.restart] or create a new handle.
  failed,
}

/// One dedicated execution context owned by a single caller (ADR-013).
///
/// Backend-facing: application code uses `DwiWorker` from `package:dwi`, which
/// wraps this interface. No platform type (`Worker`, `MessagePort`, `Isolate`,
/// `SendPort`) is exposed here.
///
/// A handle runs one task at a time and queues the rest in FIFO order. Every
/// call settles exactly once with a value or a typed `DwiException`.
abstract interface class DwiWorkerHandle {
  /// Current lifecycle state.
  DwiWorkerState get state;

  /// Whether the context is healthy and can accept work right now.
  ///
  /// Equivalent to `state == DwiWorkerState.ready`.
  bool get isUsable;

  /// Runs [task] with [input] and returns its decoded result.
  ///
  /// Queues behind the current call, up to `DwiConfig.maxQueuedTasks`, and
  /// throws [DwiTimeoutException] after `DwiConfig.queueTimeout` in the queue.
  /// Rejected with a typed error when the handle is not usable.
  Future<Object?> run(String task, Object? input);

  /// Starts [task] with [input] as a cancellable call (ADR-010 §10.1).
  ///
  /// Cancelling a queued call keeps the context; cancelling a running call
  /// terminates it and moves the handle to [DwiWorkerState.failed].
  DwiCancellableTask<Object?> start(String task, Object? input);

  /// Starts a fresh context after a failure.
  ///
  /// Only [DwiWorkerState.failed] may be restarted. The replacement has fresh
  /// local state; queued and in-flight calls were already settled with
  /// [DwiWorkerFailedException] and are never replayed.
  Future<void> restart();

  /// Terminates the context and settles every caller.
  ///
  /// Queued and in-flight calls receive `DwiWorkerClosedException`. Idempotent:
  /// [DwiWorkerState.closed] stays closed.
  Future<void> close();
}
