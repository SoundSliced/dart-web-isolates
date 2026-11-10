import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = _parser();
  ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    _printUsage(parser);
    exit(64);
  }

  final command = results.command;
  if (command == null) {
    _printUsage(parser);
    exit(64);
  }

  try {
    switch (command.name) {
      case 'build':
        exitCode = await _build(command);
      case 'generate':
        exitCode = await _generate(command);
      case 'check':
        exitCode = await _check(command);
      case 'watch':
        exitCode = await _watch(command);
      case 'clean':
        exitCode = await _clean(command);
      default:
        _printUsage(parser);
        exitCode = 64;
    }
  } on ArgumentError catch (error) {
    stderr.writeln('DWI: ${error.message}');
    exitCode = 64;
  }
}

ArgParser _parser() {
  final parser = ArgParser();
  parser
    ..addCommand('build', _commonOptions(build: true))
    ..addCommand('generate', _commonOptions(build: false))
    ..addCommand('check', _commonOptions(build: false))
    ..addCommand('watch', _commonOptions(build: false))
    ..addCommand(
      'clean',
      ArgParser()
        ..addOption('project-root', defaultsTo: '.')
        ..addOption('worker-source', defaultsTo: '.dwi/generated_worker.dart')
        ..addOption('proxies', defaultsTo: 'lib/dwi_tasks.g.dart')
        ..addOption('artifact', defaultsTo: 'web/dwi/worker.dart.js')
        ..addOption('manifest', defaultsTo: '.dwi/worker_manifest.json')
        ..addOption(
          'target',
          defaultsTo: 'js',
          allowed: <String>['js', 'wasm'],
        ),
    );
  return parser;
}

ArgParser _commonOptions({required bool build}) {
  final parser = ArgParser()
    ..addOption(
      'project-root',
      defaultsTo: '.',
      help: 'Application package root (contains pubspec.yaml).',
    )
    ..addMultiOption(
      'include',
      defaultsTo: <String>['lib'],
      help: 'Files or directories scanned for @DwiTask.',
    )
    ..addMultiOption(
      'exclude',
      defaultsTo: <String>[],
      help: 'Files or directories excluded from discovery.',
    )
    ..addOption(
      'worker-source',
      defaultsTo: '.dwi/generated_worker.dart',
      help: 'Generated worker entrypoint.',
    )
    ..addOption(
      'proxies',
      defaultsTo: 'lib/dwi_tasks.g.dart',
      help: 'Generated typed caller proxies.',
    )
    ..addOption(
      'artifact',
      defaultsTo: 'web/dwi/worker.dart.js',
      help:
          'Compiled worker artefact. For target=wasm the parent directory '
          'receives worker.wasm, worker.mjs and worker.boot.mjs.',
    )
    ..addOption(
      'manifest',
      defaultsTo: '.dwi/worker_manifest.json',
      help: 'Generated worker manifest.',
    )
    ..addOption(
      'target',
      defaultsTo: 'js',
      allowed: <String>['js', 'wasm'],
      help: 'Worker compiler output (ADR-018; wasm is experimental).',
    )
    ..addOption(
      'optimization',
      defaultsTo: 'O1',
      allowed: <String>['O0', 'O1', 'O2', 'O3', 'O4'],
      help: 'dart compile js optimisation level.',
    )
    ..addOption(
      'worker-id',
      defaultsTo: 'default',
      help: 'Worker id recorded in the manifest.',
    )
    ..addOption('dart', help: 'Dart executable used for compilation.')
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Print compilation details.',
    );
  if (build) {
    parser
      ..addFlag(
        'compile',
        defaultsTo: true,
        help: 'Compile the worker after generation.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Recompile even when the content hash is unchanged.',
      )
      ..addFlag(
        'flutter-build',
        negatable: false,
        help:
            'Run `flutter build web` after the worker build. '
            'Arguments after -- are forwarded to Flutter.',
      );
  }
  return parser;
}

DwiBuildConfig _config(ArgResults command, {required bool compile}) {
  final include = command['include'] as List<String>;
  final exclude = command['exclude'] as List<String>;
  final configuredCompile = command.options.contains('compile')
      ? command['compile'] as bool
      : true;
  return DwiBuildConfig(
    projectRoot: p.absolute(command['project-root'] as String),
    includePaths: include.isEmpty ? const <String>['lib'] : include,
    excludePaths: exclude,
    workerSourcePath: command['worker-source'] as String,
    proxiesPath: command['proxies'] as String,
    artifactPath: command['artifact'] as String,
    manifestPath: command['manifest'] as String,
    target: command.options.contains('target')
        ? command['target'] as String
        : 'js',
    optimization: command['optimization'] as String,
    compile: compile && configuredCompile,
    force: command.options.contains('force') ? command['force'] as bool : false,
    verbose: command['verbose'] as bool,
    dartExecutable: command['dart'] as String?,
    workerId: command['worker-id'] as String,
  );
}

