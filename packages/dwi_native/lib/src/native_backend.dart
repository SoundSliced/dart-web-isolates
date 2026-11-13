import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';

import 'native_worker_handle.dart';

/// One running task: the caller-side state needed to cancel it.
class _NativeState {
  _NativeState(this.task);

  final String task;
  late final DwiCancellableTask<Object?> handle;
  Isolate? isolate;
  ReceivePort? port;
  Completer<Object?>? reply;

  /// The task isolate's control port, used to signal its cancel token
  /// (ADR-027).
  SendPort? control;
  bool cancelled = false;
}

/// Message passed to a task isolate.
class _IsolateJob {
  const _IsolateJob(this.implementation, this.input, this.reply);

  final DwiTaskFunction implementation;
  final Object? input;
  final SendPort reply;
}

/// Entry point of a task isolate.
///
/// Sends `[null, controlPort]` first, then `[ok, value]` or
/// `[failed, message, type, stack]`. A message on the control port cancels
/// the task's [DwiCancelToken] (ADR-027); the port is closed once the task
/// settles so the isolate can exit.
void _isolateMain(_IsolateJob job) {
  final token = DwiCancelToken();
  final control = RawReceivePort((Object? _) => token.cancel());
  job.reply.send(<Object?>[null, control.sendPort]);
  final input = _decodeFromIsolate(job.input);
  DwiCancelToken.runWith(
    token,
    () => Future<Object?>.sync(() => job.implementation(input)),
  ).then(
    (value) {
      control.close();
      job.reply.send(<Object?>[true, _encodeForIsolate(value)]);
    },
    onError: (Object error, StackTrace stack) {
      control.close();
      job.reply.send(<Object?>[
        false,
        error.toString(),
        error.runtimeType.toString(),
        stack.toString(),
      ]);
    },
  );
}

/// Converts transferable bytes into a real native transfer.
///
/// `TransferableTypedData.fromList` may copy, so the sender's memory stays
/// valid: DWI records ownership with [DwiTransferableBytes.markSent] instead
/// (ADR-010 §10.2, rule 3).
Object? _encodeForIsolate(Object? value) {
  if (value is DwiTransferableBytes) {
    return TransferableTypedData.fromList(<Uint8List>[
      value.buffer.asUint8List(),
    ]);
  }
  return value;
}

Object? _decodeFromIsolate(Object? value) {
  if (value is TransferableTypedData) {
    return DwiTransferableBytes.fromBuffer(value.materialize());
  }
  return value;
}

/// Executes registered tasks on real Dart isolates.
///
/// Each call spawns one isolate and keeps its handle, so a running task can be
/// cancelled with `Isolate.kill` instead of being abandoned (ADR-010 §10.1).
/// Timeouts terminate the isolate for the same reason.
class NativeBackend implements DwiBackend {
  NativeBackend(this.registry);

  final DwiTaskRegistry registry;
  DwiConfig _config = const DwiConfig();
  final Set<NativeWorkerHandle> _handles = <NativeWorkerHandle>{};
  bool _closed = false;

  @override
  Future<void> configure(DwiConfig config) async {
    _config = config.validated();
  }

  @override
  Future<Object?> run(String task, Object? input) =>
      start(task, input).result;

  @override
  DwiCancellableTask<Object?> start(String task, Object? input) {
    final state = _NativeState(task);
    final handle = DwiCancellableTask<Object?>(cancel: () => _cancel(state));
    state.handle = handle;
    handle.result.ignore();
    unawaited(_execute(input, state));
    return handle;
  }

