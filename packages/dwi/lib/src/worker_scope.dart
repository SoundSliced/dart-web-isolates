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
      // Preserve the callback's error (rethrown below) and keep the cleanup
      // failure observable instead of swallowing it or replacing the original.
      Zone.current.handleUncaughtError(closeError, closeStack);
    }
    Error.throwWithStackTrace(error, stack);
  }
  await close(worker);
  return result;
}
