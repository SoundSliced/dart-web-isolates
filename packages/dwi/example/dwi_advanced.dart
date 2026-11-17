import 'dart:typed_data';

import 'package:dwi/dwi.dart';
import 'package:dwi_core/dwi_worker.dart';

int doubleInput(Object? input) => (input as int) * 2;

int byteCount(Object? input) => (input as DwiTransferableBytes).lengthInBytes;

Future<int> waitForCancel(Object? input) async {
  final token = DwiCancelToken.current;
  await token.whenCancelled;
  token.throwIfCancelled();
  return 0;
}

Future<Object?> countStream(Object? request) =>
    DwiStreamTask.serve(request, (input) async* {
      for (var value = 1; value <= (input as int); value++) {
        yield value;
      }
    });

bool listenForEcho(Object? input) {
  final channel = DwiWorkerChannels.find('port:${input as String}');
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
  Dwi.registerTask('double', doubleInput);
  Dwi.registerTask('listenForEcho', listenForEcho);
  Dwi.registerTask('byteCount', byteCount);
  Dwi.registerTask('waitForCancel', waitForCancel);
  Dwi.registerTask('countStream', countStream);
  await Dwi.configure(
    const DwiConfig(
      maxWorkers: 2,
      metrics: true,
      cancelGracePeriod: Duration(seconds: 1),
    ),
  );
  final local = Dwi.createPort(
    'status',
    scope: DwiPortScope.hostOnly,
    listeners: DwiPortListeners.broadcast,
  );
  final echo = Dwi.createPort('echo', scope: DwiPortScope.workers);
  try {
    Dwi.pause();
    final call = Dwi.run<int>('double', 21);
    Dwi.resume();
    print(await call);
    print(await Dwi.runFresh<int>('double', 10));
    print(await Dwi.runStream('countStream', 3).toList());

    final bytes = DwiTransferableBytes(Uint8List.fromList([1, 2, 3]));
    print('Transferred bytes: ${await Dwi.run<int>('byteCount', bytes)}');

    Dwi.pause();
    final pending = Dwi.runCancellable<int>('waitForCancel');
    final observed = pending.result.then<void>(
      (_) => throw StateError('Expected cancellation'),
      onError: (Object error) {
        if (error is! DwiCancelledException) throw error;
        print('Cancelled queued call');
      },
    );
    await pending.cancel();
    Dwi.resume();
    await observed;

    final first = local.messages.first;
    final second = Dwi.port('status')!.messages.first;
    await local.send('starting worker');
    print(await Future.wait([first, second]));

    await DwiWorker.using((worker) async {
      print('Ping: ${await worker.ping()}');
      final binding = await worker.bindPort(echo);
      try {
        if (!await worker.run<bool>('listenForEcho', echo.name)) {
          throw StateError('The worker did not find the echo port');
        }
        final response = echo.messages.first;
        await echo.send('hello');
        print(await response);
      } finally {
        await binding.close();
        await binding.done;
      }
    });

    print((await Dwi.capabilities()).toMap());
    print(Dwi.poolState());
    print(Dwi.metrics());
  } finally {
    await echo.close();
    await local.close();
    await Dwi.close(drain: true);
  }
}
