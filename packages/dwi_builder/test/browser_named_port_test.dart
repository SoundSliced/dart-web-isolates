import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';
import 'support/port_fixture.dart';

String _mainSource({required bool useWasm}) =>
    '''
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi/dwi.dart';

@JS('document')
external JSObject get _document;

Future<void> main() async {
  final result = <String, Object?>{};
  DwiWorker? worker;
  DwiPort? port;
  try {
    await Dwi.configure(DwiConfig(
      workerScript: ${useWasm ? 'DwiConfig.defaultWasmWorkerScript' : 'DwiConfig.defaultWorkerScript'},
      workerBackend: ${useWasm ? 'DwiWorkerBackend.wasm' : 'DwiWorkerBackend.js'},
      startupTimeout: const Duration(seconds: 20),
      channelBufferSize: 4,
    ));
    worker = await DwiWorker.spawn();
    port = Dwi.createPort('chat', scope: DwiPortScope.workers);
    final binding = await worker.bindPort(port);
    final messages = StreamIterator<Object?>(port.messages);

    result['startResult'] = await worker.run<String>('startEcho', 'port:chat');
    final echoed = <Object?>[];
    await port.send('ping');
    await messages.moveNext();
    echoed.add(messages.current);
    await port.send('pong');
    await messages.moveNext();
    echoed.add(messages.current);
    result['echoed'] = echoed;

    result['announceResult'] = await worker.run<String>('announce', 'hi');
    await messages.moveNext();
    result['announced'] = messages.current;

    await binding.close();
    await messages.cancel();
    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = '\$error';
    result['stack'] = '\$stack';
  } finally {
    await worker?.close();
    await port?.close();
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
  // Each host and worker is compiled separately (AGENTS.md rule 7), and every
  // engine loads its own page (rule 8). An engine that cannot start fails the
  // test, so a pass means all sixteen cells ran.
  for (final backend in <String>['js', 'wasm']) {
    for (final host in <String>['js', 'wasm']) {
      test('$host host binds a port to a $backend worker', () async {
        final project = FixtureProject.create();
        addTearDown(project.dispose);
        project.write('lib/port_tasks.dart', portTasks);
        project.write('web/main.dart', _mainSource(useWasm: backend == 'wasm'));
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
            // Evidence line for the audit record.
            print(
              'dwi-named-port: ${jsonEncode(<String, Object?>{'host': host, 'worker': backend, 'engine': engine.name, 'browserVersion': observed.browserVersion, 'result': decoded})}',
            );
            expectPortResults(decoded);
          }
        } finally {
          await server.close(force: true);
        }
      }, timeout: const Timeout(Duration(minutes: 8)));
    }
  }
}
