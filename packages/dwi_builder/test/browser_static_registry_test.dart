import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';
import 'support/static_acceptance_sources.dart';

// The generated adapter resolves registered tear-offs locally; only named-task
// inputs and results cross the worker boundary.
const String _tasks = r'''
import 'dart:async';
import 'package:dwi_annotations/dwi_annotations.dart';
import 'realm.dart';

int realmState = 0;

@DwiTask()
List<Object?> identity() => <Object?>[realmName(), realmState++];

@DwiTask()
int addOne(int value) => value + 1;

class MathOps {
  @DwiTask()
  static int twice(int value) => value * 2;
  @DwiTask()
  static Future<int> twiceAsync(int value) async => value * 2;
  @DwiTask()
  static FutureOr<int> twiceEither(int value) =>
      value.isEven ? value * 2 : Future<int>.value(value * 2);
  @DwiTask()
  static List<Object?> where() => <Object?>[realmName(), realmState];
  @DwiTask()
  static void ping() {}
  @DwiTask()
  static Future<void> sink(int value) async {}
  @DwiTask()
  static Future<List<int?>> nullable(List<int?> input) async => input;
  @DwiTask(name: 'math.renamed')
  static int renamed(int value) => value + 100;
}

enum Scale {
  unit;

  @DwiTask()
  static int triple(int value) => value * 3;
  @DwiTask()
  static List<Object?> where() => <Object?>[realmName(), realmState];
}

@DwiTask()
FutureOr<int> either(int value) =>
    value.isEven ? value + 2 : Future<int>.value(value + 2);
@DwiTask()
Future<int> zeroAsync() async => 7;

@DwiTask()
int busyPrimes(int limit) {
  var count = 0;
  for (var n = 2; n <= limit; n++) {
    var prime = true;
    for (var d = 2; d * d <= n; d++) {
      if (n % d == 0) {
        prime = false;
        break;
      }
    }
    if (prime) count++;
  }
  return count;
}

@DwiTask()
Future<List<int?>> nullable(List<int?> input) async => input;
@DwiTask()
void noInput() {}
@DwiTask()
Future<void> noResult(int input) async {}
@DwiTask()
int explode(int input) => throw StateError('boom');
@DwiTask()
Future<int> slow(int milliseconds) =>
    Future<int>.delayed(Duration(milliseconds: milliseconds), () => milliseconds);
''';

