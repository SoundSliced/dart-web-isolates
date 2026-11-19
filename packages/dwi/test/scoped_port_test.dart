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

    test('simultaneous scopes with one name produce one owner', () async {
      final first = await DwiWorker.spawn();
      final second = await DwiWorker.spawn();
      addTearDown(first.close);
      addTearDown(second.close);
      final owner = Completer<void>();
      final release = Completer<void>();

      final winner = first.withPort('sameName', (port) async {
        owner.complete();
        await release.future;
        return 'owner';
      });
      await owner.future;
      await expectLater(
        second.withPort('sameName', (port) => 'loser'),
        throwsA(isA<DwiChannelStateException>()),
      );
      // The losing scope must not close the owner's port.
      expect(Dwi.port('sameName'), isNotNull);
      release.complete();
      expect(await winner.timeout(timeout), 'owner');
      expect(Dwi.port('sameName'), isNull);
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

  group('failure paths (ADR-033)', () {
    setUpAll(() {
      Dwi.registerTask('slowScoped', (Object? input) async {
        await Future<void>.delayed(Duration(milliseconds: input! as int));
        return 'slow';
      });
      Dwi.registerTask('floodScoped', (Object? input) {
        final channel = DwiWorkerChannels.find(input! as String)!;
        // Two messages into a one-slot backlog: the second waits for room.
        for (var i = 0; i < 2; i++) {
          unawaited(channel.send('flood $i').catchError((Object _) {}));
        }
        return 'sent';
      });
    });

    tearDown(() => Dwi.configure(const DwiConfig()));

    test(
      'a worker failure fails the scope and frees the name after restart',
      () async {
        await Dwi.configure(
          const DwiConfig(taskTimeout: Duration(milliseconds: 50)),
        );
        final errors = await _uncaught(() async {
          final worker = await DwiWorker.spawn();
          try {
            final started = Completer<void>();
            final scope = worker.withPort<Object?>('failWait', (port) async {
              started.complete();
              return port.messages.first;
            });
            await started.future;
            await expectLater(
              worker.run<String>('slowScoped', 5000),
              throwsA(isA<DwiTimeoutException>()),
            );
            await expectLater(
              scope.timeout(timeout),
              throwsA(isA<DwiWorkerFailedException>()),
            );
            expect(Dwi.port('failWait'), isNull);

            // The restarted context starts with no inherited binding.
            await worker.restart();
            expect(
              await worker.run<bool>('scopedFind', 'port:failWait'),
              isFalse,
            );
            final reuse = await worker
                .withPort<Object?>('failWait', (port) async {
                  expect(
                    await worker.run<String>('scopedEcho', 'port:${port.name}'),
                    'listening',
                  );
                  final reply = port.messages.first;
                  await port.send('again');
                  return reply;
                })
                .timeout(timeout);
            expect(reuse, 'echo:again');
          } finally {
            await worker.close();
          }
        });
        expect(errors, isEmpty);
      },
    );

    test(
      'a worker failure while delivery is paused fails the scope promptly',
      () async {
        await Dwi.configure(
          const DwiConfig(taskTimeout: Duration(milliseconds: 50)),
        );
        final errors = await _uncaught(() async {
          final worker = await DwiWorker.spawn();
          try {
            final started = Completer<void>();
            final release = Completer<void>();
            final scope = worker.withPort<Object?>('pausedFail', (port) async {
              // A host listener that is paused: the backlog fills and the
              // binding's delivery waits, as ADR-032 describes.
              final listener = port.messages.listen((_) {});
              listener.pause();
              started.complete();
              await release.future;
              await listener.cancel();
              return 'body';
            }, bufferSize: 1);
            await started.future;
            expect(
              await worker.run<String>('floodScoped', 'port:pausedFail'),
              'sent',
            );
            await expectLater(
              worker.run<String>('slowScoped', 5000),
              throwsA(isA<DwiTimeoutException>()),
            );
            // The scope must settle now, while the body still waits on its release.
            await expectLater(
              scope.timeout(timeout),
              throwsA(isA<DwiWorkerFailedException>()),
            );
            expect(Dwi.port('pausedFail'), isNull);
            release.complete();
          } finally {
            await worker.close();
          }
        });
        expect(errors, isEmpty);
      },
    );

    test('a callback error wins over a later worker failure', () async {
      await Dwi.configure(
        const DwiConfig(taskTimeout: Duration(milliseconds: 50)),
      );
      final errors = await _uncaught(() async {
        final worker = await DwiWorker.spawn();
        try {
          final scope = worker.withPort<Object?>('bodyFirst', (port) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            throw StateError('callback failed');
          });
          await expectLater(scope.timeout(timeout), throwsA(isA<StateError>()));
          expect(Dwi.port('bodyFirst'), isNull);
          // A worker failure after the scope ended must not surface through it.
          await expectLater(
            worker.run<String>('slowScoped', 5000),
            throwsA(isA<DwiTimeoutException>()),
          );
        } finally {
          await worker.close();
        }
      });
      expect(errors, isEmpty);
    });

    test('closing the port during the callback ends the scope with a channel error', () async {
      final errors = await _uncaught(() async {
        final worker = await DwiWorker.spawn();
        try {
          final started = Completer<void>();
          final scope = worker.withPort<Object?>('manualClose', (port) async {
            started.complete();
            return port.messages.first;
          });
          await started.future;
          await Dwi.port('manualClose')!.close();
          await expectLater(
            scope.timeout(timeout),
            throwsA(isA<DwiChannelClosedException>()),
          );
          expect(Dwi.port('manualClose'), isNull);
          expect(
            await worker
                .withPort('manualClose', (port) => 'reused')
                .timeout(timeout),
            'reused',
          );
        } finally {
          await worker.close();
        }
      });
      expect(errors, isEmpty);
    });
  });
}

/// Runs [body] in a zone and returns every error that escaped it. Late callback
/// or binding failures must not appear here (ADR-033).
Future<List<Object>> _uncaught(Future<void> Function() body) async {
  final errors = <Object>[];
  await runZonedGuarded(body, (error, stack) => errors.add(error));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return errors;
}
