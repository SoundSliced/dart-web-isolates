/// Compiles the worker entrypoint into a served location.
///
/// Usage (from experiments/dart_worker_poc):
///   dart run tool/build_worker.dart
///
/// The output is `web/dwi/worker.dart.js`, which `flutter build web` copies to
/// `build/web/dwi/worker.dart.js`. The artefact is generated, not committed.
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  final root = Directory.current;
  final worker = File('${root.path}/worker.dart');
  if (!worker.existsSync()) {
    stderr.writeln('worker.dart not found in ${root.path}');
    exit(2);
  }

  final outDir = Directory('${root.path}/web/dwi')..createSync(recursive: true);
  final out = File('${outDir.path}/worker.dart.js');

  if (out.existsSync() &&
      out.lastModifiedSync().isAfter(worker.lastModifiedSync())) {
    stdout.writeln('worker artefact is up to date: ${out.path}');
    return;
  }

  final result = await Process.run(Platform.resolvedExecutable, <String>[
    'compile',
    'js',
    '-O1',
    '-o',
    out.path,
    worker.path,
  ], workingDirectory: root.path);

  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('worker compilation failed (exit ${result.exitCode})');
    exit(result.exitCode);
  }
  stdout.writeln('worker written to ${out.path}');
}
