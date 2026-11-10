import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'descriptor.dart';
import 'diagnostics.dart';
import 'discovery.dart';
import 'generator.dart';
import 'hasher.dart';
import 'publication.dart';
import 'toolchain.dart';
import 'version.dart';

/// Outcome of a successful build or generation run.
class DwiBuildResult {
  const DwiBuildResult({
    required this.discovery,
    required this.hash,
    required this.workerSourcePath,
    required this.proxiesPath,
    required this.artifactPath,
    required this.manifestPath,
    required this.compiled,
    required this.cacheHit,
    required this.duration,
  });

  /// Discovery result, including tasks and warnings.
  final DwiDiscoveryResult discovery;

  /// Content hash of the generated worker and its dependencies.
  final String hash;

  /// Absolute generated worker entrypoint path.
  final String workerSourcePath;

  /// Absolute generated proxy path.
  final String proxiesPath;

  /// Absolute compiled worker artefact path.
  final String artifactPath;

  /// Absolute manifest path.
  final String manifestPath;

  /// Whether this run invoked the Dart compiler.
  final bool compiled;

  /// Whether an unchanged compiled artefact was reused.
  final bool cacheHit;

  /// Wall-clock duration of the run.
  final Duration duration;
}

/// Outcome of `dwi check`.
class DwiCheckResult {
  const DwiCheckResult({
    required this.ok,
    required this.hash,
    required this.issues,
    required this.diagnostics,
  });

  /// Whether generated sources, manifest and artefact are all current.
  final bool ok;

  /// Hash of the sources as they would be generated now.
  final String hash;

  /// Human-readable reasons the build is stale or broken.
  final List<String> issues;

  /// Discovery diagnostics.
  final List<DwiDiagnostic> diagnostics;
}

/// Discovers tasks, writes generated sources and compiles the worker.
class DwiBuilder {
  /// Creates a builder for [config].
  DwiBuilder(this.config);

  /// Build configuration.
  final DwiBuildConfig config;

  /// Generates sources and, when [DwiBuildConfig.compile] is true, compiles the
  /// worker unless the content hash is unchanged.
  ///
  /// Builds for the same project are serialized by an exclusive file lock
  /// (`.dwi/build.lock`). The CLI and the Flutter build hook can therefore
  /// overlap safely: whichever build runs second observes the first build's
  /// manifest and artefacts, and an older computation can never publish over a
  /// newer one. Generated files and the artefact are published by atomic
  /// replace, so a failed build always leaves the last verified output
  /// available.
  ///
  /// Throws [DwiBuildException] with diagnostics when discovery fails, no task
  /// is found, or compilation fails.
  Future<DwiBuildResult> build() async {
    final cfg = config.validated();
    return _withBuildLock(cfg, () => _buildLocked(cfg));
  }

  Future<DwiBuildResult> _buildLocked(DwiBuildConfig cfg) async {
    final stopwatch = Stopwatch()..start();
    final discovery = await discoverTasks(cfg);

    if (discovery.tasks.isEmpty) {
      throw DwiBuildException(
        'No @DwiTask functions found under ${cfg.includePaths.join(', ')}.',
        discovery.diagnostics,
      );
    }
    if (discovery.hasErrors) {
      throw DwiBuildException(
        'DWI worker generation failed with '
        '${discovery.diagnostics.where((d) => d.severity == DwiDiagnosticSeverity.error).length} '
        'error(s).',
        discovery.diagnostics,
      );
    }

    final sources = DwiGenerator.generate(
      discovery.sortedTasks,
      workerId: cfg.workerId,
      target: cfg.target,
    );
    final dependencies = <String>{
      ...discovery.dependencyFiles,
      ...await collectRuntimeDependencies(cfg),
    };
    final hash = await computeWorkerHash(
      config: cfg,
      workerSource: sources.worker,
      proxiesSource: sources.proxies,
      dependencyFiles: dependencies,
    );

    await _writeIfChanged(cfg.absoluteWorkerSource, sources.worker);
    await _writeIfChanged(cfg.absoluteProxies, sources.proxies);

    var compiled = false;
    var cacheHit = false;
    if (cfg.compile) {
      final existing = await _readManifest(cfg.absoluteManifest);
      final currentDigests = await _artifactDigests(cfg);
      cacheHit =
          !cfg.force &&
          existing != null &&
          existing['hash'] == hash &&
          existing['compiled'] == true &&
          _manifestFilesMatch(existing, currentDigests);
      if (!cacheHit) {
        await compileWorker(cfg);
        compiled = true;
      }
      final artifactDigests = await _artifactDigests(cfg);
      final entryDigest = artifactDigests[_servedUrl(cfg, cfg.absoluteEntry)];
      if (entryDigest == null || entryDigest.isEmpty) {
        throw DwiBuildException(
          'Compilation produced no artefact at ${cfg.absoluteEntry}.',
        );
      }
      await _writeIfChanged(
        cfg.absoluteManifest,
        _manifestJson(
          config: cfg,
          hash: hash,
          tasks: discovery.sortedTasks,
          compiled: true,
          artifactDigest: entryDigest,
          artifactFiles: artifactDigests,
        ),
      );
    }

    stopwatch.stop();
    return DwiBuildResult(
      discovery: discovery,
      hash: hash,
      workerSourcePath: cfg.absoluteWorkerSource,
      proxiesPath: cfg.absoluteProxies,
      artifactPath: cfg.absoluteEntry,
      manifestPath: cfg.absoluteManifest,
      compiled: compiled,
      cacheHit: cacheHit,
      duration: stopwatch.elapsed,
    );
  }

