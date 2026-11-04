import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Finds the Flutter application package that owns [packageConfig].
///
/// A build hook runs from its own package directory, but the Flutter tool
/// compiles it with the *application's* package config. That config is the only
/// supported way for a dependency hook to discover the application being built.
///
/// Returns `null` when the config does not describe exactly one application
/// package that depends on `dwi` and has a web entrypoint. A hook must skip
/// quietly in that case so unrelated Flutter builds are unaffected.
String? findDwiAppRoot({
  required Uri packageConfig,
  required bool Function(String path) hasWebEntrypoint,
}) {
  final File configFile;
  try {
    configFile = File.fromUri(packageConfig);
    if (!configFile.existsSync()) return null;
  } on Object {
    return null;
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(configFile.readAsStringSync());
  } on Object {
    return null;
  }
  if (decoded is! Map || decoded['packages'] is! List) return null;

  final canonicalConfig = _canonical(configFile.path);
  final matches = <String>[];
  for (final raw in decoded['packages']! as List<Object?>) {
    if (raw is! Map) continue;
    final name = raw['name'];
    final rawRoot = raw['rootUri'];
    if (name is! String || rawRoot is! String) continue;

    Uri rootUri;
    try {
      rootUri = configFile.uri.resolve(rawRoot);
    } on Object {
      continue;
    }
    if (rootUri.scheme != 'file') continue;

    final root = p.normalize(rootUri.toFilePath());
    // The application package is the one whose own `.dart_tool` holds this
    // exact package config. Dependencies never satisfy that test.
    final ownConfig = File(p.join(root, '.dart_tool', 'package_config.json'));
    if (!ownConfig.existsSync()) continue;
    if (_canonical(ownConfig.path) != canonicalConfig) continue;

    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) continue;
    if (!_dependsOnDwi(pubspec)) continue;
    if (!hasWebEntrypoint(root)) continue;
    matches.add(root);
  }

  return matches.length == 1 ? matches.single : null;
}

bool _dependsOnDwi(File pubspec) {
  final Object? document;
  try {
    document = loadYaml(pubspec.readAsStringSync());
  } on Object {
    return false;
  }
  if (document is! YamlMap) return false;
  for (final section in const <String>['dependencies', 'dev_dependencies']) {
    final deps = document[section];
    if (deps is YamlMap && deps.containsKey('dwi')) return true;
  }
  return false;
}

String _canonical(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on Object {
    return p.normalize(p.absolute(path));
  }
}
