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

    test('is protocol v2', () {
      expect(dwiProtocolVersion, 2);
    });

    test('round-trips a channel message with name, generation and sequence', () {
      const envelope = DwiEnvelope(
        type: DwiMessageType.channelMessage,
        payload: 'hello',
        meta: <String, Object?>{'channel': 'chat', 'gen': 3, 'seq': 7},
      );
      final decoded = DwiEnvelope.fromMap(envelope.toMap());
      expect(decoded.type, DwiMessageType.channelMessage);
      expect(decoded.channel, 'chat');
      expect(decoded.seq, 7);
      expect(decoded.meta['gen'], 3);
      expect(decoded.payload, 'hello');
    });

    test('parses the channel error code', () {
      final payload = DwiErrorPayload.fromMap(<Object?, Object?>{
        'code': 'channel',
        'message': 'channel is full',
      });
      expect(payload.code, DwiErrorCode.channel);
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

    test('accepts an integral double for v and id (dart2wasm host)', () {
      // A dart2wasm host receives JS numbers; `dartify()` can surface an
      // integral value as double. Rejecting it broke the wasm/JS boundary
      // entirely (limitations §29).
      final decoded = DwiEnvelope.fromMap(<Object?, Object?>{
        'v': dwiProtocolVersion.toDouble(),
        'type': 'result',
        'id': 7.0,
      });

      expect(decoded.version, dwiProtocolVersion);
      expect(decoded.id, 7);
    });

    test('accepts an integral double for error.taskId', () {
      final payload = DwiErrorPayload.fromMap(<Object?, Object?>{
        'code': 'remote',
        'message': 'boom',
        'taskId': 3.0,
      });

      expect(payload.taskId, 3);
    });

    test('still rejects numbers that are not integral', () {
      expect(
        () => DwiEnvelope.fromMap(<Object?, Object?>{
          'v': 1.5,
          'type': 'ready',
        }),
        throwsA(isA<DwiProtocolException>()),
      );
      expect(
        () => DwiEnvelope.fromMap(<Object?, Object?>{
          'v': dwiProtocolVersion,
          'type': 'result',
          'id': 2.5,
        }),
        throwsA(isA<DwiProtocolException>()),
      );
      expect(
        () => DwiErrorPayload.fromMap(<Object?, Object?>{
          'code': 'remote',
          'message': 'boom',
          'taskId': 1.5,
        }),
        throwsA(isA<DwiProtocolException>()),
      );
    });
  });
}
