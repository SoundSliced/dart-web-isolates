import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

// Checkout-consumer contract for ADR-015 (`DwiWorker.using`) and ADR-016
// (`Dwi.runFresh`). Built against the local packages, so it may exercise APIs
// that are not published yet. The published-0.5.3 counterpart is
// `tooling/hosted_consumer/`; the two are deliberately separate evidence sets.

const String scopedTasks = r'''
import 'dart:async';

import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_core.dart';

int _counter = 0;

@DwiTask()
int counter(int input) => ++_counter;

@DwiTask()
String boom(String value) => throw StateError('boom from worker');

@DwiTask()
Future<String> slow(int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  return 'slow';
}

@DwiTask()
String echo(String value) => value;

@DwiTask()
String channelEcho(String name) {
  final channel = DwiWorkerChannels.find(name);
  if (channel == null) return 'missing';
  channel.messages.listen(
    (message) => channel.send('echo:$message'),
    onError: (Object error, StackTrace stack) {},
  );
  return 'listening';
}
''';

const String scopedMain = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi/dwi.dart';

const String workerScript = 'dwi/worker.dart.js';

@JS('document')
external JSObject get _document;

void _finish(Map<String, Object?> result) {
  _document.setProperty(
    'title'.toJS,
    base64Encode(utf8.encode(jsonEncode(result))).toJS,
  );
}

String _classify(Object error) {
  if (error is DwiWorkerClosedException) return 'DwiWorkerClosedException';
  if (error is DwiWorkerFailedException) return 'DwiWorkerFailedException';
  if (error is DwiWorkerStateException) return 'DwiWorkerStateException';
  if (error is DwiChannelClosedException) return 'DwiChannelClosedException';
  if (error is DwiTimeoutException) return 'DwiTimeoutException';
  if (error is DwiStartupException) return 'DwiStartupException';
  if (error is DwiUnknownTaskException) return 'DwiUnknownTaskException';
  if (error is DwiUnsupportedException) return 'DwiUnsupportedException';
  if (error is DwiSerializationException) return 'DwiSerializationException';
  if (error is DwiCancelledException) return 'DwiCancelledException';
  if (error is DwiRemoteException) return 'DwiRemoteException';
  return error.runtimeType.toString();
}

Future<String> _outcome(Future<Object?> future) async {
  try {
    return 'OK:${await future}';
  } catch (error) {
    return _classify(error);
  }
}

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(seconds: 5),
      ),
    );

    // 1. Two runFresh calls observe fresh worker-local state.
    result['fresh'] = <int>[
      await Dwi.runFresh<int>('counter', 0),
      await Dwi.runFresh<int>('counter', 0),
    ];

    // 2. Two calls inside one using scope retain state.
    result['scoped'] = await DwiWorker.using((worker) async => <int>[
          await worker.run<int>('counter', 0),
          await worker.run<int>('counter', 0),
        ]);

    // 3a. A callback failure closes the owned handle.
    late DwiWorker callbackWorker;
    result['callbackError'] = await _outcome(
      DwiWorker.using<void>((worker) {
        callbackWorker = worker;
        throw StateError('callback failure');
      }),
    );
    result['callbackState'] = callbackWorker.state.name;

    // 3b. A remote task failure closes the owned handle.
    late DwiWorker remoteWorker;
    result['remoteError'] = await _outcome(
      DwiWorker.using<void>((worker) {
        remoteWorker = worker;
        return worker.run<String>('boom', 'x');
      }),
    );
    result['remoteState'] = remoteWorker.state.name;

    // 4. Spawn failure does not invoke the callback.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: 'missing/worker.dart.js',
        startupTimeout: Duration(milliseconds: 400),
      ),
    );
    var bodyRan = false;
    result['spawnError'] = await _outcome(
      DwiWorker.using<void>((worker) {
        bodyRan = true;
      }),
    );
    result['spawnBodyRan'] = bodyRan;

    // 5a. Timeout settles and leaves no live handle.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(milliseconds: 300),
      ),
    );
    late DwiWorker timeoutWorker;
    result['timeoutError'] = await _outcome(
      DwiWorker.using<void>((worker) {
        timeoutWorker = worker;
        return worker.run<String>('slow', 3000);
      }),
    );
    result['timeoutState'] = timeoutWorker.state.name;

    // 5b. Cancelling a running call settles and leaves no live handle.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    late DwiWorker cancelWorker;
    result['cancelError'] = await _outcome(
      DwiWorker.using<void>((worker) async {
        cancelWorker = worker;
        final task = worker.runCancellable<String>('slow', 5000);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await task.cancel();
        await task.result;
      }),
    );
    result['cancelState'] = cancelWorker.state.name;

    // 6. Existing Dwi.run, handle and channel behaviour stays green.
    result['pool'] = await _outcome(Dwi.run<Object?>('echo', 'pool'));
    final worker = await DwiWorker.spawn();
    result['handle'] = await worker.run<int>('counter', 0);
    final channel = await worker.openChannel('progress');
    final reply = channel.messages.first;
    await worker.run<String>('channelEcho', 'progress');
    await channel.send('ping');
    result['channel'] = await reply.timeout(const Duration(seconds: 5));
    await worker.close();
    result['handleClosed'] = worker.state.name;

    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  }
  _finish(result);
}
''';

const String scopedIndex = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body><script defer src="main.dart.js"></script></body>
</html>
''';