Future<int> _build(ArgResults command) async {
  final config = _config(command, compile: true);
  final builder = DwiBuilder(config);
  try {
    final result = await builder.build();
    _printDiagnostics(result.discovery.diagnostics);
    final tasks = result.discovery.tasks.length;
    final state = result.compiled
        ? 'compiled'
        : result.cacheHit
        ? 'reused (hash unchanged)'
        : 'not compiled';
    stdout
      ..writeln('DWI: $tasks task(s); worker $state.')
      ..writeln(
        '  entrypoint: ${_relative(result.workerSourcePath, config.absoluteProjectRoot)}',
      )
      ..writeln(
        '  artifact:   ${_relative(result.artifactPath, config.absoluteProjectRoot)}',
      );
    if (config.compile) {
      stdout.writeln(
        '  manifest:   ${_relative(result.manifestPath, config.absoluteProjectRoot)}',
      );
    } else {
      stdout.writeln(
        '  manifest:   not written (compilation disabled)',
      );
    }
    stdout.writeln('  hash:       ${result.hash.substring(0, 12)}');
    if (config.compile) {
      stdout.writeln(
        'DWI: `flutter build web` copies web/ into build/web; '
        'no manual copy is required.',
      );
    }
    if (command.options.contains('flutter-build') &&
        command['flutter-build'] == true) {
      return await _runFlutterBuild(config, command.rest);
    }
    return 0;
  } on DwiBuildException catch (error) {
    stderr.writeln('DWI: ${error.summary}');
    _printDiagnostics(error.diagnostics);
    return 1;
  }
}

Future<int> _generate(ArgResults command) async {
  final config = _config(command, compile: false);
  final builder = DwiBuilder(config);
  try {
    final result = await builder.build();
    _printDiagnostics(result.discovery.diagnostics);
    stdout
      ..writeln('DWI: generated ${result.discovery.tasks.length} task(s).')
      ..writeln(
        '  entrypoint: ${_relative(result.workerSourcePath, config.absoluteProjectRoot)}',
      )
      ..writeln(
        '  proxies:    ${_relative(result.proxiesPath, config.absoluteProjectRoot)}',
      )
      ..writeln('  hash:       ${result.hash.substring(0, 12)}');
    stdout.writeln('DWI: run `dwi build` to compile the worker.');
    return 0;
  } on DwiBuildException catch (error) {
    stderr.writeln('DWI: ${error.summary}');
    _printDiagnostics(error.diagnostics);
    return 1;
  }
}

Future<int> _check(ArgResults command) async {
  final config = _config(command, compile: false);
  final builder = DwiBuilder(config);
  try {
    final result = await builder.check();
    _printDiagnostics(result.diagnostics);
    if (result.ok) {
      stdout.writeln(
        'DWI: generated worker is up to date '
        '(${result.hash.substring(0, 12)}).',
      );
      return 0;
    }
    for (final issue in result.issues) {
      stderr.writeln('DWI: $issue');
    }
    stderr.writeln('DWI: run `dwi build` to regenerate and recompile.');
    return 1;
  } on DwiBuildException catch (error) {
    stderr.writeln('DWI: ${error.summary}');
    _printDiagnostics(error.diagnostics);
    return 1;
  }
}

Future<int> _clean(ArgResults command) async {
  final config = DwiBuildConfig(
    projectRoot: p.absolute(command['project-root'] as String),
    workerSourcePath: command['worker-source'] as String,
    proxiesPath: command['proxies'] as String,
    artifactPath: command['artifact'] as String,
    manifestPath: command['manifest'] as String,
    target: command['target'] as String,
    compile: false,
  );
  await DwiBuilder(config).clean();
  stdout.writeln('DWI: removed generated worker files.');
  return 0;
}

Future<int> _watch(ArgResults command) async {
  final config = _config(command, compile: true);
  final builder = DwiBuilder(config);
  var dependencies = <String>{};

  Future<void> rebuild() async {
    try {
      final result = await builder.build();
      _printDiagnostics(result.discovery.diagnostics);
      final state = result.compiled
          ? 'compiled'
          : result.cacheHit
          ? 'reused'
          : 'generated';
      stdout.writeln(
        'DWI: worker $state in ${result.duration.inMilliseconds} ms '
        '(${result.discovery.tasks.length} task(s)).',
      );
      dependencies = <String>{
        ...result.discovery.dependencyFiles,
        ...await collectRuntimeDependencies(config),
      };
    } on DwiBuildException catch (error) {
      stderr.writeln('DWI: ${error.summary}');
      _printDiagnostics(error.diagnostics);
    }
  }

  await rebuild();
  var previous = _snapshot(config, dependencies);
  stdout.writeln(
    'DWI: watching ${config.includePaths.join(', ')} and the task dependency '
    'closure for changes. Reload the page after a worker rebuild; existing '
    'workers keep the old script.',
  );

  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    var current = _snapshot(config, dependencies);
    if (_sameSnapshot(previous, current)) continue;
    stdout.writeln('DWI: change detected, rebuilding worker...');
    // Edits that land while a build is running must trigger another build.
    do {
      final before = current;
      await rebuild();
      current = _snapshot(config, dependencies);
      if (_sameSnapshot(before, current)) break;
      stdout.writeln('DWI: inputs changed during the build, rebuilding...');
    } while (true);
    previous = current;
  }
}

