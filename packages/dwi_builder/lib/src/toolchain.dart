import 'dart:io';

import 'config.dart';
import 'diagnostics.dart';
import 'publication.dart';

/// Test seam: replaces the publication step in [compileWorker].
///
/// Tests use it to exercise publication failure without depending on
/// platform-specific filesystem permissions. Application code never sets it.
Future<void> Function(File temporary, File artifact)? debugPublishOverride;

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
/// The compiler writes to a unique temporary sibling file first. A failing
/// compilation therefore never truncates or replaces a previously valid
/// artefact. A successful compilation is published by an atomic replace, so a
/// reader never sees a partial file and the last valid artefact survives any
/// publication failure. Concurrent compilations use distinct temporary names;
/// the serialized build in [DwiBuilder] decides which result is published.
///
/// Throws [DwiBuildException] when the compiler is missing, exits non-zero,
/// produces no artefact, or the artefact cannot be published.
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

  try {
    final publish = debugPublishOverride ?? replaceFile;
    await publish(temporary, artifact);
  } on Object catch (error) {
    await _deleteIfExists(temporary);
    await _deleteCompanions(temporary);
    throw DwiBuildException(
      'Could not publish the compiled worker to ${artifact.path}: $error',
    );
  }
  await _deleteCompanions(temporary);

  return DwiCompileResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}

/// `dart compile js` writes `<output>.deps` and `<output>.map` next to its
/// output. Those companions of the temporary artefact are not part of the
/// published worker and must not leak into the project.
Future<void> _deleteCompanions(File temporary) async {
  for (final suffix in const <String>['.deps', '.map']) {
    await _deleteIfExists(File('${temporary.path}$suffix'));
  }
}

Future<void> _deleteIfExists(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // A leftover temporary file is harmless; the next build uses a new name.
  }
}
