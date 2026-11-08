/// Uses the platform-independent pieces directly: the task registry, validated
/// configuration and the capabilities a backend reports.
///
/// Backends such as `dwi_native` and `dwi_web` build on exactly these types;
/// application code usually reaches them through `package:dwi` instead.
library;

import 'package:dwi_core/dwi_core.dart';

void main() {
  // A registry owns the task table a backend executes against.
  final registry = DwiTaskRegistry();
  registry.register('double', (input) {
    final value = input! as int;
    return value * 2;
  });

  print('double(21) = ${registry.invoke('double', 21)}');
  print('knows "double": ${registry.contains('double')}');

  // Unknown task names fail with a typed error, never a silent null.
  try {
    registry.lookup('missing');
  } on DwiUnknownTaskException catch (error) {
    print('expected failure: $error');
  }

  // Configuration is validated once, before a backend is used.
  final config = const DwiConfig(
    maxWorkers: 2,
    taskTimeout: Duration(seconds: 5),
  ).validated();
  print('workers: ${config.maxWorkers}, timeout: ${config.taskTimeout}');

  // Backends report what this environment can actually do.
  const capabilities = DwiCapabilities(
    backend: DwiBackendKind.isolate,
    protocolVersion: 2,
    transferables: true,
    workerCount: 2,
    cancellation: DwiCancellation.running,
  );
  print('capabilities: ${capabilities.toMap()}');
}
