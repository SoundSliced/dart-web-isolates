import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

const String lifecycleTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
Future<String> slow(int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  return 'slow';
}

@DwiTask()
String echo(String value) => value;
''';

const String lifecycleMain = r'''
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
  if (error is DwiTimeoutException) return 'DwiTimeoutException';
  if (error is DwiUnsupportedException) return 'DwiUnsupportedException';
  if (error is DwiStartupException) return 'DwiStartupException';
  if (error is DwiSerializationException) return 'DwiSerializationException';
  if (error is DwiRemoteException) return 'DwiRemoteException';
  return 'OTHER';
}

Future<String> _outcome(Future<Object?> future) async {
  try {
    return 'OK:${await future}';
  } catch (error) {
    return _classify(error);
  }
}

Future<List<String>> _settle(
  List<Future<Object?>> futures, {
  int guardMs = 6000,
}) async {
  try {
    return await Future.wait(
      futures.map(_outcome),
    ).timeout(Duration(milliseconds: guardMs));
  } on TimeoutException {
    return <String>['HUNG'];
  }
}

Future<int> _workers() async => (await Dwi.capabilities()).workerCount;

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    // A: one hanging worker, two queued callers, a task timeout. Every future
    // must settle and later work must succeed.
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 1,
        maxQueuedTasks: 2,
        taskTimeout: Duration(milliseconds: 500),
        queueTimeout: Duration(seconds: 2),
      ),
    );
    final aWatch = Stopwatch()..start();
    result['a'] = await _settle(<Future<Object?>>[
      Dwi.run<Object?>('slow', 5000),
      Dwi.run<Object?>('echo', 'a'),
      Dwi.run<Object?>('echo', 'b'),
    ]);
    result['aMs'] = aWatch.elapsedMilliseconds;
    result['aWorkers'] = await _workers();
    result['aAfter'] = await _outcome(Dwi.run<Object?>('echo', 'later'));

    // B: a full queue rejects the extra caller instead of leaving it pending.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 1,
        maxQueuedTasks: 1,
        taskTimeout: Duration(milliseconds: 500),
        queueTimeout: Duration(seconds: 2),
      ),
    );
    result['b'] = await _settle(<Future<Object?>>[
      Dwi.run<Object?>('slow', 5000),
      Dwi.run<Object?>('echo', 'q1'),
      Dwi.run<Object?>('echo', 'q2'),
    ]);
    result['bAfter'] = await _outcome(Dwi.run<Object?>('echo', 'afterB'));

    // C: queue waiting has its own deadline, separate from the task timeout.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 1,
        maxQueuedTasks: 2,
        taskTimeout: Duration(seconds: 5),
        queueTimeout: Duration(milliseconds: 200),
      ),
    );
    final cSlow = Dwi.run<Object?>('slow', 1000);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final cWatch = Stopwatch()..start();
    final cQueued = await _outcome(Dwi.run<Object?>('echo', 'queued'));
    result['cQueued'] = cQueued;
    result['cQueueMs'] = cWatch.elapsedMilliseconds;
    result['cSlow'] = await _outcome(cSlow);

    // D: close settles the in-flight request promptly and is idempotent.
    final dSlow = Dwi.run<Object?>('slow', 5000);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final dWatch = Stopwatch()..start();
    await Dwi.close();
    final dSettled = await _outcome(dSlow);
    result['dSettled'] = dSettled;
    result['dCloseMs'] = dWatch.elapsedMilliseconds;
    await Dwi.close();
    result['dRepeatedClose'] = 'ok';
    await Dwi.configure(
      const DwiConfig(workerScript: workerScript),
    );
    result['dReused'] = await _outcome(Dwi.run<Object?>('echo', 'reused'));

    // E: concurrent first calls share worker startup without leaking capacity.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 2,
        maxQueuedTasks: 4,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    result['e'] = await _settle(<Future<Object?>>[
      Dwi.run<Object?>('echo', '1'),
      Dwi.run<Object?>('echo', '2'),
      Dwi.run<Object?>('echo', '3'),
      Dwi.run<Object?>('echo', '4'),
    ]);
    result['eWorkers'] = await _workers();

    // F: an oversized payload fails before sending and does not leak a slot.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxPayloadBytes: 100,
        taskTimeout: Duration(milliseconds: 500),
      ),
    );
    result['fLarge'] = await _outcome(
      Dwi.run<Object?>('echo', 'x' * 1024),
    );
    result['fAfter'] = await _outcome(Dwi.run<Object?>('echo', 'small'));

    // G: a missing worker script is a typed startup failure, not a hang.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: 'missing/worker.dart.js',
        startupTimeout: Duration(milliseconds: 500),
      ),
    );
    result['gMissing'] = await _outcome(Dwi.run<Object?>('echo', 'x'));

    await Dwi.close();
    await Dwi.configure(const DwiConfig(workerScript: workerScript));
    result['gReused'] = await _outcome(Dwi.run<Object?>('echo', 'back'));

    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  }
  _finish(result);
}
''';

const String lifecycleIndex = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body><script defer src="main.dart.js"></script></body>
</html>
''';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'worker pool settles every caller after timeout, overflow, close and '
    'startup failure in Chrome',
    () async {
      project.write('lib/tasks.dart', lifecycleTasks);
      project.write('web/main.dart', lifecycleMain);
      project.write('web/index.html', lifecycleIndex);

      await DwiBuilder(project.config(compile: true)).build();

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

        expect(
          decoded['ok'],
          isTrue,
          reason: '${decoded['error']}\n${decoded['stack']}',
        );

        expect(decoded['a'], <String>[
          'DwiTimeoutException',
          'OK:a',
          'OK:b',
        ]);
        expect(decoded['aWorkers'], lessThanOrEqualTo(1));
        expect(decoded['aAfter'], 'OK:later');

        expect(decoded['b'], <String>[
          'DwiTimeoutException',
          'OK:q1',
          'DwiUnsupportedException',
        ]);
        expect(decoded['bAfter'], 'OK:afterB');

        expect(decoded['cQueued'], 'DwiTimeoutException');
        expect(decoded['cQueueMs'], lessThan(800));
        expect(decoded['cSlow'], 'OK:slow');

        expect(decoded['dSettled'], 'DwiUnsupportedException');
        expect(decoded['dCloseMs'], lessThan(1000));
        expect(decoded['dRepeatedClose'], 'ok');
        expect(decoded['dReused'], 'OK:reused');

        expect(decoded['e'], <String>['OK:1', 'OK:2', 'OK:3', 'OK:4']);
        expect(decoded['eWorkers'], lessThanOrEqualTo(2));

        expect(decoded['fLarge'], 'DwiSerializationException');
        expect(decoded['fAfter'], 'OK:small');

        expect(decoded['gMissing'], 'DwiStartupException');
        expect(decoded['gReused'], 'OK:back');
      } finally {
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: chromeExecutable() == null ? 'Google Chrome is not installed.' : false,
  );
}
