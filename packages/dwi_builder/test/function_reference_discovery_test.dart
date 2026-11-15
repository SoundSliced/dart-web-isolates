import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Unannotated functions passed by name to `DwiFunctions` (ADR-030).
const String _tasks = r'''
int twice(int value) => value * 2;

Future<String> label(String value) async => 'label:$value';

class Math {
  Math._();

  static int square(int value) => value * value;
}
''';

/// Only the reference that binds deterministically is discovered; a closure is
/// reported as a warning and is not a task.
const String _app = r'''
import 'package:sample_app/dwi_tasks.g.dart';
import 'package:sample_app/tasks.dart';

Future<int> callTwice() => DwiFunctions.run(twice, 2);

Future<String> callLabel() => DwiFunctions.run(label, 'x');

Future<int> callSquare() => DwiFunctions.run(Math.square, 3);
''';

const String _nativeCheck = r'''
import 'package:dwi/dwi.dart';
import 'package:sample_app/app.dart';

Future<void> main() async {
  final doubled = await callTwice();
  final text = await callLabel();
  final squared = await callSquare();
  await Dwi.close();
  print('$doubled|$text|$squared');
}
''';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'discovers functions named by DwiFunctions without annotations',
    () async {
      project.write('lib/tasks.dart', _tasks);
      project.write('lib/app.dart', _app);

      final result = await discoverTasks(project.config());

      expect(result.tasks.map((task) => task.name), <String>[
        'twice',
        'label',
        'Math.square',
      ]);
      expect(result.hasErrors, isFalse, reason: result.diagnostics.join('\n'));
    },
  );

  test(
    'warns on a closure passed to DwiFunctions and does not invent a task',
    () async {
      project.write('lib/tasks.dart', _tasks);
      project.write('lib/app.dart', r'''
import 'package:sample_app/tasks.dart';

Future<int> callClosure() => DwiFunctions.run((int value) => value + 1, 1);
''');

      final result = await discoverTasks(project.config());

      expect(result.tasks, isEmpty);
      expect(result.hasErrors, isFalse);
      expect(
        result.diagnostics
            .where((item) => item.code == 'DWI003')
            .map((item) => item.severity),
        <DwiDiagnosticSeverity>[DwiDiagnosticSeverity.warning],
      );
    },
  );

  test('an annotated function is not discovered twice', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int twice(int value) => value * 2;
''');
    project.write('lib/app.dart', r'''
import 'package:sample_app/tasks.dart';

Future<int> callTwice() => DwiFunctions.run(twice, 2);
''');

    final result = await discoverTasks(project.config());

    expect(result.tasks.map((task) => task.name), <String>['twice']);
    expect(result.hasErrors, isFalse, reason: result.diagnostics.join('\n'));
  });

  test('DwiFunctions calls run on native isolates and compile for dart2js and dart2wasm', () async {
    project.write('lib/tasks.dart', _tasks);
    project.write('lib/app.dart', _app);
    project.write('bin/native_check.dart', _nativeCheck);

    final built = await DwiBuilder(project.config(compile: true)).build();
    expect(built.compiled, isTrue);
    final proxies = project.read('lib/dwi_tasks.g.dart');
    expect(proxies, contains("Dwi.registerTask('twice'"));
    expect(proxies, contains('abstract final class DwiFunctions'));

    final native = await Process.run(
      Platform.resolvedExecutable,
      <String>[
        '--packages=.dart_tool/package_config.json',
        'bin/native_check.dart',
      ],
      workingDirectory: project.root.path,
      environment: <String, String>{
        'PUB_CACHE': Platform.environment['PUB_CACHE'] ?? '',
      },
    );
    expect(native.exitCode, 0, reason: '${native.stdout}\n${native.stderr}');
    expect(native.stdout as String, contains('4|label:x|9'));

    for (final target in <String>['js', 'wasm']) {
      final webProject = FixtureProject.create();
      addTearDown(webProject.dispose);
      webProject.write('lib/tasks.dart', _tasks);
      webProject.write('lib/app.dart', _app);
      webProject.write(
        'web/main.dart',
        "import 'package:sample_app/app.dart';\n"
            'Future<int> run() => callTwice();\n'
            'void main() {}\n',
      );
      await DwiBuilder(webProject.config().copyWith(target: target)).build();
      final output = p.join(
        webProject.root.path,
        'web',
        target == 'js' ? 'main.dart.js' : 'main.wasm',
      );
      final compiled = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'compile',
          target,
          if (target == 'js') '-O1',
          '-o',
          output,
          'web/main.dart',
        ],
        workingDirectory: webProject.root.path,
        environment: <String, String>{
          'PUB_CACHE': Platform.environment['PUB_CACHE'] ?? '',
        },
      );
      expect(
        compiled.exitCode,
        0,
        reason: '$target: ${compiled.stdout}\n${compiled.stderr}',
      );
      expect(File(output).existsSync(), isTrue);
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
