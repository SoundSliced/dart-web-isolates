/// Base type for every failure raised by DWI.
sealed class DwiException implements Exception {
  const DwiException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The worker script is missing, blocked, or never became ready.
class DwiStartupException extends DwiException {
  const DwiStartupException(super.message);
}

/// A task or startup exceeded its configured timeout.
class DwiTimeoutException extends DwiException {
  const DwiTimeoutException(super.message);
}

/// The worker has no task registered under the requested name.
class DwiUnknownTaskException extends DwiException {
  const DwiUnknownTaskException(super.message);
}

/// A value cannot cross the worker boundary.
class DwiSerializationException extends DwiException {
  const DwiSerializationException(super.message);
}

/// The result could not be interpreted as the requested type.
class DwiResultTypeException extends DwiException {
  const DwiResultTypeException(super.message);
}

/// No backend is available (for example, no worker script on web).
class DwiUnsupportedException extends DwiException {
  const DwiUnsupportedException(super.message);
}

/// A task was cancelled before it produced a result.
///
/// Delivered through [DwiCancellableTask.result], never thrown by
/// [DwiCancellableTask.cancel]. See ADR-010 §10.1.
class DwiCancelledException extends DwiException {
  const DwiCancelledException(super.message);
}

/// A dedicated worker handle was used after [DwiWorkerHandle.close] (ADR-013).
class DwiWorkerClosedException extends DwiException {
  const DwiWorkerClosedException(super.message);
}

/// A dedicated worker handle is in the [DwiWorkerState.failed] state.
///
/// Delivered to queued calls when the context died, and to calls made on a
/// failed handle. Recovery requires an explicit restart or a new handle.
class DwiWorkerFailedException extends DwiException {
  const DwiWorkerFailedException(super.message);
}

/// A dedicated worker handle was used in a state that does not accept it.
///
/// For example a call while [DwiWorkerState.starting] or
/// [DwiWorkerState.closing], or `restart()` on a handle that has not failed.
class DwiWorkerStateException extends DwiException {
  const DwiWorkerStateException(super.message);
}

/// Base type for channel failures (ADR-014).
class DwiChannelException extends DwiException {
  const DwiChannelException(super.message);
}

/// A channel was used after it closed.
class DwiChannelClosedException extends DwiChannelException {
  const DwiChannelClosedException(super.message);
}

/// A channel operation is not valid in the channel's current state.
///
/// For example opening a name that is already open on the handle, or opening a
/// channel on a handle that is not ready.
class DwiChannelStateException extends DwiChannelException {
  const DwiChannelStateException(super.message);
}

/// A send was refused because the channel's unacknowledged window is full.
///
/// Nothing was sent. The caller can await outstanding sends and retry, or
/// consume `messages` so the peer can acknowledge.
class DwiChannelBufferException extends DwiChannelException {
  const DwiChannelBufferException(super.message);
}

/// A failure that happened inside another realm.
///
/// [remoteStackTrace] is captured by the worker runtime. It is data, never a
/// local stack trace.
class DwiRemoteException extends DwiException {
  const DwiRemoteException({
    required String message,
    this.remoteType = '',
    this.remoteStack = '',
    this.workerId,
    this.taskId,
  }) : super(message);

  final String remoteType;
  final String remoteStack;
  final String? workerId;
  final int? taskId;

  @override
  String toString() =>
      'DwiRemoteException($remoteType): $message'
      '${remoteStack.isEmpty ? '' : '\n$remoteStack'}';
}
