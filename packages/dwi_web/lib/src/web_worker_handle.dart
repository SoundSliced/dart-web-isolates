import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_protocol/dwi_protocol.dart';
import 'package:web/web.dart' as web;

import 'payload.dart';

/// One call waiting for, or holding, the dedicated worker.
class _Call {
  _Call(this.task, this.input);

  final String task;
  final Object? input;
  late final DwiCancellableTask<Object?> handle;
  Completer<DwiEnvelope>? reply;
  Timer? queueTimer;
  int? id;
  bool queued = true;
}

/// A handle backed by one dedicated Web Worker (ADR-013).
///
/// The worker is created from `DwiConfig.workerScript` and is never shared with
/// the `Dwi.run` pool. Calls run one at a time in FIFO order. A crash,
/// malformed message, heartbeat failure, task timeout, or cancelling a running
/// call fails the handle; recovery is an explicit [restart].
///
/// The script path is passed to `Worker` unchanged, so a relative path resolves
/// against the document URL and works for root (`/`) and subdirectory
/// (`/sub/app/`) deployments.
class WebWorkerHandle implements DwiWorkerHandle {
  WebWorkerHandle._(this._config, this._script, this._onClosed);

  /// Creates the worker and waits for its `ready` envelope.
  ///
  /// Throws [DwiStartupException] when the script is missing or does not become
  /// ready within `DwiConfig.startupTimeout`.
  static Future<WebWorkerHandle> spawn(
    DwiConfig config, {
    void Function()? onClosed,
  }) async {
    final validated = config.validated()..requireWorkerScript();
    final handle = WebWorkerHandle._(
      validated,
      validated.workerScript!,
      onClosed,
    );
    await handle._start();
    return handle;
  }

  final DwiConfig _config;
  final String _script;
  final void Function()? _onClosed;

  DwiWorkerState _state = DwiWorkerState.created;
  web.Worker? _worker;
  Completer<void>? _ready;
  Timer? _heartbeat;
  int _missedHeartbeats = 0;
  int _nextId = 1;
  final List<_Call> _queue = <_Call>[];
  _Call? _activeCall;
  Completer<DwiEnvelope>? _activeReply;

  @override
  DwiWorkerState get state => _state;

  @override
  bool get isUsable => _state == DwiWorkerState.ready;

  @override
  Future<Object?> run(String task, Object? input) => start(task, input).result;

  @override
  DwiCancellableTask<Object?> start(String task, Object? input) {
    final call = _Call(task, input);
    final handle = DwiCancellableTask<Object?>(cancel: () => _cancel(call));
    call.handle = handle;
    handle.result.ignore();

    if (!isUsable) {
      handle.completeError(_stateError());
      return handle;
    }
    if (_activeCall != null && _queue.length >= _config.maxQueuedTasks) {
      handle.completeError(
        DwiUnsupportedException(
          'worker queue is full (${_config.maxQueuedTasks} waiting)',
        ),
      );
      return handle;
    }
    try {
      // Reject closures and other values jsify/dartify silently corrupt before
      // anything is queued (ADR-010 §10.2 rule 5).
      validateDwiPayload(
        input,
        path: 'input',
        maxBytes: _config.maxPayloadBytes,
      );
    } on DwiSerializationException catch (error) {
      handle.completeError(error);
      return handle;
    }

    _queue.add(call);
    call.queueTimer = Timer(_config.queueTimeout, () {
      if (!call.queued) return;
      if (_queue.remove(call)) {
        call.queued = false;
        _settle(
          call,
          error: DwiTimeoutException(
            'task "$task" waited more than '
            '${_config.queueTimeout.inMilliseconds} ms in the queue',
          ),
        );
      }
    });
    _pump();
    return handle;
  }

  DwiException _stateError() {
    switch (_state) {
      case DwiWorkerState.failed:
        return const DwiWorkerFailedException(
          'worker handle has failed; call restart() or spawn a new handle',
        );
      case DwiWorkerState.closed:
        return const DwiWorkerClosedException('worker handle is closed');
      case DwiWorkerState.closing:
        return const DwiWorkerStateException('worker handle is closing');
      case DwiWorkerState.starting:
      case DwiWorkerState.created:
        return const DwiWorkerStateException('worker handle is starting');
      case DwiWorkerState.ready:
        return const DwiWorkerStateException('worker handle is not usable');
    }
  }

  void _pump() {
    if (_state != DwiWorkerState.ready ||
        _activeCall != null ||
        _queue.isEmpty) {
      return;
    }
    final call = _queue.removeAt(0);
    call.queued = false;
    call.queueTimer?.cancel();
    _activeCall = call;
    unawaited(_dispatch(call));
  }

