import 'dart:async';

/// A DWI call that can be cancelled while it is queued or running.
///
/// Backends own the completion side ([complete], [completeError]); callers use
/// [result] and [cancel]. The contract is defined in ADR-010 §10.1:
///
/// * [result] settles exactly once, with a value, a [DwiException], or
///   `DwiCancelledException`;
/// * [cancel] returns `true` only when that call changed the outcome;
/// * [cancel] never throws for races or repeats.
class DwiCancellableTask<R> {
  /// Creates a handle whose cancellation is handled by [cancel].
  DwiCancellableTask({required Future<bool> Function() cancel})
    : _cancel = cancel;

  final Future<bool> Function() _cancel;
  final Completer<R> _completer = Completer<R>();

  /// The single future that settles when the task finishes, fails or is
  /// cancelled.
  Future<R> get result => _completer.future;

  /// Whether [result] has already settled.
  bool get isDone => _completer.isCompleted;

  /// Requests cancellation.
  ///
  /// Returns `true` when this call cancelled a queued or running task and
  /// `false` when the task had already settled or could not be cancelled.
  Future<bool> cancel() => _cancel();

  /// Completes [result] with [value]. Ignored once the task has settled.
  ///
  /// Backend-facing: application code never calls this.
  void complete(R value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  /// Completes [result] with [error]. Ignored once the task has settled.
  ///
  /// Backend-facing: application code never calls this.
  void completeError(Object error, [StackTrace? stack]) {
    if (!_completer.isCompleted) _completer.completeError(error, stack);
  }
}
