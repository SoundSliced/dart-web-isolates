import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

void main() {
  group('DwiCancellableTask', () {
    test('settles once with a value and ignores later completion', () async {
      var cancelled = 0;
      final task = DwiCancellableTask<int>(cancel: () async {
        cancelled++;
        return true;
      });

      expect(task.isDone, isFalse);
      task.complete(7);
      task.complete(9);
      task.completeError(StateError('late'));

      expect(await task.result, 7);
      expect(task.isDone, isTrue);
      expect(cancelled, 0);
    });

    test('settles once with an error', () async {
      final task = DwiCancellableTask<int>(cancel: () async => false);
      task.completeError(const DwiCancelledException('cancelled'));
      task.complete(1);

      await expectLater(
        task.result,
        throwsA(isA<DwiCancelledException>()),
      );
    });

    test('cancel delegates and reports whether it changed the outcome', () async {
      var result = true;
      final task = DwiCancellableTask<int>(cancel: () async => result);

      expect(await task.cancel(), isTrue);
      result = false;
      expect(await task.cancel(), isFalse);
    });

    test('cancellation is delivered through result, not through cancel', () async {
      late final DwiCancellableTask<int> task;
      task = DwiCancellableTask<int>(cancel: () async {
        task.completeError(const DwiCancelledException('cancelled'));
        return true;
      });

      final expectation = expectLater(
        task.result,
        throwsA(isA<DwiCancelledException>()),
      );
      expect(await task.cancel(), isTrue);
      await expectation;
    });
  });
}