  Future<void> _dispatch(_Call call) async {
    final worker = _worker;
    if (worker == null) {
      _settle(
        call,
        error: const DwiWorkerFailedException(
          'dedicated worker is not available',
        ),
      );
      _clearActive(call);
      return;
    }

    final id = _nextId++;
    final reply = Completer<DwiEnvelope>();
    reply.future.ignore();
    call.id = id;
    call.reply = reply;
    _activeReply = reply;

    try {
      final transferable = call.input is DwiTransferableBytes
          ? call.input! as DwiTransferableBytes
          : null;
      final envelope = DwiEnvelope(
        type: DwiMessageType.request,
        id: id,
        task: call.task,
        payload: transferable?.buffer ?? call.input,
        meta: <String, Object?>{
          'maxPayloadBytes': _config.maxPayloadBytes,
          if (transferable != null) 'payloadKind': 'transferableBytes',
        },
      );
      if (transferable != null) {
        worker.postMessage(
          envelope.toMap().jsify(),
          <JSObject>[transferable.buffer.toJS].toJS,
        );
        // Ownership leaves the caller only after the browser accepted it.
        transferable.markSent();
      } else {
        worker.postMessage(envelope.toMap().jsify());
      }
    } catch (error) {
      _settle(
        call,
        error: DwiSerializationException(
          'could not send task "${call.task}" to the dedicated worker: $error',
        ),
      );
      _clearActive(call);
      return;
    }

    try {
      final response = await reply.future.timeout(_config.taskTimeout);
      if (response.type == DwiMessageType.error) {
        throw _mapError(response);
      }
      if (response.type != DwiMessageType.result) {
        throw DwiRemoteException(
          message: 'unexpected ${response.type.name} for task "${call.task}"',
          taskId: id,
        );
      }
      Object? payload = response.payload;
      if (response.meta['payloadKind'] == 'transferableBytes' &&
          payload is ByteBuffer) {
        payload = DwiTransferableBytes.fromBuffer(payload);
      }
      validateDwiPayload(
        payload,
        path: 'result',
        maxBytes: _config.maxPayloadBytes,
      );
      _settle(call, value: payload);
    } on TimeoutException {
      final error = DwiTimeoutException(
        'task "${call.task}" exceeded '
        '${_config.taskTimeout.inMilliseconds} ms',
      );
      _settle(call, error: error);
      _fail(
        const DwiWorkerFailedException(
          'worker handle failed after a task timeout',
        ),
      );
    } catch (error) {
      if (error is DwiException) {
        _settle(call, error: error);
      } else {
        _settle(
          call,
          error: DwiRemoteException(
            message: error.toString(),
            remoteType: error.runtimeType.toString(),
          ),
        );
      }
    } finally {
      _clearActive(call);
    }
  }

  void _clearActive(_Call call) {
    if (identical(_activeCall, call)) {
      _activeCall = null;
      _activeReply = null;
      _pump();
    }
  }

  void _settle(_Call call, {Object? value, DwiException? error}) {
    call.queueTimer?.cancel();
    call.queued = false;
    if (call.handle.isDone) return;
    if (error != null) {
      call.handle.completeError(error);
    } else {
      call.handle.complete(value);
    }
  }

  Future<bool> _cancel(_Call call) async {
    if (call.handle.isDone) return false;
    final error = DwiCancelledException('task "${call.task}" was cancelled');
    if (call.queued && _queue.remove(call)) {
      // Queued cancellation keeps the worker: nothing has been posted.
      _settle(call, error: error);
      return true;
    }
    if (identical(_activeCall, call)) {
      // A running task cannot answer a cancel envelope, so it is terminated.
      _settle(call, error: error);
      _fail(
        const DwiWorkerFailedException(
          'worker handle failed after cancelling a running task',
        ),
      );
      return true;
    }
    return false;
  }

  @override
  Future<void> restart() async {
    if (_state != DwiWorkerState.failed) {
      throw const DwiWorkerStateException(
        'only a failed worker handle can be restarted',
      );
    }
    _terminateWorker();
    await _start();
  }

  Future<void> _start() async {
    _state = DwiWorkerState.starting;
    _queue.clear();
    _missedHeartbeats = 0;

    web.Worker worker;
    try {
      worker = web.Worker(_script.toJS);
    } catch (error) {
      _state = DwiWorkerState.failed;
      throw DwiStartupException(
        'could not create a worker for "$_script": $error',
      );
    }
    _worker = worker;
    final ready = Completer<void>();
    _ready = ready;

    worker.onmessage = ((web.MessageEvent event) {
      if (!identical(_worker, worker)) return;
      _onMessage(event);
    }).toJS;
    worker.onerror = ((web.ErrorEvent event) {
      if (!identical(_worker, worker)) return;
      _fail(
        DwiRemoteException(
          message: event.message.isEmpty
              ? 'dedicated worker reported an error'
              : event.message,
        ),
      );
    }).toJS;
    worker.onmessageerror = ((web.Event event) {
      if (!identical(_worker, worker)) return;
      _fail(
        const DwiRemoteException(
          message: 'dedicated worker sent a message that could not be '
              'deserialized',
        ),
      );
    }).toJS;

    try {
      await ready.future.timeout(_config.startupTimeout);
      _ready = null;
      _state = DwiWorkerState.ready;
      _startHeartbeat();
      _pump();
    } on TimeoutException {
      _state = DwiWorkerState.failed;
      _ready = null;
      _terminateWorker();
      throw DwiStartupException(
        'worker "$_script" did not send ready within '
        '${_config.startupTimeout.inMilliseconds} ms',
      );
    } catch (error) {
      _state = DwiWorkerState.failed;
      _ready = null;
      _terminateWorker();
      if (error is DwiException) rethrow;
      throw DwiStartupException(
        'worker "$_script" failed to start: $error',
      );
    }
  }

