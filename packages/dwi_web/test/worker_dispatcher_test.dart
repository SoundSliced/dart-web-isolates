import 'dart:async';

import 'package:dwi_core/dwi_core.dart';
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

  group('channels (ADR-014)', () {
    setUp(DwiWorkerChannels.clear);

    DwiEnvelope channel(
      DwiMessageType type, {
      String name = 'chat',
      int gen = 1,
      int? seq,
      Object? payload,
      Map<String, Object?> extra = const <String, Object?>{},
    }) {
      return DwiEnvelope(
        type: type,
        payload: payload,
        meta: <String, Object?>{
          'channel': name,
          'gen': gen,
          if (seq != null) 'seq': seq,
          ...extra,
        },
      );
    }

    test('opens a channel, receives and acknowledges a message', () async {
      final emitted = <DwiEnvelope>[];
      final dispatcher = DwiWorkerDispatcher(
        <String, DwiWorkerTask>{},
        emit: emitted.add,
      );

      final opened = await dispatcher.handle(
        channel(
          DwiMessageType.channelOpen,
          extra: <String, Object?>{'bufferSize': 4},
        ),
      );
      expect(opened!.type, DwiMessageType.channelOpened);
      expect(opened.meta['opened'], isTrue);
      expect(opened.meta['gen'], 1);

      final endpoint = DwiWorkerChannels.find('chat');
      expect(endpoint, isNotNull);
      final received = <Object?>[];
      endpoint!.messages.listen(
        received.add,
        onError: (Object error, StackTrace stack) {},
      );

      await dispatcher.handle(
        channel(DwiMessageType.channelMessage, seq: 1, payload: 'ping'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, <Object?>['ping']);
      expect(
        emitted.where((envelope) => envelope.type == DwiMessageType.channelAck),
        hasLength(1),
      );
      expect(
        emitted.firstWhere(
          (envelope) => envelope.type == DwiMessageType.channelAck,
        ).meta['seq'],
        1,
      );
    });

    test('sends from the worker side and completes on a host ack', () async {
      final emitted = <DwiEnvelope>[];
      final dispatcher = DwiWorkerDispatcher(
        <String, DwiWorkerTask>{},
        emit: emitted.add,
      );
      await dispatcher.handle(channel(DwiMessageType.channelOpen));
      final endpoint = DwiWorkerChannels.find('chat')!;

      final send = endpoint.send('progress');
      expect(emitted, hasLength(1));
      expect(emitted.single.type, DwiMessageType.channelMessage);
      expect(emitted.single.meta['gen'], 1);
      final seq = emitted.single.meta['seq']! as int;

      var completed = false;
      unawaited(send.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      await dispatcher.handle(
        channel(DwiMessageType.channelAck, seq: seq),
      );
      await send;
    });

    test('rejects a duplicate name and a stale generation is ignored',
        () async {
      final emitted = <DwiEnvelope>[];
      final dispatcher = DwiWorkerDispatcher(
        <String, DwiWorkerTask>{},
        emit: emitted.add,
      );
      await dispatcher.handle(channel(DwiMessageType.channelOpen));

      final duplicate = await dispatcher.handle(
        channel(DwiMessageType.channelOpen),
      );
      expect(duplicate!.type, DwiMessageType.error);
      expect(duplicate.error!.code, DwiErrorCode.channel);
      expect(duplicate.meta['channel'], 'chat');

      final endpoint = DwiWorkerChannels.find('chat')!;
      final received = <Object?>[];
      endpoint.messages.listen(
        received.add,
        onError: (Object error, StackTrace stack) {},
      );
      await dispatcher.handle(
        channel(
          DwiMessageType.channelMessage,
          gen: 2,
          seq: 1,
          payload: 'stale',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
      expect(emitted, isEmpty);
    });

    test('a host close closes the worker endpoint and replies', () async {
      final emitted = <DwiEnvelope>[];
      final dispatcher = DwiWorkerDispatcher(
        <String, DwiWorkerTask>{},
        emit: emitted.add,
      );
      await dispatcher.handle(channel(DwiMessageType.channelOpen));
      final endpoint = DwiWorkerChannels.find('chat')!;
      final done = Completer<void>();
      endpoint.messages.listen(
        (_) {},
        onError: (Object error, StackTrace stack) {},
        onDone: done.complete,
      );

      await dispatcher.handle(channel(DwiMessageType.channelClose));
      await done.future.timeout(const Duration(seconds: 5));
      expect(
        emitted.any(
          (envelope) => envelope.type == DwiMessageType.channelClosed,
        ),
        isTrue,
      );
      expect(DwiWorkerChannels.find('chat'), isNull);
    });

    test('shutdown errors open channels', () async {
      final dispatcher = DwiWorkerDispatcher(
        <String, DwiWorkerTask>{},
        emit: (_) {},
      );
      await dispatcher.handle(channel(DwiMessageType.channelOpen));
      final endpoint = DwiWorkerChannels.find('chat')!;
      Object? caught;
      final done = Completer<void>();
      endpoint.messages.listen(
        (_) {},
        onError: (Object error, StackTrace stack) {
          caught = error;
        },
        onDone: done.complete,
      );
      await dispatcher.handle(
        const DwiEnvelope(type: DwiMessageType.shutdown),
      );
      await done.future.timeout(const Duration(seconds: 5));
      expect(caught, isA<DwiWorkerClosedException>());
    });
  });
  });
}

class _PayloadObject {
  final int value = 1;
}
