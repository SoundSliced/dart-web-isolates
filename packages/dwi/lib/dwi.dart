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
import 'src/worker_scope.dart';

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
        DwiStreamTask,
        DwiTaskFunction,
        DwiTaskRegistry,
        DwiTimeoutException,
        DwiTransferableBytes,
        DwiUnknownTaskException,
        DwiUnsupportedException,
        DwiWorkerClosedException,
        DwiWorkerFailedException,
        DwiWorkerHandle,
        DwiWorkerBackend,
        DwiWorkerState,
        DwiWorkerStateException,
        DwiWorkerStop,
        DwiChannel,
        DwiChannelException,
        DwiChannelClosedException,
        DwiChannelStateException,
        DwiChannelBufferException;

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

  /// Pooled and fresh calls that have not settled, for `close(drain: true)`.
  static final Set<Future<Object?>> _inFlight = <Future<Object?>>{};

  /// Set while a draining [close] waits; new calls are refused meanwhile.
  static bool _closing = false;

  /// Records [call] until it settles and returns it unchanged.
  static Future<T> _track<T>(Future<T> call) {
    _inFlight.add(call);
    call.then<void>((_) {}, onError: (Object _) {}).whenComplete(
      () => _inFlight.remove(call),
    );
    return call;
  }

  static void _refuseWhileClosing(String task) {
    if (_closing) {
      throw DwiUnsupportedException(
        'task "$task" was refused: DWI is closing',
      );
    }
  }

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
    _refuseWhileClosing(task);
    final result = await _track(_active.run(task, input));
    if (result is R) return result;
    throw DwiResultTypeException(
      'task "$task" returned ${result.runtimeType}, expected $R',
    );
  }

  /// Runs exactly one [task] in a fresh execution context (ADR-016).
  ///
  /// Unlike [run], which may reuse a pooled Web Worker, this spawns a dedicated
  /// handle for the call and closes it before completing. No worker-local state
  /// enters or leaves the call and two calls never share a context, matching
  /// `Isolate.run`'s fresh-context guarantee on both native and web. The task is
  /// still selected by name, so this is not `Isolate.run(fn)`.
  ///
  /// ```dart
  /// final count = await Dwi.runFresh<int>('primes', 5000000);
  /// ```
  ///
  /// Startup is paid per call, so this is for isolation from pooled state, not
  /// a performance improvement. Errors are the same typed failures [run] and
  /// [DwiWorker.run] raise; a spawn failure propagates unchanged and nothing is
  /// retried.
  static Future<R> runFresh<R>(String task, [Object? input]) async {
    _refuseWhileClosing(task);
    return _track(
      DwiWorker.using<R>((worker) => worker.run<R>(task, input)),
    );
  }

  /// Runs a stream [task] in a fresh execution context and returns its items
  /// as they are produced (ADR-022).
  ///
  /// The task must return a `Stream` and be generated by `dwi_builder` (its
  /// worker entry uses [DwiStreamTask]); calling a stream task through [run]
  /// fails with [DwiUnsupportedException].
  ///
  /// ```dart
  /// await for (final progress in Dwi.runStream('scan', files)) {
  ///   print(progress);
  /// }
  /// ```
  ///
  /// - The context is spawned when the stream is listened to and closed when
  ///   it ends, fails or the subscription is cancelled. Cancelling therefore
  ///   terminates the task; work that has not been delivered is discarded.
  /// - Items arrive in order. A paused or slow listener pauses the producer
  ///   once [DwiConfig.channelBufferSize] items are waiting; nothing is
  ///   dropped and nothing fails because the listener is slow.
  /// - An error thrown by the task is delivered after the items sent before
  ///   it, then the stream closes. Startup, timeout and crash failures are the
  ///   same typed errors as [run]. [DwiConfig.taskTimeout] bounds the whole
  ///   stream, not one item.
  ///
  /// Single-subscription; each listen is one call. Generated proxies return
  /// typed streams; this name-based form yields decoded wire values.
  static Stream<Object?> runStream(String task, [Object? input]) async* {
    final worker = await DwiWorker.spawn();
    try {
      final channel = await worker.openChannel(DwiStreamTask.channelName);
      final window = _config.channelBufferSize;
      // Credit is returned in batches so a busy stream does not double its
      // message count; the worker never has more than [window] items in flight.
      final batch = window > 1 ? window ~/ 2 : 1;
      var consumed = 0;
      Object? failure;
      StackTrace? failureStack;
      final call = worker
          .run<Object?>(task, <Object?>[
            DwiStreamTask.channelName,
            input,
            window,
          ])
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              failure = error;
              failureStack = stack;
            },
          );
      Object? channelError;
      StackTrace? channelStack;
      try {
        await for (final item in channel.messages) {
          yield item;
          if (++consumed == batch) {
            consumed = 0;
            try {
              await channel.send(batch);
            } on DwiChannelClosedException {
              // The worker finished and closed the channel; no credit needed.
            }
          }
        }
      } on Object catch (error, stack) {
        channelError = error;
        channelStack = stack;
      }
      await call;
      // The task's own error explains more than the channel failure it caused.
      final error = failure ?? channelError;
      if (error != null) {
        Error.throwWithStackTrace(error, failureStack ?? channelStack!);
      }
    } finally {
      await worker.close();
    }
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
  static DwiCancellableTask<R> runCancellable<R>(String task, [Object? input]) {
    if (_closing) {
      final refused = DwiCancellableTask<R>(cancel: () async => false);
      refused.result.ignore();
      refused.completeError(
        DwiUnsupportedException('task "$task" was refused: DWI is closing'),
      );
      return refused;
    }
    final inner = _active.start(task, input);
    _track(inner.result);
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

  /// Terminates workers/isolates and keeps the applied [DwiConfig].
  ///
  /// The next [run], [runFresh], [DwiWorker.spawn] or [capabilities] call
  /// creates a fresh backend already configured with the same settings, so a
  /// page or application teardown cannot silently fall back to the defaults
  /// (for example the default JS worker script in an app configured for Wasm).
  ///
  /// Live [DwiWorker] handles are closed first (ADR-013), so page or
  /// application teardown cannot leak a dedicated context.
  ///
  /// With [drain] (ADR-024), new [run], [runCancellable] and [runFresh] calls
  /// are refused with [DwiUnsupportedException] while the calls already
  /// started (queued or running) settle normally, each still bounded by its
  /// own timeouts; then everything is closed as usual. Dedicated handles,
  /// their calls, links and [runStream] streams are not waited for: close them
  /// first if they must finish.
  static Future<void> close({bool drain = false}) async {
    if (drain && !_closing) {
      _closing = true;
      try {
        while (_inFlight.isNotEmpty) {
          await Future.wait(<Future<void>>[
            for (final call in List<Future<Object?>>.of(_inFlight))
              call.then<void>((_) {}, onError: (Object _) {}),
          ]);
        }
      } finally {
        _closing = false;
      }
    }
    final backend = _backend;
    _backend = null;
    await backend?.close();
    // A closed backend cannot be reused, so arm its replacement with the
    // configuration that was in effect instead of leaving it unconfigured.
    final next = impl.createBackend(registry);
    await next.configure(_config);
    _backend = next;
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

  /// Spawns a handle, runs [body] with it, and closes it when [body] finishes.
  ///
  /// The helper owns the handle: it closes it whether [body] returns or throws,
  /// and it adds no error type of its own. It is sugar over [spawn] and
  /// `try`/`finally`, so repeated calls inside the callback still reach one
  /// context and keep worker-local state until the scope ends.
  ///
  /// ```dart
  /// final values = await DwiWorker.using((worker) async {
  ///   final first = await worker.run<int>('counter');
  ///   final second = await worker.run<int>('counter');
  ///   return (first, second); // (1, 2)
  /// });
  /// ```
  ///
  /// - If spawning fails, [body] never runs, no `close()` is attempted, and the
  ///   spawn error propagates unchanged.
  /// - The returned future completes with [body]'s value. A synchronous
  ///   callback and `R == void` are both supported.
  /// - Work started in [body] is not tracked. On scope exit `close()` cancels
  ///   calls, sends and channels that are still active, so callers must await
  ///   every operation whose result they need.
  /// - If [body] throws, that error object is rethrown unchanged even when
  ///   `close()` also throws, and the returned future carries it. The cleanup
  ///   error is appended to that error's stack trace instead of being silently
  ///   lost or reported as an uncaught zone error. If [body] succeeded, a
  ///   `close()` failure is this call's error.
  /// - Closing the handle inside [body] is allowed; the helper's close is a
  ///   no-op because `close()` is idempotent. Calls made after that close throw
  ///   [DwiWorkerClosedException]. Open channels are failed at scope exit.
  ///
  /// There is no `onError`/`onFinally` variant: the callback already has both
  /// the return value and typed exceptions, and the guaranteed `close()` is the
  /// cleanup hook.
  static Future<R> using<R>(FutureOr<R> Function(DwiWorker worker) body) {
    return runScopedWorker<R>(
      open: spawn,
      close: (worker) => worker.close(),
      body: body,
    );
  }

  /// Current lifecycle state of the handle.
  DwiWorkerState get state => _handle.state;

  /// Whether the handle can accept work right now.
  bool get isUsable => _handle.isUsable;

  /// Why the current context stopped, or `null` while it is active (ADR-017).
  ///
  /// Unlike a call error, this is also set when an idle context crashes and no
  /// call observed it. It is readable when the terminal transition starts,
  /// before affected calls and channels settle, and is cleared when [restart]
  /// starts a replacement. A failed [restart] leaves it `null`.
  DwiWorkerStop? get stopReason => _handle.stopReason;

  /// Terminal transitions of this handle, one event per context generation.
  ///
  /// Broadcast and replay-free: late subscribers read [stopReason]. The stream
  /// carries no error, stays open across [restart], and closes after the last
  /// event of a final [close] (including `Dwi.close()`).
  ///
  /// ```dart
  /// final worker = await DwiWorker.spawn();
  /// final subscription = worker.stops.listen((reason) => log('$reason'));
  /// // ...
  /// await subscription.cancel();
  /// await worker.close();
  /// ```
  Stream<DwiWorkerStop> get stops => _handle.stops;

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

  /// Opens a named duplex channel on this handle (ADR-014).
  ///
  /// Resolves after the worker acknowledged the channel. Channels carry progress
  /// updates, multiple results and long-lived conversations over the handle's
  /// single context. They are not `SendPort`/`ReceivePort` parity: one
  /// subscriber, FIFO per channel, bounded ack window, and no survival across
  /// [close] or [restart].
  Future<DwiChannel> openChannel(String name) => _handle.openChannel(name);

  /// Connects channel [name] in [a] to channel [name] in [b] (ADR-023).
  ///
  /// Task code in each worker finds its end with
  /// `DwiWorkerChannels.find(name)` and talks to the other worker as if the
  /// channel were direct. The host relays every message, so:
  ///
  /// - order is preserved per direction, and each message is copied (a
  ///   transferred buffer is transferred to the host, then copied on);
  /// - both ends acknowledge a message only when their reader takes it, so a
  ///   worker that awaits each send waits for the other worker to read: a slow
  ///   reader slows the writer instead of failing it. A writer that does not
  ///   await can still exceed [DwiConfig.channelBufferSize] and get
  ///   [DwiChannelBufferException];
  /// - when either worker closes its end, fails or is closed, the other end
  ///   is closed and [DwiLink.done] settles (with the failure, if any).
  ///
  /// [a] and [b] must be different, ready handles, and [name] must be free on
  /// both. A channel name is an ordinary `String`, so a worker can tell another
  /// worker which link to use by sending the name in a message.
  ///
  /// ```dart
  /// final link = await DwiWorker.link(producer, consumer, 'rows');
  /// final sum = consumer.run<int>('sumRows');
  /// await producer.run<void>('emitRows', 1000);
  /// print(await sum);
  /// await link.close();
  /// ```
  static Future<DwiLink> link(DwiWorker a, DwiWorker b, String name) async {
    if (identical(a, b)) {
      throw const DwiChannelStateException(
        'a link needs two different handles',
      );
    }
    // Both ends acknowledge on consumption, so each worker's awaited send is
    // paced by the relay and, through it, by the other worker's reader.
    final first = await a._handle.openChannel(name, ackOnConsume: true);
    final DwiChannel second;
    try {
      second = await b._handle.openChannel(name, ackOnConsume: true);
    } catch (_) {
      await first.close();
      rethrow;
    }
    return DwiLink._(name, first, second);
  }

  /// Cancels queued and running work, then terminates the context.
  ///
  /// Every affected caller settles with [DwiWorkerClosedException]. Idempotent.
  Future<void> close() => _handle.close();
}

/// A host-relayed connection between two handles' channels (ADR-023).
///
/// Created by [DwiWorker.link]. This is a logical link, not a transferred
/// `SendPort`: every message passes through the host.
final class DwiLink {
  DwiLink._(this.name, this._a, this._b) {
    _done.future.ignore();
    unawaited(_relay(_a, _b));
    unawaited(_relay(_b, _a));
  }

  /// Channel name used in both workers.
  final String name;

  final DwiChannel _a;
  final DwiChannel _b;
  final Completer<void> _done = Completer<void>();

  /// Completes when the link closes normally, and completes with the typed
  /// error that closed it otherwise.
  Future<void> get done => _done.future;

  /// Whether the link has closed.
  bool get isClosed => _done.isCompleted;

  /// Closes both ends. Idempotent; pending relayed sends are settled by the
  /// channels' own close rules.
  Future<void> close() => _finish(null, null);

  Future<void> _relay(DwiChannel from, DwiChannel to) async {
    try {
      await for (final message in from.messages) {
        await to.send(message);
      }
      await _finish(null, null);
    } on DwiChannelClosedException {
      // The other direction closed the link first.
      await _finish(null, null);
    } on Object catch (error, stack) {
      await _finish(error, stack);
    }
  }

  Future<void> _finish(Object? error, StackTrace? stack) async {
    if (_done.isCompleted) return;
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(error, stack);
    }
    await Future.wait(<Future<void>>[_close(_a), _close(_b)]);
  }

  static Future<void> _close(DwiChannel channel) async {
    try {
      await channel.close();
    } on Object {
      // A channel whose handle already failed is closed already.
    }
  }
}