void main() {
  late FixtureProject project;
  late HttpServer server;
  late String url;

  setUpAll(() async {
    project = FixtureProject.create();
    project.write('lib/tasks.dart', scopedTasks);
    project.write('web/main.dart', scopedMain);
    project.write('web/index.html', scopedIndex);

    await DwiBuilder(project.config(compile: true)).build();

    final compiled = await Process.run(
      Platform.resolvedExecutable,
      <String>['compile', 'js', '-O1', '-o', 'web/main.dart.js', 'web/main.dart'],
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

    server = await serveDirectory(p.join(project.root.path, 'web'));
    url = 'http://127.0.0.1:${server.port}/index.html';
  });

  tearDownAll(() async {
    await server.close(force: true);
    project.dispose();
  });

  for (final engine in BrowserEngine.values) {
    test(
      'scoped helper contract in ${engine.name}',
      () async {
        final availability = browserAvailability(engine);
        if (!availability.available) {
          await _recordBlocked(engine, availability.reason!);
          markTestSkipped(availability.reason!);
          return;
        }

        final runs = <Map<String, Object?>>[];
        var browserVersion = 'unknown';
        var failures = 0;

        for (var run = 1; run <= 2; run++) {
          Map<String, dynamic>? decoded;
          Object? lastError;
          for (var attempt = 1; attempt <= 2 && decoded == null; attempt++) {
            try {
              final result = await probeBrowser(engine, url);
              browserVersion = result.browserVersion;
              decoded = result.data;
            } on BrowserBlockedException catch (error) {
              await _recordBlocked(engine, error.reason);
              markTestSkipped(error.reason);
              return;
            } catch (error) {
              lastError = error;
            }
          }

          if (decoded == null) {
            failures++;
            runs.add(<String, Object?>{
              'run': run,
              'status': 'error',
              'error': '$lastError',
            });
            continue;
          }

          final problems = <String>[];
          try {
            _expectContract(decoded);
          } catch (error) {
            problems.add('$error');
          }
          if (problems.isEmpty) {
            runs.add(<String, Object?>{'run': run, 'status': 'pass'});
          } else {
            failures++;
            runs.add(<String, Object?>{
              'run': run,
              'status': 'fail',
              'details': problems.join('\n'),
            });
          }
        }

        await _recordRun(
          engine,
          browserVersion: browserVersion,
          runs: runs,
        );
        expect(
          failures,
          0,
          reason: '$failures of ${runs.length} runs failed in ${engine.name}: '
              '$runs',
        );
      },
      timeout: const Timeout(Duration(minutes: 12)),
    );
  }
}

void _expectContract(Map<String, dynamic> decoded) {
  expect(
    decoded['ok'],
    isTrue,
    reason: '${decoded['error']}\n${decoded['stack']}',
  );

  // ADR-016: every call starts from fresh worker-local state.
  expect(decoded['fresh'], <int>[1, 1]);

  // ADR-015: one scope keeps state.
  expect(decoded['scoped'], <int>[1, 2]);

  // ADR-015 Decision 4: the callback error wins and the handle is closed.
  expect(decoded['callbackError'], 'StateError');
  expect(decoded['callbackState'], 'closed');
  expect(decoded['remoteError'], 'DwiRemoteException');
  expect(decoded['remoteState'], 'closed');

  // ADR-015 Decision 2 and 6.
  expect(decoded['spawnError'], 'DwiStartupException');
  expect(decoded['spawnBodyRan'], isFalse);
  expect(decoded['timeoutError'], 'DwiTimeoutException');
  expect(decoded['timeoutState'], 'closed');
  expect(decoded['cancelError'], 'DwiCancelledException');
  expect(decoded['cancelState'], 'closed');

  // Unchanged behaviour.
  expect(decoded['pool'], 'OK:pool');
  expect(decoded['handle'], 1);
  expect(decoded['channel'], 'echo:ping');
  expect(decoded['handleClosed'], 'closed');
}

Future<void> _recordBlocked(BrowserEngine engine, String reason) async {
  await _writeEvidence(engine, <String, Object?>{
    'engine': engine.name,
    'status': 'blocked',
    'reason': reason,
  });
}

Future<void> _recordRun(
  BrowserEngine engine, {
  required String browserVersion,
  required List<Map<String, Object?>> runs,
}) async {
  final passed = runs.where((run) => run['status'] == 'pass').length;
  await _writeEvidence(engine, <String, Object?>{
    'engine': engine.name,
    'status': passed == runs.length ? 'pass' : 'fail',
    'browserVersion': browserVersion,
    'harness': 'packages/dwi_builder/test/browser_scoped_test.dart',
    'command':
        'dart test test/browser_scoped_test.dart --plain-name '
            '"scoped helper contract in ${engine.name}"',
    'environment': <String, Object?>{
      'os': Platform.operatingSystemVersion,
      'dartVersion': Platform.version,
      'cpuCount': Platform.numberOfProcessors,
    },
    'runs': runs,
    'passed': passed,
    'failed': runs.length - passed,
  });
}

Future<void> _writeEvidence(
  BrowserEngine engine,
  Map<String, Object?> report,
) async {
  final directory = Platform.environment['DWI_EVIDENCE_DIR'];
  if (directory == null || directory.isEmpty) return;
  final now = DateTime.now().toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp = '${now.year}${two(now.month)}${two(now.day)}';
  final file = File(
    p.join(directory, 'scoped-matrix-${engine.name}-$stamp.json'),
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
}
