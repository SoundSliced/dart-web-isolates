import 'dart:async';
import 'dart:js_interop';

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
}

/// Executes named tasks in dedicated Web Workers over the DWI protocol.
///
/// Workers are pooled lazily. A task that exceeds `taskTimeout`, or a worker
/// that crashes, is terminated; failures are never silently retried on the main
/// thread. Queued callers are woken when capacity becomes available, including
/// after a termination or startup failure.
class WebBackend implements DwiBackend {
  DwiConfig _config = const DwiConfig();
  final List<_WorkerSlot> _slots = <_WorkerSlot>[];
  final List<Completer<_WorkerSlot>> _waiters = <Completer<_WorkerSlot>>[];
  int _nextWorkerId = 1;
  int _nextTaskId = 1;
  bool _closed = false;
  bool _draining = false;

  @override
  Future<void> configure(DwiConfig config) async {
    _config = config.validated();
  }

  @override
  Future<Object?> run(String task, Object? input) async {
    if (_closed) {
      throw const DwiUnsupportedException('backend is closed');
    }
    // Reject values jsify/dartify would silently corrupt (for example a closure
    // becoming `{}`) before a worker is acquired.
    validateDwiPayload(
      input,
      path: 'input',
      maxBytes: _config.maxPayloadBytes,
    );

    final slot = await _acquire();
    final id = _nextTaskId++;
    final completer = Completer<DwiEnvelope>();
    slot.pending[id] = completer;

    try {
      final envelope = DwiEnvelope(
        type: DwiMessageType.request,
        id: id,
        task: task,
        payload: input,
        meta: <String, Object?>{
          'workerId': 'w${slot.id}',
          'maxPayloadBytes': _config.maxPayloadBytes,
        },
      );
      try {
        slot.worker.postMessage(envelope.toMap().jsify());
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
      validateDwiPayload(
        response.payload,
        path: 'result',
        maxBytes: _config.maxPayloadBytes,
      );
      return response.payload;
    } on TimeoutException {
      _terminate(slot);
      throw DwiTimeoutException(
        'task "$task" exceeded ${_config.taskTimeout.inMilliseconds} ms',
      );
    } finally {
      slot.pending.remove(id);
      if (!slot.failed) _release(slot);
    }
  }

  @override
  Future<DwiCapabilities> capabilities() async {
    return DwiCapabilities(
      backend: _closed ? DwiBackendKind.unsupported : DwiBackendKind.worker,
      protocolVersion: dwiProtocolVersion,
      // v0.3 copies every payload. Transfer semantics arrive in v0.4.
      transferables: false,
      workerCount: _slots.length,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final slot in List<_WorkerSlot>.of(_slots)) {
      _terminate(slot);
    }
    _slots.clear();
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(const DwiUnsupportedException('backend is closed'));
      }
    }
    _waiters.clear();
  }

  Future<_WorkerSlot> _acquire() async {
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
    final waiter = Completer<_WorkerSlot>();
    _waiters.add(waiter);
    _drainWaiters();
    return waiter.future;
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
    final slot = _WorkerSlot(web.Worker(script.toJS), _nextWorkerId++);
    _slots.add(slot);

    slot.worker.onmessage = ((web.MessageEvent event) {
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

    try {
      await slot.ready.future.timeout(_config.startupTimeout);
    } on TimeoutException {
      _terminate(slot);
      throw DwiStartupException(
        'worker "$script" did not send ready within '
        '${_config.startupTimeout.inMilliseconds} ms',
      );
    }
    return slot;
  }

  void _fail(_WorkerSlot slot, String message) {
    if (slot.failed) return;
    slot.failed = true;
    if (!slot.ready.isCompleted) {
      slot.ready.completeError(DwiStartupException(message));
    }
    for (final completer in slot.pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          DwiRemoteException(message: message, workerId: 'w${slot.id}'),
        );
      }
    }
    slot.pending.clear();
    _terminate(slot);
  }

  void _terminate(_WorkerSlot slot) {
    slot.failed = true;
    _slots.remove(slot);
    try {
      slot.worker.terminate();
    } catch (_) {
      // terminate on an already-dead worker is not an error.
    }
    // A terminated worker frees capacity; hand it to queued callers instead of
    // leaving them waiting for a release that will never happen.
    _drainWaiters();
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
        final idle = _idleSlot();
        if (idle != null) {
          idle.busy = true;
          _waiters.removeAt(0).complete(idle);
          continue;
        }
        if (_slots.length >= _config.maxWorkers) break;

        _WorkerSlot slot;
        try {
          slot = await _spawn();
        } catch (error, stack) {
          final waiter = _waiters.removeAt(0);
          if (!waiter.isCompleted) waiter.completeError(error, stack);
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
        slot.busy = true;
        _waiters.removeAt(0).complete(slot);
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
