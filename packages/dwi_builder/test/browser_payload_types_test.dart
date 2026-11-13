import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';
import 'support/payload_fixture.dart';

/// Sources stamped into the ADR-021 evidence, relative to this package.
const List<String> _sources = <String>[
  '../dwi_annotations/lib/dwi_annotations.dart',
  'lib/src/descriptor.dart',
  'lib/src/discovery.dart',
  'lib/src/generator.dart',
  'test/browser_payload_types_test.dart',
  'test/native_payload_types_test.dart',
  'test/support/browser_engines.dart',
  'test/support/browser_probe.dart',
  'test/support/fixture.dart',
  'test/support/payload_fixture.dart',
];

/// A web-only task proving that a converted value was rebuilt in the worker.
const String _realmTask = r'''
import 'dart:js_interop';
import 'package:dwi_annotations/dwi_annotations.dart';
import 'model.dart';

@JS('globalThis.constructor.name')
external JSString get _scope;

@DwiTask()
(String, Color) where(Color color) => (_scope.toDart, color);
''';

String _mainSource({required bool useWasm}) =>
    '''
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';
import 'package:sample_app/model.dart';
import 'package:sample_app/tasks.dart';

@JS('document')
external JSObject get _document;

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    await Dwi.configure(DwiConfig(
      workerScript: $useWasm
          ? DwiConfig.defaultWasmWorkerScript
          : DwiConfig.defaultWorkerScript,
      workerBackend: $useWasm ? DwiWorkerBackend.wasm : DwiWorkerBackend.js,
      startupTimeout: const Duration(seconds: 20),
    ));
$payloadCalls
    final where = await DwiTasks.where(Color.green);
    result['realm'] = <Object?>[where.\$1, where.\$2.name];
    final capabilities = await Dwi.capabilities();
    result['backend'] = capabilities.backend.name;
    result['workerBackend'] = capabilities.workerBackend;
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
  final evidence = <Map<String, Object?>>[];
  tearDownAll(() async {
    final path = Platform.environment['DWI_PAYLOAD_EVIDENCE'];
    if (path == null) return;
    final revision = await Process.run('git', <String>['rev-parse', 'HEAD']);
    if (revision.exitCode != 0) throw StateError('${revision.stderr}');
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'sdk': Platform.version,
        'revision': (revision.stdout as String).trim(),
        'sourceState': 'local ADR-021 implementation, uncommitted',
        'sourceDigests': <String, String>{for (final source in _sources) source: sha256.convert(File(source).readAsBytesSync()).toString()},
        'fixture': 'packages/dwi_builder/test/browser_payload_types_test.dart',
        'command': 'dart test test/browser_payload_types_test.dart -r expanded',
        'runs': evidence,
        'complete': evidence.length == 16 && evidence.every((run) => run['status'] == 'pass'),
      })}\n',
    );
  });

  // Each host and worker is compiled separately (AGENTS.md rule 7) and every
  // engine runs its own page load (rule 8). An engine that cannot start fails
  // the test, so a pass always means all sixteen cells ran.
  for (final backend in <String>['js', 'wasm']) {
    for (final host in <String>['js', 'wasm']) {
      test('$host host exchanges converted payloads with a $backend worker', () async {
        final project = FixtureProject.create();
        addTearDown(project.dispose);
        project.write('lib/model.dart', payloadModel);
        project.write('lib/tasks.dart', payloadTasks);
        project.write('lib/realm_task.dart', _realmTask);
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
            evidence.add(<String, Object?>{
              'host': host,
              'worker': backend,
              'engine': engine.name,
              'browserVersion': observed.browserVersion,
              'result': decoded,
            });
            // Evidence line: exact observed payload for the audit record.
            print(
              'dwi-payload-types: ${jsonEncode(<String, Object?>{'host': host, 'worker': backend, 'engine': engine.name, 'browserVersion': observed.browserVersion, 'result': decoded})}',
            );
            expect(
              decoded['ok'],
              isTrue,
              reason: '${decoded['error']}\n${decoded['stack']}',
            );
            expectPayloadResults(decoded);
            expect(decoded['realm'], <Object?>[
              'DedicatedWorkerGlobalScope',
              'green',
            ]);
            expect(decoded['backend'], 'worker');
            expect(
              decoded['workerBackend'],
              backend == 'wasm' ? 'dart2wasm' : 'dart2js',
            );
            evidence.last['status'] = 'pass';
          }
        } finally {
          await server.close(force: true);
        }
      }, timeout: const Timeout(Duration(minutes: 8)));
    }
  }
}
