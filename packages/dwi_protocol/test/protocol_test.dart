import 'package:dwi_protocol/dwi_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('DwiEnvelope', () {
    test('round-trips a request', () {
      const envelope = DwiEnvelope(
        type: DwiMessageType.request,
        id: 7,
        task: 'primes',
        payload: <String, Object?>{'limit': 100},
      );
      final decoded = DwiEnvelope.fromMap(envelope.toMap());
      expect(decoded.type, DwiMessageType.request);
      expect(decoded.id, 7);
      expect(decoded.task, 'primes');
      expect(decoded.payload, <String, Object?>{'limit': 100});
      expect(decoded.version, dwiProtocolVersion);
    });

    test('rejects a missing or foreign version', () {
      expect(
        () => DwiEnvelope.fromMap(<Object?, Object?>{'type': 'ready'}),
        throwsA(isA<DwiProtocolException>()),
      );
      expect(
        () => DwiEnvelope.fromMap(
          <Object?, Object?>{'v': 99, 'type': 'ready'},
        ),
        throwsA(isA<DwiProtocolException>()),
      );
    });

    test('rejects an unknown type', () {
      expect(
        () => DwiEnvelope.fromMap(<Object?, Object?>{'v': 1, 'type': 'nope'}),
        throwsA(isA<DwiProtocolException>()),
      );
    });

    test('rejects a negative id', () {
      expect(
        () => DwiEnvelope.fromMap(
          <Object?, Object?>{'v': 1, 'type': 'request', 'id': -1},
        ),
        throwsA(isA<DwiProtocolException>()),
      );
    });

    test('round-trips an error payload', () {
      const envelope = DwiEnvelope(
        type: DwiMessageType.error,
        id: 3,
        error: DwiErrorPayload(
          code: DwiErrorCode.unknownTask,
          message: 'unknown operation: nope',
          remoteType: 'StateError',
          remoteStack: '#0 worker',
          fatal: false,
          taskId: 3,
        ),
      );
      final decoded = DwiEnvelope.fromMap(envelope.toMap());
      expect(decoded.error!.code, DwiErrorCode.unknownTask);
      expect(decoded.error!.message, 'unknown operation: nope');
      expect(decoded.error!.remoteType, 'StateError');
      expect(decoded.error!.taskId, 3);
    });

    test('maps an unknown error code to protocol', () {
      final payload = DwiErrorPayload.fromMap(<Object?, Object?>{
        'code': 'teapot',
        'message': 'nope',
      });
      expect(payload.code, DwiErrorCode.protocol);
      expect(payload.fatal, isFalse);
    });

    test('rejects an error without a message', () {
      expect(
        () => DwiErrorPayload.fromMap(<Object?, Object?>{'code': 'remote'}),
        throwsA(isA<DwiProtocolException>()),
      );
    });

    test('keeps meta values', () {
      const envelope = DwiEnvelope(
        type: DwiMessageType.ready,
        meta: <String, Object?>{'workerId': 'w1'},
      );
      final decoded = DwiEnvelope.fromMap(envelope.toMap());
      expect(decoded.meta['workerId'], 'w1');
    });
  });
}
