import 'dart:async';

import 'package:dwi_flutter/dwi_flutter.dart';
import 'package:test/test.dart';

void main() {
  test('results follow input order when completion order differs', () async {
    Future<int> task(int input) async {
      await Future<void>.delayed(Duration(milliseconds: 30 - input * 10));
      return input * input;
    }

    expect(await computeParallelBounded(task, <int>[0, 1, 2], concurrency: 3), [
      0,
      1,
      4,
    ]);
  });

  test('empty input returns an empty list without calling task', () async {
    var calls = 0;
    final result = await computeParallelBounded<int, int>((input) async {
      calls++;
      return input;
    }, const []);
    expect(result, isEmpty);
    expect(calls, 0);
  });

  test('one input completes with its result', () async {
    expect(await computeParallelBounded<int, int>((i) async => i + 1, [4]), [
      5,
    ]);
  });

  test('never has more than concurrency calls in flight', () async {
    var inFlight = 0;
    var peak = 0;
    final gates = <Completer<void>>[];

    Future<int> task(int input) async {
      inFlight++;
      if (inFlight > peak) peak = inFlight;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      inFlight--;
      return input;
    }

    final call = computeParallelBounded(
      task,
      List<int>.generate(20, (i) => i),
      concurrency: 3,
    );

    // Release admitted calls one at a time, until the batch is complete.
    var released = 0;
    while (true) {
      await Future<void>.delayed(Duration.zero);
      if (released < gates.length) {
        gates[released].complete();
        released++;
      } else {
        break;
      }
    }
    final result = await call;
    expect(result, List<int>.generate(20, (i) => i));
    expect(peak, 3);
  });

  test('a synchronous throw from task becomes a failed call', () async {
    Future<int> task(int input) {
      if (input == 0) throw ArgumentError('sync failure');
      return Future<int>.value(input);
    }

    await expectLater(
      computeParallelBounded(task, [0, 1], concurrency: 2),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('the first failure stops admission of new calls', () async {
    final started = <int>[];
    Future<int> task(int input) async {
      started.add(input);
      if (input == 0) throw StateError('fail');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return input;
    }

    await expectLater(
      computeParallelBounded(
        task,
        List<int>.generate(10, (i) => i),
        concurrency: 2,
      ),
      throwsA(isA<StateError>()),
    );
    expect(started.length, lessThan(10));
  });

  test('concurrency below 1 throws ArgumentError synchronously', () {
    expect(
      () =>
          computeParallelBounded<int, int>((i) async => i, [1], concurrency: 0),
      throwsArgumentError,
    );
  });
}
