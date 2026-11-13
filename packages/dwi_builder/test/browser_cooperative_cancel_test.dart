import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

/// Sources stamped into the ADR-027 evidence, relative to this package.
const List<String> _sources = <String>[
  '../dwi/lib/dwi.dart',
  '../dwi_core/lib/src/cancel_token.dart',
  '../dwi_core/lib/src/config.dart',
  '../dwi_web/lib/src/web_backend.dart',
  '../dwi_web/lib/src/worker_dispatcher.dart',
  'test/browser_cooperative_cancel_test.dart',
  'test/support/browser_engines.dart',
  'test/support/browser_probe.dart',
  'test/support/fixture.dart',
];

/// `lib/coop_tasks.dart`.
const String _tasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_worker.dart';

int _stoppedAt = -1;

/// Takes [count] 20 ms steps and stops at the first one after cancellation.
@DwiTask()
Future<int> steps(int count) async {
  for (var index = 0; index < count; index++) {
    if (DwiCancelToken.current.isCancelled) {
      _stoppedAt = index;
      DwiCancelToken.current.throwIfCancelled();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return count;
}

/// Step at which the last cancelled [steps] call stopped, or -1.
@DwiTask()
int stoppedAt(int ignored) => _stoppedAt;

/// Synchronous work that cannot observe the token.
@DwiTask()
int spin(int milliseconds) {
  final until = DateTime.now().add(Duration(milliseconds: milliseconds));
  while (DateTime.now().isBefore(until)) {}
  return milliseconds;
}

@DwiTask()
String echo(String value) => value;
''';

/// Cooperative cancellation (ADR-027), with one pooled worker and
/// `cancelGracePeriod: 1 s`.
const String _calls = r'''
    int created() => _workerStats().toDart[0].toDartInt;
    int terminated() => _workerStats().toDart[1].toDartInt;

    // A cooperative task stops within the grace period and its worker is kept.
    result['warm'] = await DwiTasks.echo('a');
    final coop = Dwi.runCancellable<Object?>('steps', 500);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final cancelWatch = Stopwatch()..start();
    result['cancelled'] = await coop.cancel();
    try {
      await coop.result;
      result['coopResult'] = 'completed';
    } on DwiCancelledException {
      result['coopResult'] = 'DwiCancelledException';
    }
    result['settleFast'] = cancelWatch.elapsedMilliseconds < 200;
    // With one worker this call waits until the task has stopped.
    result['next'] = await DwiTasks.echo('b');
    final stoppedAt = await DwiTasks.stoppedAt(0);
    result['observed'] = stoppedAt >= 1 && stoppedAt < 500;
    result['reused'] = created() == 1 && terminated() == 0;
    result['cancelAgain'] = await coop.cancel();

    // A task that never yields is terminated when the period ends.
    final stubborn = Dwi.runCancellable<Object?>('spin', 4000);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    result['stubbornCancelled'] = await stubborn.cancel();
    try {
      await stubborn.result;
      result['stubbornResult'] = 'completed';
    } on DwiCancelledException {
      result['stubbornResult'] = 'DwiCancelledException';
    }
    final waitWatch = Stopwatch()..start();
    result['afterStubborn'] = await DwiTasks.echo('c');
    final waited = waitWatch.elapsedMilliseconds;
    // Freed by termination near 1 s, not by the 4 s loop finishing.
    result['terminatedAtGrace'] = waited >= 600 && waited < 3000;
    result['replaced'] = created() == 2 && terminated() == 1;
    // The state of the terminated worker is gone with it.
    result['freshState'] = await DwiTasks.stoppedAt(0);
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
      maxWorkers: 1,
      cancelGracePeriod: const Duration(seconds: 1),
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
    final path = Platform.environment['DWI_COOP_EVIDENCE'];
    if (path == null) return;
    final revision = await Process.run('git', <String>['rev-parse', 'HEAD']);
    if (revision.exitCode != 0) throw StateError('${revision.stderr}');
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'sdk': Platform.version,
        'revision': (revision.stdout as String).trim(),
        'sourceState': 'local ADR-027 implementation, uncommitted',
        'sourceDigests': <String, String>{for (final source in _sources) source: sha256.convert(File(source).readAsBytesSync()).toString()},
        'fixture': 'packages/dwi_builder/test/browser_cooperative_cancel_test.dart',
        'command': 'dart test test/browser_cooperative_cancel_test.dart -r expanded',
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
      test('$host host cancels $backend worker tasks cooperatively', () async {
        final project = FixtureProject.create();
        addTearDown(project.dispose);
        project.write('lib/coop_tasks.dart', _tasks);
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
              'dwi-coop-cancel: ${jsonEncode(<String, Object?>{'host': host, 'worker': backend, 'engine': engine.name, 'browserVersion': observed.browserVersion, 'result': decoded})}',
            );
            expect(
              decoded['ok'],
              isTrue,
              reason: '${decoded['error']}\n${decoded['stack']}',
            );
            expect(decoded['warm'], 'a');
            expect(decoded['cancelled'], isTrue);
            expect(decoded['coopResult'], 'DwiCancelledException');
            expect(decoded['settleFast'], isTrue);
            expect(decoded['next'], 'b');
            expect(decoded['observed'], isTrue);
            expect(decoded['reused'], isTrue);
            expect(decoded['cancelAgain'], isFalse);
            expect(decoded['stubbornCancelled'], isTrue);
            expect(decoded['stubbornResult'], 'DwiCancelledException');
            expect(decoded['afterStubborn'], 'c');
            expect(decoded['terminatedAtGrace'], isTrue);
            expect(decoded['replaced'], isTrue);
            expect(decoded['freshState'], -1);
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
