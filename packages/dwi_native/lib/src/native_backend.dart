import 'dart:async';
import 'dart:isolate';

import 'package:dwi_core/dwi_core.dart';

/// Executes registered tasks on real Dart isolates.
class NativeBackend implements DwiBackend {
  NativeBackend(this.registry);

  final DwiTaskRegistry registry;
  DwiConfig _config = const DwiConfig();
  bool _closed = false;

  @override
  Future<void> configure(DwiConfig config) async {
    _config = config.validated();
  }

  @override
  Future<Object?> run(String task, Object? input) async {
    if (_closed) {
      throw const DwiUnsupportedException('backend is closed');
    }
    final implementation = registry.lookup(task);
    final future = Isolate.run<Object?>(() => implementation(input));
    try {
      return await future.timeout(_config.taskTimeout);
    } on TimeoutException {
      // A running isolate cannot be killed from the outside; the future is
      // abandoned and the caller is told the truth.
      throw DwiTimeoutException(
        'task "$task" exceeded ${_config.taskTimeout.inMilliseconds} ms',
      );
    }
  }

  @override
  Future<DwiCapabilities> capabilities() async => DwiCapabilities(
        backend: _closed ? DwiBackendKind.unsupported : DwiBackendKind.isolate,
        protocolVersion: 1,
        transferables: true,
      );

  @override
  Future<void> close() async {
    _closed = true;
  }
}
