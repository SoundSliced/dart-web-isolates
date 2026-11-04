import 'cancellable_task.dart';
import 'capabilities.dart';
import 'config.dart';

/// The platform-specific half of DWI.
///
/// Implementations: `dwi_native` (isolates) and `dwi_web` (workers).
abstract interface class DwiBackend {
  /// Applies configuration. May be called more than once before first use.
  Future<void> configure(DwiConfig config);

  /// Executes [task] with [input] and returns the decoded result.
  ///
  /// Equivalent to `start(task, input).result`.
  Future<Object?> run(String task, Object? input);

  /// Starts [task] with [input] and returns a cancellable handle.
  ///
  /// Never throws synchronously: every failure, including a closed backend or
  /// an invalid payload, settles the returned task's result with a
  /// [DwiException]. See ADR-010 §10.1.
  DwiCancellableTask<Object?> start(String task, Object? input);

  /// Reports what the backend can actually do in this environment.
  Future<DwiCapabilities> capabilities();

  /// Releases all workers/isolates. Safe to call multiple times.
  Future<void> close();
}
