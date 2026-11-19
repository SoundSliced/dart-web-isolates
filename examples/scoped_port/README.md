# scoped_port

`Dwi.withPort` and `DwiWorker.withPort` create a named port for one callback
and close it when the callback returns or throws (ADR-033). The port is never
adopted from an existing open name: a duplicate name throws
`DwiChannelStateException` and the first port stays open.

```dart
final status = await Dwi.withPort('status', (port) async {
  final received = port.messages.first;
  await port.send('ready');
  return await received;
});
```

`DwiWorker.withPort` binds the port to the handle you pass before the callback
runs. The worker's application must confirm it is ready before the first send;
the channel acknowledgement only means the channel is open.

```dart
final response = await DwiWorker.using((worker) {
  return worker.withPort('echo', (port) async {
    final ready = await worker.run<bool>('listenForEcho', port.name);
    if (!ready) throw StateError('Echo listener failed to start');
    final reply = port.messages.first;
    await port.send('hello');
    return await reply;
  });
});
```

Closing the port during the callback is an early termination, and it cannot
cancel work the callback already started. Await what you need before returning.

Run it on the VM:

```bash
dart pub get
dart run bin/main.dart
```
