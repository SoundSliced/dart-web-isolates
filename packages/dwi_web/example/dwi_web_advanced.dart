import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_web/dwi_web.dart';

Future<void> main() async {
  final backend = WebBackend();
  try {
    await backend.configure(const DwiConfig());
    final worker = await backend.spawnHandle();
    try {
      print(await worker.ping());
      print(await worker.run('sum', 10));
      print(await worker.run('sum', 20));
    } finally {
      await worker.close();
    }
  } finally {
    await backend.close();
  }
}
