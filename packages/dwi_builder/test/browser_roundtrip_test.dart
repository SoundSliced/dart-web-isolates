import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

const String browserTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

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
''';

const String browserMain = r'''
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';

@JS('document')
external JSObject get _document;

void _finish(Map<String, Object?> result) {
  _document.setProperty(
    'title'.toJS,
    base64Encode(utf8.encode(jsonEncode(result))).toJS,
  );
}

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    await Dwi.configure(
      const DwiConfig(workerScript: 'dwi/worker.dart.js'),
    );
    result['ints'] = await DwiTasks.echoInts(<int>[1, 2, 3]);
    result['strings'] = await DwiTasks.echoNullableStrings(<String?>[
      'a',
      null,
    ]);
    result['nested'] = await DwiTasks.echoNested(<List<int>>[
      <int>[1],
      <int>[2, 3],
    ]);
    result['map'] = await DwiTasks.echoMap(<String, int>{'a': 1, 'b': 2});
    result['nestedMap'] = await DwiTasks.echoNestedMap(<String, List<int>>{
      'a': <int>[1, 2],
    });
    result['nullableNull'] = await DwiTasks.echoNullable(null);
    result['nullableValue'] = await DwiTasks.echoNullable(<int>[7]);

    try {
      await Dwi.run<Object?>('echoInts', <Object?>[1, 'oops']);
      result['invalidInput'] = 'NO_ERROR';
    } on DwiSerializationException catch (error) {
      result['invalidInput'] =
          'DwiSerializationException:${error.message.contains('expected int')}:'
          '${error.message.contains('input[1]')}';
    }
    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  }
  _finish(result);
}
''';

const String browserIndex = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body><script defer src="main.dart.js"></script></body>
</html>
''';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'typed collections round-trip through a real worker in Chrome',
    () async {
      project.write('lib/tasks.dart', browserTasks);
      project.write('web/main.dart', browserMain);
      project.write('web/index.html', browserIndex);

      await DwiBuilder(project.config(compile: true)).build();

      final compiled = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'compile',
          'js',
          '-O1',
          '-o',
          'web/main.dart.js',
          'web/main.dart',
        ],
        workingDirectory: project.root.path,
        environment: <String, String>{
          'PUB_CACHE': Platform.environment['PUB_CACHE'] ?? '',
        },
      );
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}\n${compiled.stderr}',
      );

      final webRoot = p.join(project.root.path, 'web');
      final server = await serveDirectory(webRoot);
      try {
        final decoded = await probeChrome(
          'http://127.0.0.1:${server.port}/index.html',
        );

        expect(
          decoded['ok'],
          isTrue,
          reason: '${decoded['error']}\n${decoded['stack']}',
        );
        expect(decoded['ints'], <int>[1, 2, 3]);
        expect(decoded['strings'], <String?>['a', null]);
        expect(decoded['nested'], <List<int>>[
          <int>[1],
          <int>[2, 3],
        ]);
        expect(decoded['map'], <String, int>{'a': 1, 'b': 2});
        expect(decoded['nestedMap'], <String, dynamic>{
          'a': <int>[1, 2],
        });
        expect(decoded['nullableNull'], isNull);
        expect(decoded['nullableValue'], <int>[7]);
        expect(decoded['invalidInput'], 'DwiSerializationException:true:true');
      } finally {
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: chromeExecutable() == null ? 'Google Chrome is not installed.' : false,
  );
}
