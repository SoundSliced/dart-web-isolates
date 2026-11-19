import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

const String artifactTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
List<int> echoInts(List<int> input) => input;

@DwiTask()
int twice(int value) => value * 2;
''';

// No Dwi.configure call: the generated proxies apply the served artifact
// themselves (ADR-037). The page reports the results and the outcome.
const String artifactMain = r'''
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:sample_app/dwi_tasks.g.dart';

@JS('document')
external JSObject get _document;

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    result['twice'] = await DwiTasks.twice(21);
    result['ints'] = await DwiTasks.echoInts(<int>[1, 2, 3]);
    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  }
  _document.setProperty(
    'title'.toJS,
    base64Encode(utf8.encode(jsonEncode(result))).toJS,
  );
}
''';

const String artifactIndex = '''
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
    'a page without explicit configuration runs on a custom-path JS artifact',
    () async {
      project.write('lib/tasks.dart', artifactTasks);
      project.write('web/main.dart', artifactMain);
      project.write('web/index.html', artifactIndex);

      // A custom served path: the default DwiConfig would load the wrong URL,
      // so success proves the generated artifact supplied the path (ADR-037).
      await DwiBuilder(
        DwiBuildConfig(
          projectRoot: project.root.path,
          compile: true,
          artifactPath: 'web/app/worker.dart.js',
        ),
      ).build();

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

      final server = await serveDirectory(p.join(project.root.path, 'web'));
      try {
        final decoded = await probeChrome(
          'http://127.0.0.1:${server.port}/index.html',
        );
        expect(
          decoded['ok'],
          isTrue,
          reason: '${decoded['error']}\n${decoded['stack']}',
        );
        expect(decoded['twice'], 42);
        expect(decoded['ints'], <int>[1, 2, 3]);
      } finally {
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: chromeExecutable() == null
        ? 'Google Chrome is not installed.'
        : false,
  );
}
