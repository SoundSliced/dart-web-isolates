import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

const String lifecycleTasks = r'''
import 'dart:typed_data';

import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_core.dart';

@DwiTask()
Future<String> slow(int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  return 'slow';
}

@DwiTask()
String echo(String value) => value;

@DwiTask()
String spin(int milliseconds) {
  final until = DateTime.now().add(Duration(milliseconds: milliseconds));
  while (DateTime.now().isBefore(until)) {
    // Synchronous CPU work: the worker cannot read a message until it returns.
  }
  return 'spun';
}

@DwiTask()
DwiTransferableBytes echoBytes(DwiTransferableBytes input) => input;

@DwiTask()
DwiTransferableBytes makeBytes(int length) {
  final data = Uint8List(length)..fillRange(0, length, 7);
  return DwiTransferableBytes(data);
}
''';

const String lifecycleMain = r'''
import 'dart:async';
import 'dart:typed_data';
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
  if (error is DwiCancelledException) return 'DwiCancelledException';
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

    // H: cancellation — queued, running, repeated, after completion, recovery.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 1,
        maxQueuedTasks: 2,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    final hRunning = Dwi.runCancellable<String>('spin', 3000);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final hQueued = Dwi.runCancellable<String>('echo', 'queued');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    result['hQueuedCancel'] = await hQueued.cancel();
    result['hQueuedResult'] = await _outcome(hQueued.result);

    final hWatch = Stopwatch()..start();
    result['hRunningCancel'] = await hRunning.cancel();
    result['hRunningResult'] = await _outcome(hRunning.result);
    result['hRunningMs'] = hWatch.elapsedMilliseconds;
    result['hRepeatedCancel'] = await hRunning.cancel();
    result['hAfter'] = await _outcome(Dwi.run<Object?>('echo', 'afterCancel'));

    final hDone = Dwi.runCancellable<String>('echo', 'done');
    result['hDoneValue'] = await hDone.result;
    result['hDoneCancel'] = await hDone.cancel();

    // A cancel must beat a task timeout that would otherwise terminate the
    // same worker.
    final hRace = Dwi.runCancellable<String>('spin', 2000);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    result['hRaceCancel'] = await hRace.cancel();
    result['hRaceResult'] = await _outcome(hRace.result);

    result['hCaps'] = (await Dwi.capabilities()).cancellation.name;

    // I: transferable bytes — argument detach, returned buffer, repeated send.
    final iBytes = DwiTransferableBytes(Uint8List.fromList(<int>[1, 2, 3, 4]));
    final iEcho = await Dwi.run<DwiTransferableBytes>('echoBytes', iBytes);
    result['iEchoLength'] = iEcho.lengthInBytes;
    result['iEchoFirst'] = iEcho.bytes.first;
    result['iEchoLast'] = iEcho.bytes.last;
    result['iDetached'] = iBytes.isDetached;
    try {
      iBytes.bytes;
      result['iSenderRead'] = 'readable';
    } catch (error) {
      result['iSenderRead'] = _classify(error);
    }
    try {
      await Dwi.run<DwiTransferableBytes>('echoBytes', iBytes);
      result['iRepeat'] = 'accepted';
    } catch (error) {
      result['iRepeat'] = _classify(error);
    }
    final iReturned = await Dwi.run<DwiTransferableBytes>('makeBytes', 6);
    result['iReturnedLength'] = iReturned.lengthInBytes;
    result['iReturnedAllSeven'] = iReturned.bytes.every((value) => value == 7);
    result['iTransferables'] = (await Dwi.capabilities()).transferables;

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

        expect(decoded['hQueuedCancel'], isTrue);
        expect(decoded['hQueuedResult'], 'DwiCancelledException');
        expect(decoded['hRunningCancel'], isTrue);
        expect(decoded['hRunningResult'], 'DwiCancelledException');
        expect(decoded['hRunningMs'], lessThan(1000));
        expect(decoded['hRepeatedCancel'], isFalse);
        expect(decoded['hAfter'], 'OK:afterCancel');
        expect(decoded['hDoneValue'], 'done');
        expect(decoded['hDoneCancel'], isFalse);
        expect(decoded['hRaceCancel'], isTrue);
        expect(decoded['hRaceResult'], 'DwiCancelledException');
        expect(decoded['hCaps'], 'running');

        expect(decoded['iEchoLength'], 4);
        expect(decoded['iEchoFirst'], 1);
        expect(decoded['iEchoLast'], 4);
        expect(decoded['iDetached'], isTrue);
        expect(decoded['iSenderRead'], 'DwiSerializationException');
        expect(decoded['iRepeat'], 'DwiSerializationException');
        expect(decoded['iReturnedLength'], 6);
        expect(decoded['iReturnedAllSeven'], isTrue);
        expect(decoded['iTransferables'], isTrue);
      } finally {
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: chromeExecutable() == null ? 'Google Chrome is not installed.' : false,
  );
}
