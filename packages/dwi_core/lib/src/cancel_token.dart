import 'dart:async';

import 'exceptions.dart';

/// Cancellation signal a running task can observe (ADR-027).
///
/// Task code reads [DwiCancelToken.current] between steps:
///
/// ```dart
/// @DwiTask()
/// Future<int> sumSlowly(int n) async {
///   var total = 0;
///   for (var i = 0; i < n; i++) {
///     DwiCancelToken.current.throwIfCancelled();
///     total += await step(i);
///   }
///   return total;
/// }
/// ```
///
/// The token is cancelled only when the caller cancels a running call and
/// `DwiConfig.cancelGracePeriod` is set. Without it, cancelling terminates the
/// worker or isolate at once and the token is never observed. A task that
/// does not stop within the grace period is terminated as before, so
/// termination stays the fallback: a synchronous loop that never yields cannot
/// see the token at all.
///
/// Outside a DWI task, or in a call started without a cancellable handle,
/// [current] returns a token that is never cancelled.
final class DwiCancelToken {
  /// Creates a token that is not cancelled yet.
  ///
  /// Backend-facing: application code reads [current] instead.
  DwiCancelToken();

  DwiCancelToken._never();

  static final DwiCancelToken _none = DwiCancelToken._never();
  static final Object _zoneKey = Object();

  /// The token of the task running in the current zone.
  static DwiCancelToken get current {
    final token = Zone.current[_zoneKey];
    return token is DwiCancelToken ? token : _none;
  }

  /// Runs [body] with [token] as [current].
  ///
  /// Backend-facing: workers wrap each task call with it.
  static R runWith<R>(DwiCancelToken token, R Function() body) =>
      runZoned(body, zoneValues: <Object?, Object?>{_zoneKey: token});

  final Completer<void> _cancelled = Completer<void>();

  /// Whether the caller cancelled this call.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when the caller cancels this call; never completes otherwise.
  Future<void> get whenCancelled => _cancelled.future;

  /// Throws [DwiCancelledException] when [isCancelled].
  void throwIfCancelled() {
    if (isCancelled) {
      throw const DwiCancelledException('task observed cancellation');
    }
  }

  /// Marks the token cancelled. Repeats are ignored.
  ///
  /// Backend-facing: application code never calls this.
  void cancel() {
    if (identical(this, _none)) return;
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