String _mainSource({required bool useWasm}) =>
    r'''
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';
import 'package:sample_app/tasks.dart';

const bool _useWasm = __USE_WASM__;

/// Not annotated and therefore not in the generated registry.
int unregistered(int value) => value;
int unregistered0() => 0;
class Receiver {
  int method(int value) => value;
  int method0() => 0;
}

/// Worker constructions and terminations counted by `index.html`.
@JS('__dwiWorkerStats')
external JSArray<JSNumber> _workerStats();

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
    await Dwi.configure(DwiConfig(
      workerScript: _useWasm
          ? DwiConfig.defaultWasmWorkerScript
          : DwiConfig.defaultWorkerScript,
      workerBackend: _useWasm ? DwiWorkerBackend.wasm : DwiWorkerBackend.js,
      startupTimeout: const Duration(seconds: 20),
    ));

    final receiver = Receiver();
    final capture = Object();
    var rejected = 0;
    for (final target in <int Function(int)>[
      unregistered, (int value) => value + 1,
      (int value) => value + capture.hashCode, receiver.method,
    ]) {
      try { await DwiFunctions.run(target, 1); }
      on DwiUnknownTaskException { rejected++; }
    }
    result['rejected'] = rejected;
    var rejected0 = 0;
    for (final target in <int Function()>[
      unregistered0, () => 1, () => capture.hashCode, receiver.method0,
    ]) {
      try { await DwiFunctions.run0(target); }
      on DwiUnknownTaskException { rejected0++; }
    }
    result['rejected0'] = rejected0;
    // A registered task called through a caller signature its proxy does not
    // have (a nested Future result) is refused before registration or startup.
    var unsupported = 0;
    try { await DwiFunctions.run<int, Future<int>>(slow, 1); }
    on DwiUnsupportedException { unsupported++; }
    try { await DwiFunctions.run<int, Future<int>>(MathOps.twiceAsync, 1); }
    on DwiUnsupportedException { unsupported++; }
    try { await DwiFunctions.run0<Future<int>>(zeroAsync); }
    on DwiUnsupportedException { unsupported++; }
    result['unsupported'] = unsupported;
    result['workersBeforeAccepted'] = _workerStats().toDart.first.toDartInt;
    result['registryBeforeAccepted'] = Dwi.registry.names.toList();
    final candidates = <int Function(int)>[addOne, MathOps.twice, addOne, MathOps.twice];
    result['selectedResults'] = <int>[
      for (final selected in candidates)
        await DwiFunctions.run(selected, 21),
    ];

    final typedResult = await DwiFunctions.run(addOne, 21);
    result['typedInt'] = typedResult is int;
    result['namedControl'] = await DwiTasks.addOne(21);
    result['collections'] = await DwiFunctions.run(nullable, <int?>[1, null, 3]);
    await DwiFunctions.run0<void>(noInput);
    await DwiFunctions.run<int, void>(noResult, 1);
    try { await DwiFunctions.run(explode, 1); }
    on DwiRemoteException catch (error) {
      result['remote'] = error.message.contains('boom') && error.remoteStack.isNotEmpty;
    }
    result['either'] = <int>[
      await DwiFunctions.run(either, 2), await DwiFunctions.run(either, 3),
    ];
    result['zeroAsync'] = await DwiFunctions.run0(zeroAsync);
    result['staticAsync'] = await DwiFunctions.run(MathOps.twiceAsync, 21);
    final staticAsync = await DwiFunctions.run(MathOps.twiceAsync, 21);
    result['staticTypedInt'] = staticAsync is int;
    result['staticEither'] = <int>[
      await DwiFunctions.run(MathOps.twiceEither, 2),
      await DwiFunctions.run(MathOps.twiceEither, 3),
    ];
    result['staticZero'] = (await DwiFunctions.run0(MathOps.where)).first;
    await DwiFunctions.run0<void>(MathOps.ping);
    await DwiFunctions.run<int, void>(MathOps.sink, 1);
    result['staticVoid'] = true;
    result['staticCollections'] =
        await DwiFunctions.run(MathOps.nullable, <int?>[1, null, 3]);
    result['staticRenamed'] = await DwiFunctions.run(MathOps.renamed, 1);
    result['staticRenamedProxy'] = await DwiTasks.MathOps$renamed(1);
    result['enumStatic'] = await DwiFunctions.run(Scale.triple, 7);
    result['enumProxy'] = await DwiTasks.Scale$triple(7);
    result['enumRealm'] = (await DwiFunctions.run0(Scale.where)).first;
    result['staticRenamedByName'] = await Dwi.run<Object?>('math.renamed', 1);

    result['busyPrimes'] = await DwiFunctions.run(busyPrimes, 100000);
    realmState = 1000;
    result['workerIdentity'] = await DwiFunctions.run0(identity);
    result['hostState'] = realmState;
    result['hostIdentity'] = identity();

    final capabilities = await Dwi.capabilities();
    result['backend'] = capabilities.backend.name;
    result['workerBackend'] = capabilities.workerBackend;
    result['workerCount'] = capabilities.workerCount;
    result['protocolVersion'] = capabilities.protocolVersion;
    await Dwi.close();
    await Dwi.configure(DwiConfig(
      workerScript: _useWasm
          ? DwiConfig.defaultWasmWorkerScript
          : DwiConfig.defaultWorkerScript,
      workerBackend: _useWasm ? DwiWorkerBackend.wasm : DwiWorkerBackend.js,
      taskTimeout: const Duration(milliseconds: 50),
      startupTimeout: const Duration(seconds: 20),
    ));
    try { await DwiFunctions.run(slow, 1000); }
    on DwiTimeoutException { result['timeout'] = true; }
    await Dwi.close();
    await Dwi.configure(DwiConfig(
      workerScript: 'missing-worker.js',
      workerBackend: _useWasm ? DwiWorkerBackend.wasm : DwiWorkerBackend.js,
      startupTimeout: const Duration(seconds: 3),
    ));
    try { await DwiFunctions.run(addOne, 1); }
    on DwiStartupException { result['startupFailure'] = true; }
    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  } finally {
    await Dwi.close();
  }
  final stats = _workerStats().toDart;
  result['workersCreated'] = stats[0].toDartInt;
  result['workersTerminated'] = stats[1].toDartInt;
  _finish(result);
}
'''
        .replaceFirst('__USE_WASM__', useWasm ? 'true' : 'false');

String _index(String host) =>
    '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body><script>
