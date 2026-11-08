/// Runs a task on a real Dart isolate through the native backend directly.
///
/// Application code usually uses `package:dwi`, which picks this backend on
/// native platforms; using it directly is useful in tests and tools.
library;

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';

Future<void> main() async {
  final registry = DwiTaskRegistry()
    ..register('sum', (input) {
      final limit = input! as int;
      var total = 0;
      for (var i = 1; i <= limit; i++) {
        total += i;
      }
      return total;
    });

  final backend = NativeBackend(registry);
  try {
    final sum = await backend.run('sum', 1000);
    print('sum(1000) = $sum');

    final capabilities = await backend.capabilities();
    print(
      'backend: ${capabilities.backend.name}, '
      'protocol: v${capabilities.protocolVersion}, '
      'cancellation: ${capabilities.cancellation.name}',
    );
  } finally {
    await backend.close();
  }
}
