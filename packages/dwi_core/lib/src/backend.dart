import 'capabilities.dart';
import 'config.dart';

/// The platform-specific half of DWI.
///
/// Implementations: `dwi_native` (isolates) and `dwi_web` (workers).
abstract interface class DwiBackend {
  /// Applies configuration. May be called more than once before first use.
  Future<void> configure(DwiConfig config);

  /// Executes [task] with [input] and returns the decoded result.
  Future<Object?> run(String task, Object? input);

  /// Reports what the backend can actually do in this environment.
  Future<DwiCapabilities> capabilities();

  /// Releases all workers/isolates. Safe to call multiple times.
  Future<void> close();
}
