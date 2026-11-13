import 'dart:async';

import 'cancellable_task.dart';
import 'channel.dart';

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

/// Why a [DwiWorkerHandle]'s execution context stopped (ADR-017).
///
/// Only a terminal transition emits a value; call-local failures such as a
/// queued timeout or a remote task error do not stop the context. The first
/// terminal cause for one generation wins, and [DwiWorkerHandle.restart] starts
/// a new generation.
enum DwiWorkerStop {
  /// The handle was closed with [DwiWorkerHandle.close] or `Dwi.close()`.
  callerClosed,

  /// The context died unexpectedly: an isolate exit not caused by `close`, a
  /// port error, a worker error, or missed idle heartbeats.
  crashed,

  /// A running call exceeded `DwiConfig.taskTimeout`.
  timedOut,

  /// A running call was cancelled; the context cannot be reused.
  cancelled,

  /// The context sent a malformed or protocol-invalid message.
  protocolViolation,
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

  /// Why the current context stopped, or `null` while it is active (ADR-017).
  ///
  /// Becomes readable when a terminal transition starts — before affected calls
  /// and channels settle — and is cleared only when [restart] starts a
  /// replacement. A failed `restart()` leaves this `null`: a startup failure is
  /// not a running context stopping.
  ///
  /// Late observers read this instead of replaying [stops].
  DwiWorkerStop? get stopReason;

  /// Terminal transitions of this handle, one event per context generation.
  ///
  /// Broadcast: subscribers receive events independently and a throwing
  /// listener cannot affect cleanup. There is no replay; read [stopReason] for
  /// the latest cause. The stream carries no error, stays open across [restart]
  /// and closes after the last event of a final [close] — including a close
  /// performed by `Dwi.close()`.
  Stream<DwiWorkerStop> get stops;

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

  /// Opens a named duplex channel on this handle (ADR-014).
  ///
  /// Resolves after the worker acknowledged the channel; throws
  /// [DwiChannelStateException] when the name is already open or the handle is
  /// not ready, and [DwiUnsupportedException] when the worker artefact does not
  /// implement protocol v2. Channels never survive [restart].
  ///
  /// With [ackOnConsume], both ends acknowledge a message only when their
  /// reader takes it (ADR-023), so an awaiting sender is paced by the reader.
  Future<DwiChannel> openChannel(String name, {bool ackOnConsume = false});

  /// Terminates the context and settles every caller.
  ///
  /// Queued and in-flight calls receive `DwiWorkerClosedException`. Idempotent:
  /// [DwiWorkerState.closed] stays closed.
  Future<void> close();
}
