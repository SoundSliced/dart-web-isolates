import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

void main() {
  group('DwiConfig', () {
    test('has safe defaults', () {
      const config = DwiConfig();
      expect(config.maxWorkers, 4);
      expect(config.taskTimeout, const Duration(seconds: 30));
      expect(config.startupTimeout, const Duration(seconds: 10));
      expect(config.queueTimeout, const Duration(seconds: 30));
      expect(config.maxQueuedTasks, 64);
      expect(config.validated(), same(config));
    });

    test('idleTimeout is off by default and must be positive (ADR-024)', () {
      expect(const DwiConfig().idleTimeout, isNull);
      const config = DwiConfig(idleTimeout: Duration(seconds: 1));
      expect(config.validated().idleTimeout, const Duration(seconds: 1));
      expect(
        () => const DwiConfig(idleTimeout: Duration.zero).validated(),
        throwsArgumentError,
      );
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
        () => const DwiConfig(queueTimeout: Duration.zero).validated(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const DwiConfig(maxPayloadBytes: 0).validated(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const DwiConfig(heartbeatInterval: Duration.zero).validated(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const DwiConfig(heartbeatMisses: 0).validated(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('has heartbeat defaults', () {
      const config = DwiConfig();
      expect(config.heartbeatInterval, const Duration(seconds: 5));
      expect(config.heartbeatMisses, 2);
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

  group('worker backend selection (ADR-018)', () {
    test('defaults to js and keeps the js worker script', () {
      const config = DwiConfig();
      expect(config.workerBackend, DwiWorkerBackend.js);
      expect(config.workerScript, 'dwi/worker.dart.js');
      expect(DwiConfig.defaultWasmWorkerScript, 'dwi/worker.boot.mjs');
    });

    test('can select wasm explicitly', () {
      const config = DwiConfig(
        workerBackend: DwiWorkerBackend.wasm,
        workerScript: DwiConfig.defaultWasmWorkerScript,
      );
      expect(config.workerBackend, DwiWorkerBackend.wasm);
      expect(config.workerScript, 'dwi/worker.boot.mjs');
    });

    test('capabilities report an observed worker backend only when present', () {
      const js = DwiCapabilities(
        backend: DwiBackendKind.worker,
        protocolVersion: 2,
      );
      expect(js.toMap().containsKey('workerBackend'), isFalse);

      const wasm = DwiCapabilities(
        backend: DwiBackendKind.worker,
        protocolVersion: 2,
        workerBackend: 'dart2wasm',
      );
      expect(wasm.toMap()['workerBackend'], 'dart2wasm');
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
