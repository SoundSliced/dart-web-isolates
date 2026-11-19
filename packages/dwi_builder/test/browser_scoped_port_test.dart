import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';
import 'support/port_fixture.dart';

/// ADR-033 browser cells: `Dwi.withPort` on the host and `DwiWorker.withPort`
/// bound to a dedicated worker, in every host/worker combination.
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
  try {
    await Dwi.configure(DwiConfig(
      workerScript: ${useWasm ? 'DwiConfig.defaultWasmWorkerScript' : 'DwiConfig.defaultWorkerScript'},
      workerBackend: ${useWasm ? 'DwiWorkerBackend.wasm' : 'DwiWorkerBackend.js'},
      startupTimeout: const Duration(seconds: 20),
      channelBufferSize: 4,
    ));

    result['status'] = await Dwi.withPort('status', (port) async {
      final received = port.messages.first;
      await port.send('ready');
      return await received;
    });

    final echoed = <Object?>[];
    final announced = <Object?>[];
    final outcome = await DwiWorker.using((worker) {
      return worker.withPort('chat', (port) async {
        result['startResult'] = await worker.run<String>(
          'startEcho',
          'port:\${port.name}',
        );
        final messages = StreamIterator<Object?>(port.messages);
        await port.send('ping');
        await messages.moveNext();
        echoed.add(messages.current);
        await port.send('pong');
        await messages.moveNext();
        echoed.add(messages.current);

        result['announceResult'] = await worker.run<String>('announce', 'hi');
        await messages.moveNext();
        announced.add(messages.current);
        await messages.cancel();
        return 'done';
      });
    });
    result['outcome'] = outcome;
    result['echoed'] = echoed;
    result['announced'] = announced.single;
    result['closed'] = Dwi.port('chat') == null;
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
      test('$host host scopes a port on a $backend worker', () async {
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
              throw StateError('${engine.name} blocked: ${availability.reason}');
            }
            final observed = await probeBrowser(
              engine,
              'http://127.0.0.1:${server.port}/index.html',
            );
            final decoded = observed.data;
            print(
              'dwi-scoped-port: ${jsonEncode(<String, Object?>{'host': host, 'worker': backend, 'engine': engine.name, 'browserVersion': observed.browserVersion, 'result': decoded})}',
            );
            expect(
              decoded['ok'],
              isTrue,
              reason: '${decoded['error']}\n${decoded['stack']}',
            );
            expect(decoded['status'], 'ready');
            expect(decoded['echoed'], <Object?>['echo:ping', 'echo:pong']);
            expect(decoded['announced'], 'announced:hi');
            expect(decoded['startResult'], 'listening');
            expect(decoded['announceResult'], 'sent');
            expect(decoded['outcome'], 'done');
            expect(decoded['closed'], isTrue);
          }
        } finally {
          await server.close(force: true);
        }
      }, timeout: const Timeout(Duration(minutes: 8)));
    }
  }
}
