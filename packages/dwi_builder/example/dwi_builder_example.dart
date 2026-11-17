/// Builds a project's worker entrypoint programmatically.
///
/// Equivalent to `dart run dwi_builder:dwi generate`. The
/// `compile: false` setting generates sources without compiling a worker.
library;

import 'package:dwi_builder/dwi_builder.dart';

Future<void> main(List<String> args) async {
  final builder = DwiBuilder(
    DwiBuildConfig(
      projectRoot: args.isEmpty ? '.' : args.single,
      compile: false,
    ),
  );

  final result = await builder.build();
  print('package: ${result.discovery.packageName}');
  print('tasks: ${result.discovery.tasks.map((task) => task.name).join(', ')}');
  print('generated worker: ${result.workerSourcePath}');
  print('generated proxies: ${result.proxiesPath}');
  print('content hash: ${result.hash}');
  print('compiled: ${result.compiled}, cache hit: ${result.cacheHit}');
  print('took ${result.duration.inMilliseconds} ms');
}
