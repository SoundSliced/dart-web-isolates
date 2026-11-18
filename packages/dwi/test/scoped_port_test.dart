import 'dart:async';

import 'package:dwi/dwi.dart';
import 'package:dwi_core/dwi_worker.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    Dwi.registerTask('scopedEcho', (Object? input) {
      final channel = DwiWorkerChannels.find(input! as String);
      if (channel == null) return 'missing';
      channel.messages.listen(
        (message) => channel.send('echo:$message'),
        onError: (Object error, StackTrace stack) {},
      );
      return 'listening';
    });
    Dwi.registerTask('scopedFind', (Object? input) {
      return DwiWorkerChannels.find(input! as String) != null;
    });
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  const timeout = Duration(seconds: 10);

  group('Dwi.withPort (host-only)', () {
    test('returns the body result and the name is free afterwards', () async {
      final result = await Dwi.withPort('hostScope', (port) async {
        expect(Dwi.port('hostScope'), same(port));
        final reply = port.messages.first;
        await port.send('ping');
        return reply;
      }).timeout(timeout);
      expect(result, 'ping');
      expect(Dwi.port('hostScope'), isNull);
    });

    test('a synchronous throw closes the port and is the result', () async {
      await expectLater(
        Dwi.withPort<void>('syncThrow', (port) => throw StateError('sync')),
        throwsA(isA<StateError>()),
      );
      expect(Dwi.port('syncThrow'), isNull);
    });

    test('an asynchronous failure closes the port', () async {
      await expectLater(
        Dwi.withPort<void>('asyncFail', (port) async {
          throw StateError('async');
        }),
        throwsA(isA<StateError>()),
      );
      expect(Dwi.port('asyncFail'), isNull);
    });

    test('a duplicate name throws and never closes the first port', () async {
      final first = Dwi.createPort('dupScope');
      await expectLater(
        Dwi.withPort('dupScope', (port) => 'unreachable'),
        throwsA(isA<DwiChannelStateException>()),
      );
      expect(Dwi.port('dupScope'), same(first));
      await first.close();
    });

    test('concurrent scopes with distinct names do not interfere', () async {
      final results = await Future.wait<String>([
        Dwi.withPort('concA', (port) async {
          final reply = port.messages.first;
          await port.send('a');
          return reply.then((value) => 'A:$value');
        }),
        Dwi.withPort('concB', (port) async {
          final reply = port.messages.first;
          await port.send('b');
          return reply.then((value) => 'B:$value');
        }),
      ]).timeout(timeout);
      expect(results, ['A:a', 'B:b']);
    });
  });

  group('DwiWorker.withPort (bound to the handle)', () {
    test('the worker sees the bound name when the callback starts', () async {
      await DwiWorker.using((worker) async {
        final found = await worker.withPort('boundFind', (port) async {
          return worker.run<bool>('scopedFind', 'port:${port.name}');
        });
        expect(found, isTrue);
      }).timeout(timeout);
    });

    test('a worker echoes through the scoped port', () async {
      final reply = await DwiWorker.using((worker) {
        return worker.withPort('boundEcho', (port) async {
          expect(
            await worker.run<String>('scopedEcho', 'port:${port.name}'),
            'listening',
          );
          final received = port.messages.first;
          await port.send('hi');
          return received;
        });
      }).timeout(timeout);
      expect(reply, 'echo:hi');
    });

    test('the same worker can reuse the name after the scope ends', () async {
      await DwiWorker.using((worker) async {
        for (var round = 0; round < 2; round++) {
          await worker.withPort('reuseName', (port) async {
            expect(
              await worker.run<bool>('scopedFind', 'port:${port.name}'),
              isTrue,
            );
          });
          expect(Dwi.port('reuseName'), isNull);
        }
      }).timeout(timeout);
    });

    test('a closed handle fails binding and never runs the callback', () async {
      final worker = await DwiWorker.spawn();
      await worker.close();
      var called = false;
      await expectLater(
        worker.withPort('boundClosed', (port) {
          called = true;
        }),
        throwsA(isA<DwiException>()),
      );
      expect(called, isFalse);
      expect(Dwi.port('boundClosed'), isNull);
    });

    test(
      'a worker closed during the callback ends it with a typed error',
      () async {
        final worker = await DwiWorker.spawn();
        final started = Completer<void>();
        final result = worker.withPort<Object?>('boundStop', (port) async {
          started.complete();
          return port.messages.first;
        });
        await started.future;
        await worker.close();
        await expectLater(
          result.timeout(timeout),
          throwsA(
            anyOf(
              isA<DwiWorkerClosedException>(),
              isA<DwiChannelClosedException>(),
            ),
          ),
        );
        expect(Dwi.port('boundStop'), isNull);
      },
    );
  });
}
