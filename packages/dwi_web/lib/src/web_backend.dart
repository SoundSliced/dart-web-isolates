import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_protocol/dwi_protocol.dart';
import 'package:web/web.dart' as web;

import 'payload.dart';

/// One live worker and its in-flight requests.
class _WorkerSlot {
  _WorkerSlot(this.worker, this.id);

  final web.Worker worker;
  final int id;
  final Map<int, Completer<DwiEnvelope>> pending =
      <int, Completer<DwiEnvelope>>{};
  final Completer<void> ready = Completer<void>();
  bool busy = false;
  bool failed = false;

  /// Consecutive heartbeats not answered while idle (ADR-010 §10.3).
  int missedHeartbeats = 0;
  Timer? heartbeat;
}

/// One caller waiting for pool capacity.
///
/// [timedOut] lets the drain loop skip a waiter whose queue deadline expired
/// between being scheduled and being handed a slot.
class _Waiter {
  final Completer<_WorkerSlot> completer = Completer<_WorkerSlot>();
  bool timedOut = false;
}

/// Where a cancellable request currently sits in the pool.
///
/// `waiter` is set while the request is queued, `slot`/`id` once a worker
/// executes it, and [cancelled] records a cancellation that arrived in the
/// window between being handed a slot and posting the request.
class _CancelState {
  late final DwiCancellableTask<Object?> handle;
  _Waiter? waiter;
  _WorkerSlot? slot;
  int? id;
  bool cancelled = false;
}

/// Executes named tasks in dedicated Web Workers over the DWI protocol.
///
/// Workers are pooled lazily. A task that exceeds `taskTimeout`, a worker that
/// crashes, or a message that cannot be decoded terminates that worker and
/// settles every affected caller with a typed error. Queued callers are woken
/// when capacity becomes available, including after a termination or startup
/// failure, and their wait is bounded by `queueTimeout`.
///
/// Cancellation follows ADR-010 §10.1: a queued request leaves the queue, a
/// running request terminates its worker, and `result` is the only future that
/// receives [DwiCancelledException].
class WebBackend implements DwiBackend {
  /// How many startups may fail in a row before the queued callers are failed.
  static const int _maxConsecutiveSpawnFailures = 3;

  DwiConfig _config = const DwiConfig();
  final List<_WorkerSlot> _slots = <_WorkerSlot>[];
  final List<_Waiter> _waiters = <_Waiter>[];
  int _nextWorkerId = 1;
  int _nextTaskId = 1;
  int _consecutiveSpawnFailures = 0;
  bool _closed = false;
  bool _draining = false;

  @override
  Future<void> configure(DwiConfig config) async {
    _config = config.validated();
  }

  @override
  Future<Object?> run(String task, Object? input) =>
      start(task, input).result;

  @override
  DwiCancellableTask<Object?> start(String task, Object? input) {
    final state = _CancelState();
    final handle = DwiCancellableTask<Object?>(
      cancel: () => _cancel(task, state),
    );
    state.handle = handle;
    // A late settlement (close, termination) must not become an unhandled
    // asynchronous error after the caller stopped listening.
    handle.result.ignore();
    unawaited(_execute(task, input, state));
    return handle;
  }