  Future<void> _execute(Object? input, _NativeState state) async {
    final handle = state.handle;
    final task = state.task;
    ReceivePort? port;
    try {
      if (_closed) {
        throw const DwiUnsupportedException('backend is closed');
      }
      final implementation = registry.lookup(task);

      port = ReceivePort();
      state.port = port;
      final reply = Completer<Object?>();
      // A cancel during spawn completes this before it is awaited.
      reply.future.ignore();
      state.reply = reply;

      final transferable = input is DwiTransferableBytes ? input : null;
      final isolateInput = transferable == null
          ? input
          : _encodeForIsolate(transferable);

      final isolate = await Isolate.spawn(
        _isolateMain,
        _IsolateJob(implementation, isolateInput, port.sendPort),
        debugName: 'dwi:$task',
      );
      state.isolate = isolate;
      // Ownership moves only once the isolate exists; a spawn failure leaves
      // the wrapper usable for a retry (ADR-010 §10.2, rule 5).
      transferable?.markSent();

      port.listen(
        (message) {
          if (reply.isCompleted) return;
          final fields = message as List<Object?>;
          if (fields[0] == null) {
            final control = fields[1]! as SendPort;
            state.control = control;
            // A cancel that arrived before the port did is delivered now.
            if (state.cancelled) control.send(null);
            return;
          }
          if (fields[0] == true) {
            reply.complete(_decodeFromIsolate(fields[1]));
            return;
          }
          reply.completeError(
            DwiRemoteException(
              message: fields[1]! as String,
              remoteType: fields[2]! as String,
              remoteStack: fields[3]! as String,
            ),
          );
        },
        onError: (Object error, StackTrace stack) {
          if (!reply.isCompleted) reply.completeError(error, stack);
        },
      );

      if (state.cancelled) {
        if (_config.cancelGracePeriod == null) {
          isolate.kill(priority: Isolate.immediate);
        } else {
          _killAfterGrace(isolate, port);
        }
        throw DwiCancelledException('task "$task" was cancelled');
      }

      final value = await reply.future.timeout(_config.taskTimeout);
      if (!handle.isDone) handle.complete(value);
    } on TimeoutException {
      final error = DwiTimeoutException(
        'task "$task" exceeded ${_config.taskTimeout.inMilliseconds} ms',
      );
      state.isolate?.kill(priority: Isolate.immediate);
      handle.completeError(error);
    } on DwiCancelledException catch (error) {
      handle.completeError(error);
    } catch (error, stack) {
      if (error is DwiException) {
        handle.completeError(error);
      } else {
        // DWI must deliver a typed failure so callers never have to depend on
        // the remote error type.
        handle.completeError(
          DwiRemoteException(
            message: error.toString(),
            remoteType: error.runtimeType.toString(),
            remoteStack: stack.toString(),
          ),
        );
      }
    } finally {
      state.isolate = null;
      state.reply = null;
      state.control = null;
      // With a grace period the port stays open until the period ends, so
      // the cancel signal and the task's exit are not cut short.
      if (!state.cancelled || _config.cancelGracePeriod == null) {
        state.port = null;
        port?.close();
      }
    }
  }

  /// Cancels the call described by [state] (ADR-010 §10.1).
  ///
  /// A task whose isolate has not started is prevented from starting; a running
  /// task's isolate is killed. Either way the caller's result future settles
  /// with [DwiCancelledException] and `cancel()` reports `true`.
  Future<bool> _cancel(_NativeState state) async {
    if (state.handle.isDone) return false;
    state.cancelled = true;
    final error = DwiCancelledException(
      'task "${state.task}" was cancelled',
    );
    state.handle.completeError(error);
    final reply = state.reply;
    if (reply != null && !reply.isCompleted) reply.completeError(error);
    final isolate = state.isolate;
    if (isolate == null) return true;
    if (_config.cancelGracePeriod == null) {
      isolate.kill(priority: Isolate.immediate);
      return true;
    }
    // Cooperative cancellation (ADR-027): signal the task, then kill the
    // isolate when the grace period ends. An isolate that already exited
    // ignores the kill. Before the control port arrives, the listener sends
    // the signal as soon as it does.
    state.control?.send(null);
    _killAfterGrace(isolate, state.port);
    return true;
  }

  void _killAfterGrace(Isolate isolate, [ReceivePort? port]) {
    Timer(_config.cancelGracePeriod!, () {
      isolate.kill(priority: Isolate.immediate);
      port?.close();
    });
  }

  @override
  Future<DwiCapabilities> capabilities() async => DwiCapabilities(
        backend: _closed ? DwiBackendKind.unsupported : DwiBackendKind.isolate,
        protocolVersion: 1,
        transferables: true,
        cancellation: DwiCancellation.running,
      );

  @override
  Future<DwiWorkerHandle> spawnHandle() async {
    if (_closed) {
      throw const DwiUnsupportedException('backend is closed');
    }
    late final NativeWorkerHandle handle;
    handle = await NativeWorkerHandle.spawn(
      registry,
      _config,
      onClosed: () => _handles.remove(handle),
    );
    if (_closed) {
      await handle.close();
      throw const DwiUnsupportedException('backend is closed');
    }
    _handles.add(handle);
    return handle;
  }

  @override
  Future<void> close() async {
    _closed = true;
    // Dedicated handles are owned by this backend (ADR-013 decision 9).
    final handles = List<NativeWorkerHandle>.of(_handles);
    _handles.clear();
    for (final handle in handles) {
      await handle.close();
    }
  }
}
