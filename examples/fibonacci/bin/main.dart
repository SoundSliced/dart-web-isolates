import 'dart:io';

import 'package:dwi/dwi.dart';

/// Deliberately exponential: enough work to be worth an isolate.
int fibonacci(int n) => n < 2 ? n : fibonacci(n - 1) + fibonacci(n - 2);

Future<void> main(List<String> args) async {
  final n = args.isEmpty ? 32 : int.parse(args.first);

  Dwi.registerTask('fibonacci', (Object? input) => fibonacci(input! as int));
  await Dwi.configure(const DwiConfig(taskTimeout: Duration(seconds: 60)));

  final caps = await Dwi.capabilities();
  stdout.writeln('backend: ${caps.backend.name}');

  final stopwatch = Stopwatch()..start();
  final result = await Dwi.run<int>('fibonacci', n);
  stopwatch.stop();

  stdout.writeln('fib($n) = $result in ${stopwatch.elapsedMilliseconds} ms');
  await Dwi.close();
}
