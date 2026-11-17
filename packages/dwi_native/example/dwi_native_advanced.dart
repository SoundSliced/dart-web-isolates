import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';

int _total = 0;

int accumulate(Object? input) => _total += input as int;

Future<void> main() async {
  final registry = DwiTaskRegistry()..register('accumulate', accumulate);
  final backend = NativeBackend(registry);
  try {
    await backend.configure(const DwiConfig(maxWorkers: 2));
    final worker = await backend.spawnHandle();
    try {
      print(await worker.run('accumulate', 2)); // 2
      print(await worker.run('accumulate', 3)); // 5
      print(await worker.ping());
    } finally {
      await worker.close();
    }
  } finally {
    await backend.close();
  }
}
