import 'package:dwi/dwi.dart';
import 'package:dwi_core/dwi_worker.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    Dwi.registerTask('scopedChannelFind', (Object? input) {
      return DwiWorkerChannels.find(input! as String) != null;
    });
    Dwi.registerTask('scopedChannelEcho', (Object? input) {
      final channel = DwiWorkerChannels.find(input! as String);
      if (channel == null) return 'missing';
      channel.messages.listen(
        (message) => channel.send('echo:$message'),
        onError: (Object error, StackTrace stack) {},
      );
      return 'listening';
    });
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  const timeout = Duration(seconds: 10);

  group('DwiWorker.withChannel', () {
    test('body sees the channel and the worker echoes through it', () async {
      final reply = await DwiWorker.using((worker) {
        return worker.withChannel('scopeEcho', (channel) async {
          expect(
            await worker.run<String>('scopedChannelEcho', 'scopeEcho'),
            'listening',
          );
          final received = channel.messages.first;
          await channel.send('hi');
          return received;
        });
      }).timeout(timeout);
      expect(reply, 'echo:hi');
    });

    test('the name is free after the scope and can be reused', () async {
      await DwiWorker.using((worker) async {
        for (var round = 0; round < 2; round++) {
          await worker.withChannel('reuseChannel', (channel) async {
            expect(
              await worker.run<bool>('scopedChannelFind', 'reuseChannel'),
              isTrue,
            );
          });
        }
        // The handle stays usable after the scope.
        expect(
          await worker.run<bool>('scopedChannelFind', 'reuseChannel'),
          isFalse,
        );
      }).timeout(timeout);
    });

    test(
      'a synchronous body throw is the result and closes the scope',
      () async {
        await DwiWorker.using((worker) async {
          await expectLater(
            worker.withChannel<void>('syncChannel', (channel) {
              throw StateError('sync');
            }),
            throwsA(isA<StateError>()),
          );
          // The name was released, so a second open succeeds.
          await worker.withChannel('syncChannel', (channel) => 1);
        }).timeout(timeout);
      },
    );

    test('an asynchronous body failure is the result', () async {
      await DwiWorker.using((worker) async {
        await expectLater(
          worker.withChannel<void>('asyncChannel', (channel) async {
            throw StateError('async');
          }),
          throwsA(isA<StateError>()),
        );
        expect(await worker.withChannel('asyncChannel', (c) => 2), 2);
      }).timeout(timeout);
    });

    test('a duplicate name fails the scope and never runs the body', () async {
      await DwiWorker.using((worker) async {
        final first = await worker.openChannel('dupChannel');
        var ran = false;
        await expectLater(
          worker.withChannel('dupChannel', (channel) {
            ran = true;
          }),
          throwsA(isA<DwiChannelStateException>()),
        );
        expect(ran, isFalse);
        await first.close();
      }).timeout(timeout);
    });
  });

  group('DwiWorker.withLink', () {
    test(
      'both ends are visible in the body and both workers stay usable',
      () async {
        await DwiWorker.using((a) async {
          await DwiWorker.using((b) async {
            await DwiWorker.withLink(a, b, 'scopeLink', (link) async {
              expect(
                await a.run<bool>('scopedChannelFind', 'scopeLink'),
                isTrue,
              );
              expect(
                await b.run<bool>('scopedChannelFind', 'scopeLink'),
                isTrue,
              );
            });
            // Both handles still run tasks after the link scope.
            expect(
              await a.run<bool>('scopedChannelFind', 'scopeLink'),
              isFalse,
            );
            expect(
              await b.run<bool>('scopedChannelFind', 'scopeLink'),
              isFalse,
            );
          });
        }).timeout(timeout);
      },
    );

    test('the same handle twice fails before the body runs', () async {
      await DwiWorker.using((a) async {
        var ran = false;
        await expectLater(
          DwiWorker.withLink(a, a, 'selfLink', (link) {
            ran = true;
          }),
          throwsA(isA<DwiChannelStateException>()),
        );
        expect(ran, isFalse);
      }).timeout(timeout);
    });

    test('a name already in use fails before the body runs', () async {
      await DwiWorker.using((a) async {
        await DwiWorker.using((b) async {
          final existing = await DwiWorker.link(a, b, 'busyLink');
          var ran = false;
          await expectLater(
            DwiWorker.withLink(a, b, 'busyLink', (link) {
              ran = true;
            }),
            throwsA(isA<DwiChannelStateException>()),
          );
          expect(ran, isFalse);
          await existing.close();
        });
      }).timeout(timeout);
    });
  });
}
