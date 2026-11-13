import 'dart:async';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';
import 'package:test/test.dart';

/// `DwiWorkerHandle.ping` on a native isolate handle (ADR-028).
void main() {
  late DwiTaskRegistry registry;

  setUp(() {
    registry = DwiTaskRegistry()
      ..register('slow', (Object? input) async {
        await Future<void>.delayed(Duration(milliseconds: input! as int));
        return input;
      })
      ..register('spin', (Object? input) {
        final until = DateTime.now().add(Duration(milliseconds: input! as int));
        while (DateTime.now().isBefore(until)) {}
        return input;
      });
  });

  Future<NativeWorkerHandle> spawn([DwiConfig config = const DwiConfig()]) =>
      NativeWorkerHandle.spawn(registry, config);

  test('an idle handle answers with a round-trip time', () async {
    final handle = await spawn();
    addTearDown(handle.close);
    final latency = await handle.ping();
    expect(latency, lessThan(const Duration(seconds: 1)));
    expect(handle.isUsable, isTrue);
  });

  test('an asynchronous task in progress does not block the answer', () async {
    final handle = await spawn();
    addTearDown(handle.close);
    final call = handle.run('slow', 600);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final latency = await handle.ping(
      timeout: const Duration(milliseconds: 300),
    );
    expect(latency, lessThan(const Duration(milliseconds: 300)));
    expect(await call, 600);
  });

  test(
    'a synchronous task makes the ping time out without failing the handle',
    () async {
      final handle = await spawn();
      addTearDown(handle.close);
      final call = handle.run('spin', 800);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
        handle.ping(timeout: const Duration(milliseconds: 200)),
        throwsA(isA<DwiTimeoutException>()),
      );
      expect(await call, 800);
      expect(handle.isUsable, isTrue);
      expect(await handle.ping(), isA<Duration>());
    },
  );

  test('closing the handle settles a pending ping', () async {
    final handle = await spawn();
    final call = handle.run('spin', 800);
    call.ignore();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final ping = expectLater(
      handle.ping(timeout: const Duration(seconds: 5)),
      throwsA(isA<DwiWorkerClosedException>()),
    );
    await handle.close();
    await ping;
  });

  test('a closed handle refuses to ping; timeout must be positive', () async {
    final handle = await spawn();
    await expectLater(handle.ping(timeout: Duration.zero), throwsArgumentError);
    await handle.close();
    await expectLater(handle.ping(), throwsA(isA<DwiWorkerClosedException>()));
  });
}
