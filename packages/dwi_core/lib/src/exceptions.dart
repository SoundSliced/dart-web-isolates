/// Base type for every failure raised by DWI.
sealed class DwiException implements Exception {
  const DwiException(this.message);

  /// The human-readable description of the failure.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The worker script is missing, blocked, or never became ready.
class DwiStartupException extends DwiException {
  /// A worker could not start: a missing or refused script, a failed load, or no ready message in time.
  const DwiStartupException(super.message);
}

/// A task or startup exceeded its configured timeout.
class DwiTimeoutException extends DwiException {
  /// A task or a startup exceeded its configured timeout.
  const DwiTimeoutException(super.message);
}

/// The worker has no task registered under the requested name.
class DwiUnknownTaskException extends DwiException {
  /// The task name is not registered in the worker.
  const DwiUnknownTaskException(super.message);
}

/// A value cannot cross the worker boundary.
class DwiSerializationException extends DwiException {
  /// A value could not cross the boundary, or a received value could not be rebuilt.
  const DwiSerializationException(super.message);
}

/// The result could not be interpreted as the requested type.
class DwiResultTypeException extends DwiException {
  /// A task returned a value of a type the caller did not expect.
  const DwiResultTypeException(super.message);
}

/// No backend is available (for example, no worker script on web).
class DwiUnsupportedException extends DwiException {
  /// The operation is not supported by this backend or platform.
  const DwiUnsupportedException(super.message);
}

/// A task was cancelled before it produced a result.
///
/// Delivered through [DwiCancellableTask.result], never thrown by
/// [DwiCancellableTask.cancel]. See ADR-010 §10.1.
class DwiCancelledException extends DwiException {
  /// The call was cancelled before it produced a result.
  const DwiCancelledException(super.message);
}

/// A dedicated worker handle was used after [DwiWorkerHandle.close] (ADR-013).
class DwiWorkerClosedException extends DwiException {
  /// The worker was closed while the call was pending or was used afterwards.
  const DwiWorkerClosedException(super.message);
}

/// A dedicated worker handle is in the [DwiWorkerState.failed] state.
///
/// Delivered to queued calls when the context died, and to calls made on a
/// failed handle. Recovery requires an explicit restart or a new handle.
class DwiWorkerFailedException extends DwiException {
  /// The worker failed: it crashed, reported an error, or stopped unexpectedly.
  const DwiWorkerFailedException(super.message);
}

/// A dedicated worker handle was used in a state that does not accept it.
///
/// For example a call while [DwiWorkerState.starting] or
/// [DwiWorkerState.closing], or `restart()` on a handle that has not failed.
class DwiWorkerStateException extends DwiException {
  /// The worker is not in a state that allows the operation.
  const DwiWorkerStateException(super.message);
}

/// Base type for channel failures (ADR-014).
class DwiChannelException extends DwiException {
  /// A channel operation failed.
  const DwiChannelException(super.message);
}

/// A channel was used after it closed.
class DwiChannelClosedException extends DwiChannelException {
  /// The channel was closed before the operation completed.
  const DwiChannelClosedException(super.message);
}

/// A channel operation is not valid in the channel's current state.
///
/// For example opening a name that is already open on the handle, or opening a
/// channel on a handle that is not ready.
class DwiChannelStateException extends DwiChannelException {
  /// The channel is not in a state that allows the operation.
  const DwiChannelStateException(super.message);
}

/// A send was refused because the channel's unacknowledged window is full.
///
/// Nothing was sent. The caller can await outstanding sends and retry, or
/// consume `messages` so the peer can acknowledge.
class DwiChannelBufferException extends DwiChannelException {
  /// The channel buffer is full and the message was not accepted.
  const DwiChannelBufferException(super.message);
}

/// A failure that happened inside another realm.
///
/// [remoteStackTrace] is captured by the worker runtime. It is data, never a
/// local stack trace.
class DwiRemoteException extends DwiException {
  /// An error thrown by a task in the worker, reconstructed on the host.
  const DwiRemoteException({
    required String message,
    this.remoteType = '',
    this.remoteStack = '',
    this.workerId,
    this.taskId,
  }) : super(message);

  /// The type name of the error the task threw.
  final String remoteType;

  /// The stack trace of the error the task threw, as text.
  final String remoteStack;

  /// The id of the worker that reported the error, when known.
  final String? workerId;

  /// The id of the task that failed, when known.
  final int? taskId;

  @override
  String toString() =>
      'DwiRemoteException($remoteType): $message'
      '${remoteStack.isEmpty ? '' : '\n$remoteStack'}';
}
