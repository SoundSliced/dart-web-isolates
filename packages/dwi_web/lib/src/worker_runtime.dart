import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_protocol/dwi_protocol.dart';

import 'worker_dispatcher.dart';

@JS('postMessage')
external void _postMessage(JSAny? message, [JSObject transfer]);

@JS('self')
external JSObject get _self;

/// Starts the DWI protocol inside a dedicated Web Worker.
///
/// Generated worker entrypoints call [start] once with a map of static task
/// references. The runtime sends `ready`, dispatches `request` envelopes,
/// awaits asynchronous tasks, forwards typed errors and handles `shutdown`.
///
/// This file is not part of the host-side API; it is imported by the generated
/// worker entrypoint and compiled with `dart compile js`.
abstract final class DwiWorkerRuntime {
  /// Installs the message handler and announces readiness.
  ///
  /// [tasks] must contain real references to the task implementations, never
  /// task names alone: a string cannot keep a function alive through tree
  /// shaking.
  static void start(Map<String, DwiWorkerTask> tasks, {String workerId = ''}) {
    final dispatcher = DwiWorkerDispatcher(
      tasks,
      workerId: workerId,
      emit: _send,
    );
    _self.setProperty(
      'onmessage'.toJS,
      ((JSAny? event) {
        unawaited(_handle(dispatcher, event));
      }).toJS,
    );
    _send(
      DwiEnvelope(
        type: DwiMessageType.ready,
        meta: <String, Object?>{
          'capabilities': <String, Object?>{
            'protocolVersion': dwiProtocolVersion,
            'channels': true,
          },
          if (workerId.isNotEmpty) 'workerId': workerId,
        },
      ),
    );
  }

  static Future<void> _handle(
    DwiWorkerDispatcher dispatcher,
    JSAny? event,
  ) async {
    DwiEnvelope envelope;
    try {
      final raw = (event as JSObject).getProperty('data'.toJS);
      final data = (raw as JSObject?)?.dartify();
      if (data is! Map) {
        _sendError(null, DwiErrorCode.protocol, 'message must be an object');
        return;
      }
      envelope = DwiEnvelope.fromMap(Map<Object?, Object?>.from(data));
    } on DwiProtocolException catch (error) {
      _sendError(null, DwiErrorCode.protocol, error.message);
      return;
    } catch (error) {
      _sendError(
        null,
        DwiErrorCode.protocol,
        'could not decode message: $error',
      );
      return;
    }

    final response = await dispatcher.handle(envelope);
    if (response == null) return;
    _send(response);
    if (response.type == DwiMessageType.closed) {
      _close();
    }
  }

  static void _sendError(
    int? id,
    DwiErrorCode code,
    String message, {
    String remoteType = '',
    String remoteStack = '',
    String? channel,
  }) {
    _send(
      DwiEnvelope(
        type: DwiMessageType.error,
        id: id,
        error: DwiErrorPayload(
          code: code,
          message: message,
          remoteType: remoteType,
          remoteStack: remoteStack,
          taskId: id,
        ),
        meta: <String, Object?>{
          if (channel != null) 'channel': channel,
        },
      ),
    );
  }

  static void _send(DwiEnvelope envelope) {
    JSObject? transfer;
    final map = envelope.toMap();
    final payload = envelope.payload;
    if (payload is DwiTransferableBytes) {
      if (payload.isDetached) {
        // Nothing was sent yet, so a typed error can still reach the host.
        _sendError(
          envelope.id,
          DwiErrorCode.serialization,
          'worker tried to transfer bytes it had already sent',
        );
        return;
      }
      map['payload'] = payload.buffer;
      map['meta'] = <String, Object?>{
        ...envelope.meta,
        'payloadKind': 'transferableBytes',
      };
      transfer = <JSObject>[payload.buffer.toJS].toJS;
      payload.markSent();
    }
    try {
      if (transfer == null) {
        _postMessage(map.jsify());
      } else {
        _postMessage(map.jsify(), transfer);
      }
    } catch (error) {
      // A result payload that cannot be structured-cloned must not disappear.
      // Send a typed serialization error instead; if that also fails, close the
      // worker so the host's pending request fails rather than hanging.
      if (envelope.type == DwiMessageType.error) {
        _close();
        return;
      }
      _sendError(
        envelope.id,
        DwiErrorCode.serialization,
        'worker could not serialize the message: $error',
        remoteType: error.runtimeType.toString(),
        channel: envelope.channel,
      );
    }
  }

  static void _close() {
    try {
      _self.callMethod('close'.toJS);
    } catch (_) {
      // A worker that is already closing cannot do anything else.
    }
  }
}
