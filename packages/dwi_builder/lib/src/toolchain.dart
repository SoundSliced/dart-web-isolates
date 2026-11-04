import 'dart:io';

import 'config.dart';
import 'diagnostics.dart';

/// Result of one compiler invocation.
class DwiCompileResult {
  const DwiCompileResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Compiles the generated worker entrypoint with `dart compile js`.
///
/// The compiler writes to a temporary sibling file first. A failing
/// compilation therefore never truncates or replaces a previously valid
/// artefact, and a successful one is published by rename so readers never see a
/// partial file. Concurrent compilations use distinct temporary names; the last
/// successful rename wins.
///
/// Throws [DwiBuildException] when the compiler is missing, exits non-zero, or
/// produces no artefact.
Future<DwiCompileResult> compileWorker(DwiBuildConfig config) async {
  final source = File(config.absoluteWorkerSource);
  if (!source.existsSync()) {
    throw DwiBuildException(
      'Generated worker entrypoint does not exist: ${source.path}',
    );
  }

  final artifact = File(config.absoluteArtifact);
  await artifact.parent.create(recursive: true);
  final temporary = File(
    '${artifact.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
  );

  ProcessResult result;
  try {
    result = await Process.run(config.executable, <String>[
      'compile',
      'js',
      '-${config.optimization}',
      '-o',
      temporary.path,
      source.path,
    ], workingDirectory: config.absoluteProjectRoot);
  } on ProcessException catch (error) {
    await _deleteIfExists(temporary);
    throw DwiBuildException(
      'Could not start the Dart compiler (${config.executable}): '
      '${error.message}',
    );
  }

  if (result.exitCode != 0 || !temporary.existsSync()) {
    await _deleteIfExists(temporary);
    if (result.exitCode != 0) {
      throw DwiBuildException(
        'Worker compilation failed with exit ${result.exitCode}.',
        <DwiDiagnostic>[
          DwiDiagnostic(
            code: 'DWI007',
            severity: DwiDiagnosticSeverity.error,
            message: '${result.stdout}${result.stderr}'.trim(),
            file: source.path,
          ),
        ],
      );
    }
    throw DwiBuildException(
      'The Dart compiler exited 0 but produced no artefact at '
      '${temporary.path}.',
    );
  }

  if (await artifact.exists()) await artifact.delete();
  await temporary.rename(artifact.path);

  return DwiCompileResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}

Future<void> _deleteIfExists(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // A leftover temporary file is harmless; the next build uses a new name.
  }
}
