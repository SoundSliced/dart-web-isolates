import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_protocol/dwi_protocol.dart';
import 'package:web/web.dart' as web;

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
/// thread.
class WebBackend implements DwiBackend {
  DwiConfig _config = const DwiConfig();
  final List<_WorkerSlot> _slots = <_WorkerSlot>[];
  final List<Completer<_WorkerSlot>> _waiters = <Completer<_WorkerSlot>>[];
  int _nextWorkerId = 1;
  int _nextTaskId = 1;
  bool _closed = false;

  @override
  Future<void> configure(DwiConfig config) async {
    _config = config.validated();
  }

  @override
  Future<Object?> run(String task, Object? input) async {
    final slot = await _acquire();
    final id = _nextTaskId++;
    final completer = Completer<DwiEnvelope>();
    slot.pending[id] = completer;

    final envelope = DwiEnvelope(
      type: DwiMessageType.request,
      id: id,
      task: task,
      payload: input,
      meta: <String, Object?>{'workerId': 'w${slot.id}'},
    );
    slot.worker.postMessage(envelope.toMap().jsify());

    try {
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
    final transferables =
        (web.window as JSObject).hasProperty('ArrayBuffer'.toJS).toDart;
    return DwiCapabilities(
      backend: _closed ? DwiBackendKind.unsupported : DwiBackendKind.worker,
      protocolVersion: dwiProtocolVersion,
      transferables: transferables,
      workerCount: _slots.where((slot) => !slot.failed).length,
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

    for (final slot in _slots) {
      if (!slot.failed && slot.ready.isCompleted && !slot.busy) {
        slot.busy = true;
        return slot;
      }
    }
    if (_slots.length < _config.maxWorkers) {
      final slot = await _spawn();
      slot.busy = true;
      return slot;
    }
    if (_waiters.length >= _config.maxQueuedTasks) {
      throw DwiUnsupportedException(
        'task queue is full (${_config.maxQueuedTasks} waiting)',
      );
    }
    final waiter = Completer<_WorkerSlot>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release(_WorkerSlot slot) {
    slot.busy = false;
    if (_waiters.isNotEmpty && !slot.failed && slot.ready.isCompleted) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) {
        slot.busy = true;
        waiter.complete(slot);
      }
    }
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
