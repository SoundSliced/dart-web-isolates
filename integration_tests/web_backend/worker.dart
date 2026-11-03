// Worker entrypoint speaking DWI protocol v1.
//
// Compile:
//   dart compile js -O1 -o build/worker.js worker.dart

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_protocol/dwi_protocol.dart';

@JS('postMessage')
external void _postMessage(JSAny? message);

@JS('self')
external JSObject get _self;

int countPrimes(int limit) {
  final sieve = List<bool>.filled(limit + 1, false);
  var count = 0;
  for (var i = 2; i <= limit; i++) {
    if (sieve[i]) continue;
    count++;
    for (var j = i * i; j <= limit; j += i) {
      sieve[j] = true;
    }
  }
  return count;
}

final DwiTaskRegistry _registry = DwiTaskRegistry()
  ..register('echo', (Object? input) => input)
  ..register('primes', (Object? input) {
    final args = input! as Map<Object?, Object?>;
    return countPrimes(args['limit']! as int);
  })
  ..register('boom', (Object? input) => throw StateError('boom from worker'));

void _send(DwiEnvelope envelope) {
  _postMessage(envelope.toMap().jsify());
}

void _sendError(
  int? id,
  DwiErrorCode code,
  String message, {
  String remoteType = '',
  String remoteStack = '',
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
    ),
  );
}

void _handleMessage(JSAny? event) {
  final raw = (event as JSObject).getProperty('data'.toJS);
  final data = (raw as JSObject?)?.dartify();
  if (data is! Map) {
    _sendError(null, DwiErrorCode.protocol, 'message must be an object');
    return;
  }

  DwiEnvelope envelope;
  try {
    envelope = DwiEnvelope.fromMap(Map<Object?, Object?>.from(data));
  } on DwiProtocolException catch (error) {
    _sendError(null, DwiErrorCode.protocol, error.message);
    return;
  }

  if (envelope.type != DwiMessageType.request) {
    _sendError(envelope.id, DwiErrorCode.protocol, 'unexpected ${envelope.type.name}');
    return;
  }
  final task = envelope.task;
  if (task == null) {
    _sendError(envelope.id, DwiErrorCode.protocol, 'request without a task');
    return;
  }
  if (!_registry.contains(task)) {
    _sendError(envelope.id, DwiErrorCode.unknownTask, 'unknown task "$task"');
    return;
  }

  try {
    final result = _registry.invoke(task, envelope.payload);
    _send(DwiEnvelope(
      type: DwiMessageType.result,
      id: envelope.id,
      payload: result,
    ));
  } catch (error, stack) {
    _sendError(
      envelope.id,
      DwiErrorCode.remote,
      '$error',
      remoteType: error.runtimeType.toString(),
      remoteStack: stack.toString(),
    );
  }
}

void main() {
  _self.setProperty('onmessage'.toJS, _handleMessage.toJS);
  _send(const DwiEnvelope(
    type: DwiMessageType.ready,
    meta: <String, Object?>{'workerId': 'integration-worker'},
  ));
}
