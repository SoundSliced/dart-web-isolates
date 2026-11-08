/// Runs one task through the shared pool, then two through a dedicated worker.
///
/// On native platforms the work runs in real isolates; on web it runs in
/// dedicated Web Workers compiled by `dwi_builder`. The calling code is the
/// same either way.
library;

import 'package:dwi/dwi.dart';

Future<void> main() async {
  Dwi.registerTask('sum', (input) {
    final limit = input! as int;
    var total = 0;
    for (var i = 1; i <= limit; i++) {
      total += i;
    }
    return total;
  });

  // One call, borrowing a worker from the shared pool.
  final pooled = await Dwi.run<int>('sum', 100);
  print('pooled: $pooled');

  // A dedicated worker keeps its own context between calls.
  final worker = await DwiWorker.spawn();
  try {
    final first = await worker.run<int>('sum', 10);
    final second = await worker.run<int>('sum', 20);
    print('dedicated: $first then $second');
  } finally {
    await worker.close();
  }

  // Releases the pool. Safe to call when nothing is running.
  await Dwi.close();
}
