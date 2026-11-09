import 'dart:async';

import 'package:dwi/dwi.dart';

var _counter = 0;

int nextCount(Object? input) => ++_counter;

Future<void> main() async {
  Dwi.registerTask('counter', nextCount);
  await Dwi.configure(const DwiConfig());

  final worker = await DwiWorker.spawn();
  final events = <DwiWorkerStop>[];
  final done = Completer<void>();
  final subscription = worker.stops.listen(events.add, onDone: done.complete);

  // A healthy context has no terminal reason.
  print('before ${worker.stopReason}'); // null
  print('count  ${await worker.run<int>('counter')}'); // 1

  await worker.close();
  // The final event is delivered before the stream closes.
  await done.future;
  print('events $events'); // [DwiWorkerStop.callerClosed]
  print('after  ${worker.stopReason}'); // DwiWorkerStop.callerClosed

  await subscription.cancel();
  await Dwi.close();
}
