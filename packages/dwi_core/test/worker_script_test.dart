import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

void main() {
  test('a served same-origin worker script is accepted', () {
    expect(
      () =>
          const DwiConfig(workerScript: 'dwi/worker.dart.js')
              .requireWorkerScript(),
      returnsNormally,
    );
  });

  test('blob, data and javascript worker scripts are refused (ADR-006)', () {
    for (final script in <String>[
      'blob:https://example.test/abc',
      '  BLOB:https://example.test/abc',
      'data:text/javascript,postMessage(1)',
      'javascript:postMessage(1)',
    ]) {
      expect(
        () => DwiConfig(workerScript: script).requireWorkerScript(),
        throwsA(isA<DwiStartupException>()),
        reason: script,
      );
    }
  });

  test('a missing worker script still fails with a typed startup error', () {
    expect(
      () => const DwiConfig(workerScript: null).requireWorkerScript(),
      throwsA(isA<DwiStartupException>()),
    );
  });
}
