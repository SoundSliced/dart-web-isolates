import 'dart:async';
import 'dart:io';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';
import 'package:test/test.dart';

/// Cooperative cancellation on native isolates (ADR-027).
///
/// Task isolates cannot return a value once the caller was cancelled, so each
/// task records what it saw in a marker file named by its input.
void main() {
  late Directory dir;
  late NativeBackend backend;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dwi_coop_');
    final registry = DwiTaskRegistry()
      ..register('cooperative', (Object? input) async {
        final path = input! as String;
        final token = DwiCancelToken.current;
        for (var i = 0; i < 200; i++) {
          if (token.isCancelled) {
            File(path).writeAsStringSync('stopped at $i');
            token.throwIfCancelled();
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        File(path).writeAsStringSync('finished');
        return 'finished';
      })
      ..register('stubborn', (Object? input) {
        // Never yields, so it cannot observe the token; it would write the
        // marker after 1.5 s if it were not killed.
        final until = DateTime.now().add(const Duration(milliseconds: 1500));
        while (DateTime.now().isBefore(until)) {}
        File(input! as String).writeAsStringSync('survived');
        return 'survived';
      });
    backend = NativeBackend(registry);
  });

  tearDown(() async {
    await backend.close();
    dir.deleteSync(recursive: true);
  });

  /// Waits until [file] has content: `writeAsStringSync` creates the file
  /// before writing, so existence alone can be observed with nothing in it.
  Future<void> waitFor(File file, Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (!(file.existsSync() && file.lengthSync() > 0) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('with a grace period the task observes the token and stops', () async {
    await backend.configure(
      const DwiConfig(cancelGracePeriod: Duration(seconds: 2)),
    );
    final marker = File('${dir.path}/coop');
    final task = backend.start('cooperative', marker.path);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final watch = Stopwatch()..start();
    expect(await task.cancel(), isTrue);
    await expectLater(task.result, throwsA(isA<DwiCancelledException>()));
    // The caller is settled at once, not after the task stops.
    expect(watch.elapsedMilliseconds, lessThan(500));

    await waitFor(marker, const Duration(seconds: 2));
    expect(marker.readAsStringSync(), startsWith('stopped at'));
    expect(await task.cancel(), isFalse);
  });

  test('cancelling before the isolate reports its control port still '
      'reaches the task', () async {
    await backend.configure(
      const DwiConfig(cancelGracePeriod: Duration(seconds: 2)),
    );
    final marker = File('${dir.path}/early');
    final task = backend.start('cooperative', marker.path);
    expect(await task.cancel(), isTrue);
    await expectLater(task.result, throwsA(isA<DwiCancelledException>()));

    await waitFor(marker, const Duration(seconds: 3));
    // Either the isolate never ran the task (cancelled before spawn
    // completed) or it saw the token; it never runs to completion.
    if (marker.existsSync()) {
      expect(marker.readAsStringSync(), startsWith('stopped at'));
    }
  });

  test(
    'a task that never yields is killed when the grace period ends',
    () async {
      await backend.configure(
        const DwiConfig(cancelGracePeriod: Duration(milliseconds: 200)),
      );
      final marker = File('${dir.path}/stubborn');
      final task = backend.start('stubborn', marker.path);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(await task.cancel(), isTrue);
      await expectLater(task.result, throwsA(isA<DwiCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(marker.existsSync(), isFalse);
    },
  );

  test('without a grace period cancellation kills at once (ADR-010)', () async {
    await backend.configure(const DwiConfig());
    final marker = File('${dir.path}/plain');
    final task = backend.start('cooperative', marker.path);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(await task.cancel(), isTrue);
    await expectLater(task.result, throwsA(isA<DwiCancelledException>()));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(marker.existsSync(), isFalse);
  });

  test('a call that is not cancelled sees a token that never fires', () async {
    await backend.configure(
      const DwiConfig(cancelGracePeriod: Duration(seconds: 1)),
    );
    final marker = File('${dir.path}/normal');
    final task = backend.start('cooperative', marker.path);
    expect(await task.result, 'finished');
    expect(marker.readAsStringSync(), 'finished');
  });
}
