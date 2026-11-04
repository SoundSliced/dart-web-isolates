import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'descriptor.dart';
import 'diagnostics.dart';
import 'discovery.dart';
import 'generator.dart';
import 'hasher.dart';
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
  /// Throws [DwiBuildException] with diagnostics when discovery fails, no task
  /// is found, or compilation fails.
  Future<DwiBuildResult> build() async {
    final stopwatch = Stopwatch()..start();
    final cfg = config.validated();
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
      final existingDigest = existing?['artifactDigest'];
      cacheHit =
          !cfg.force &&
          existing != null &&
          existing['hash'] == hash &&
          existing['compiled'] == true &&
          existingDigest is String &&
          existingDigest.isNotEmpty &&
          existingDigest == await fileDigest(cfg.absoluteArtifact);
      if (!cacheHit) {
        await compileWorker(cfg);
        compiled = true;
      }
      final artifactDigest = await fileDigest(cfg.absoluteArtifact);
      if (artifactDigest.isEmpty) {
        throw DwiBuildException(
          'Compilation produced no artefact at ${cfg.absoluteArtifact}.',
        );
      }
      await _writeIfChanged(
        cfg.absoluteManifest,
        _manifestJson(
          config: cfg,
          hash: hash,
          tasks: discovery.sortedTasks,
          compiled: true,
          artifactDigest: artifactDigest,
        ),
      );
    }

    stopwatch.stop();
    return DwiBuildResult(
      discovery: discovery,
      hash: hash,
      workerSourcePath: cfg.absoluteWorkerSource,
      proxiesPath: cfg.absoluteProxies,
      artifactPath: cfg.absoluteArtifact,
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
    final artifact = File(cfg.absoluteArtifact);
    final artifactExists = await artifact.exists();
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
      } else if (artifactExists &&
          digest != await fileDigest(cfg.absoluteArtifact)) {
        issues.add(
          'Worker artefact digest does not match the manifest; the artefact is '
          'missing, truncated or corrupt.',
        );
      }
    }
    if (!artifactExists) {
      issues.add('Worker artefact is missing: ${cfg.absoluteArtifact}');
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
    for (final path in <String>[
      cfg.absoluteWorkerSource,
      cfg.absoluteProxies,
      cfg.absoluteArtifact,
      cfg.absoluteManifest,
    ]) {
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
  }) {
    final data = <String, Object?>{
      'protocol': dwiWorkerManifestProtocol,
      'generator': 'dwi_builder',
      'generatorVersion': dwiBuilderVersion,
      'hash': hash,
      'target': 'js',
      'optimization': config.optimization,
      'compiled': compiled,
      'artifactDigest': artifactDigest,
      'workers': <String, Object?>{
        config.workerId: <String, Object?>{
          'artifact': _artifactUrl(config),
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

  String _artifactUrl(DwiBuildConfig config) {
    final webRoot = p.join(config.absoluteProjectRoot, 'web');
    if (p.isWithin(webRoot, config.absoluteArtifact)) {
      return _relative(config.absoluteArtifact, webRoot);
    }
    return _relative(config.absoluteArtifact, config.absoluteProjectRoot);
  }
}

Future<void> _writeIfChanged(String path, String content) async {
  final file = File(path);
  if (await file.exists() && await file.readAsString() == content) return;
  await file.parent.create(recursive: true);
  final temporary = File('$path.tmp');
  await temporary.writeAsString(content, flush: true);
  if (await file.exists()) await file.delete();
  await temporary.rename(path);
}

String _relative(String path, String root) {
  if (p.isWithin(root, path)) {
    return p.posix.joinAll(p.split(p.relative(path, from: root)));
  }
  return p.posix.joinAll(p.split(path));
}
