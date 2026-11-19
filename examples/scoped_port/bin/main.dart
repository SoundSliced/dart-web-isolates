import 'package:dwi/dwi.dart';
import 'package:dwi_core/dwi_worker.dart';

/// Worker task: attaches a reader to the reserved channel `port:<name>` and
/// echoes each message back. Returns whether the reader was installed.
bool listenForEcho(Object? input) {
  final channel = DwiWorkerChannels.find('port:${input! as String}');
  if (channel == null) return false;
  channel.messages
      .asyncMap((message) => channel.send('echo: $message'))
      .listen(
        (_) {},
        onError: (Object error) => print('Echo channel closed with $error'),
      );
  return true;
}

Future<void> main() async {
  Dwi.registerTask('listenForEcho', listenForEcho);
  await Dwi.configure(const DwiConfig());

  // Host-only: the port exists only for the callback and is closed afterwards.
  final status = await Dwi.withPort('status', (port) async {
    final received = port.messages.first;
    await port.send('ready');
    return await received;
  });
  print('host-only: $status'); // ready

  // Worker-bound: the port is bound to this worker before the callback runs.
  // The worker is spawned and closed by DwiWorker.using.
  final response = await DwiWorker.using((worker) {
    return worker.withPort('echo', (port) async {
      final ready = await worker.run<bool>('listenForEcho', port.name);
      if (!ready) throw StateError('Echo listener failed to start');
      // Subscribe before the send that triggers the reply.
      final reply = port.messages.first;
      await port.send('hello');
      return await reply;
    });
  });
  print('worker-bound: $response'); // echo: hello

  // Both ports are gone after their scope returns.
  print('echo still open: ${Dwi.port('echo') != null}'); // false

  await Dwi.close();
}