  /// Reports whether generated sources, the manifest and the artefact are
  /// current. Writes nothing.
  Future<DwiCheckResult> check() async {
    final cfg = config.validated();
    final discovery = await discoverTasks(cfg);
    final issues = <String>[];

    for (final diagnostic in discovery.diagnostics) {
      if (diagnostic.severity == DwiDiagnosticSeverity.error) {
        issues.add(diagnostic.format());
      }
    }
    if (discovery.tasks.isEmpty) {
      issues.add('No @DwiTask functions found.');
    }
    if (issues.isNotEmpty) {
      return DwiCheckResult(
        ok: false,
        hash: '',
        issues: issues,
        diagnostics: discovery.diagnostics,
      );
    }

    final sources = DwiGenerator.generate(
      discovery.sortedTasks,
      workerId: cfg.workerId,
      target: cfg.target,
    );
    final dependencies = <String>{
      ...discovery.dependencyFiles,
      ...await collectRuntimeDependencies(cfg),
    };
    final hash = await computeWorkerHash(
      config: cfg,
      workerSource: sources.worker,
      proxiesSource: sources.proxies,
      dependencyFiles: dependencies,
    );

    await _checkContent(
      cfg.absoluteWorkerSource,
      sources.worker,
      'generated worker entrypoint',
      issues,
    );
    await _checkContent(
      cfg.absoluteProxies,
      sources.proxies,
      'generated proxies',
      issues,
    );

    final manifest = await _readManifest(cfg.absoluteManifest);
    final artifactDigests = await _artifactDigests(cfg);
    final artifactExists = artifactDigests.values.every(
      (digest) => digest.isNotEmpty,
    );
    if (manifest == null) {
      issues.add('Manifest is missing: ${cfg.absoluteManifest}');
    } else {
      if (manifest['hash'] != hash) {
        issues.add('Manifest hash does not match the current task sources.');
      }
      if (manifest['compiled'] != true) {
        issues.add('Manifest does not record a successful compilation.');
      }
      final digest = manifest['artifactDigest'];
      if (digest is! String || digest.isEmpty) {
        issues.add('Manifest does not record the compiled artefact digest.');
      }
      if (!_manifestFilesMatch(manifest, artifactDigests)) {
        issues.add(
          'Worker artefact set does not match the manifest; a file is missing, '
          'truncated, corrupt or from another target.',
        );
      }
    }
    if (!artifactExists) {
      final missing = artifactDigests.entries
          .where((entry) => entry.value.isEmpty)
          .map((entry) => entry.key)
          .join(', ');
      issues.add('Worker artefact is missing: $missing');
    }

    return DwiCheckResult(
      ok: issues.isEmpty,
      hash: hash,
      issues: issues,
      diagnostics: discovery.diagnostics,
    );
  }

  /// Removes generated sources, manifest and artefact.
  Future<void> clean() async {
    final cfg = config.validated();
    for (final path in <String>{
      cfg.absoluteWorkerSource,
      cfg.absoluteProxies,
      cfg.absoluteArtifact,
      ...cfg.absoluteArtifacts,
      cfg.absoluteManifest,
    }) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    final workerDirectory = Directory(p.dirname(cfg.absoluteWorkerSource));
    if (p.basename(workerDirectory.path) == '.dwi' &&
        await workerDirectory.exists()) {
      await workerDirectory.delete(recursive: true);
    }
  }

  Future<void> _checkContent(
    String path,
    String expected,
    String label,
    List<String> issues,
  ) async {
    final file = File(path);
    if (!await file.exists()) {
      issues.add('Missing $label: $path');
      return;
    }
    if (await file.readAsString() != expected) {
      issues.add('Stale $label: $path');
    }
  }

