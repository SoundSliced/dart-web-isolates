import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

/// Sources stamped into the ADR-028 evidence, relative to this package.
const List<String> _sources = <String>[
  '../dwi/lib/dwi.dart',
  '../dwi_core/lib/src/worker_handle.dart',
  '../dwi_web/lib/src/web_worker_handle.dart',
  '../dwi_web/lib/src/worker_dispatcher.dart',
  'test/browser_dispatch_control_test.dart',
  'test/support/browser_engines.dart',
  'test/support/browser_probe.dart',
  'test/support/fixture.dart',
];

/// `lib/control_tasks.dart`.
const String _tasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
Future<int> slow(int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  return milliseconds;
}

/// Synchronous work that holds the worker's event loop.
@DwiTask()
int spin(int milliseconds) {
  final until = DateTime.now().add(Duration(milliseconds: milliseconds));
  while (DateTime.now().isBefore(until)) {}
  return milliseconds;
}

@DwiTask()
String echo(String value) => value;
''';

/// Dispatch pause/resume and `DwiWorker.ping` (ADR-028).
const String _calls = r'''
    // Held calls do not start until resume; a held call can be cancelled.
    Dwi.pause();
    final order = <String>[];
    final first = DwiTasks.echo('a').then(order.add);
    final second = DwiTasks.echo('b').then(order.add);
    final held = Dwi.runCancellable<Object?>('echo', 'c');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    result['heldBeforeResume'] = order.length;
    result['paused'] = Dwi.isPaused;
    result['heldCancel'] = await held.cancel();
    try {
      await held.result;
      result['heldResult'] = 'completed';
    } on DwiCancelledException {
      result['heldResult'] = 'DwiCancelledException';
    }
    Dwi.resume();
    await first;
    await second;
    order.sort();
    result['order'] = order;
    result['afterResume'] = await DwiTasks.echo('d');
    // Read now: after the closes below the fresh pool has no worker yet.
    result['observedWorkerBackend'] =
        (await Dwi.capabilities()).workerBackend;

    // A call already dispatched keeps running while paused.
    final running = DwiTasks.slow(300);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    Dwi.pause();
    result['running'] = await running;
    Dwi.resume();

    // close fails held calls; close(drain: true) dispatches them.
    Dwi.pause();
    final failed = DwiTasks.echo('x').then<Object?>(
      (value) => value,
      onError: (Object error) => error.runtimeType.toString(),
    );
    await Dwi.close();
    result['closedHeld'] = await failed;
    Dwi.pause();
    final drained = DwiTasks.echo('y');
    await Dwi.close(drain: true);
    result['drainedHeld'] = await drained;
    result['pausedAfterClose'] = Dwi.isPaused;

    // ping on a dedicated handle.
    final worker = await DwiWorker.spawn();
    result['idlePing'] =
        (await worker.ping(timeout: const Duration(seconds: 2)))
            .inMilliseconds < 1000;
    final asyncCall = worker.run<Object?>('slow', 600);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    result['asyncBusyPing'] =
        (await worker.ping(timeout: const Duration(milliseconds: 400)))
            .inMilliseconds < 400;
    result['asyncCall'] = await asyncCall;
    final syncCall = worker.run<Object?>('spin', 1000);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      await worker.ping(timeout: const Duration(milliseconds: 300));
      result['syncBusyPing'] = 'answered';
    } on DwiTimeoutException {
      result['syncBusyPing'] = 'DwiTimeoutException';
    }
    result['syncCall'] = await syncCall;
    result['usableAfter'] = worker.isUsable;
    result['pingAfter'] =
        (await worker.ping(timeout: const Duration(seconds: 2)))
            .inMilliseconds < 1000;
    await worker.close();
    try {
      await worker.ping();
      result['closedPing'] = 'answered';
    } on DwiWorkerClosedException {
      result['closedPing'] = 'DwiWorkerClosedException';
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
// every worker the page created was released.
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
    final path = Platform.environment['DWI_CONTROL_EVIDENCE'];
    if (path == null) return;
    final revision = await Process.run('git', <String>['rev-parse', 'HEAD']);
    if (revision.exitCode != 0) throw StateError('${revision.stderr}');
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'sdk': Platform.version,
        'revision': (revision.stdout as String).trim(),
        'sourceState': 'local ADR-028 implementation, uncommitted',
        'sourceDigests': <String, String>{for (final source in _sources) source: sha256.convert(File(source).readAsBytesSync()).toString()},
        'fixture': 'packages/dwi_builder/test/browser_dispatch_control_test.dart',
        'command': 'dart test test/browser_dispatch_control_test.dart -r expanded',
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
      test('$host host pauses dispatch and pings $backend workers', () async {
        final project = FixtureProject.create();
        addTearDown(project.dispose);
        project.write('lib/control_tasks.dart', _tasks);
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
              'dwi-dispatch-control: ${jsonEncode(<String, Object?>{'host': host, 'worker': backend, 'engine': engine.name, 'browserVersion': observed.browserVersion, 'result': decoded})}',
            );
            expect(
              decoded['ok'],
              isTrue,
              reason: '${decoded['error']}\n${decoded['stack']}',
            );
            expect(decoded['heldBeforeResume'], 0);
            expect(decoded['paused'], isTrue);
            expect(decoded['heldCancel'], isTrue);
            expect(decoded['heldResult'], 'DwiCancelledException');
            expect(decoded['order'], <String>['a', 'b']);
            expect(decoded['afterResume'], 'd');
            expect(decoded['running'], 300);
            expect(decoded['closedHeld'], 'DwiUnsupportedException');
            expect(decoded['drainedHeld'], 'y');
            expect(decoded['pausedAfterClose'], isFalse);
            expect(decoded['idlePing'], isTrue);
            expect(decoded['asyncBusyPing'], isTrue);
            expect(decoded['asyncCall'], 600);
            expect(decoded['syncBusyPing'], 'DwiTimeoutException');
            expect(decoded['syncCall'], 1000);
            expect(decoded['usableAfter'], isTrue);
            expect(decoded['pingAfter'], isTrue);
            expect(decoded['closedPing'], 'DwiWorkerClosedException');
            // Every worker the page created was terminated.
            final workers = (decoded['workers'] as List).cast<int>();
            expect(workers[1], workers[0]);
            expect(decoded['backend'], 'worker');
            expect(
              decoded['observedWorkerBackend'],
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
