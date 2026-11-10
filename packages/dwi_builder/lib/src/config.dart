import 'dart:io';

import 'package:path/path.dart' as p;

/// Configuration for one `dwi_builder` run.
class DwiBuildConfig {
  const DwiBuildConfig({
    required this.projectRoot,
    this.includePaths = const <String>['lib'],
    this.excludePaths = const <String>[],
    this.workerSourcePath = '.dwi/generated_worker.dart',
    this.proxiesPath = 'lib/dwi_tasks.g.dart',
    this.artifactPath = 'web/dwi/worker.dart.js',
    this.manifestPath = '.dwi/worker_manifest.json',
    this.target = 'js',
    this.optimization = 'O1',
    this.compile = true,
    this.force = false,
    this.verbose = false,
    this.dartExecutable,
    this.workerId = 'default',
  });

  /// Project root containing `pubspec.yaml`.
  final String projectRoot;

  /// Files or directories scanned for `@DwiTask` annotations.
  final List<String> includePaths;

  /// Files or directories excluded from discovery.
  final List<String> excludePaths;

  /// Generated worker entrypoint path, relative to [projectRoot] by default.
  final String workerSourcePath;

  /// Generated typed-proxy path, relative to [projectRoot] by default.
  final String proxiesPath;

  /// Compiled worker artefact path, relative to [projectRoot] by default.
  ///
  /// For `target: 'js'` this is the single compiled file. For
  /// `target: 'wasm'` the worker directory is its parent directory and the
  /// published names are fixed: `worker.wasm`, `worker.mjs` and
  /// `worker.boot.mjs` (ADR-018). The entry URL is [absoluteEntry].
  final String artifactPath;

  /// Generated manifest path, relative to [projectRoot] by default.
  final String manifestPath;

  /// Worker compiler output: `js` (default) or `wasm` (ADR-018, experimental).
  final String target;

  /// `dart compile js` optimisation level (`O0`–`O4`).
  final String optimization;

  /// Whether to compile the worker. `false` is generation-only.
  final bool compile;

  /// Recompile even when the content hash is unchanged.
  final bool force;

  /// Print additional progress information.
  final bool verbose;

  /// Dart executable used for compilation; defaults to the running SDK.
  final String? dartExecutable;

  /// Worker id copied into generated metadata and the manifest.
  final String workerId;

  /// Absolute, normalised project root.
  String get absoluteProjectRoot => p.normalize(p.absolute(projectRoot));

  /// Resolves a configured path against [projectRoot].
  String resolve(String path) => p.normalize(
    p.isAbsolute(path) ? path : p.join(absoluteProjectRoot, path),
  );

  /// Absolute generated worker entrypoint.
  String get absoluteWorkerSource => resolve(workerSourcePath);

  /// Absolute generated proxy file.
  String get absoluteProxies => resolve(proxiesPath);

  /// Absolute compiled worker artefact.
  String get absoluteArtifact => resolve(artifactPath);

  /// Whether this build targets dart2wasm.
  bool get isWasm => target == 'wasm';

  /// Absolute directory holding the published worker artefacts.
  String get absoluteArtifactDir => p.dirname(absoluteArtifact);

  /// Absolute entry artefact: the `.js` worker, or the wasm bootstrap.
  String get absoluteEntry => isWasm
      ? p.join(absoluteArtifactDir, 'worker.boot.mjs')
      : absoluteArtifact;

  /// Absolute `.wasm` module path (wasm target only).
  ///
  /// Prefer [wasmGeneration] paths; a generation is published as a complete
  /// directory before the entry references it (ADR-018).
  String get absoluteWasmModule => p.join(absoluteArtifactDir, 'worker.wasm');

  /// Absolute compiler loader path (wasm target only).
  String get absoluteWasmLoader => p.join(absoluteArtifactDir, 'worker.mjs');

  /// Directory that holds the files of one content-addressed generation.
  String wasmGenerationDir(String generation) =>
      p.join(absoluteArtifactDir, 'gen-$generation');

  /// Loader inside a generation directory.
  String wasmGenerationLoader(String generation) =>
      p.join(wasmGenerationDir(generation), 'worker.mjs');

  /// Module inside a generation directory.
  String wasmGenerationModule(String generation) =>
      p.join(wasmGenerationDir(generation), 'worker.wasm');

  /// Every file the worker entry needs for [generation].
  ///
  /// For `js` the generation is ignored and the single artefact is returned.
  List<String> artifactSet(String generation) => isWasm
      ? <String>[
          absoluteEntry,
          wasmGenerationLoader(generation),
          wasmGenerationModule(generation),
        ]
      : <String>[absoluteArtifact];

  /// Every file this build publishes.
  ///
  /// Only meaningful for the `js` target; a wasm build needs its generation.
  List<String> get absoluteArtifacts => isWasm
      ? <String>[absoluteEntry]
      : <String>[absoluteArtifact];

  /// Absolute manifest file.
  String get absoluteManifest => resolve(manifestPath);

  /// Absolute include paths.
  List<String> get absoluteIncludePaths =>
      includePaths.map(resolve).toList(growable: false);

  /// Absolute exclude paths.
  List<String> get absoluteExcludePaths =>
      excludePaths.map(resolve).toList(growable: false);

  /// The Dart executable used for compilation.
  String get executable => dartExecutable ?? Platform.resolvedExecutable;

  /// Validates configuration values that have no sensible recovery.
  ///
  /// Throws [ArgumentError] for invalid optimisation levels or empty includes.
  DwiBuildConfig validated() {
    const optimisations = <String>{'O0', 'O1', 'O2', 'O3', 'O4'};
    if (!optimisations.contains(optimization)) {
      throw ArgumentError.value(
        optimization,
        'optimization',
        'must be one of ${optimisations.join(', ')}',
      );
    }
    if (includePaths.isEmpty) {
      throw ArgumentError.value(
        includePaths,
        'includePaths',
        'must contain at least one path',
      );
    }
    if (workerId.trim().isEmpty) {
      throw ArgumentError.value(workerId, 'workerId', 'must not be empty');
    }
    if (target != 'js' && target != 'wasm') {
      throw ArgumentError.value(
        target,
        'target',
        'must be "js" or "wasm"',
      );
    }
    return this;
  }

  /// Returns a copy with selected values replaced.
  DwiBuildConfig copyWith({
    String? projectRoot,
    List<String>? includePaths,
    List<String>? excludePaths,
    String? workerSourcePath,
    String? proxiesPath,
    String? artifactPath,
    String? manifestPath,
    String? target,
    String? optimization,
    bool? compile,
    bool? force,
    bool? verbose,
    String? dartExecutable,
    String? workerId,
  }) {
    return DwiBuildConfig(
      projectRoot: projectRoot ?? this.projectRoot,
      includePaths: includePaths ?? this.includePaths,
      excludePaths: excludePaths ?? this.excludePaths,
      workerSourcePath: workerSourcePath ?? this.workerSourcePath,
      proxiesPath: proxiesPath ?? this.proxiesPath,
      artifactPath: artifactPath ?? this.artifactPath,
      manifestPath: manifestPath ?? this.manifestPath,
      target: target ?? this.target,
      optimization: optimization ?? this.optimization,
      compile: compile ?? this.compile,
      force: force ?? this.force,
      verbose: verbose ?? this.verbose,
      dartExecutable: dartExecutable ?? this.dartExecutable,
      workerId: workerId ?? this.workerId,
    );
  }
}
