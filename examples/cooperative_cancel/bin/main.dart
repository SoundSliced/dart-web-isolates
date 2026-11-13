import 'package:dwi/dwi.dart';

/// Works through [input] steps and stops at the first step after the caller
/// cancelled, so it can release what it holds instead of being killed.
Future<Object?> processBatch(Object? input) async {
  final steps = input! as int;
  final token = DwiCancelToken.current;
  for (var step = 0; step < steps; step++) {
    if (token.isCancelled) {
      // Runs inside the worker: tidy up, then stop.
      print('worker: stopped cleanly at step $step');
      token.throwIfCancelled();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return steps;
}

Future<void> main() async {
  Dwi.registerTask('processBatch', processBatch);
  // Without cancelGracePeriod, cancel() terminates the worker at once and the
  // task never sees the token (ADR-010). With it, the task gets this long to
  // stop on its own before termination.
  await Dwi.configure(const DwiConfig(cancelGracePeriod: Duration(seconds: 1)));
  try {
    final task = Dwi.runCancellable<int>('processBatch', 1000);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    print('host: cancel() -> ${await task.cancel()}');
    try {
      await task.result;
    } on DwiCancelledException {
      print('host: result settled with DwiCancelledException');
    }
    // Leave the worker time to print before the program exits.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  } finally {
    await Dwi.close();
  }
}