  Future<void> _execute(
    String task,
    Object? input,
    _CancelState state,
  ) async {
    final handle = state.handle;
    _WorkerSlot? slot;
    int? id;
    try {
      if (_closed) {
        throw const DwiUnsupportedException('backend is closed');
      }
      // Reject values jsify/dartify would silently corrupt (for example a
      // closure becoming `{}`) before a worker is acquired.
      validateDwiPayload(
        input,
        path: 'input',
        maxBytes: _config.maxPayloadBytes,
      );

      slot = await _acquire(task, state);
      state.slot = slot;
      if (state.cancelled || _closed) {
        throw DwiCancelledException('task "$task" was cancelled');
      }

      id = _nextTaskId++;
      state.id = id;
      final completer = Completer<DwiEnvelope>();
      completer.future.ignore();
      slot.pending[id] = completer;

      try {
        final transferable = input is DwiTransferableBytes ? input : null;
        final envelope = DwiEnvelope(
          type: DwiMessageType.request,
          id: id,
          task: task,
          payload: transferable?.buffer ?? input,
          meta: <String, Object?>{
            'workerId': 'w${slot.id}',
            'maxPayloadBytes': _config.maxPayloadBytes,
            if (transferable != null) 'payloadKind': 'transferableBytes',
          },
        );
        if (transferable != null) {
          slot.worker.postMessage(
            envelope.toMap().jsify(),
            <JSObject>[transferable.buffer.toJS].toJS,
          );
          // Ownership leaves the caller only after the browser accepted the
          // transfer; a DataCloneError above keeps it usable.
          transferable.markSent();
        } else {
          slot.worker.postMessage(envelope.toMap().jsify());
        }
      } catch (error) {
        // A synchronous postMessage failure (for example DataCloneError) must
        // not leave the slot busy forever.
        throw DwiSerializationException(
          'could not send task "$task" to worker w${slot.id}: $error',
        );
      }

      final response = await completer.future.timeout(_config.taskTimeout);
      if (response.type == DwiMessageType.error) {
        throw _mapError(response);
      }
      if (response.type != DwiMessageType.result) {
        throw DwiRemoteException(
          message: 'unexpected ${response.type.name} for task "$task"',
          workerId: 'w${slot.id}',
          taskId: id,
        );
      }
      Object? payload = response.payload;
      if (response.meta['payloadKind'] == 'transferableBytes' &&
          payload is ByteBuffer) {
        // The worker transferred ownership; the caller receives the buffer.
        payload = DwiTransferableBytes.fromBuffer(payload);
      }
      validateDwiPayload(
        payload,
        path: 'result',
        maxBytes: _config.maxPayloadBytes,
      );
      handle.complete(payload);
    } on TimeoutException {
      final error = DwiTimeoutException(
        'task "$task" exceeded ${_config.taskTimeout.inMilliseconds} ms',
      );
      if (slot != null) _terminate(slot, error);
      handle.completeError(error);
    } on DwiCancelledException catch (error) {
      handle.completeError(error);
    } catch (error, stack) {
      handle.completeError(error, stack);
    } finally {
      state.slot = null;
      if (slot != null && id != null) slot.pending.remove(id);
      if (slot != null && !slot.failed) _release(slot);
    }
  }

