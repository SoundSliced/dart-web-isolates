import 'package:dwi/dwi.dart';

/// Isolate-local state for the dedicated handle. `Dwi.run` starts a fresh
/// isolate per call, so only a handle observes growth between calls.
var _counter = 0;

int nextCount(Object? input) => ++_counter;

Future<void> main() async {
  Dwi.registerTask('counter', nextCount);
  await Dwi.configure(const DwiConfig());

  final worker = await DwiWorker.spawn();
  try {
    print('first  ${await worker.run<int>('counter')}'); // 1
    print('second ${await worker.run<int>('counter')}'); // 2
    print('third  ${await worker.run<int>('counter')}'); // 3

    // A second handle owns a second isolate with its own fresh state.
    final other = await DwiWorker.spawn();
    try {
      print('other  ${await other.run<int>('counter')}'); // 1
    } finally {
      await other.close();
    }

    print('fourth ${await worker.run<int>('counter')}'); // 4
  } finally {
    // Always release the dedicated context, including on failure.
    await worker.close();
    // Let any pooled call still running finish before shutting down (ADR-024).
    await Dwi.close(drain: true);
  }
}
