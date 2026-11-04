import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture.dart';

const String generatedTasks = r'''
import 'dart:typed_data';

import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int twice(int value) => value * 2;

@DwiTask()
int noInput() => 42;

@DwiTask()
Future<int> delayed(int value) async => value + 1;

@DwiTask()
void fireAndForget(int value) {}

@DwiTask()
Future<void> fireLater(int value) async {}

@DwiTask()
Uint8List echoBytes(Uint8List input) => input;

@DwiTask()
List<int> echoInts(List<int> input) => input;

@DwiTask()
List<String?> echoNullableStrings(List<String?> input) => input;

@DwiTask()
List<List<int>> echoNested(List<List<int>> input) => input;

@DwiTask()
Map<String, int> echoMap(Map<String, int> input) => input;

@DwiTask()
Map<String, List<int>> echoNestedMap(Map<String, List<int>> input) => input;

@DwiTask()
List<int>? echoNullable(List<int>? input) => input;

@DwiTask()
int explode(int value) => throw StateError('boom');
''';

const String nativeCheck = r'''
import 'dart:convert';
import 'dart:typed_data';

import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';

Future<void> main() async {
  // Several concurrent first calls must register exactly once and all settle.
  final first = await Future.wait<int>(<Future<int>>[
    DwiTasks.twice(1),
    DwiTasks.twice(2),
    DwiTasks.twice(3),
  ]);

  final bytes = await DwiTasks.echoBytes(Uint8List.fromList(<int>[1, 2, 3]));
  final ints = await DwiTasks.echoInts(<int>[4, 5, 6]);
  final nested = await DwiTasks.echoNested(<List<int>>[
    <int>[1],
    <int>[2, 3],
  ]);
  final map = await DwiTasks.echoMap(<String, int>{'a': 1, 'b': 2});
  final nestedMap = await DwiTasks.echoNestedMap(<String, List<int>>{
    'a': <int>[1, 2],
  });
  final nullable = await DwiTasks.echoNullable(null);
  await DwiTasks.fireAndForget(1);
  await DwiTasks.fireLater(1);

  String remote = 'none';
  try {
    await DwiTasks.explode(1);
  } on DwiRemoteException catch (error) {
    remote = '${error.remoteType}:${error.message.contains('boom')}:'
        '${error.remoteStack.isNotEmpty}';
  }

  await Dwi.close();
  final reused = await DwiTasks.twice(4);

  print(jsonEncode(<String, Object?>{
    'first': first,
    'bytes': bytes.toList(),
    'ints': ints,
    'nested': nested,
    'map': map,
    'nestedMap': nestedMap,
    'nullable': nullable,
    'remote': remote,
    'reused': reused,
  }));
}
''';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'generated proxies run on native isolates with typed collections',
    () async {
      project.write('lib/tasks.dart', generatedTasks);
      project.write('bin/native_check.dart', nativeCheck);

      final built = await DwiBuilder(
        project.config(compile: true),
      ).build();
      expect(built.compiled, isTrue);

      final workerSource = project.read('.dwi/generated_worker.dart');
      expect(workerSource, contains("import 'dart:typed_data' as dwi_t0;"));
      expect(
        workerSource,
        contains('dwi_t0.Uint8List _dwiDecode'),
      );

      final proxies = project.read('lib/dwi_tasks.g.dart');
      expect(proxies, contains("Dwi.registerTask('echoBytes'"));
      expect(proxies, contains('static Future<dwi_t0.Uint8List> echoBytes('));

      final result = await Process.run(
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
      expect(
        result.exitCode,
        0,
        reason: '${result.stdout}\n${result.stderr}',
      );

      final lines = (result.stdout as String)
          .trim()
          .split('\n')
          .where((line) => line.startsWith('{'))
          .toList(growable: false);
      expect(lines, isNotEmpty, reason: result.stdout as String);
      final decoded = jsonDecode(lines.last) as Map<String, dynamic>;

      expect(decoded['first'], <int>[2, 4, 6]);
      expect(decoded['bytes'], <int>[1, 2, 3]);
      expect(decoded['ints'], <int>[4, 5, 6]);
      expect(decoded['nested'], <List<int>>[
        <int>[1],
        <int>[2, 3],
      ]);
      expect(decoded['map'], <String, int>{'a': 1, 'b': 2});
      expect(decoded['nestedMap'], <String, dynamic>{
        'a': <int>[1, 2],
      });
      expect(decoded['nullable'], isNull);
      expect(decoded['remote'], 'StateError:true:true');
      expect(decoded['reused'], 8);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'generated worker and proxies compile for the web target',
    () async {
      project.write('lib/tasks.dart', generatedTasks);
      project.write(
        'web/main.dart',
        "import 'package:sample_app/dwi_tasks.g.dart';\n"
            'void main() {}\n',
      );

      await DwiBuilder(project.config()).build();

      final output = p.join(project.root.path, 'web', 'main.dart.js');
      final result = await Process.run(
        Platform.resolvedExecutable,
        <String>['compile', 'js', '-O1', '-o', output, 'web/main.dart'],
        workingDirectory: project.root.path,
        environment: <String, String>{
          'PUB_CACHE': Platform.environment['PUB_CACHE'] ?? '',
        },
      );
      expect(
        result.exitCode,
        0,
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(File(output).existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