Future<int> _runFlutterBuild(
  DwiBuildConfig config,
  List<String> arguments,
) async {
  final flutter = _flutterExecutable();
  stdout.writeln('DWI: running `$flutter build web ${arguments.join(' ')}`.');
  try {
    final result = await Process.run(flutter, <String>[
      'build',
      'web',
      ...arguments,
    ], workingDirectory: config.absoluteProjectRoot);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    return result.exitCode;
  } on ProcessException catch (error) {
    stderr.writeln('DWI: could not run Flutter: ${error.message}');
    return 1;
  }
}

String _flutterExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final candidate = p.join(root, 'bin', 'flutter');
    if (File(candidate).existsSync()) return candidate;
  }
  return 'flutter';
}

Map<String, String> _snapshot(
  DwiBuildConfig config,
  Iterable<String> dependencies,
) {
  final entries = <String, String>{};
  for (final include in config.absoluteIncludePaths) {
    final type = FileSystemEntity.typeSync(include);
    if (type == FileSystemEntityType.file) {
      _addSnapshot(entries, include, config);
      continue;
    }
    if (type != FileSystemEntityType.directory) continue;
    for (final entity in Directory(
      include,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is File) _addSnapshot(entries, entity.path, config);
    }
  }
  // The task closure can reach files outside --include (other packages,
  // helpers) and the DWI runtime sources compiled into the worker.
  for (final dependency in dependencies) {
    final file = File(dependency);
    final normalised = p.normalize(dependency);
    if (!file.existsSync()) {
      entries[normalised] = 'missing';
      continue;
    }
    final stat = file.statSync();
    entries[normalised] =
        '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
  }
  for (final path in <String>[
    p.join(config.absoluteProjectRoot, 'pubspec.yaml'),
    p.join(config.absoluteProjectRoot, 'pubspec.lock'),
    p.join(config.absoluteProjectRoot, '.dart_tool', 'package_config.json'),
  ]) {
    final file = File(path);
    if (!file.existsSync()) {
      entries[p.normalize(path)] = 'missing';
      continue;
    }
    final stat = file.statSync();
    entries[p.normalize(path)] =
        '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
  }
  return entries;
}

void _addSnapshot(
  Map<String, String> entries,
  String path,
  DwiBuildConfig config,
) {
  if (!path.endsWith('.dart')) return;
  final normalised = p.normalize(path);
  if (p.equals(normalised, config.absoluteProxies) ||
      p.equals(normalised, config.absoluteWorkerSource)) {
    return;
  }
  final segments = p.split(normalised);
  if (segments.contains('.dwi') ||
      segments.contains('.dart_tool') ||
      segments.contains('build')) {
    return;
  }
  final stat = File(normalised).statSync();
  entries[normalised] = '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
}

bool _sameSnapshot(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

void _printDiagnostics(List<DwiDiagnostic> diagnostics) {
  for (final diagnostic in diagnostics) {
    final sink = diagnostic.severity == DwiDiagnosticSeverity.error
        ? stderr
        : stdout;
    sink.writeln(diagnostic.format());
  }
}

String _relative(String path, String root) {
  if (p.isWithin(root, path)) {
    return p.posix.joinAll(p.split(p.relative(path, from: root)));
  }
  return p.posix.joinAll(p.split(path));
}

void _printUsage(ArgParser parser) {
  stdout
    ..writeln('DWI — automatic worker generation and compilation.')
    ..writeln()
    ..writeln('Usage: dart run dwi_builder:dwi <command> [options]')
    ..writeln()
    ..writeln('Commands:')
    ..writeln(
      '  build      Discover @DwiTask, generate sources, compile worker',
    )
    ..writeln('  generate   Discover @DwiTask and generate sources only')
    ..writeln(
      '  check      Fail if generated sources or the artefact are stale',
    )
    ..writeln('  watch      Rebuild the worker when Dart sources change')
    ..writeln('  clean      Remove generated worker files')
    ..writeln()
    ..writeln('Run `dwi <command> --help` for options.');
}
