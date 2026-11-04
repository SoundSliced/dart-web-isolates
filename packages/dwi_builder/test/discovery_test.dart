import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'discovers annotated top-level functions and their signatures',
    () async {
      project.write('lib/tasks.dart', goodTasks);

      final result = await discoverTasks(project.config());

      expect(result.hasErrors, isFalse);
      expect(
        result.tasks.map((task) => task.name),
        containsAll(<String>['calculatePrimes', 'greet', 'delayed', 'noInput']),
      );

      final primes = result.tasks.singleWhere(
        (task) => task.name == 'calculatePrimes',
      );
      expect(primes.functionName, 'calculatePrimes');
      expect(primes.inputType, 'int');
      expect(primes.outputType, 'int');
      expect(primes.returnsFuture, isFalse);
      expect(primes.importUri, 'package:sample_app/tasks.dart');

      final greet = result.tasks.singleWhere((task) => task.name == 'greet');
      expect(greet.functionName, 'greet');
      expect(greet.outputType, 'String');

      final delayed = result.tasks.singleWhere(
        (task) => task.name == 'delayed',
      );
      expect(delayed.returnsFuture, isTrue);
      expect(delayed.outputType, 'int');

      final noInput = result.tasks.singleWhere(
        (task) => task.name == 'noInput',
      );
      expect(noInput.inputType, isNull);
      expect(noInput.returnsVoid, isTrue);

      expect(
        result.dependencyFiles.any((path) => path.endsWith('lib/tasks.dart')),
        isTrue,
      );
    },
  );

  test('reports a non-transferable Function input', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
void bad(Function callback) {}
''');

    final result = await discoverTasks(project.config());

    expect(result.hasErrors, isTrue);
    final diagnostic = result.diagnostics.singleWhere(
      (item) => item.code == 'DWI001',
    );
    expect(diagnostic.severity, DwiDiagnosticSeverity.error);
    expect(diagnostic.message, contains('function values'));
  });

  test('reports method annotations and unsupported signatures', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

class Holder {
  @DwiTask()
  int method(int value) => value;
}

@DwiTask()
int many(int a, int b) => a + b;

@DwiTask()
int named({int? value}) => value ?? 0;

@DwiTask()
int optional([int value = 0]) => value;

@DwiTask()
int _private(int value) => value;

@DwiTask()
T generic<T>(T value) => value;

@DwiTask()
int main() => 1;
''');

    final result = await discoverTasks(project.config());

    expect(result.hasErrors, isTrue);
    final signatureErrors = result.diagnostics
        .where((item) => item.code == 'DWI003')
        .toList(growable: false);
    expect(signatureErrors.length, greaterThanOrEqualTo(6));
    expect(
      signatureErrors.map((item) => item.message).join('\n'),
      allOf(
        contains('not a method'),
        contains('2 parameters'),
        contains('named parameter'),
        contains('optional parameter'),
        contains('private'),
        contains('generic'),
        contains('main'),
      ),
    );
  });

  test('reports duplicate task names and proxy method collisions', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask(name: 'same')
int first(int value) => value;

@DwiTask(name: 'same')
int second(int value) => value;

@DwiTask(name: 'renamed')
int third(int value) => value;
''');
    project.write('lib/more.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask(name: 'thirdTask')
int third(int value) => value;
''');

    final result = await discoverTasks(project.config());

    expect(result.hasErrors, isTrue);
    final duplicates = result.diagnostics
        .where((item) => item.code == 'DWI004')
        .toList(growable: false);
    expect(duplicates.length, greaterThanOrEqualTo(2));
    expect(
      duplicates.map((item) => item.message).join('\n'),
      anyOf(contains('Duplicate task name'), contains('function name')),
    );
  });

  test('reports libraries that cannot run in a worker', () async {
    project.write('lib/tasks.dart', r'''
import 'dart:io';

import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
String readIt(int value) => File('x').path;
''');

    final result = await discoverTasks(project.config());

    expect(result.hasErrors, isTrue);
    expect(result.diagnostics.any((item) => item.code == 'DWI002'), isTrue);
  });

  test(
    'reports analyzer errors instead of generating from broken code',
    () async {
      project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int good(int value) => value;

int broken( {
''');

      final result = await discoverTasks(project.config());

      expect(result.hasErrors, isTrue);
      expect(result.diagnostics.any((item) => item.code == 'DWI005'), isTrue);
    },
  );

  test('accepts typed collections and rejects non-transferable types', () async {
    project.write('lib/tasks.dart', r'''
import 'dart:typed_data';

import 'package:dwi_annotations/dwi_annotations.dart';

class Point {
  Point(this.x);
  final int x;
}

enum Color { red, green }

@DwiTask()
List<dynamic> okList(List<dynamic> input) => input;

@DwiTask()
Map<Object?, Object?> okMap(Map<Object?, Object?> input) => input;

@DwiTask()
List<int> typedList(List<int> input) => input;

@DwiTask()
Map<String, int> typedMap(Map<String, int> input) => input;

@DwiTask()
Set<int> typedSet(Set<int> input) => input;

@DwiTask()
Uint8List echoBytes(Uint8List input) => input;

@DwiTask()
Point point(Point input) => input;

@DwiTask()
Color color(Color input) => input;

@DwiTask()
DateTime when(DateTime input) => input;
''');

    final result = await discoverTasks(project.config());

    expect(result.hasErrors, isTrue);
    final typeErrors = result.diagnostics
        .where((item) => item.code == 'DWI001')
        .toList(growable: false);
    expect(
      typeErrors.map((item) => item.message).join('\n'),
      allOf(
        contains('Point'),
        contains('Color'),
        contains('DateTime'),
      ),
    );
    expect(
      result.tasks.map((task) => task.name),
      containsAll(<String>[
        'okList',
        'okMap',
        'typedList',
        'typedMap',
        'typedSet',
        'echoBytes',
      ]),
    );

    final typedList = result.tasks.singleWhere(
      (task) => task.name == 'typedList',
    );
    expect(typedList.inputType, 'List<int>');
    expect(typedList.outputType, 'List<int>');
    final bytes = result.tasks.singleWhere(
      (task) => task.name == 'echoBytes',
    );
    expect(bytes.inputType, 'Uint8List');
    expect(bytes.input!.libraryUri, 'dart:typed_data');
  });

  test('rejects map keys that are not strings', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
Map<int, String> badKeys(Map<int, String> input) => input;
''');

    final result = await discoverTasks(project.config());

    expect(result.hasErrors, isTrue);
    expect(
      result.diagnostics
          .where((item) => item.code == 'DWI001')
          .map((item) => item.message)
          .join('\n'),
      contains('map keys must be String'),
    );
  });

  test('ignores an unrelated annotation named DwiTask', () async {
    project.write('lib/tasks.dart', r'''
class DwiTask {
  const DwiTask();
}

@DwiTask()
int notATask(int value) => value;
''');

    final result = await discoverTasks(project.config());

    expect(result.tasks, isEmpty);
    expect(result.hasErrors, isFalse);
  });

  test('warns when no task is found', () async {
    project.write('lib/plain.dart', 'int notATask() => 1;\n');

    final result = await discoverTasks(project.config());

    expect(result.tasks, isEmpty);
    expect(result.hasErrors, isFalse);
    expect(result.diagnostics.any((item) => item.code == 'DWI005'), isTrue);
  });
}
