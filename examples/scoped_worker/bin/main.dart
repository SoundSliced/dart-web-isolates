import 'package:dwi/dwi.dart';

/// Isolate- or worker-local state for the scoped handle.
var _counter = 0;

int nextCount(Object? input) => ++_counter;

Future<void> main() async {
  Dwi.registerTask('counter', nextCount);
  await Dwi.configure(const DwiConfig());

  // One scope owns the handle: it is spawned here and closed on every path.
  final values = await DwiWorker.using((worker) async {
    final first = await worker.run<int>('counter'); // 1
    final second = await worker.run<int>('counter'); // 2
    return (first, second);
  });
  print('scoped value: $values');

  // The callback may also return void.
  await DwiWorker.using<void>((worker) async {
    print('void scope: ${await worker.run<int>('counter')}'); // 1 (fresh context)
  });

  // Dwi.runFresh is the same ownership rule for a single call: a fresh context
  // that never shares state with the pool or with another call.
  print('fresh: ${await Dwi.runFresh<int>('counter')}'); // 1
  print('fresh: ${await Dwi.runFresh<int>('counter')}'); // 1 again

  // The scope closed the handle; using it now throws a typed error.
  await Dwi.close();
}
