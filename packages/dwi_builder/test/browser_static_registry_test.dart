import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

// Experimental DWI-5 prototype: a generated caller registry maps registered
// static tear-offs to task names by identity. The host chooses a function at
// runtime, resolves its task name, and calls the existing named-task API. No
// public API is added.
const String _tasks = r'''
import 'dart:async';
import 'dart:math';

import 'package:dwi_annotations/dwi_annotations.dart';

/// A token created inside the worker program. The host has its own token, so a
/// matching token would mean the task did not run in a separate program.
final String _workerToken =
    'worker-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 31)}';

@DwiTask()
String identity() => _workerToken;

@DwiTask()
int addOne(int value) => value + 1;

@DwiTask()
int twice(int value) => value * 2;

/// Gives the host event loop time to run timers while the worker computes.
@DwiTask()
Future<int> busyPrimes(int limit) async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
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
''';

String _mainSource({required bool useWasm}) =>
    r'''
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_caller_registry.g.dart';
import 'package:sample_app/tasks.dart';

const bool _useWasm = __USE_WASM__;

/// Not annotated and therefore not in the generated registry.
int unregistered(int value) => value;

final String _hostToken =
    'host-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 31)}';

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

    // The function is chosen at runtime; the generated registry resolves it to
    // a task name by identity. No function crosses the worker boundary.
    final candidates = <int Function(int)>[addOne, twice];
    final names = <String>['addOne', 'twice'];
    final index = DateTime.now().microsecond % candidates.length;
    final selected = candidates[index];
    result['selectedName'] = names[index];
    final task = dwiCallerRegistry[selected];
    result['mappedTask'] = task;
    result['mappedResult'] = await Dwi.run<int>(task!, 21);

    // Both registered entries resolve to their own task, not just the one
    // chosen above.
    result['mappedAddOne'] = await Dwi.run<int>(
      dwiCallerRegistry[addOne]!,
      21,
    );
    result['mappedTwice'] = await Dwi.run<int>(
      dwiCallerRegistry[twice]!,
      21,
    );
    result['unregisteredMapped'] = dwiCallerRegistry[unregistered];

    // A worker task with a deliberate delay: the main thread must keep ticking
    // if execution is off-thread.
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    result['busyPrimes'] = await Dwi.run<int>('busyPrimes', 100000);
    timer.cancel();
    result['ticks'] = ticks;

    result['workerToken'] = await Dwi.run<String>('identity');
    result['hostToken'] = _hostToken;
    result['distinctToken'] = result['workerToken'] != _hostToken;

    final capabilities = await Dwi.capabilities();
    result['backend'] = capabilities.backend.name;
    result['workerBackend'] = capabilities.workerBackend;
    result['workerCount'] = capabilities.workerCount;
    result['protocolVersion'] = capabilities.protocolVersion;
    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  }
  _finish(result);
}
'''
        .replaceFirst('__USE_WASM__', useWasm ? 'true' : 'false');

const String _index = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body><script defer src="main.dart.js"></script></body>
</html>
''';

/// A prototype-only generator: map every discovered task's function tear-off to
/// its task name. The map keys are static references, so tree shaking keeps
/// them; the map value is the name the existing API already accepts.
String _callerRegistry(DwiDiscoveryResult discovery) {
  final tasks = discovery.sortedTasks;
  final uris = tasks.map((task) => task.importUri).toSet().toList()..sort();
  final prefixes = <String, String>{
    for (var index = 0; index < uris.length; index++)
      uris[index]: 'tasks$index',
  };
  final buffer = StringBuffer()
    ..writeln('// GENERATED PROTOTYPE CALLER REGISTRY - DO NOT EDIT.')
    ..writeln('// Maps registered static tear-offs to task names by identity.')
    ..writeln();
  for (final uri in uris) {
    buffer.writeln('import ${jsonEncode(uri)} as ${prefixes[uri]};');
  }
  buffer
    ..writeln()
    ..writeln(
      'final Map<Function, String> dwiCallerRegistry = <Function, String>{',
    );
  for (final task in tasks) {
    buffer.writeln(
      '  ${prefixes[task.importUri]}.${task.functionName}: '
      '${jsonEncode(task.name)},',
    );
  }
  buffer.writeln('};');
  return buffer.toString();
}

void main() {
  for (final backend in <String>['js', 'wasm']) {
    test('registered static mapping executes in a $backend worker', () async {
      if (chromeExecutable() == null) {
        markTestSkipped('Google Chrome is not installed.');
        return;
      }

      final project = FixtureProject.create();
      addTearDown(project.dispose);

      project.write('lib/tasks.dart', _tasks);
      final discovery = await discoverTasks(project.config());
      expect(
        discovery.hasErrors,
        isFalse,
        reason: discovery.diagnostics.map((d) => d.message).join('\n'),
      );
      project.write(
        'lib/dwi_caller_registry.g.dart',
        _callerRegistry(discovery),
      );
      project.write('web/main.dart', _mainSource(useWasm: backend == 'wasm'));
      project.write('web/index.html', _index);

      await DwiBuilder(project.config(compile: true).copyWith(target: backend))
          .build();

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
        // Evidence line: exact observed payload for the audit record.
        print('dwi5-static-registry-$backend: ${jsonEncode(decoded)}');

        expect(
          decoded['ok'],
          isTrue,
          reason: '${decoded['error']}\n${decoded['stack']}',
        );

        final selectedName = decoded['selectedName'] as String;
        expect(decoded['mappedTask'], selectedName);
        expect(decoded['mappedResult'], selectedName == 'addOne' ? 22 : 42);
        expect(decoded['mappedAddOne'], 22);
        expect(decoded['mappedTwice'], 42);
        expect(decoded['unregisteredMapped'], isNull);
        expect(decoded['busyPrimes'], 9592);
        expect(
          decoded['ticks'],
          greaterThan(0),
          reason: 'the main thread did not tick while the worker computed',
        );
        expect(decoded['workerToken'], isNot(decoded['hostToken']));
        expect(decoded['distinctToken'], isTrue);
        expect(decoded['backend'], 'worker');
        expect(
          decoded['workerBackend'],
          backend == 'wasm' ? 'dart2wasm' : 'dart2js',
        );
        expect(decoded['workerCount'], greaterThanOrEqualTo(1));
      } finally {
        await server.close(force: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
