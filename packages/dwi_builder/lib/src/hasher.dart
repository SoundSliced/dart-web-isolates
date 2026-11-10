import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'version.dart';

/// Packages whose Dart sources are compiled into the worker entrypoint (or that
/// generate it) and therefore belong to the compilation inputs.
const Set<String> _runtimePackages = <String>{
  'dwi',
  'dwi_annotations',
  'dwi_builder',
  'dwi_core',
  'dwi_protocol',
  'dwi_web',
};

/// Computes the content hash used to decide whether a worker must be rebuilt.
///
/// The hash covers the generated worker and proxies, every library reachable
/// from a task library, the worker/protocol runtime and generator sources, the
/// project's package resolution, the generator version, the actual compiler
/// identity (not the running tool's SDK) and the compiler options. It
/// deliberately does not cover the manifest or the output path, so switching
/// output locations does not force a recompilation.
Future<String> computeWorkerHash({
  required DwiBuildConfig config,
  required String workerSource,
  required String proxiesSource,
  required Iterable<String> dependencyFiles,
}) async {
  final builder = BytesBuilder(copy: false);

  void addBytes(String label, List<int> bytes) {
    final header = utf8.encode('$label:${bytes.length}\n');
    builder
      ..add(header)
      ..add(bytes)
      ..add(const <int>[0]);
  }

  void addString(String label, String value) =>
      addBytes(label, utf8.encode(value));

  addString('builder', dwiBuilderVersion);
  addString('manifestProtocol', '$dwiWorkerManifestProtocol');
  // The selected compiler may differ from the tool running the build, so its
  // own identity is hashed rather than Platform.version.
  addString('compiler', await compilerIdentity(config.executable));
  addString('target', config.target);
  addString('optimization', config.optimization);
  addString('workerId', config.workerId);
  addString('workerSource', workerSource);
  addString('proxiesSource', proxiesSource);

  final dependencies = dependencyFiles.toSet().toList(growable: false)..sort();
  for (final path in dependencies) {
    final file = File(path);
    final label = 'dep:${_relative(path, config.absoluteProjectRoot)}';
    if (!file.existsSync()) {
      addString(label, '<missing>');
      continue;
    }
    addBytes(label, await file.readAsBytes());
  }

  return sha256.convert(builder.takeBytes()).toString();
}

/// Identity of the compiler executable selected for this build.
///
/// Runs `<executable> --version`; the output and exit code are part of the
/// worker hash so changing compilers (or SDKs) invalidates the cache even when
/// the build tool itself runs on a different SDK.
Future<String> compilerIdentity(String executable) async {
  try {
    final result = await Process.run(executable, <String>['--version']);
    return '${result.exitCode}\n${result.stdout}\n${result.stderr}'.trim();
  } on ProcessException catch (error) {
    return 'unavailable:${error.message}';
  }
}

/// SHA-256 digest of a file's bytes.
Future<String> fileDigest(String path) async {
  final file = File(path);
  if (!await file.exists()) return '';
  return sha256.convert(await file.readAsBytes()).toString();
}

/// Every Dart source of the DWI runtime packages plus the project's package
/// resolution, resolved through `.dart_tool/package_config.json`.
///
/// Missing package config or unresolved entries are ignored: the caller still
/// hashes the task closure and generated source, so the cache fails safe by
/// rebuilding fewer times rather than certifying stale code.
Future<Set<String>> collectRuntimeDependencies(DwiBuildConfig config) async {
  final files = <String>{};
  final configFile = File(
    p.join(config.absoluteProjectRoot, '.dart_tool', 'package_config.json'),
  );
  if (!await configFile.exists()) return files;
  files.add(p.normalize(configFile.path));

  Object? decoded;
  try {
    decoded = jsonDecode(await configFile.readAsString());
  } on FormatException {
    return files;
  }
  if (decoded is! Map || decoded['packages'] is! List) return files;

  final base = configFile.parent.uri;
  for (final entry in decoded['packages'] as List<dynamic>) {
    if (entry is! Map) continue;
    final name = entry['name'];
    final rawRoot = entry['rootUri'];
    if (name is! String ||
        !_runtimePackages.contains(name) ||
        rawRoot is! String) {
      continue;
    }
    final raw = Uri.parse(rawRoot);
    final resolved = raw.hasScheme ? raw : base.resolveUri(raw);
    if (resolved.scheme != 'file') continue;
    final lib = Directory(p.join(resolved.toFilePath(), 'lib'));
    if (!await lib.exists()) continue;
    await for (final entity in lib.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && entity.path.endsWith('.dart')) {
        files.add(p.normalize(entity.path));
      }
    }
  }
  return files;
}

String _relative(String path, String root) {
  if (p.isWithin(root, path)) {
    return p.posix.joinAll(p.split(p.relative(path, from: root)));
  }
  return p.posix.joinAll(p.split(path));
}
