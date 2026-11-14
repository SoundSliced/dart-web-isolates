import 'dart:async';

import 'package:dwi_flutter/dwi_flutter.dart';
import 'package:test/test.dart';

void main() {
  test('returns results in input order, not completion order', () async {
    Future<int> task(int input) async {
      // Later inputs finish first.
      await Future<void>.delayed(Duration(milliseconds: 30 - input * 10));
      return input * input;
    }

    expect(await computeParallel(task, <int>[0, 1, 2]), [0, 1, 4]);
  });

  test(
    'empty input completes with an empty list without calling task',
    () async {
      var calls = 0;
      final result = await computeParallel<int, int>((int input) async {
        calls++;
        return input;
      }, const []);
      expect(result, isEmpty);
      expect(calls, 0);
    },
  );

  test('the first error fails the call', () async {
    Future<int> task(int input) async {
      if (input == 1) throw StateError('input 1 failed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return input;
    }

    await expectLater(
      computeParallel(task, [0, 1, 2]),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'a synchronous throw from task becomes a failed call, not a throw',
    () async {
      Future<int> task(int input) {
        if (input == 0) throw ArgumentError('sync failure');
        return Future<int>.value(input);
      }

      final call = computeParallel(task, [0, 1]);
      await expectLater(call, throwsA(isA<ArgumentError>()));
    },
  );

  test('calls already dispatched run to completion after a failure', () async {
    final finished = <int>[];
    Future<int> task(int input) async {
      if (input == 0) throw StateError('fail fast');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      finished.add(input);
      return input;
    }

    await expectLater(
      computeParallel(task, [0, 1, 2]),
      throwsA(isA<StateError>()),
    );
    // The call failed at once; the other two were not cancelled.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(finished, unorderedEquals([1, 2]));
  });
}
