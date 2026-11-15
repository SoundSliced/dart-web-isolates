import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

/// Tasks whose parameters travel as one record (ADR-029).
const String _tasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
String joinParts(int count, String label) => '$label$count';

@DwiTask()
Future<List<int>> spread(int start, int count) async =>
    List<int>.generate(count, (index) => start + index);

@DwiTask()
Stream<int> countBetween(int from, int to) async* {
  for (var value = from; value <= to; value++) {
    yield value;
  }
}
''';

String _mainSource({required bool useWasm}) =>
    '''
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';

@JS('document')
external JSObject get _document;

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    await Dwi.configure(DwiConfig(
      workerScript: ${useWasm ? 'DwiConfig.defaultWasmWorkerScript' : 'DwiConfig.defaultWorkerScript'},
      workerBackend: ${useWasm ? 'DwiWorkerBackend.wasm' : 'DwiWorkerBackend.js'},
      startupTimeout: const Duration(seconds: 20),
    ));
    result['joined'] = await DwiTasks.joinParts(3, 'x');
    result['spread'] = await DwiTasks.spread(1, 3);
    result['streamed'] = await DwiTasks.countBetween(1, 3).toList();
    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = '\$error';
    result['stack'] = '\$stack';
  } finally {
    await Dwi.close();
  }
  _document.setProperty(
    'title'.toJS,
    base64Encode(utf8.encode(jsonEncode(result))).toJS,
  );
}
''';

String _index(String host) =>
    '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body>${host == 'js' ? '<script defer src="main.dart.js"></script>' : '''<script type="module">
import { compileStreaming } from './main.mjs';
const app = await (await compileStreaming(fetch('./main.wasm'))).instantiate({});
app.invokeMain();
</script>'''}</body>
</html>
''';

void main() {
  for (final backend in <String>['js', 'wasm']) {
    for (final host in <String>['js', 'wasm']) {
      test(
        '$host host calls multi-parameter tasks on a $backend worker',
        () async {
          final project = FixtureProject.create();
          addTearDown(project.dispose);
          project.write('lib/tasks.dart', _tasks);
          project.write(
            'web/main.dart',
            _mainSource(useWasm: backend == 'wasm'),
          );
          project.write('web/index.html', _index(host));

          await DwiBuilder(
            project.config(compile: true).copyWith(target: backend),
          ).build();

          final compiled = await Process.run(
            Platform.resolvedExecutable,
            <String>[
              'compile',
              host,
              if (host == 'js') '-O1',
              '-o',
              host == 'js' ? 'web/main.dart.js' : 'web/main.wasm',
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
            for (final engine in BrowserEngine.values) {
              final availability = browserAvailability(engine);
              if (!availability.available) {
                throw StateError(
                  '${engine.name} blocked: ${availability.reason}',
                );
              }
              final observed = await probeBrowser(
                engine,
                'http://127.0.0.1:${server.port}/index.html',
              );
              final decoded = observed.data;
              expect(
                decoded['ok'],
                isTrue,
                reason: '${decoded['error']}\n${decoded['stack']}',
              );
              expect(decoded['joined'], 'x3');
              expect(decoded['spread'], <int>[1, 2, 3]);
              expect(decoded['streamed'], <int>[1, 2, 3]);
            }
          } finally {
            await server.close(force: true);
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
    }
  }
}
