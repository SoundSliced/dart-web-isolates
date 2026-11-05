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
        DwiCancellableTask,
        DwiCancellation,
        DwiCancelledException,
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
        DwiTransferableBytes,
        DwiUnknownTaskException,
        DwiUnsupportedException,
        DwiWorkerClosedException,
        DwiWorkerFailedException,
        DwiWorkerHandle,
        DwiWorkerState,
        DwiWorkerStateException;

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

  /// Runs [task] with [input] and returns a handle that can be cancelled.
  ///
  /// The task settles exactly once through [DwiCancellableTask.result] with a
  /// value, a [DwiException], or [DwiCancelledException]. [DwiCancellableTask.cancel]
  /// never throws (ADR-010 §10.1).
  ///
  /// ```dart
  /// final task = Dwi.runCancellable<int>('primes', 5000000);
  /// final cancelled = await task.cancel();
  /// ```
  static DwiCancellableTask<R> runCancellable<R>(
    String task, [
    Object? input,
  ]) {
    final inner = _active.start(task, input);
    final outer = DwiCancellableTask<R>(cancel: inner.cancel);
    outer.result.ignore();
    unawaited(
      inner.result.then<void>(
        (value) {
          if (value is R) {
            outer.complete(value);
          } else {
            outer.completeError(
              DwiResultTypeException(
                'task "$task" returned ${value.runtimeType}, expected $R',
              ),
            );
          }
        },
        onError: (Object error, StackTrace stack) {
          outer.completeError(error, stack);
        },
      ),
    );
    return outer;
  }

  /// Reports what the selected backend can actually do here.
  static Future<DwiCapabilities> capabilities() => _active.capabilities();

  /// Terminates workers/isolates and forgets configuration.
  ///
  /// Live [DwiWorker] handles are closed first (ADR-013), so page or
  /// application teardown cannot leak a dedicated context.
  static Future<void> close() async {
    await _backend?.close();
    _backend = null;
  }
}

/// A handle to one dedicated worker or isolate (ADR-013).
///
/// The handle owns its execution context for its whole lifetime and does not
/// borrow a slot from the [Dwi.run] pool. Calls run one at a time in FIFO
/// order, and task implementations may keep worker-local state between calls.
///
/// ```dart
/// final worker = await DwiWorker.spawn();
/// try {
///   final first = await worker.run<int>('counter', null);   // 1
///   final second = await worker.run<int>('counter', null);  // 2
/// } finally {
///   await worker.close();
/// }
/// ```
///
/// On web the artefact is [DwiConfig.workerScript]; on native no URL is used.
/// Losing the context — close, timeout, crash, or cancelling a running call —
/// loses its local state. A replacement created with [restart] or [DwiWorker.spawn]
/// starts fresh and never replays a task.
final class DwiWorker {
  DwiWorker._(this._handle);

  final DwiWorkerHandle _handle;

  /// Starts a dedicated execution context and waits until it is ready.
  ///
  /// Throws [DwiUnsupportedException] when no backend or worker script is
  /// available and [DwiStartupException] when the context never becomes ready.
  static Future<DwiWorker> spawn() async {
    final handle = await Dwi._active.spawnHandle();
    return DwiWorker._(handle);
  }

  /// Current lifecycle state of the handle.
  DwiWorkerState get state => _handle.state;

  /// Whether the handle can accept work right now.
  bool get isUsable => _handle.isUsable;

  /// Runs [task] with [input] and returns its result as [R].
  ///
  /// Queues behind the current call. Throws [DwiUnknownTaskException],
  /// [DwiTimeoutException], [DwiSerializationException], [DwiRemoteException],
  /// or a handle-state exception on failure. A mismatched [R] throws
  /// [DwiResultTypeException].
  Future<R> run<R>(String task, [Object? input]) async {
    final result = await _handle.run(task, input);
    if (result is R) return result;
    throw DwiResultTypeException(
      'task "$task" returned ${result.runtimeType}, expected $R',
    );
  }

  /// Runs [task] with [input] and returns a cancellable call.
  ///
  /// Reuses [DwiCancellableTask] unchanged: [DwiCancellableTask.result] settles
  /// exactly once and [DwiCancellableTask.cancel] never throws. Cancelling a
  /// queued call keeps the context; cancelling a running call terminates it and
  /// moves the handle to [DwiWorkerState.failed].
  DwiCancellableTask<R> runCancellable<R>(String task, [Object? input]) {
    final inner = _handle.start(task, input);
    final outer = DwiCancellableTask<R>(cancel: inner.cancel);
    outer.result.ignore();
    unawaited(
      inner.result.then<void>(
        (value) {
          if (value is R) {
            outer.complete(value);
          } else {
            outer.completeError(
              DwiResultTypeException(
                'task "$task" returned ${value.runtimeType}, expected $R',
              ),
            );
          }
        },
        onError: (Object error, StackTrace stack) {
          outer.completeError(error, stack);
        },
      ),
    );
    return outer;
  }

  /// Replaces a failed context with a fresh one.
  ///
  /// Only allowed while [state] is [DwiWorkerState.failed]. The new context has
  /// fresh local state and never receives work that failed with the old one.
  /// Throws [DwiWorkerStateException] in any other state.
  Future<void> restart() => _handle.restart();

  /// Cancels queued and running work, then terminates the context.
  ///
  /// Every affected caller settles with [DwiWorkerClosedException]. Idempotent.
  Future<void> close() => _handle.close();
}
