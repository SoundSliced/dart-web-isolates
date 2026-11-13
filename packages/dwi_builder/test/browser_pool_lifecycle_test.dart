import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

/// Sources stamped into the ADR-024 evidence, relative to this package.
const List<String> _sources = <String>[
  '../dwi/lib/dwi.dart',
  '../dwi_core/lib/src/config.dart',
  '../dwi_web/lib/src/web_backend.dart',
  'test/browser_pool_lifecycle_test.dart',
  'test/support/browser_engines.dart',
  'test/support/browser_probe.dart',
  'test/support/fixture.dart',
];

/// `lib/pool_tasks.dart`.
const String _tasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
Future<int> slow(int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  return milliseconds;
}

@DwiTask()
String echo(String value) => value;
''';

/// Idle retirement and draining close (ADR-024), with `idleTimeout: 300 ms`.
const String _calls = r'''
    int workers() => _workerStats().toDart[0].toDartInt;
    int terminated() => _workerStats().toDart[1].toDartInt;

    // Idle retirement: one worker, retired after 300 ms without work.
    result['echo'] = await DwiTasks.echo('a');
    result['countBusy'] = (await Dwi.capabilities()).workerCount;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    result['countIdle'] = (await Dwi.capabilities()).workerCount;
    result['retired'] = terminated();
    // The next call starts a replacement worker and succeeds.
    result['afterRetire'] = await DwiTasks.echo('b');
    result['countAgain'] = (await Dwi.capabilities()).workerCount;
    // Steady work keeps a worker alive: 6 calls 100 ms apart, under 300 ms.
    final before = workers();
    for (var index = 0; index < 6; index++) {
      await DwiTasks.echo('$index');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    result['steadyNewWorkers'] = workers() - before;

    // Draining close: started calls finish, new calls are refused.
    final first = DwiTasks.slow(400);
    final second = DwiTasks.slow(250);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final closing = Dwi.close(drain: true);
    try {
      await DwiTasks.echo('late');
      result['refused'] = 'accepted';
    } on DwiUnsupportedException {
      result['refused'] = true;
    }
    result['drained'] = <int>[await first, await second];
    await closing;
    result['afterDrain'] = await DwiTasks.echo('c');

    // A plain close still settles a running call instead of waiting.
    final cut = Dwi.run<Object?>('slow', 2000);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await Dwi.close();
    try {
      await cut;
      result['cut'] = 'completed';
    } on DwiException catch (error) {
      result['cut'] = error.runtimeType.toString();
    }
    result['afterCut'] = await DwiTasks.echo('d');
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

@JS('__dwiWorkerStats')
external JSArray<JSNumber> _workerStats();

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    await Dwi.configure(DwiConfig(
      workerScript: $useWasm
          ? DwiConfig.defaultWasmWorkerScript
          : DwiConfig.defaultWorkerScript,
      workerBackend: $useWasm ? DwiWorkerBackend.wasm : DwiWorkerBackend.js,
      startupTimeout: const Duration(seconds: 20),
      idleTimeout: const Duration(milliseconds: 300),
    ));
$_calls
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
  final stats = _workerStats().toDart;
  result['workers'] = <int>[stats[0].toDartInt, stats[1].toDartInt];
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
<body><script>
// Counts Worker construction and termination so the test can assert that
// every stream, including a cancelled one, released its worker.
(() => {
  const NativeWorker = globalThis.Worker;
  let created = 0;
  let terminated = 0;
  globalThis.Worker = class extends NativeWorker {
    #terminated = false;
    constructor(...args) { super(...args); created++; }
    terminate() {
      if (!this.#terminated) { this.#terminated = true; terminated++; }
      return super.terminate();
    }
  };
  globalThis.__dwiWorkerStats = () => [created, terminated];
})();
</script>${host == 'js' ? '<script defer src="main.dart.js"></script>' : '''<script type="module">
import { compileStreaming } from './main.mjs';
const app = await (await compileStreaming(fetch('./main.wasm'))).instantiate({});
app.invokeMain();
</script>'''}</body>
</html>
''';

void main() {
  final evidence = <Map<String, Object?>>[];
  tearDownAll(() async {
    final path = Platform.environment['DWI_POOL_EVIDENCE'];
    if (path == null) return;
    final revision = await Process.run('git', <String>['rev-parse', 'HEAD']);
    if (revision.exitCode != 0) throw StateError('${revision.stderr}');
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'sdk': Platform.version,
        'revision': (revision.stdout as String).trim(),
        'sourceState': 'local ADR-024 implementation, uncommitted',
        'sourceDigests': <String, String>{for (final source in _sources) source: sha256.convert(File(source).readAsBytesSync()).toString()},
        'fixture': 'packages/dwi_builder/test/browser_pool_lifecycle_test.dart',
        'command': 'dart test test/browser_pool_lifecycle_test.dart -r expanded',
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
      test('$host host retires idle $backend workers and drains on close', () async {
        final project = FixtureProject.create();
        addTearDown(project.dispose);
        project.write('lib/pool_tasks.dart', _tasks);
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
              'dwi-pool-lifecycle: ${jsonEncode(<String, Object?>{'host': host, 'worker': backend, 'engine': engine.name, 'browserVersion': observed.browserVersion, 'result': decoded})}',
            );
            expect(
              decoded['ok'],
              isTrue,
              reason: '${decoded['error']}\n${decoded['stack']}',
            );
            expect(decoded['echo'], 'a');
            expect(decoded['countBusy'], 1);
            expect(decoded['countIdle'], 0);
            expect(decoded['retired'], 1);
            expect(decoded['afterRetire'], 'b');
            expect(decoded['countAgain'], 1);
            expect(decoded['steadyNewWorkers'], 0);
            expect(decoded['refused'], isTrue);
            expect(decoded['drained'], <int>[400, 250]);
            expect(decoded['afterDrain'], 'c');
            expect(decoded['cut'], 'DwiUnsupportedException');
            expect(decoded['afterCut'], 'd');
            // Every worker the page created was terminated.
            final workers = (decoded['workers'] as List).cast<int>();
            expect(workers[1], workers[0]);
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
