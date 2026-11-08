/// Builds a project's worker entrypoint programmatically.
///
/// Equivalent to `dart run dwi_builder build`, and to what the Flutter build
/// hook runs. Set `compile: false` to generate sources without invoking
/// `dart compile js`.
library;

import 'package:dwi_builder/dwi_builder.dart';

Future<void> main() async {
  final builder = DwiBuilder(
    const DwiBuildConfig(
      projectRoot: '.',
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