  void _onMessage(web.MessageEvent event) {
    if (_state == DwiWorkerState.closed || _state == DwiWorkerState.closing) {
      return;
    }
    // Any inbound message proves the worker is alive.
    _missedHeartbeats = 0;
    final data = (event.data as JSObject?)?.dartify();
    if (data is! Map) {
      _fail(
        const DwiWorkerFailedException(
          'dedicated worker sent a non-object message',
        ),
      );
      return;
    }
    DwiEnvelope envelope;
    try {
      envelope = DwiEnvelope.fromMap(Map<Object?, Object?>.from(data));
    } on DwiProtocolException catch (error) {
      _fail(DwiWorkerFailedException(error.message));
      return;
    }

    switch (envelope.type) {
      case DwiMessageType.ready:
        final ready = _ready;
        if (ready != null && !ready.isCompleted) ready.complete();
      case DwiMessageType.heartbeat:
        return;
      case DwiMessageType.result:
      case DwiMessageType.error:
        _onReply(envelope);
      default:
        _fail(
          DwiWorkerFailedException(
            'dedicated worker sent an unexpected ${envelope.type.name} '
            'message',
          ),
        );
    }
  }

  void _onReply(DwiEnvelope envelope) {
    final id = envelope.id;
    final call = _activeCall;
    final reply = _activeReply;
    if (id == null ||
        call == null ||
        call.id != id ||
        reply == null ||
        reply.isCompleted) {
      // A late reply for a call that already settled is ignored.
      return;
    }
    reply.complete(envelope);
  }

  /// Pings an idle worker so a silently dead one fails the handle instead of
  /// hanging the next call (ADR-010 §10.3).
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_config.heartbeatInterval, (timer) {
      if (_state != DwiWorkerState.ready) {
        timer.cancel();
        return;
      }
      if (_activeCall != null) {
        // A busy worker cannot answer; its work is bounded by taskTimeout.
        _missedHeartbeats = 0;
        return;
      }
      if (_missedHeartbeats >= _config.heartbeatMisses) {
        timer.cancel();
        _fail(
          const DwiWorkerFailedException(
            'dedicated worker stopped answering heartbeats',
          ),
        );
        return;
      }
      _missedHeartbeats++;
      try {
        _worker?.postMessage(
          DwiEnvelope(
            type: DwiMessageType.heartbeat,
            meta: <String, Object?>{'nonce': _missedHeartbeats},
          ).toMap().jsify(),
        );
      } catch (_) {
        // A post that throws counts as an unanswered ping.
      }
    });
  }

  void _terminateWorker() {
    _heartbeat?.cancel();
    _heartbeat = null;
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    try {
      worker.terminate();
    } catch (_) {
      // Terminating an already-dead worker is not an error.
    }
  }

  /// Moves the handle to `failed`, settles every caller, and terminates the
  /// worker exactly once.
  void _fail(DwiException error) {
    if (_state == DwiWorkerState.failed ||
        _state == DwiWorkerState.closing ||
        _state == DwiWorkerState.closed) {
      return;
    }
    _state = DwiWorkerState.failed;

    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(DwiStartupException(error.message));
    }
    final reply = _activeReply;
    _activeReply = null;
    if (reply != null && !reply.isCompleted) reply.completeError(error);

    final active = _activeCall;
    _activeCall = null;
    if (active != null) _settle(active, error: error);
    final waiting = List<_Call>.of(_queue);
    _queue.clear();
    for (final call in waiting) {
      _settle(
        call,
        error: DwiWorkerFailedException(
          'worker handle failed before the call ran: ${error.message}',
        ),
      );
    }
    _terminateWorker();
  }

  @override
  Future<void> close() async {
    if (_state == DwiWorkerState.closed ||
        _state == DwiWorkerState.closing) {
      return;
    }
    _state = DwiWorkerState.closing;
    const error = DwiWorkerClosedException('worker handle was closed');

    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    final reply = _activeReply;
    _activeReply = null;
    if (reply != null && !reply.isCompleted) reply.completeError(error);

    final active = _activeCall;
    _activeCall = null;
    if (active != null) _settle(active, error: error);
    final waiting = List<_Call>.of(_queue);
    _queue.clear();
    for (final call in waiting) {
      _settle(call, error: error);
    }

    _terminateWorker();
    _state = DwiWorkerState.closed;
    _onClosed?.call();
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
