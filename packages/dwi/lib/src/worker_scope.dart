import 'dart:async';

import '../dwi.dart';

/// Runs [body] against one handle opened by [open] and always releases it with
/// [close]. This is the implementation of [DwiWorker.using] (ADR-015).
///
/// The functions are injectable so tests can exercise spawn failures and a
/// throwing cleanup without a special backend. This library is internal; it is
/// not part of the package's public API.
Future<R> runScopedWorker<R>({
  required Future<DwiWorker> Function() open,
  required Future<void> Function(DwiWorker worker) close,
  required FutureOr<R> Function(DwiWorker worker) body,
}) async {
  final worker = await open();
  final R result;
  try {
    result = await body(worker);
  } catch (error, stack) {
    try {
      await close(worker);
    } catch (closeError, closeStack) {
      // Both failed. The callback error stays the future's error and keeps its
      // identity, and the cleanup failure is recorded in the stack trace that
      // travels with it. It is neither silently dropped nor reported as an
      // uncaught zone error, which would fail ordinary callers and test runs
      // for a condition the returned future already describes (ADR-015).
      Error.throwWithStackTrace(
        error,
        _CleanupFailureStack(stack, closeError, closeStack),
      );
    }
    Error.throwWithStackTrace(error, stack);
  }
  await close(worker);
  return result;
}

/// The callback error's [StackTrace], extended with the cleanup failure.
///
/// Used only when both the callback and `close()` throw. `Error.throwWithStackTrace`
/// carries one stack trace, so the cleanup failure rides along here instead of
/// becoming a second, uncaught error.
final class _CleanupFailureStack implements StackTrace {
  _CleanupFailureStack(
    this._callbackStack,
    this._cleanupError,
    this._cleanupStack,
  );

  final StackTrace _callbackStack;
  final Object _cleanupError;
  final StackTrace _cleanupStack;

  @override
  String toString() {
    return '$_callbackStack\n'
        '---\n'
        'While handling the error above, close() also failed. The callback '
        'error takes precedence (ADR-015); this cleanup failure is recorded '
        'here instead of being rethrown or reported as an uncaught error:\n'
        '$_cleanupError\n'
        '$_cleanupStack';
  }
}
