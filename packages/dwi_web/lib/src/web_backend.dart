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

/// One caller waiting for pool capacity.
///
/// [timedOut] lets the drain loop skip a waiter whose queue deadline expired
/// between being scheduled and being handed a slot.
class _Waiter {
  final Completer<_WorkerSlot> completer = Completer<_WorkerSlot>();
  bool timedOut = false;
}

/// Executes named tasks in dedicated Web Workers over the DWI protocol.
///
/// Workers are pooled lazily. A task that exceeds `taskTimeout`, a worker that
/// crashes, or a message that cannot be decoded terminates that worker and
/// settles every affected caller with a typed error. Queued callers are woken
/// when capacity becomes available, including after a termination or startup
/// failure, and their wait is bounded by `queueTimeout`.
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

    final slot = await _acquire(task);
    if (_closed) {
      _release(slot);
      throw const DwiUnsupportedException('backend is closed');
    }
    final id = _nextTaskId++;
    final completer = Completer<DwiEnvelope>();
    // A late settlement (close, termination) must not become an unhandled
    // asynchronous error after the request itself already failed.
    completer.future.ignore();
    slot.pending[id] = completer;

    try {
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
      _terminate(
        slot,
        DwiTimeoutException(
          'task "$task" exceeded ${_config.taskTimeout.inMilliseconds} ms',
        ),
      );
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
      // v0.3 copies every payload. Transfer semantics arrive in a later
      // version, so advertising them here would be a false claim.
      transferables: false,
      workerCount: _slots.length,
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

  Future<_WorkerSlot> _acquire(String task) async {
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
    _waiters.add(waiter);
    _drainWaiters();
    try {
      return await waiter.completer.future.timeout(_config.queueTimeout);
    } on TimeoutException {
      waiter.timedOut = true;
      _waiters.remove(waiter);
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
    return slot;
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