  Future<Map<String, Object?>?> _readManifest(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return Map<String, Object?>.from(decoded);
    } on FormatException {
      return null;
    }
  }

  String _manifestJson({
    required DwiBuildConfig config,
    required String hash,
    required List<DwiTaskDescriptor> tasks,
    required bool compiled,
    required String artifactDigest,
    required Map<String, String> artifactFiles,
  }) {
    final files = artifactFiles.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final data = <String, Object?>{
      'protocol': dwiWorkerManifestProtocol,
      'generator': 'dwi_builder',
      'generatorVersion': dwiBuilderVersion,
      'hash': hash,
      'target': config.target,
      'optimization': config.optimization,
      'compiled': compiled,
      'artifactDigest': artifactDigest,
      'artifactFiles': <Object?>[
        for (final entry in files)
          <String, Object?>{'path': entry.key, 'digest': entry.value},
      ],
      'workers': <String, Object?>{
        config.workerId: <String, Object?>{
          'artifact': _servedUrl(config, config.absoluteEntry),
          'files': files.map((entry) => entry.key).toList(growable: false),
          'entrypoint': _relative(
            config.absoluteWorkerSource,
            config.absoluteProjectRoot,
          ),
          'tasks': tasks.map((task) => task.name).toList(growable: false),
        },
      },
    };
    return '${const JsonEncoder.withIndent('  ').convert(data)}\n';
  }

  /// Served URL and digest for every file this target publishes.
  Future<Map<String, String>> _artifactDigests(DwiBuildConfig config) async {
    final result = <String, String>{};
    for (final path in config.absoluteArtifacts) {
      result[_servedUrl(config, path)] = await fileDigest(path);
    }
    return result;
  }

  /// Whether the manifest's recorded file set matches [current] exactly.
  bool _manifestFilesMatch(
    Map<String, Object?> manifest,
    Map<String, String> current,
  ) {
    final raw = manifest['artifactFiles'];
    if (raw is! List) return false;
    final recorded = <String, String>{};
    for (final entry in raw) {
      if (entry is Map &&
          entry['path'] is String &&
          entry['digest'] is String) {
        recorded[entry['path'] as String] = entry['digest'] as String;
      }
    }
    if (recorded.length != current.length) return false;
    for (final entry in current.entries) {
      if (entry.value.isEmpty || recorded[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  String _servedUrl(DwiBuildConfig config, String path) {
    final webRoot = p.join(config.absoluteProjectRoot, 'web');
    if (p.isWithin(webRoot, path)) {
      return _relative(path, webRoot);
    }
    return _relative(path, config.absoluteProjectRoot);
  }
}

Future<void> _writeIfChanged(String path, String content) async {
  await writeFileAtomically(path, content);
}

/// In-process build queues keyed by absolute project root.
///
/// `File.lock` is per process on some platforms (macOS observed: a second
/// handle in the same process can acquire a lock the first handle holds), so
/// the file lock alone does not serialize two builds started in one isolate.
final Map<String, Future<void>> _buildQueues = <String, Future<void>>{};

/// Runs [body] while holding the project-wide build lock.
///
/// Two mechanisms cooperate:
///
/// * an in-process FIFO queue per project root, so builds started by the same
///   isolate (for example a widget-test harness) run one at a time;
/// * an advisory exclusive lock on `.dwi/build.lock`, taken with a non-blocking
///   syscall and retried, so the CLI and the Flutter hook — separate processes —
///   are serialized too. The operating system releases it if the process dies,
///   and a stale lock file on disk is inert: only the held lock, never its
///   presence, serializes builds.
Future<T> _withBuildLock<T>(
  DwiBuildConfig config,
  Future<T> Function() body,
) {
  final key = config.absoluteProjectRoot;
  final previous = _buildQueues[key];
  final released = Completer<void>();
  _buildQueues[key] = released.future;

  Future<T> run() async {
    if (previous != null) await previous;
    try {
      return await _withFileLock(config, body);
    } finally {
      released.complete();
      if (identical(_buildQueues[key], released.future)) {
        _buildQueues.remove(key);
      }
    }
  }

  return run();
}

Future<T> _withFileLock<T>(
  DwiBuildConfig config,
  Future<T> Function() body,
) async {
  final directory = Directory(p.join(config.absoluteProjectRoot, '.dwi'));
  await directory.create(recursive: true);
  final lockFile = File(p.join(directory.path, 'build.lock'));
  final handle = await lockFile.open(mode: FileMode.append);
  try {
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (true) {
      try {
        await handle.lock(FileLock.exclusive);
        break;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) {
          throw DwiBuildException(
            'Timed out waiting for another DWI build to finish. The lock file '
            'is ${lockFile.path}.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return await body();
  } finally {
    try {
      await handle.unlock();
    } on FileSystemException {
      // Closing the handle releases the lock even if unlock fails.
    }
    await handle.close();
  }
}

String _relative(String path, String root) {
  if (p.isWithin(root, path)) {
    return p.posix.joinAll(p.split(p.relative(path, from: root)));
  }
  return p.posix.joinAll(p.split(path));
}
