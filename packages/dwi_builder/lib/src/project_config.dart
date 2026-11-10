import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Project-level worker build settings shared by the CLI and the Flutter hook.
///
/// The file is optional. An application that needs the experimental Wasm
/// worker writes `dwi.yaml` next to its `pubspec.yaml`:
///
/// ```yaml
/// target: wasm
/// ```
///
/// The Flutter build hook and `dwi build` read the same file, so a normal
/// `flutter build web` cannot silently replace a requested Wasm worker with a
/// JS one (ADR-018). An explicit CLI `--target` overrides the file.
class DwiProjectConfig {
  const DwiProjectConfig({this.target});

  /// Conventional file name, resolved against the application package root.
  static const String fileName = 'dwi.yaml';

  /// Configured worker target (`js` or `wasm`), or `null` when unset.
  final String? target;

  /// Absolute path of the configuration file for [projectRoot].
  static String pathFor(String projectRoot) =>
      p.join(projectRoot, fileName);

  /// Reads the configuration for [projectRoot].
  ///
  /// A missing file means "no project preference". Invalid YAML, an unknown
  /// key, or an unsupported target throws [ArgumentError] so a typo fails the
  /// build instead of silently selecting the default.
  static DwiProjectConfig load(String projectRoot) {
    final file = File(pathFor(projectRoot));
    if (!file.existsSync()) return const DwiProjectConfig();

    final Object? document;
    try {
      document = loadYaml(file.readAsStringSync());
    } on YamlException catch (error) {
      throw ArgumentError(
        '${fileName}: invalid YAML: ${error.message}',
      );
    }
    if (document == null) return const DwiProjectConfig();
    if (document is! YamlMap) {
      throw ArgumentError('${fileName}: the document must be a map');
    }

    String? target;
    for (final entry in document.entries) {
      final key = entry.key;
      if (key != 'target') {
        throw ArgumentError('${fileName}: unknown key "$key"');
      }
      final value = entry.value;
      if (value is! String) {
        throw ArgumentError('${fileName}: target must be a string');
      }
      if (value != 'js' && value != 'wasm') {
        throw ArgumentError(
          '${fileName}: target must be "js" or "wasm", got "$value"',
        );
      }
      target = value;
    }
    return DwiProjectConfig(target: target);
  }

  /// Resolves the effective target: an explicit CLI value, then the file, then
  /// `js`.
  static String resolveTarget({
    required String projectRoot,
    String? cliTarget,
  }) {
    if (cliTarget != null && cliTarget.isNotEmpty) return cliTarget;
    return load(projectRoot).target ?? 'js';
  }
}
