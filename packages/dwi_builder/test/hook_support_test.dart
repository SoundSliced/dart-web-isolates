import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/src/hook_support.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory app;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('dwi_hook_support_');
    app = Directory(p.join(temp.path, 'app'))..createSync(recursive: true);
    Directory(p.join(app.path, '.dart_tool')).createSync(recursive: true);
    Directory(p.join(app.path, 'web')).createSync(recursive: true);
    File(p.join(app.path, 'web', 'index.html')).writeAsStringSync('<html></html>');
    writeAppPubspec(app);
    writeConfig(app);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  bool hasWeb(String path) => File(p.join(path, 'web', 'index.html')).existsSync();

  test('finds the application package that owns the config', () {
    final config = File(p.join(app.path, '.dart_tool', 'package_config.json'));

    expect(
      findDwiAppRoot(packageConfig: config.uri, hasWebEntrypoint: hasWeb),
      p.normalize(app.path),
    );
  });

  test('ignores packages whose own config is a different file', () {
    // A dependency can have its own package config. It must not be mistaken
    // for the application just because it is listed in the app's config.
    final dependency = Directory(p.join(temp.path, 'dep'))..createSync();
    Directory(p.join(dependency.path, 'web')).createSync();
    File(
      p.join(dependency.path, 'web', 'index.html'),
    ).writeAsStringSync('<html></html>');
    writeAppPubspec(dependency);
    Directory(p.join(dependency.path, '.dart_tool')).createSync();
    writeConfig(dependency);

    final appConfig = File(p.join(app.path, '.dart_tool', 'package_config.json'));
    appConfig.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'configVersion': 2,
        'packages': <Map<String, Object?>>[
          <String, Object?>{
            'name': 'dep',
            'rootUri': p.relative(dependency.path, from: appConfig.parent.path),
            'packageUri': 'lib/',
            'languageVersion': '3.13',
          },
        ],
      }),
    );

    expect(
      findDwiAppRoot(packageConfig: appConfig.uri, hasWebEntrypoint: hasWeb),
      isNull,
    );
  });

  test('returns null when the app does not depend on dwi', () {
    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_app
environment:
  sdk: ^3.13.0
dependencies:
  flutter:
    sdk: flutter
''');
    final config = File(p.join(app.path, '.dart_tool', 'package_config.json'));

    expect(
      findDwiAppRoot(packageConfig: config.uri, hasWebEntrypoint: hasWeb),
      isNull,
    );
  });

  test('returns null without a web entrypoint', () {
    File(p.join(app.path, 'web', 'index.html')).deleteSync();
    final config = File(p.join(app.path, '.dart_tool', 'package_config.json'));

    expect(
      findDwiAppRoot(packageConfig: config.uri, hasWebEntrypoint: hasWeb),
      isNull,
    );
  });

  test('returns null for a missing or invalid package config', () {
    expect(
      findDwiAppRoot(
        packageConfig: Uri.file(p.join(temp.path, 'missing.json')),
        hasWebEntrypoint: hasWeb,
      ),
      isNull,
    );

    final invalid = File(p.join(temp.path, 'invalid.json'))
      ..writeAsStringSync('not json');
    expect(
      findDwiAppRoot(packageConfig: invalid.uri, hasWebEntrypoint: hasWeb),
      isNull,
    );
  });
}

void writeAppPubspec(Directory app) {
  File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('''
name: sample_app
environment:
  sdk: ^3.13.0
dependencies:
  dwi:
    path: ../packages/dwi
''');
}

void writeConfig(
  Directory app, {
  String name = 'sample_app',
  String dependency = 'dwi',
}) {
  final packages = <Map<String, Object?>>[
    <String, Object?>{
      'name': name,
      'rootUri': '../',
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    },
    <String, Object?>{
      'name': dependency,
      'rootUri': 'file:///tmp/$dependency',
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    },
  ];
  File(p.join(app.path, '.dart_tool', 'package_config.json')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'configVersion': 2,
      'packages': packages,
    }),
  );
}
