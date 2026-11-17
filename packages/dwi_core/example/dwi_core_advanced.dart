import 'package:dwi_core/dwi_core.dart';

Future<void> main() async {
  final port = DwiPortRegistry.create(
    name: 'status',
    scope: DwiPortScope.hostOnly,
    listeners: DwiPortListeners.broadcast,
    bufferSize: 4,
  );
  try {
    final received = port.messages.first;
    await port.send('ready');
    print(await received);
  } finally {
    await port.close();
  }
}
