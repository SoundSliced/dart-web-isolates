import 'dart:typed_data';

import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    Dwi.registerTask('echo', (Object? input) => input);
    Dwi.registerTask('boom', (Object? input) => throw StateError('boom'));
    Dwi.registerTask('ignoreBytes', (Object? input) => 'ok');
    Dwi.registerTask('napMs', (Object? input) async {
      await Future<void>.delayed(Duration(milliseconds: input! as int));
      return 'rested';
    });
    await Dwi.configure(const DwiConfig(metrics: true, maxWorkers: 3));
  });

  tearDownAll(() => Dwi.close());

  test('counts completed and failed calls and their durations', () async {
    final before = Dwi.metrics();

    expect(await Dwi.run<Object?>('echo', 'a'), 'a');
    expect(await Dwi.run<Object?>('echo', 'b'), 'b');
    await expectLater(Dwi.run<Object?>('boom'), throwsA(isA<DwiException>()));

    final after = Dwi.metrics();
    expect(after.callsStarted - before.callsStarted, 3);
    expect(after.callsCompleted - before.callsCompleted, 2);
    expect(after.callsFailed - before.callsFailed, 1);
    expect(after.callsRunning, 0);
    expect(after.maxCallTime, greaterThan(Duration.zero));
    expect(after.totalCallTime, greaterThanOrEqualTo(after.maxCallTime));
  });

  test('counts transferable bytes and not copied inputs', () async {
    final before = Dwi.metrics();

    await Dwi.run<Object?>(
      'ignoreBytes',
      DwiTransferableBytes(Uint8List(1024)),
    );
    await Dwi.run<Object?>('ignoreBytes', Uint8List(4096));

    final after = Dwi.metrics();
    expect(after.transferableBytes - before.transferableBytes, 1024);
  });

  test('poolState lists running calls and is empty when idle', () async {
    final call = Dwi.run<Object?>('napMs', 300);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final busy = Dwi.poolState();
    expect(busy.maxWorkers, 3);
    expect(busy.queued, 0);
    expect(busy.workers, hasLength(1));
    expect(busy.workers.single.busy, isTrue);
    expect(busy.workers.single.failed, isFalse);

    expect(await call, 'rested');
    final idle = Dwi.poolState();
    expect(idle.workers, isEmpty);
    expect(idle.queued, 0);
  });
}