// Counts every Worker the page constructs and terminates, so the test can
// assert that the adapter path leaves no worker behind.
(() => {
  const NativeWorker = globalThis.Worker;
  let created = 0;
  let terminated = 0;
  globalThis.Worker = class extends NativeWorker {
    #terminated = false;
    constructor(...args) {
      super(...args);
      created++;
    }
    terminate() {
      if (!this.#terminated) {
        this.#terminated = true;
        terminated++;
      }
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
    final path = Platform.environment['DWI_STATIC_EVIDENCE'];
    if (path == null) return;
    final revision = await Process.run('git', <String>['rev-parse', 'HEAD']);
    if (revision.exitCode != 0) throw StateError('${revision.stderr}');
    final report = <String, Object?>{
      'sdk': Platform.version,
      'revision': (revision.stdout as String).trim(),
      'sourceState': 'local ADR-020 implementation, uncommitted',
      'sourceDigests': <String, String>{
        for (final source in staticAcceptanceSources)
          source: sha256.convert(File(source).readAsBytesSync()).toString(),
      },
      'fixture': 'packages/dwi_builder/test/browser_static_registry_test.dart',
      'command': 'dart test test/browser_static_registry_test.dart -r expanded',
      'runs': evidence,
      'complete':
          evidence.length == 16 &&
          evidence.every((run) => run['status'] == 'pass'),
    };
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
  });
  for (final backend in <String>['js', 'wasm']) {
    for (final host in <String>['js', 'wasm']) {
      test('$host host registered mapping executes in a $backend worker', () async {
        final project = FixtureProject.create();
        addTearDown(project.dispose);

        project.write('lib/tasks.dart', _tasks);
        project.write('lib/realm.dart', r'''
import 'dart:js_interop';
@JS('globalThis.constructor.name')
external JSString get _scope;
String realmName() => _scope.toDart;
''');
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
              'dwi5-static-registry: ${jsonEncode(<String, Object?>{'host': host, 'worker': backend, 'engine': engine.name, 'browserVersion': observed.browserVersion, 'result': decoded})}',
            );

            expect(
              decoded['ok'],
              isTrue,
              reason: '${decoded['error']}\n${decoded['stack']}',
            );

            expect(decoded['selectedResults'], <int>[22, 42, 22, 42]);
            expect(decoded['typedInt'], isTrue);
            expect(decoded['namedControl'], 22);
            expect(decoded['rejected'], 4);
            expect(decoded['rejected0'], 4);
            expect(decoded['unsupported'], 3);
            expect(decoded['registryBeforeAccepted'], isEmpty);
            expect(decoded['workersBeforeAccepted'], 0);
            expect(decoded['either'], <int>[4, 5]);
            expect(decoded['zeroAsync'], 7);
            expect(decoded['staticAsync'], 42);
            expect(decoded['staticTypedInt'], isTrue);
            expect(decoded['staticEither'], <int>[4, 6]);
            expect(decoded['staticZero'], 'DedicatedWorkerGlobalScope');
            expect(decoded['staticVoid'], isTrue);
            expect(decoded['staticCollections'], <int?>[1, null, 3]);
            expect(decoded['staticRenamed'], 101);
            expect(decoded['staticRenamedProxy'], 101);
            expect(decoded['staticRenamedByName'], 101);
            expect(decoded['enumStatic'], 21);
            expect(decoded['enumProxy'], 21);
            expect(decoded['enumRealm'], 'DedicatedWorkerGlobalScope');
            expect(decoded['collections'], <int?>[1, null, 3]);
            expect(decoded['remote'], isTrue);
            expect(decoded['timeout'], isTrue);
            expect(decoded['startupFailure'], isTrue);
            expect(decoded['busyPrimes'], 9592);
            expect(decoded['workerIdentity'], <Object?>[
              'DedicatedWorkerGlobalScope',
              0,
            ]);
            expect(decoded['hostIdentity'], <Object?>['Window', 1000]);
            expect(decoded['hostState'], 1000);
            expect(decoded['backend'], 'worker');
            expect(
              decoded['workerBackend'],
              backend == 'wasm' ? 'dart2wasm' : 'dart2js',
            );
            expect(decoded['workerCount'], greaterThanOrEqualTo(1));
            expect(decoded['protocolVersion'], 2);
            // Cleanup: the pool, the timed-out worker and the worker that
            // failed to start were all terminated; none is left running.
            expect(decoded['workersCreated'], greaterThanOrEqualTo(3));
            expect(decoded['workersTerminated'], decoded['workersCreated']);
            evidence.last['status'] = 'pass';
          }
        } finally {
          await server.close(force: true);
        }
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  }
}
