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

  test(
    'discovers qualified static methods without colliding with top-level tasks',
    () async {
      project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
@DwiTask()
int twice(int value) => value * 2;
class MathOps {
  @DwiTask()
  static Future<List<int>> twice(int value) async => <int>[value * 2];
}
class Other {
  @DwiTask(name: 'custom')
  static int twice(int value) => value;
}
''');
      final result = await discoverTasks(project.config());
      expect(result.diagnostics, isEmpty);
      final method = result.tasks.singleWhere(
        (task) => task.name == 'MathOps.twice',
      );
      expect(method.declaringType, 'MathOps');
      expect(method.qualifiedName, 'MathOps.twice');
      expect(method.proxyName, r'MathOps$twice');
      expect(method.inputType, 'int');
      expect(method.outputType, 'List<int>');
      expect(method.returnsFuture, isTrue);
      expect(
        result.tasks.map((task) => task.name),
        containsAll(<String>['twice', 'custom']),
      );
    },
  );

  test(
    'rejects inaccessible and generic static declarations and proxy collisions',
    () async {
      project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
class _Private {
  @DwiTask()
  static int task(int value) => value;
}
class Generic<T> {
  @DwiTask()
  static int task(int value) => value;
}
class Public {
  @DwiTask()
  static T generic<T>(T value) => value;
  @DwiTask()
  static int get getter => 1;
  @DwiTask()
  static int optional([int value = 0]) => value;
  @DwiTask()
  static int _private(int value) => value;
  @DwiTask()
  static int named({required int value}) => value;
  @DwiTask()
  static int many(int a, int b) => a + b;
  @DwiTask()
  static int task(int value) => value;
}
@DwiTask()
int Public$task(int value) => value;
''');
      final result = await discoverTasks(project.config());
      final messages = result.diagnostics
          .map((item) => item.message)
          .join('\n');
      expect(
        messages,
        allOf(<Matcher>[
          contains('private class'),
          contains('generic class'),
          contains('generic'),
          contains('getter'),
          contains('optional'),
          contains('private'),
          contains('named parameter'),
          contains('2 parameters'),
          contains('collide'),
        ]),
      );
      expect(result.diagnostics.any((item) => item.code == 'DWI004'), isTrue);
      expect(result.diagnostics.every((item) => item.line > 0), isTrue);
    },
  );

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

  test(
    'rejects every annotated declaration that is not a supported task',
    () async {
      project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
enum Level {
  @DwiTask()
  low;
  @DwiTask()
  static int enumStatic(int value) => value;
  @DwiTask()
  int enumInstance(int value) => value;
}
extension IntTasks on int {
  @DwiTask()
  static int extensionStatic(int value) => value;
  @DwiTask()
  int extensionInstance(int value) => value;
}
extension type Wrapped(int raw) {
  @DwiTask()
  static int extensionTypeStatic(int value) => value;
}
@DwiTask()
class Annotated {
  @DwiTask()
  Annotated();
  @DwiTask()
  static int field = 0;
  static int withLocal(int value) {
    @DwiTask()
    int local(int inner) => inner;
    return local(value);
  }
  static int withParameter(@DwiTask() int value) => value;
}
@DwiTask()
mixin AnnotatedMixin {}
@DwiTask()
typedef Alias = int Function(int);
class Public {
  @DwiTask()
  static int ok(int value) => value;
}
''');
      final result = await discoverTasks(project.config());
      // The enum static method is the only other supported declaration here.
      expect(result.tasks.map((task) => task.name), <String>[
        'Level.enumStatic',
        'Public.ok',
      ]);
      expect(result.hasErrors, isTrue);
      final rejected = result.diagnostics
          .where((item) => item.code == 'DWI003')
          .toList(growable: false);
      // One diagnostic per unsupported annotation; none is silently ignored.
      expect(rejected, hasLength(12));
      expect(
        rejected.every((item) => item.severity == DwiDiagnosticSeverity.error),
        isTrue,
      );
      expect(rejected.map((item) => item.line).toSet(), hasLength(12));
      expect(
        rejected.map((item) => item.message).join('\n'),
        allOf(<Matcher>[
          contains('an enum constant'),
          contains('not a method with a receiver'),
          contains('a member of an extension;'),
          contains('a member of an extension type'),
          contains('a class;'),
          contains('a constructor'),
          contains('a field'),
          contains('a local function'),
          contains('a parameter'),
          contains('a mixin'),
          contains('a typedef'),
        ]),
      );
    },
  );

  test('an unsupported annotation alone still fails generation', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
extension IntTasks on int {

  @DwiTask()
  static int twice(int value) => value * 2;
}
''');
    final result = await discoverTasks(project.config());
    expect(result.tasks, isEmpty);
    expect(result.hasErrors, isTrue);
    final diagnostic = result.diagnostics.single;
    expect(diagnostic.code, 'DWI003');
    expect(diagnostic.line, 4);
    expect(diagnostic.message, contains('a member of an extension'));
  });

  test('discovers static methods of public non-generic enums', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
enum Scale {
  unit;
  @DwiTask()
  static Future<int> triple(int value) async => value * 3;
  @DwiTask(name: 'scale.zero')
  static int zero() => 0;
  @DwiTask()
  int instance(int value) => value;
}
enum _Hidden {
  unit;
  @DwiTask()
  static int task(int value) => value;
}
enum Boxed<T> {
  unit<int>();
  @DwiTask()
  static int task(int value) => value;
}
''');
    final result = await discoverTasks(project.config());
    expect(result.tasks.map((task) => task.name), <String>[
      'Scale.triple',
      'scale.zero',
    ]);
    final triple = result.tasks.first;
    expect(triple.declaringType, 'Scale');
    expect(triple.qualifiedName, 'Scale.triple');
    expect(triple.proxyName, r'Scale$triple');
    expect(triple.inputType, 'int');
    expect(triple.outputType, 'int');
    expect(triple.returnsFuture, isTrue);
    expect(result.tasks.last.proxyName, r'Scale$zero');
    final rejected = result.diagnostics
        .where((item) => item.code == 'DWI003')
        .map((item) => item.message)
        .toList(growable: false);
    expect(rejected, hasLength(3));
    expect(
      rejected.join('\n'),
      allOf(
        contains('not a method with a receiver'),
        contains('private enum'),
        contains('generic enum'),
      ),
    );
  });

  test('rejects external top-level and static declarations', () async {
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
@DwiTask()
external int externalTopLevel(int value);
class Public {
  @DwiTask()
  external static int externalStatic(int value);
  @DwiTask()
  static int ok(int value) => value;
}
''');
    final result = await discoverTasks(project.config());
    expect(result.tasks.map((task) => task.name), <String>['Public.ok']);
    final rejected = result.diagnostics
        .where((item) => item.code == 'DWI003')
        .toList(growable: false);
    expect(rejected, hasLength(2));
    expect(
      rejected.map((item) => item.message).join('\n'),
      allOf(
        contains('`externalTopLevel` is external'),
        contains('`externalStatic` is external'),
      ),
    );
    expect(rejected.map((item) => item.line), <int>[3, 6]);
  });

  test(
    'static methods retain payload and dependency-closure validation',
    () async {
      project.write('lib/tasks.dart', r'''
import 'dart:io';
import 'package:dwi_annotations/dwi_annotations.dart';
class Ops {
  @DwiTask()
  static String read(int input) => File('x').path;
  @DwiTask()
  static void callback(Function input) {}
}
''');
      final result = await discoverTasks(project.config());
      expect(result.diagnostics.any((item) => item.code == 'DWI001'), isTrue);
      expect(result.diagnostics.any((item) => item.code == 'DWI002'), isTrue);
    },
  );

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

  test(
    'accepts typed collections and rejects non-transferable types',
    () async {
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
          contains('`Point` is not a type DWI can send'),
          isNot(contains('Color')),
          isNot(contains('DateTime')),
        ),
      );
      expect(
        typeErrors.map((item) => item.hint).join('\n'),
        contains('@DwiPayload()'),
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
          'color',
          'when',
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
    },
  );

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
  test(
    'describes enums, core value types, records and payload classes',
    () async {
      project.write('lib/model.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
enum Color { red, green }
@DwiPayload()
class Node {
  Node(this.value, this.children, {this.color});
  final int value;
  final List<Node> children;
  final Color? color;
}
''');
      project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
import 'model.dart';
@DwiTask()
Color color(Color input) => input;
@DwiTask()
(int, {Duration wait, BigInt? big}) record((Uri, DateTime) input) =>
    (1, wait: Duration.zero, big: null);
@DwiTask()
Node? node(List<Node> input) => null;
''');
      final result = await discoverTasks(project.config());
      expect(result.diagnostics, isEmpty);
      final byName = <String, DwiTaskDescriptor>{
        for (final task in result.tasks) task.name: task,
      };

      final color = byName['color']!.input!;
      expect(color.kind, DwiTypeKind.enumeration);
      expect(color.canonical, 'Color');
      expect(color.codecKey, 'package:sample_app/model.dart#Color');
      expect(color.needsEncoding, isTrue);

      final record = byName['record']!;
      expect(record.inputType, '(Uri, DateTime)');
      // Named fields are sorted, so the wire order does not depend on source.
      expect(record.outputType, '(int, {BigInt? big, Duration wait})');
      expect(record.output.kind, DwiTypeKind.record);
      expect(record.output.named.keys, <String>['big', 'wait']);

      final node = byName['node']!;
      expect(node.outputType, 'Node?');
      expect(node.input!.needsEncoding, isTrue);
      final shape = node.output.shape!;
      expect(shape.fields.map((field) => field.name), <String>[
        'value',
        'children',
        'color',
      ]);
      expect(shape.fields.last.isNamed, isTrue);
      // A recursive class resolves to one shared shape.
      expect(shape.fields[1].type.arguments.single.shape, same(shape));
    },
  );

  test('rejects payload types the generated code cannot rebuild', () async {
    project.write('lib/model.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
enum _Hidden { a }
typedef Hidden = _Hidden;
@DwiPayload()
class Generic<T> { Generic(this.value); final T value; }
@DwiPayload()
abstract class Abstract { Abstract(this.value); final int value; }
@DwiPayload()
class NoConstructor { NoConstructor.named(this.value); final int value; }
@DwiPayload()
class NoGetter { NoGetter(int value) : _value = value; final int _value; }
@DwiPayload()
class WrongType { WrongType(int value) : value = '$value'; final String value; }
@DwiPayload()
class BadField { BadField(this.callback); final void Function() callback; }
@DwiPayload()
class _Private { _Private(this.value); final int value; }
typedef Private = _Private;
class Plain { Plain(this.value); final int value; }
''');
    project.write('lib/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
import 'model.dart';
@DwiTask()
int hidden(Hidden input) => 0;
@DwiTask()
int generic(Generic<int> input) => 0;
@DwiTask()
int abstract(Abstract input) => 0;
@DwiTask()
int noConstructor(NoConstructor input) => 0;
@DwiTask()
int noGetter(NoGetter input) => 0;
@DwiTask()
int wrongType(WrongType input) => 0;
@DwiTask()
int badField(BadField input) => 0;
@DwiTask()
int private(Private input) => 0;
@DwiTask()
int plain((int, Plain) input) => 0;
@DwiTask()
int anyRecord(Record input) => 0;
@DwiTask()
int anyEnum(Enum input) => 0;
@DwiTask()
int enumKey(Map<Hidden, int> input) => 0;
''');
    final result = await discoverTasks(project.config());
    expect(result.hasErrors, isTrue);
    String messageFor(String task) => result.diagnostics
        .where(
          (item) => item.code == 'DWI001' && item.message.contains('`$task`'),
        )
        .map((item) => item.message)
        .join('\n');
    expect(messageFor('hidden'), contains('enum `_Hidden` is private'));
    expect(messageFor('generic'), contains('concrete and non-generic'));
    expect(messageFor('abstract'), contains('concrete and non-generic'));
    expect(
      messageFor('noConstructor'),
      contains('no public unnamed constructor'),
    );
    expect(
      messageFor('noGetter'),
      contains('no public getter or field `value`'),
    );
    expect(
      messageFor('wrongType'),
      contains('`WrongType.value` is `String` but the constructor takes `int`'),
    );
    expect(messageFor('badField'), contains('function values'));
    expect(
      messageFor('private'),
      contains('payload class `_Private` is private'),
    );
    expect(messageFor('plain'), contains('`Plain` is not a type DWI can send'));
    expect(messageFor('anyRecord'), contains('`Record` does not say which'));
    expect(messageFor('anyEnum'), contains('`Enum` does not say which'));
    expect(messageFor('enumKey'), contains('map keys must be String'));
  });

  test('rejects payload types declared outside lib/', () async {
    project.write('bin/tasks.dart', r'''
import 'package:dwi_annotations/dwi_annotations.dart';
enum Local { a }
@DwiTask()
int local(Local input) => 0;
''');
    final result = await discoverTasks(
      project.config(includePaths: const <String>['bin']),
    );
    expect(
      result.diagnostics.map((item) => item.message).join('\n'),
      contains('enum `Local` is declared outside lib/'),
    );
  });
  test('accepts Stream<T> results and rejects other stream shapes', () async {
    project.write('lib/tasks.dart', r'''
import 'dart:async';
import 'package:dwi_annotations/dwi_annotations.dart';
enum Phase { a, b }
@DwiTask()
Stream<int> counts(int limit) async* {}
@DwiTask()
Stream<(Phase, String?)> phases() async* {}
@DwiTask()
Stream<void> noItems() async* {}
@DwiTask()
Stream<dynamic> untyped() async* {}
@DwiTask()
int takesStream(Stream<int> input) => 0;
@DwiTask()
Future<Stream<int>> nested() async => const Stream<int>.empty();
@DwiTask()
Stream<Function> functions() async* {}
''');
    final result = await discoverTasks(project.config());
    final byName = <String, DwiTaskDescriptor>{
      for (final task in result.tasks) task.name: task,
    };
    final counts = byName['counts']!;
    expect(counts.returnsStream, isTrue);
    expect(counts.returnsFuture, isFalse);
    expect(counts.outputType, 'int');
    expect(counts.proxyReturnType, 'Stream<int>');
    expect(byName['phases']!.outputType, '(Phase, String?)');
    expect(byName['phases']!.takesInput, isFalse);

    String messages(String task) => result.diagnostics
        .where(
          (item) => item.code == 'DWI001' && item.message.contains('`$task`'),
        )
        .map((item) => item.message)
        .join('\n');
    expect(messages('noItems'), contains('must declare its item type'));
    expect(messages('untyped'), contains('must declare its item type'));
    expect(messages('takesStream'), contains('a Stream cannot be sent'));
    expect(messages('nested'), contains('a Stream cannot be sent'));
    expect(messages('functions'), contains('function values'));
    expect(messages('counts'), isEmpty);
    expect(messages('phases'), isEmpty);
  });
}
