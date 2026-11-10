import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'diagnostics.dart';
import 'publication.dart';
import 'version.dart';

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
  if (config.isWasm) return _compileWasm(config, source);

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

/// Compiles the worker with `dart compile wasm` and publishes the three-file
/// artefact set (ADR-018).
///
/// The compiler runs in a temporary directory; the module, loader and generated
/// bootstrap are published by atomic replace only after every file exists. A
/// failed compilation therefore leaves the previous worker untouched.
Future<DwiCompileResult> _compileWasm(
  DwiBuildConfig config,
  File source,
) async {
  final directory = Directory(config.absoluteArtifactDir);
  await directory.create(recursive: true);
  final temporaryDir = Directory(
    p.join(
      directory.path,
      '.dwi-wasm-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
    ),
  );
  await temporaryDir.create(recursive: true);
  final module = File(p.join(temporaryDir.path, 'worker.wasm'));
  final loader = File(p.join(temporaryDir.path, 'worker.mjs'));
  final bootstrap = File(p.join(temporaryDir.path, 'worker.boot.mjs'));

  try {
    ProcessResult result;
    try {
      result = await Process.run(config.executable, <String>[
        'compile',
        'wasm',
        '--no-source-maps',
        '-o',
        module.path,
        source.path,
      ], workingDirectory: config.absoluteProjectRoot);
    } on ProcessException catch (error) {
      throw DwiBuildException(
        'Could not start the Dart compiler (${config.executable}): '
        '${error.message}',
      );
    }

    if (result.exitCode != 0 ||
        !module.existsSync() ||
        !loader.existsSync()) {
      if (result.exitCode != 0) {
        throw DwiBuildException(
          'Wasm worker compilation failed with exit ${result.exitCode}.',
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
        'The Wasm compiler exited 0 but did not produce both '
        'worker.wasm and worker.mjs in ${temporaryDir.path}.',
      );
    }

    await bootstrap.writeAsString(_bootstrapSource, flush: true);

    final publish = debugPublishOverride ?? replaceFile;
    try {
      await publish(bootstrap, File(config.absoluteEntry));
      await publish(loader, File(config.absoluteWasmLoader));
      await publish(module, File(config.absoluteWasmModule));
    } on Object catch (error) {
      throw DwiBuildException(
        'Could not publish the compiled Wasm worker to '
        '${config.absoluteArtifactDir}: $error',
      );
    }

    return DwiCompileResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  } finally {
    try {
      if (await temporaryDir.exists()) {
        await temporaryDir.delete(recursive: true);
      }
    } on FileSystemException {
      // A leftover temporary directory is inert; the next build uses a new one.
    }
  }
}

/// Generic, application-independent bootstrap for a dart2wasm worker.
///
/// `dart compile wasm` emits a module and a loader that never invokes `main`.
/// This wrapper imports the loader, fetches the module relative to its own URL,
/// instantiates it and calls `main`. It posts a typed startup failure instead of
/// letting a load error disappear (ADR-018).
const String _bootstrapSource = '''
// GENERATED CODE - DO NOT MODIFY BY HAND.
// Generated by dwi_builder $dwiBuilderVersion; bootstrap format 1.
// Generic dart2wasm worker bootstrap. No application logic belongs here.
const PROTOCOL_VERSION = 2;

const post = (message) => {
  try {
    self.postMessage(message);
  } catch (_) {
    // The host may already have terminated this worker.
  }
};

function startupFailure(error) {
  post({
    v: PROTOCOL_VERSION,
    type: 'error',
    id: null,
    task: null,
    payload: null,
    error: {
      code: 'protocol',
      message: String(error && error.stack ? error.stack : error),
      remoteType: 'startup',
      remoteStack: '',
      fatal: true,
      taskId: null,
    },
    meta: { phase: 'startup', code: 'bootstrap' },
  });
}

try {
  const loader = await import(new URL('./worker.mjs', import.meta.url));
  const response = await fetch(new URL('./worker.wasm', import.meta.url));
  if (!response.ok) {
    throw new Error(
      'wasm fetch failed: ' + response.status + ' ' + response.statusText,
    );
  }
  const compiled = await loader.compileStreaming(response);
  const app = await compiled.instantiate({});
  app.invokeMain();
} catch (error) {
  startupFailure(error);
}
''';

Future<void> _deleteIfExists(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // A leftover temporary file is harmless; the next build uses a new name.
  }
}