  /// Cancels the request described by [state] (ADR-010 §10.1).
  Future<bool> _cancel(String task, _CancelState state) async {
    final handle = state.handle;
    if (handle.isDone) return false;
    final error = DwiCancelledException('task "$task" was cancelled');

    final waiter = state.waiter;
    if (waiter != null) {
      state.cancelled = true;
      state.waiter = null;
      _waiters.remove(waiter);
      // Keeps a concurrent drain pass from handing this waiter a worker.
      waiter.timedOut = true;
      handle.completeError(error);
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error);
      }
      return true;
    }

    final slot = state.slot;
    final id = state.id;
    if (slot != null && id != null && slot.pending.containsKey(id)) {
      state.cancelled = true;
      // Settle the caller first so the observable outcome is "cancelled" even
      // though termination also settles the in-flight request.
      handle.completeError(error);
      _terminate(slot, error);
      return true;
    }
    return false;
  }

  @override
  Future<DwiWorkerHandle> spawnHandle() async {
    throw const DwiUnsupportedException(
      'dedicated handles are not implemented yet',
    );
  }

  @override
  Future<DwiCapabilities> capabilities() async {
    return DwiCapabilities(
      backend: _closed ? DwiBackendKind.unsupported : DwiBackendKind.worker,
      protocolVersion: dwiProtocolVersion,
      // Transfer semantics are implemented for arguments and results
      // (`DwiTransferableBytes`), and covered by the Chrome lifecycle test.
      transferables: true,
      workerCount: _slots.length,
      // Queued and running cancellation are implemented here; the value is
      // reported even when closed so the contract stays readable.
      cancellation: DwiCancellation.running,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    const error = DwiUnsupportedException('backend is closed');
    // Settle queued callers first: they must not wait for their queue deadline.
    for (final waiter in _waiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error);
      }
    }
    _waiters.clear();
    // Terminating a slot settles its pending requests and its startup future,
    // so a close during startup cannot leave an `_acquire` hanging.
    for (final slot in List<_WorkerSlot>.of(_slots)) {
      _terminate(slot, error);
    }
    _slots.clear();
  }

  Future<_WorkerSlot> _acquire(String task, _CancelState state) async {
    if (_closed) {
      throw const DwiUnsupportedException('backend is closed');
    }
    _config.requireWorkerScript();

    // Existing waiters have priority so first-in-first-out order is preserved.
    if (_waiters.isEmpty) {
      final idle = _idleSlot();
      if (idle != null) {
        idle.busy = true;
        return idle;
      }
      if (_slots.length < _config.maxWorkers) {
        final slot = await _spawn();
        if (_closed) {
          _terminate(slot);
          throw const DwiUnsupportedException('backend is closed');
        }
        slot.busy = true;
        return slot;
      }
    }

    if (_waiters.length >= _config.maxQueuedTasks) {
      throw DwiUnsupportedException(
        'task queue is full (${_config.maxQueuedTasks} waiting)',
      );
    }
    final waiter = _Waiter();
    state.waiter = waiter;
    _waiters.add(waiter);
    _drainWaiters();
    try {
      return await waiter.completer.future.timeout(_config.queueTimeout);
    } on TimeoutException {
      waiter.timedOut = true;
      _waiters.remove(waiter);
      if (identical(state.waiter, waiter)) state.waiter = null;
      throw DwiTimeoutException(
        'task "$task" waited more than '
        '${_config.queueTimeout.inMilliseconds} ms in the queue',
      );
    }
  }

  _WorkerSlot? _idleSlot() {
    for (final slot in _slots) {
      if (!slot.failed && slot.ready.isCompleted && !slot.busy) return slot;
    }
    return null;
  }

  void _release(_WorkerSlot slot) {
    if (slot.failed) return;
    slot.busy = false;
    _drainWaiters();
  }

  Future<_WorkerSlot> _spawn() async {
    final script = _config.workerScript!;
    web.Worker worker;
    try {
      worker = web.Worker(script.toJS);
    } catch (error) {
      throw DwiStartupException(
        'could not create a worker for "$script": $error',
      );
    }
    final slot = _WorkerSlot(worker, _nextWorkerId++);
    _slots.add(slot);

    slot.worker.onmessage = ((web.MessageEvent event) {
      if (slot.failed || _closed) return;
      // Any inbound message proves the worker is alive.
      slot.missedHeartbeats = 0;
      final data = (event.data as JSObject?)?.dartify();
      if (data is! Map) {
        _fail(slot, 'worker sent a non-object message');
        return;
      }
      DwiEnvelope envelope;
      try {
        envelope = DwiEnvelope.fromMap(data);
      } on DwiProtocolException catch (error) {
        _fail(slot, error.message);
        return;
      }
      if (envelope.type == DwiMessageType.ready) {
        if (!slot.ready.isCompleted) slot.ready.complete();
        return;
      }
      final id = envelope.id;
      final completer = id == null ? null : slot.pending[id];
      if (completer != null && !completer.isCompleted) {
        completer.complete(envelope);
      }
    }).toJS;

    slot.worker.onerror = ((web.ErrorEvent event) {
      _fail(slot, event.message.isEmpty ? 'worker error' : event.message);
    }).toJS;

    // Fires when the browser could not deserialize an inbound message. Without
    // this handler the request would wait for its full task timeout.
    slot.worker.onmessageerror = ((web.Event event) {
      _fail(slot, 'worker sent a message that could not be deserialized');
    }).toJS;

    try {
      await slot.ready.future.timeout(_config.startupTimeout);
    } on TimeoutException {
      _terminate(
        slot,
        DwiStartupException(
          'worker "$script" did not send ready within '
          '${_config.startupTimeout.inMilliseconds} ms',
        ),
      );
      throw DwiStartupException(
        'worker "$script" did not send ready within '
        '${_config.startupTimeout.inMilliseconds} ms',
      );
    }
    _startHeartbeat(slot);
    return slot;
  }

  /// Pings an idle worker so a silently dead one is replaced instead of handed
  /// the next request (ADR-010 §10.3).
  ///
  /// Busy workers are never pinged: a synchronous task cannot answer until it
  /// returns, so its liveness is bounded by `taskTimeout` instead. Detection
  /// takes up to `heartbeatMisses + 1` intervals.
  void _startHeartbeat(_WorkerSlot slot) {
    slot.heartbeat?.cancel();
    slot.heartbeat = Timer.periodic(_config.heartbeatInterval, (timer) {
      if (_closed || slot.failed) {
        timer.cancel();
        return;
      }
      if (slot.busy) {
        // Normal for long CPU work: not a missed heartbeat.
        slot.missedHeartbeats = 0;
        return;
      }
      if (slot.missedHeartbeats >= _config.heartbeatMisses) {
        timer.cancel();
        _fail(slot, 'worker w${slot.id} stopped answering heartbeats');
        return;
      }
      slot.missedHeartbeats++;
      try {
        slot.worker.postMessage(
          DwiEnvelope(
            type: DwiMessageType.heartbeat,
            id: null,
            payload: null,
            meta: <String, Object?>{'nonce': slot.missedHeartbeats},
          ).toMap().jsify(),
        );
      } catch (_) {
        // A post that throws counts as an unanswered ping.
      }
    });
  }

  void _fail(_WorkerSlot slot, String message) {
    if (slot.failed) return;
    final error = DwiRemoteException(
      message: message,
      workerId: 'w${slot.id}',
    );
    if (!slot.ready.isCompleted) {
      slot.ready.completeError(DwiStartupException(message));
    }
    _settlePending(slot, error);
    _terminate(slot, error);
  }

  /// Terminates [slot], settles its pending requests with [cause], and offers
  /// the freed capacity to queued callers.
  void _terminate(_WorkerSlot slot, [DwiException? cause]) {
    slot.failed = true;
    slot.heartbeat?.cancel();
    slot.heartbeat = null;
    _slots.remove(slot);
    final error =
        cause ??
        DwiRemoteException(
          message: 'worker w${slot.id} was terminated',
          workerId: 'w${slot.id}',
        );
    if (!slot.ready.isCompleted) {
      slot.ready.completeError(error);
    }
    _settlePending(slot, error);
    try {
      slot.worker.terminate();
    } catch (_) {
      // terminate on an already-dead worker is not an error.
    }
    _drainWaiters();
  }

  void _settlePending(_WorkerSlot slot, DwiException error) {
    for (final completer in slot.pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    slot.pending.clear();
  }

  bool get _hasCapacity =>
      _idleSlot() != null || _slots.length < _config.maxWorkers;

  void _drainWaiters() {
    if (_draining || _closed) return;
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (!_closed && _waiters.isNotEmpty) {
        final waiter = _waiters.first;
        if (waiter.timedOut || waiter.completer.isCompleted) {
          _waiters.removeAt(0);
          continue;
        }
        final idle = _idleSlot();
        if (idle != null) {
          _waiters.removeAt(0);
          idle.busy = true;
          waiter.completer.complete(idle);
          _consecutiveSpawnFailures = 0;
          continue;
        }
        if (_slots.length >= _config.maxWorkers) break;

        _WorkerSlot slot;
        try {
          slot = await _spawn();
          _consecutiveSpawnFailures = 0;
        } catch (error, stack) {
          _consecutiveSpawnFailures++;
          _waiters.remove(waiter);
          if (!waiter.completer.isCompleted) {
            waiter.completer.completeError(error, stack);
          }
          if (_consecutiveSpawnFailures >= _maxConsecutiveSpawnFailures) {
            // A worker that cannot start must not be respawned in a loop: fail
            // every remaining caller with the terminal startup error.
            final terminal = DwiStartupException(
              'worker startup failed $_consecutiveSpawnFailures times in a '
              'row; last error: $error',
            );
            for (final remaining in _waiters) {
              if (!remaining.completer.isCompleted) {
                remaining.completer.completeError(terminal);
              }
            }
            _waiters.clear();
          }
          continue;
        }
        if (_closed) {
          _terminate(slot);
          break;
        }
        if (_waiters.isEmpty) {
          slot.busy = false;
          break;
        }
        final target = _waiters.removeAt(0);
        if (target.timedOut || target.completer.isCompleted) {
          slot.busy = false;
          continue;
        }
        slot.busy = true;
        target.completer.complete(slot);
      }
    } finally {
      _draining = false;
      if (!_closed && _waiters.isNotEmpty && _hasCapacity) _drainWaiters();
    }
  }

  DwiException _mapError(DwiEnvelope envelope) {
    final error = envelope.error;
    if (error == null) {
      return DwiRemoteException(
        message: 'error message without an error payload',
        taskId: envelope.id,
      );
    }
    switch (error.code) {
      case DwiErrorCode.unknownTask:
        return DwiUnknownTaskException(error.message);
      case DwiErrorCode.serialization:
        return DwiSerializationException(error.message);
      case DwiErrorCode.timeout:
        return DwiTimeoutException(error.message);
      case DwiErrorCode.protocol:
        return DwiRemoteException(
          message: error.message,
          remoteType: 'ProtocolError',
          remoteStack: error.remoteStack,
          taskId: error.taskId ?? envelope.id,
        );
      case DwiErrorCode.remote:
      case DwiErrorCode.internal:
        return DwiRemoteException(
          message: error.message,
          remoteType: error.remoteType,
          remoteStack: error.remoteStack,
          taskId: error.taskId ?? envelope.id,
        );
    }
  }
}
