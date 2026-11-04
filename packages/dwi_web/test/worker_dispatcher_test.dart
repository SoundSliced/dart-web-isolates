import 'dart:async';

import 'package:dwi_protocol/dwi_protocol.dart';
import 'package:dwi_web/src/worker_dispatcher.dart';
import 'package:test/test.dart';

DwiEnvelope request(String task, {Object? payload, int id = 1}) => DwiEnvelope(
  type: DwiMessageType.request,
  id: id,
  task: task,
  payload: payload,
);

void main() {
  group('DwiWorkerDispatcher', () {
    test('runs a task and returns its result', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{
        'double': (input) => (input! as int) * 2,
      }, workerId: 'w1');

      final response = await dispatcher.handle(request('double', payload: 21));

      expect(response, isNotNull);
      expect(response!.type, DwiMessageType.result);
      expect(response.id, 1);
      expect(response.payload, 42);
      expect(response.meta['workerId'], 'w1');
    });

    test('awaits asynchronous tasks', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{
        'later': (input) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return input;
        },
      });

      final response = await dispatcher.handle(request('later', payload: 'ok'));

      expect(response!.type, DwiMessageType.result);
      expect(response.payload, 'ok');
    });

    test('maps an unknown task to a typed error', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{});

      final response = await dispatcher.handle(request('missing'));

      expect(response!.type, DwiMessageType.error);
      expect(response.error!.code, DwiErrorCode.unknownTask);
      expect(response.error!.message, contains('missing'));
    });

    test('requires a task name', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{});

      final response = await dispatcher.handle(
        const DwiEnvelope(type: DwiMessageType.request, id: 3),
      );

      expect(response!.type, DwiMessageType.error);
      expect(response.error!.code, DwiErrorCode.protocol);
    });

    test('captures remote type and stack', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{
        'boom': (input) => throw StateError('boom'),
      });

      final response = await dispatcher.handle(request('boom'));

      expect(response!.type, DwiMessageType.error);
      expect(response.error!.code, DwiErrorCode.remote);
      expect(response.error!.remoteType, contains('StateError'));
      expect(response.error!.remoteStack, isNotEmpty);
      expect(response.error!.taskId, 1);
    });

    test('rejects a non-cloneable result instead of sending it', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{
        'closure': (Object? input) => (int value) => value,
        'object': (Object? input) => _PayloadObject(),
      });

      final closure = await dispatcher.handle(
        const DwiEnvelope(
          type: DwiMessageType.request,
          id: 1,
          task: 'closure',
        ),
      );
      expect(closure?.type, DwiMessageType.error);
      expect(closure?.error?.code, DwiErrorCode.serialization);

      final object = await dispatcher.handle(
        const DwiEnvelope(
          type: DwiMessageType.request,
          id: 2,
          task: 'object',
        ),
      );
      expect(object?.type, DwiMessageType.error);
      expect(object?.error?.code, DwiErrorCode.serialization);
    });

    test('rejects a non-cloneable input instead of invoking the task', () async {
      var invoked = false;
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{
        'echo': (Object? input) {
          invoked = true;
          return input;
        },
      });

      final response = await dispatcher.handle(
        DwiEnvelope(
          type: DwiMessageType.request,
          id: 3,
          task: 'echo',
          payload: <Object?, Object?>{1: 'bad key'},
        ),
      );

      expect(invoked, isFalse);
      expect(response?.type, DwiMessageType.error);
      expect(response?.error?.code, DwiErrorCode.serialization);
    });

    test('shutdown closes the dispatcher', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{
        'echo': (input) => input,
      });

      final closed = await dispatcher.handle(
        const DwiEnvelope(type: DwiMessageType.shutdown, id: 7),
      );
      final after = await dispatcher.handle(request('echo', id: 8));

      expect(closed!.type, DwiMessageType.closed);
      expect(dispatcher.isClosed, isTrue);
      expect(after!.type, DwiMessageType.error);
      expect(after.error!.code, DwiErrorCode.protocol);
    });

    test('does not pretend cancellation is implemented', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{});

      final response = await dispatcher.handle(
        const DwiEnvelope(type: DwiMessageType.cancel, id: 9),
      );

      expect(response!.type, DwiMessageType.error);
      expect(response.error!.code, DwiErrorCode.protocol);
      expect(response.error!.message, contains('not implemented'));
    });

    test('enforces the payload budget sent in request metadata', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{
        'big': (Object? input) => 'x' * 200,
      });

      final response = await dispatcher.handle(
        const DwiEnvelope(
          type: DwiMessageType.request,
          id: 11,
          task: 'big',
          meta: <String, Object?>{'maxPayloadBytes': 64},
        ),
      );

      expect(response?.type, DwiMessageType.error);
      expect(response?.error?.code, DwiErrorCode.serialization);
      expect(response?.error?.message, contains('maxPayloadBytes'));
    });

    test('rejects unexpected message types', () async {
      final dispatcher = DwiWorkerDispatcher(<String, DwiWorkerTask>{});

      final response = await dispatcher.handle(
        const DwiEnvelope(type: DwiMessageType.result, id: 10),
      );

      expect(response!.type, DwiMessageType.error);
      expect(response.error!.code, DwiErrorCode.protocol);
    });
  });
}

class _PayloadObject {
  final int value = 1;
}
