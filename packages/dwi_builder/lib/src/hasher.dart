import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'version.dart';

/// Computes the content hash used to decide whether a worker must be rebuilt.
///
/// The hash covers the generated worker and proxies, every library reachable
/// from a task library, the Dart compiler version, the DWI generator version
/// and the compiler options. It deliberately does not cover the manifest or the
/// output path, so switching output locations does not force a recompilation.
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
  addString('dartVersion', Platform.version);
  addString('dartExecutable', config.executable);
  addString('target', 'js');
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

String _relative(String path, String root) {
  if (p.isWithin(root, path)) {
    return p.posix.joinAll(p.split(p.relative(path, from: root)));
  }
  return p.posix.joinAll(p.split(path));
}
