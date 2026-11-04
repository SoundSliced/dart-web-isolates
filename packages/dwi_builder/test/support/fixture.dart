import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;

/// A throwaway package with a valid analyzer package config.
class FixtureProject {
  FixtureProject._(this.root);

  /// Temporary package root.
  final Directory root;

  /// Creates a package named [packageName] under the system temp directory.
  static FixtureProject create({String packageName = 'sample_app'}) {
    final directory = Directory.systemTemp.createTempSync('dwi_builder_test_');
    final project = FixtureProject._(directory);
    project.write(
      'pubspec.yaml',
      'name: $packageName\nenvironment:\n  sdk: ^3.13.0\n',
    );
    project._writePackageConfig(packageName);
    return project;
  }

  /// Build configuration rooted at this fixture.
  DwiBuildConfig config({
    bool compile = false,
    bool force = false,
    String optimization = 'O1',
    List<String> includePaths = const <String>['lib'],
  }) {
    return DwiBuildConfig(
      projectRoot: root.path,
      includePaths: includePaths,
      compile: compile,
      force: force,
      optimization: optimization,
    );
  }

  /// Writes a file relative to the package root.
  void write(String relative, String content) {
    final file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// Reads a file relative to the package root.
  String read(String relative) =>
      File(p.join(root.path, relative)).readAsStringSync();

  /// Whether a file exists relative to the package root.
  bool exists(String relative) =>
      File(p.join(root.path, relative)).existsSync();

  /// Deletes the package tree.
  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  void _writePackageConfig(String packageName) {
    final builderRoot = Directory.current;
    final builderConfig = File(
      p.join(builderRoot.path, '.dart_tool', 'package_config.json'),
    );
    if (!builderConfig.existsSync()) {
      throw StateError(
        'Run `dart pub get` in packages/dwi_builder before running tests.',
      );
    }
    final decoded =
        jsonDecode(builderConfig.readAsStringSync()) as Map<String, dynamic>;
    final packages = <Map<String, dynamic>>[
      for (final entry in decoded['packages'] as List)
        Map<String, dynamic>.from(entry as Map),
    ];

    // Resolve relative rootUri values against the builder's package config
    // before copying them into a different package's .dart_tool directory.
    final configBase = builderConfig.parent.uri;
    for (final entry in packages) {
      final raw = Uri.parse(entry['rootUri'] as String);
      entry['rootUri'] = (raw.hasScheme ? raw : configBase.resolveUri(raw))
          .toString();
    }

    final packagesRoot = p.dirname(builderRoot.path);
    void addWorkspacePackage(String name) {
      if (packages.any((entry) => entry['name'] == name)) return;
      packages.add(<String, dynamic>{
        'name': name,
        'rootUri': Directory(p.join(packagesRoot, name)).uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.13',
      });
    }

    addWorkspacePackage('dwi');
    addWorkspacePackage('dwi_web');
    addWorkspacePackage('dwi_core');
    addWorkspacePackage('dwi_protocol');
    addWorkspacePackage('dwi_native');

    packages.removeWhere((entry) => entry['name'] == packageName);
    packages.add(<String, dynamic>{
      'name': packageName,
      'rootUri': root.uri.toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    });

    final config = File(p.join(root.path, '.dart_tool', 'package_config.json'));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'configVersion': 2, 'packages': packages})}\n',
    );
  }
}

/// Tasks covering the supported signature shapes.
const String goodTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int calculatePrimes(int limit) => limit;

@DwiTask(name: 'greet')
String greet(String name) => 'Hello $name';

@DwiTask()
Future<int> delayed(int value) async => value + 1;

@DwiTask()
void noInput() {}
''';
