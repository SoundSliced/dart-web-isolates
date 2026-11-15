import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

DwiTypeDescriptor _int() =>
    const DwiTypeDescriptor(name: 'int', libraryUri: 'dart:core');

DwiTypeDescriptor _string() =>
    const DwiTypeDescriptor(name: 'String', libraryUri: 'dart:core');

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'discovers a task with several required positional parameters',
    () async {
      project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int add(int left, int right) => left + right;
''');

      final result = await discoverTasks(project.config());

      expect(result.hasErrors, isFalse, reason: result.diagnostics.join('\n'));
      final task = result.tasks.singleWhere((task) => task.name == 'add');
      expect(task.inputNames, <String>['left', 'right']);
      expect(task.takesRecordInput, isTrue);
      expect(task.input!.kind, DwiTypeKind.record);
      expect(task.input!.positional.map((type) => type.name), <String>[
        'int',
        'int',
      ]);
    },
  );

  test('keeps one-parameter tasks unchanged', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int twice(int value) => value * 2;
''');

    final result = await discoverTasks(project.config());

    final task = result.tasks.singleWhere((task) => task.name == 'twice');
    expect(task.inputNames, isEmpty);
    expect(task.takesRecordInput, isFalse);
    expect(task.input!.kind, DwiTypeKind.value);
  });

  test('still rejects an optional parameter among several', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int mixed(int left, [int right = 0]) => left + right;
''');

    final result = await discoverTasks(project.config());

    expect(result.hasErrors, isTrue);
    expect(
      result.diagnostics
          .where((item) => item.code == 'DWI003')
          .map((item) => item.message),
      contains(contains('optional parameter')),
    );
  });

  test(
    'generates a proxy taking separate arguments and a record worker entry',
    () {
      final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
        DwiTaskDescriptor(
          name: 'add',
          functionName: 'add',
          importUri: 'package:app/tasks.dart',
          sourcePath: '/app/lib/tasks.dart',
          line: 4,
          column: 5,
          input: DwiTypeDescriptor(
            name: 'Record',
            kind: DwiTypeKind.record,
            positional: <DwiTypeDescriptor>[_int(), _string()],
          ),
          inputNames: const <String>['left', 'label'],
          output: _int(),
          returnsFuture: false,
        ),
      ], workerId: 'w1');

      expect(
        sources.proxies,
        contains('Future<int> add(int left, String label)'),
      );
      expect(sources.proxies, contains('(left, label)'));
      expect(sources.worker, contains('record.\$1, record.\$2'));
    },
  );
}
