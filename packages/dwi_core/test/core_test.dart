import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

void main() {
  group('DwiConfig', () {
    test('has safe defaults', () {
      const config = DwiConfig();
      expect(config.maxWorkers, 4);
      expect(config.taskTimeout, const Duration(seconds: 30));
      expect(config.startupTimeout, const Duration(seconds: 10));
      expect(config.maxQueuedTasks, 64);
      expect(config.validated(), same(config));
    });

    test('rejects invalid values', () {
      expect(
        () => const DwiConfig(maxWorkers: 0).validated(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const DwiConfig(taskTimeout: Duration.zero).validated(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const DwiConfig(maxPayloadBytes: 0).validated(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('defaults to the generated worker path', () {
      const config = DwiConfig();
      expect(config.workerScript, DwiConfig.defaultWorkerScript);
      expect(config.requireWorkerScript, returnsNormally);
    });

    test('rejects an explicitly empty worker script', () {
      expect(
        () => const DwiConfig(workerScript: '').requireWorkerScript(),
        throwsA(isA<DwiStartupException>()),
      );
    });
  });

  group('DwiTaskRegistry', () {
    test('registers and invokes a task', () {
      final registry = DwiTaskRegistry()
        ..register('double', (i) => (i! as int) * 2);
      expect(registry.contains('double'), isTrue);
      expect(registry.invoke('double', 21), 42);
    });

    test('replaces a task on re-registration', () {
      final registry = DwiTaskRegistry()
        ..register('value', (_) => 1)
        ..register('value', (_) => 2);
      expect(registry.invoke('value', null), 2);
    });

    test('rejects an empty name', () {
      expect(
        () => DwiTaskRegistry().register(' ', (_) => null),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws DwiUnknownTaskException for a missing task', () {
      expect(
        () => DwiTaskRegistry().lookup('nope'),
        throwsA(isA<DwiUnknownTaskException>()),
      );
    });
  });

  group('exceptions', () {
    test('remote exception keeps its context out of toString', () {
      const error = DwiRemoteException(
        message: 'bad',
        remoteType: 'StateError',
        remoteStack: '#0',
        taskId: 4,
      );
      expect(error.toString(), contains('StateError'));
      expect(error.taskId, 4);
    });

    test('every exception is a DwiException', () {
      expect(const DwiTimeoutException('t'), isA<DwiException>());
      expect(const DwiStartupException('s'), isA<DwiException>());
      expect(const DwiUnknownTaskException('u'), isA<DwiException>());
      expect(const DwiSerializationException('s'), isA<DwiException>());
      expect(const DwiResultTypeException('r'), isA<DwiException>());
      expect(const DwiUnsupportedException('u'), isA<DwiException>());
    });
  });
}
