/// Public API for Dart Web Isolates.
///
/// On native platforms tasks run on real Dart isolates. On web they run in
/// dedicated Web Workers using a precompiled worker entrypoint. The API is the
/// same; the supported semantics and their limits are documented in
/// `docs/compatibility-matrix.md`.
library;

import 'dart:async';

import 'package:dwi_core/dwi_core.dart';

import 'src/backend_native.dart'
    if (dart.library.js_interop) 'src/backend_web.dart'
    as impl;

export 'package:dwi_annotations/dwi_annotations.dart' show DwiTask;

export 'package:dwi_core/dwi_core.dart'
    show
        DwiBackendKind,
        DwiCapabilities,
        DwiConfig,
        DwiException,
        DwiRemoteException,
        DwiResultTypeException,
        DwiSerializationException,
        DwiStartupException,
        DwiTaskFunction,
        DwiTaskRegistry,
        DwiTimeoutException,
        DwiUnknownTaskException,
        DwiUnsupportedException;

/// Entry point for worker-backed, isolate-like concurrency.
///
/// ```dart
/// Dwi.registerTask('primes', (input) => countPrimes(input! as int));
/// final count = await Dwi.run<int>('primes', 5000000);
/// ```
abstract final class Dwi {
  static final DwiTaskRegistry registry = DwiTaskRegistry();
  static DwiConfig _config = const DwiConfig();
  static DwiBackend? _backend;

  static DwiBackend get _active => _backend ??= impl.createBackend(registry);

  /// Applies configuration. Safe to call before the first task.
  ///
  /// On web, [DwiConfig.workerScript] is required; without it calls fail with
  /// [DwiStartupException] rather than falling back to the main thread.
  static Future<void> configure(DwiConfig config) async {
    _config = config.validated();
    _backend ??= impl.createBackend(registry);
    await _backend!.configure(_config);
  }

  /// Registers a task implementation for the native backend and for tests.
  ///
  /// Worker entrypoints keep their own registry; see `docs/compiler-strategy.md`.
  static void registerTask(String name, DwiTaskFunction task) {
    registry.register(name, task);
  }

  /// Runs [task] with [input] and returns its result as [R].
  ///
  /// Throws [DwiUnknownTaskException], [DwiStartupException],
  /// [DwiTimeoutException], [DwiSerializationException] or [DwiRemoteException]
  /// on failure. There is no main-thread fallback.
  static Future<R> run<R>(String task, [Object? input]) async {
    final result = await _active.run(task, input);
    if (result is R) return result;
    throw DwiResultTypeException(
      'task "$task" returned ${result.runtimeType}, expected $R',
    );
  }

  /// Reports what the selected backend can actually do here.
  static Future<DwiCapabilities> capabilities() => _active.capabilities();

  /// Terminates workers/isolates and forgets configuration.
  static Future<void> close() async {
    await _backend?.close();
    _backend = null;
  }
}
