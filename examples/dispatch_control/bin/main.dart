import 'package:dwi/dwi.dart';

Future<Object?> resize(Object? input) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return 'resized ${input! as String}';
}

Object? crunch(Object? input) {
  // Synchronous work: the worker cannot answer anything until it returns.
  final until = DateTime.now().add(Duration(milliseconds: input! as int));
  while (DateTime.now().isBefore(until)) {}
  return input;
}

Future<void> main() async {
  Dwi.registerTask('resize', resize);
  Dwi.registerTask('crunch', crunch);
  await Dwi.configure(const DwiConfig());
  try {
    // Hold new work, for example while the app is in the background.
    Dwi.pause();
    final pending = <Future<String>>[
      for (final name in <String>['a.png', 'b.png', 'c.png'])
        Dwi.run<String>('resize', name),
    ];
    print('paused: ${Dwi.isPaused}, 3 calls held');
    Dwi.resume(); // dispatched in the order they were made
    print(await Future.wait(pending));

    // Check that a dedicated worker's event loop is responsive.
    final worker = await DwiWorker.spawn();
    try {
      print('idle ping: ${(await worker.ping()).inMicroseconds} µs');
      final busy = worker.run<int>('crunch', 500);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        await worker.ping(timeout: const Duration(milliseconds: 100));
      } on DwiTimeoutException {
        print('busy ping: no answer within 100 ms (synchronous work)');
      }
      await busy;
      print('worker still usable: ${worker.isUsable}');
    } finally {
      await worker.close();
    }
  } finally {
    await Dwi.close();
  }
}
