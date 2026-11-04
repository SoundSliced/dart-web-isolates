import 'dart:async';
import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_protocol/dwi_protocol.dart';

import 'payload.dart';

/// Signature of a task executable inside a DWI worker.
///
/// Generated worker entrypoints build a `Map<String, DwiWorkerTask>` with
/// static references so the compiler keeps the task implementations alive.
typedef DwiWorkerTask = FutureOr<Object?> Function(Object? input);

/// Worker-side protocol handling, independent of JavaScript interop.
///
/// This class is deliberately pure Dart so it can be unit-tested on the VM.
/// [DwiWorkerRuntime] wires it to `self.onmessage` and `postMessage`.
class DwiWorkerDispatcher {
  /// Creates a dispatcher for [tasks].
  ///
  /// [workerId] is copied into response metadata to make worker-side logs
  /// attributable to a specific pooled worker.
  DwiWorkerDispatcher(Map<String, DwiWorkerTask> tasks, {this.workerId = ''})
    : _tasks = Map<String, DwiWorkerTask>.unmodifiable(tasks);

  final Map<String, DwiWorkerTask> _tasks;

  /// Identifier copied into error/result metadata.
  final String workerId;

  bool _closed = false;

  /// Whether a `shutdown` message has been handled.
  bool get isClosed => _closed;

  /// Task names known to this worker.
  Iterable<String> get taskNames => _tasks.keys;

  /// Handles one decoded [envelope].
  ///
  /// Returns the response envelope, or `null` when no response is required.
  /// A `shutdown` request returns a `closed` envelope and marks the dispatcher
  /// closed; later requests fail with a protocol error.
  Future<DwiEnvelope?> handle(DwiEnvelope envelope) async {
    if (_closed) {
      return _error(envelope.id, DwiErrorCode.protocol, 'worker is closed');
    }
    switch (envelope.type) {
      case DwiMessageType.request:
        return _handleRequest(envelope);
      case DwiMessageType.heartbeat:
        // Liveness probe from the host. Echo the nonce so a late reply cannot
        // be mistaken for a fresh one (ADR-010 §10.3).
        return DwiEnvelope(
          type: DwiMessageType.heartbeat,
          id: envelope.id,
          payload: null,
          meta: <String, Object?>{
            ..._meta(),
            if (envelope.meta['nonce'] != null) 'nonce': envelope.meta['nonce'],
          },
        );
      case DwiMessageType.shutdown:
        _closed = true;
        return DwiEnvelope(
          type: DwiMessageType.closed,
          id: envelope.id,
          meta: _meta(),
        );
      case DwiMessageType.cancel:
        return _error(
          envelope.id,
          DwiErrorCode.protocol,
          'cancellation is not implemented in protocol v1',
        );
      default:
        return _error(
          envelope.id,
          DwiErrorCode.protocol,
          'unexpected ${envelope.type.name} message',
        );
    }
  }

  Future<DwiEnvelope> _handleRequest(DwiEnvelope envelope) async {
    final task = envelope.task;
    if (task == null) {
      return _error(
        envelope.id,
        DwiErrorCode.protocol,
        'request without a task name',
      );
    }
    final implementation = _tasks[task];
    if (implementation == null) {
      return _error(
        envelope.id,
        DwiErrorCode.unknownTask,
        'unknown task "$task"',
      );
    }

    try {
      final limit = envelope.meta['maxPayloadBytes'];
      final maxBytes = limit is int && limit > 0 ? limit : null;
      Object? input = envelope.payload;
      if (envelope.meta['payloadKind'] == 'transferableBytes' &&
          input is ByteBuffer) {
        // The host transferred ownership of the buffer to this worker.
        input = DwiTransferableBytes.fromBuffer(input);
      }
      validateDwiPayload(input, path: 'input', maxBytes: maxBytes);
      final result = await Future<Object?>.sync(() => implementation(input));
      validateDwiPayload(result, path: 'result', maxBytes: maxBytes);
      return DwiEnvelope(
        type: DwiMessageType.result,
        id: envelope.id,
        payload: result,
        meta: _meta(),
      );
    } on DwiSerializationException catch (error) {
      return _error(
        envelope.id,
        DwiErrorCode.serialization,
        error.message,
      );
    } catch (error, stack) {
      return _error(
        envelope.id,
        DwiErrorCode.remote,
        error.toString(),
        remoteType: error.runtimeType.toString(),
        remoteStack: stack.toString(),
      );
    }
  }

  DwiEnvelope _error(
    int? id,
    DwiErrorCode code,
    String message, {
    String remoteType = '',
    String remoteStack = '',
  }) {
    return DwiEnvelope(
      type: DwiMessageType.error,
      id: id,
      error: DwiErrorPayload(
        code: code,
        message: message,
        remoteType: remoteType,
        remoteStack: remoteStack,
        taskId: id,
      ),
      meta: _meta(),
    );
  }

  Map<String, Object?> _meta() => workerId.isEmpty
      ? const <String, Object?>{}
      : <String, Object?>{'workerId': workerId};
}
