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

/// Test seam called after each named publication step of a Wasm build.
///
/// Steps are `generation` (all generation files published, entry still old)
/// and `entry` (entry switched, manifest not yet written). Throwing here
/// simulates an interrupted or failed publication at that exact boundary.
Future<void> Function(String step)? debugPublicationStep;

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
Future<DwiCompileResult> compileWorker(
  DwiBuildConfig config, {
  String? generation,
}) async {
  final source = File(config.absoluteWorkerSource);
  if (!source.existsSync()) {
    throw DwiBuildException(
      'Generated worker entrypoint does not exist: ${source.path}',
    );
  }
  if (config.isWasm) {
    final id = generation;
    if (id == null || id.isEmpty) {
      throw DwiBuildException(
        'A Wasm worker build requires its content generation id.',
      );
    }
    return _compileWasm(config, source, id);
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

/// Compiles the worker with `dart compile wasm` and publishes a complete
/// content-addressed generation before switching the entry (ADR-018).
///
/// A generation is never referenced while it is being written: the stable
/// `worker.boot.mjs` entry is replaced only after `gen-<id>/worker.mjs` and
/// `gen-<id>/worker.wasm` are in place. A failed build therefore leaves the
/// previous entry and generation usable, and a reader sees either the old pair
/// or the new pair. Deployment must upload generation directories before the
/// entry; a reader that arrives mid-deploy fails with a typed startup error
/// rather than executing mixed files.
Future<DwiCompileResult> _compileWasm(
  DwiBuildConfig config,
  File source,
  String generation,
) async {
  final directory = Directory(config.absoluteArtifactDir);
  await directory.create(recursive: true);
  final temporaryDir = await directory.createTemp('.dwi-wasm-');
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

    await bootstrap.writeAsString(
      _bootstrapSource(generation),
      flush: true,
    );

    final publish = debugPublishOverride ?? replaceFile;
    final generationDir = Directory(config.wasmGenerationDir(generation));
    await generationDir.create(recursive: true);
    try {
      await publish(
        loader,
        File(config.wasmGenerationLoader(generation)),
      );
      await publish(
        module,
        File(config.wasmGenerationModule(generation)),
      );
    } on Object catch (error) {
      throw DwiBuildException(
        'Could not publish Wasm generation $generation to '
        '${generationDir.path}: $error',
      );
    }
    try {
      await debugPublicationStep?.call('generation');
    } on Object catch (error) {
      throw DwiBuildException(
        'Wasm generation $generation publication was interrupted after the '
        'generation files were written: $error',
      );
    }

    try {
      await publish(bootstrap, File(config.absoluteEntry));
    } on Object catch (error) {
      throw DwiBuildException(
        'Could not switch the Wasm worker entry to generation $generation: '
        '$error',
      );
    }
    try {
      await debugPublicationStep?.call('entry');
    } on Object catch (error) {
      throw DwiBuildException(
        'Wasm worker entry was switched to generation $generation but the '
        'build did not finish: $error',
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
/// and instantiates the generation [generation]. The generation is content
/// addressed, so an entry switch is the only mutable reference (ADR-018).
String _bootstrapSource(String generation) => '''
// GENERATED CODE - DO NOT MODIFY BY HAND.
// Generated by dwi_builder $dwiBuilderVersion; bootstrap format 2.
// Generation: $generation
// Generic dart2wasm worker bootstrap. No application logic belongs here.
const PROTOCOL_VERSION = 2;
const GENERATION = '$generation';

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
  const base = new URL('gen-' + GENERATION + '/', import.meta.url);
  const loader = await import(new URL('worker.mjs', base));
  const response = await fetch(new URL('worker.wasm', base));
  if (!response.ok) {
    throw new Error(
      'wasm fetch failed: ' + response.status + ' ' + response.statusText +
      ' (' + base.pathname + 'worker.wasm)',
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
