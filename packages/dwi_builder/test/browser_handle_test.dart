import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

const String handleTasks = r'''
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_core.dart';

@JS('self')
external JSObject get _self;

int _counter = 0;

@DwiTask()
int count(int input) => ++_counter;

@DwiTask()
String echo(String value) => value;

@DwiTask()
String boom(String value) => throw StateError('boom from worker');

@DwiTask()
Future<String> slow(int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  return 'slow';
}

@DwiTask()
String spin(int milliseconds) {
  final until = DateTime.now().add(Duration(milliseconds: milliseconds));
  while (DateTime.now().isBefore(until)) {
    // Synchronous CPU work: the worker cannot answer a heartbeat.
  }
  return 'spun';
}

@DwiTask()
String dieAfter(String value) {
  // Answer first, then close the worker's global scope so the host is left with
  // an idle dedicated worker that can never answer again.
  Timer(const Duration(milliseconds: 100), () {
    try {
      _self.callMethod('close'.toJS);
    } catch (_) {
      // Already closing.
    }
  });
  return value;
}

@DwiTask()
String dieNow(String value) {
  // Close without answering: the pending call can only settle by timeout.
  _self.callMethod('close'.toJS);
  return value;
}

@DwiTask()
String sendGarbage(String value) {
  _self.callMethod('postMessage'.toJS, 'not-an-object'.toJS);
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(until)) {}
  return value;
}

@DwiTask()
DwiTransferableBytes echoBytes(DwiTransferableBytes input) => input;

@DwiTask()
DwiTransferableBytes makeBytes(int length) {
  final data = Uint8List(length)..fillRange(0, length, 7);
  return DwiTransferableBytes(data);
}

@DwiTask()
String startChannelEcho(String name) {
  final channel = DwiWorkerChannels.find(name);
  if (channel == null) return 'missing';
  channel.messages.listen(
    (message) => channel.send('echo:$message'),
    onError: (Object error, StackTrace stack) {},
  );
  return 'listening';
}

@DwiTask()
String announceChannel(String name) {
  final channel = DwiWorkerChannels.find(name);
  if (channel == null) return 'missing';
  channel.send('hello');
  return 'sent';
}
''';

const String handleMain = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

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
  if (error is DwiChannelStateException) return 'DwiChannelStateException';
  if (error is DwiChannelClosedException) return 'DwiChannelClosedException';
  if (error is DwiChannelBufferException) return 'DwiChannelBufferException';
  if (error is DwiTimeoutException) return 'DwiTimeoutException';
  if (error is DwiStartupException) return 'DwiStartupException';
  if (error is DwiUnknownTaskException) return 'DwiUnknownTaskException';
  if (error is DwiUnsupportedException) return 'DwiUnsupportedException';
  if (error is DwiSerializationException) return 'DwiSerializationException';
  if (error is DwiCancelledException) return 'DwiCancelledException';
  if (error is DwiRemoteException) return 'DwiRemoteException';
  return 'OTHER:${error.runtimeType}';
}

Future<String> _outcome(Future<Object?> future) async {
  try {
    return 'OK:${await future}';
  } catch (error) {
    return _classify(error);
  }
}

Future<String> _openOutcome(DwiWorker worker, String name) async {
  try {
    await worker.openChannel(name);
    return 'NO_ERROR';
  } catch (error) {
    return _classify(error);
  }
}

Future<String> _spawnOutcome() async {
  try {
    await DwiWorker.spawn();
    return 'NO_ERROR';
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
    result['aPoolBefore'] = await _outcome(Dwi.run<Object?>('echo', 'pool'));

    // ADR-016: runFresh never shares a context; the pool may reuse one worker.
    result['freshCount'] = <int>[
      await Dwi.runFresh<int>('count', 0),
      await Dwi.runFresh<int>('count', 0),
    ];
    result['poolCount'] = <int>[
      await Dwi.run<int>('count', 0),
      await Dwi.run<int>('count', 0),
    ];

    // A: retained state, isolated handles, typed healthy errors, close.
    final first = await DwiWorker.spawn();
    result['aState'] = first.state.name;
    result['aUsable'] = first.isUsable;
    result['aCount'] = <int>[
      await first.run<int>('count', 0),
      await first.run<int>('count', 0),
      await first.run<int>('count', 0),
    ];
    final second = await DwiWorker.spawn();
    result['aOtherCount'] = await second.run<int>('count', 0);
    result['aCountAfterOther'] = await first.run<int>('count', 0);
    result['aPoolDuring'] = await _outcome(Dwi.run<Object?>('echo', 'during'));

    result['aUnknown'] = await _outcome(first.run<Object?>('missing', null));
    result['aAfterUnknown'] = first.state.name;
    result['aRemote'] = await _outcome(first.run<Object?>('boom', 'x'));

    await second.close();
    await first.close();
    result['aClosed'] = first.state.name;
    result['aAfterClose'] = await _outcome(first.run<int>('count', 0));
    await first.close();
    result['aRepeatedClose'] = first.state.name;
    result['aPoolAfter'] = await _outcome(Dwi.run<Object?>('echo', 'after'));

    // B: close during a running call and a queued call.
    final b = await DwiWorker.spawn();
    final bRunning = b.run<String>('slow', 5000);
    final bQueued = b.run<String>('echo', 'queued');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    result['bRunningBefore'] = b.state.name;
    final bWatch = Stopwatch()..start();
    await b.close();
    result['bRunning'] = await _outcome(bRunning);
    result['bQueued'] = await _outcome(bQueued);
    result['bState'] = b.state.name;
    result['bMs'] = bWatch.elapsedMilliseconds;

    // C: timeout fails the handle, queued call settles, restart is fresh.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(milliseconds: 300),
        queueTimeout: Duration(seconds: 2),
      ),
    );
    final c = await DwiWorker.spawn();
    final cRunning = c.run<String>('spin', 3000);
    final cQueued = c.run<int>('count', 0);
    result['cRunning'] = await _outcome(cRunning);
    result['cQueued'] = await _outcome(cQueued);
    result['cState'] = c.state.name;
    result['cAfterFail'] = await _outcome(c.run<int>('count', 0));
    await c.restart();
    result['cRestartState'] = c.state.name;
    result['cFresh'] = await c.run<int>('count', 0);
    await c.close();

    // D: queued cancellation keeps the worker; running cancellation fails it.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    final d = await DwiWorker.spawn();
    final dRunning = d.run<String>('slow', 1000);
    final dQueued = d.runCancellable<int>('count', 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    result['dQueuedCancel'] = await dQueued.cancel();
    result['dQueuedResult'] = await _outcome(dQueued.result);
    result['dStateAfterQueued'] = d.state.name;
    result['dRunningValue'] = await _outcome(dRunning);

    final dRunningTask = d.runCancellable<String>('spin', 3000);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    result['dRunningCancel'] = await dRunningTask.cancel();
    result['dRunningResult'] = await _outcome(dRunningTask.result);
    result['dStateAfterRunning'] = d.state.name;
    result['dRepeatedCancel'] = await dRunningTask.cancel();
    await d.restart();
    result['dFresh'] = await d.run<int>('count', 0);
    await d.close();

    // E: transferable argument and result through a handle.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    final e = await DwiWorker.spawn();
    final eBytes = DwiTransferableBytes(Uint8List.fromList(<int>[1, 2, 3]));
    final echoed = await e.run<DwiTransferableBytes>('echoBytes', eBytes);
    result['eLength'] = echoed.lengthInBytes;
    result['eDetached'] = eBytes.isDetached;
    result['eFirst'] = echoed.bytes.first;
    final made = await e.run<DwiTransferableBytes>('makeBytes', 4);
    result['eMade'] = made.lengthInBytes;
    await e.close();

    // F: a missing worker script is a typed startup failure.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: 'missing/worker.dart.js',
        startupTimeout: Duration(milliseconds: 400),
      ),
    );
    result['fStartup'] = await _spawnOutcome();

    // G: a silently dead idle worker fails the handle by heartbeat, and a
    // restart starts with fresh state.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        heartbeatInterval: Duration(milliseconds: 150),
        heartbeatMisses: 1,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    final g = await DwiWorker.spawn();
    result['gFirst'] = await _outcome(g.run<Object?>('dieAfter', 'alive'));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    result['gState'] = g.state.name;
    result['gRun'] = await _outcome(g.run<int>('count', 0));
    await g.restart();
    result['gFresh'] = await g.run<int>('count', 0);
    await g.close();

    // H: a worker that dies with a call pending settles it by timeout.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(milliseconds: 400),
      ),
    );
    final h = await DwiWorker.spawn();
    result['hPending'] = await _outcome(h.run<Object?>('dieNow', 'x'));
    result['hState'] = h.state.name;
    await h.close();

    // I: a non-object message fails the handle.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    final i = await DwiWorker.spawn();
    result['iMalformed'] = await _outcome(i.run<Object?>('sendGarbage', 'x'));
    result['iState'] = i.state.name;
    await i.close();

    // J: repeated spawn/close cycles, with pool calls interleaved, all start
    // from fresh state.
    final stress = <int>[];
    final poolStress = <String>[];
    for (var k = 0; k < 10; k++) {
      final handle = await DwiWorker.spawn();
      stress.add(await handle.run<int>('count', 0));
      if (k % 3 == 0) {
        poolStress.add(await _outcome(Dwi.run<Object?>('echo', 'pool-$k')));
      }
      await handle.close();
    }
    result['jStress'] = stress;
    result['jPoolStress'] = poolStress;

    // K: the handle queue is bounded and a queued call has its own deadline.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(seconds: 5),
        queueTimeout: Duration(milliseconds: 150),
        maxQueuedTasks: 1,
      ),
    );
    final k = await DwiWorker.spawn();
    final kRunning = k.run<String>('slow', 400);
    final kQueued = k.run<int>('count', 0);
    result['kQueueFull'] = await _outcome(k.run<int>('count', 0));
    result['kQueued'] = await _outcome(kQueued);
    result['kState'] = k.state.name;
    result['kRunning'] = await _outcome(kRunning);
    await k.close();

    // L: Dwi.close() closes a live handle before releasing the pool.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    final l = await DwiWorker.spawn();
    result['lBefore'] = await _outcome(l.run<int>('count', 0));
    await Dwi.close();
    result['lState'] = l.state.name;
    result['lAfter'] = await _outcome(l.run<int>('count', 0));

    // M: channels carry worker-initiated messages, host messages, a bounded
    // window and a clean close (ADR-014).
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        taskTimeout: Duration(seconds: 5),
        channelBufferSize: 1,
      ),
    );
    final m = await DwiWorker.spawn();
    final chat = await m.openChannel('chat');
    result['mName'] = chat.name;
    final mReceived = <Object?>[];
    chat.messages.listen(
      mReceived.add,
      onError: (Object error, StackTrace stack) {
        mReceived.add('ERR:$error');
      },
    );
    result['mEchoStart'] =
        await _outcome(m.run<Object?>('startChannelEcho', 'chat'));
    result['mSend'] = await _outcome(chat.send('ping'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    result['mEcho'] = mReceived.whereType<String>().toList();
    result['mAnnounce'] =
        await _outcome(m.run<Object?>('announceChannel', 'chat'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    result['mHello'] = mReceived.contains('hello');
    result['mDuplicate'] = await _openOutcome(m, 'chat');
    await chat.close();
    result['mAfterClose'] = await _outcome(chat.send('x'));

    final again = await m.openChannel('chat');
    result['mReopen'] = again.name;
    await again.close();

    final raw = await m.openChannel('raw');
    result['mRawFirst'] = await _outcome(raw.send('a'));
    result['mRawSecond'] = await _outcome(raw.send('b'));
    await raw.close();
    result['mState'] = m.state.name;
    await m.close();

    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  }
  _finish(result);
}
''';

const String handleIndex = '''
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
    project.write('lib/tasks.dart', handleTasks);
    project.write('web/main.dart', handleMain);
    project.write('web/index.html', handleIndex);

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

    server = await serveDirectory(p.join(project.root.path, 'web'));
    url = 'http://127.0.0.1:${server.port}/index.html';
  });

  tearDownAll(() async {
    await server.close(force: true);
    project.dispose();
  });

  for (final engine in BrowserEngine.values) {
    test(
      'handle lifecycle contract in ${engine.name}',
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

        for (var run = 1; run <= 3; run++) {
          Map<String, dynamic>? decoded;
          Object? lastError;
          // Retry a transport-level failure once before classifying it.
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
      // Four engines × three page loads is heavy; under a parallel `dart test`
      // run a slow engine can otherwise exhaust the budget.
      timeout: const Timeout(Duration(minutes: 12)),
    );
  }
}

/// The assertions every engine must satisfy, unchanged across engines.
void _expectContract(Map<String, dynamic> decoded) {
  expect(
    decoded['ok'],
    isTrue,
    reason: '${decoded['error']}\n${decoded['stack']}',
  );

  // A: identity, retained state, isolated handles, healthy errors.
  expect(decoded['aPoolBefore'], 'OK:pool');
  // ADR-016: fresh contexts never share worker-local state; the pool may reuse
  // one worker, so its counter advances across calls.
  expect(decoded['freshCount'], <int>[1, 1]);
  expect(decoded['poolCount'], <int>[1, 2]);
  expect(decoded['aState'], 'ready');
  expect(decoded['aUsable'], isTrue);
  expect(decoded['aCount'], <int>[1, 2, 3]);
  expect(decoded['aOtherCount'], 1);
  expect(decoded['aCountAfterOther'], 4);
  expect(decoded['aPoolDuring'], 'OK:during');
  expect(decoded['aUnknown'], 'DwiUnknownTaskException');
  expect(decoded['aAfterUnknown'], 'ready');
  expect(decoded['aRemote'], 'DwiRemoteException');
  expect(decoded['aClosed'], 'closed');
  expect(decoded['aAfterClose'], 'DwiWorkerClosedException');
  expect(decoded['aRepeatedClose'], 'closed');
  expect(decoded['aPoolAfter'], 'OK:after');

  // B: close settles running and queued callers promptly.
  expect(decoded['bRunningBefore'], 'ready');
  expect(decoded['bRunning'], 'DwiWorkerClosedException');
  expect(decoded['bQueued'], 'DwiWorkerClosedException');
  expect(decoded['bState'], 'closed');
  expect(decoded['bMs'], lessThan(2000));

  // C: timeout fails the handle, the queue settles, restart is fresh.
  expect(decoded['cRunning'], 'DwiTimeoutException');
  expect(decoded['cQueued'], 'DwiWorkerFailedException');
  expect(decoded['cState'], 'failed');
  expect(decoded['cAfterFail'], 'DwiWorkerFailedException');
  expect(decoded['cRestartState'], 'ready');
  expect(decoded['cFresh'], 1);

  // D: cancellation semantics.
  expect(decoded['dQueuedCancel'], isTrue);
  expect(decoded['dQueuedResult'], 'DwiCancelledException');
  expect(decoded['dStateAfterQueued'], 'ready');
  expect(decoded['dRunningValue'], 'OK:slow');
  expect(decoded['dRunningCancel'], isTrue);
  expect(decoded['dRunningResult'], 'DwiCancelledException');
  expect(decoded['dStateAfterRunning'], 'failed');
  expect(decoded['dRepeatedCancel'], isFalse);
  expect(decoded['dFresh'], 1);

  // E: transferables stay one-way and detach the sender.
  expect(decoded['eLength'], 3);
  expect(decoded['eDetached'], isTrue);
  expect(decoded['eFirst'], 1);
  expect(decoded['eMade'], 4);

  // F/H/I: every failure is typed and settles.
  expect(decoded['fStartup'], 'DwiStartupException');
  expect(decoded['hPending'], 'DwiTimeoutException');
  expect(decoded['hState'], 'failed');
  expect(decoded['iMalformed'], 'DwiWorkerFailedException');
  expect(decoded['iState'], 'failed');

  // G: heartbeat detects a silently dead idle worker.
  expect(decoded['gFirst'], 'OK:alive');
  expect(decoded['gState'], 'failed');
  expect(decoded['gRun'], 'DwiWorkerFailedException');
  expect(decoded['gFresh'], 1);

  // J: repeated spawn/close always starts from fresh state, and the pool keeps
  // working alongside dedicated handles.
  expect(decoded['jStress'], <int>[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]);
  expect(decoded['jPoolStress'], <String>['OK:pool-0', 'OK:pool-3', 'OK:pool-6', 'OK:pool-9']);

  // K: bounded queue and caller-local queue deadline.
  expect(decoded['kQueueFull'], 'DwiUnsupportedException');
  expect(decoded['kQueued'], 'DwiTimeoutException');
  expect(decoded['kState'], 'ready');
  expect(decoded['kRunning'], 'OK:slow');

  // L: Dwi.close() owns live handles.
  expect(decoded['lBefore'], 'OK:1');
  expect(decoded['lState'], 'closed');
  expect(decoded['lAfter'], 'DwiWorkerClosedException');

  // M: channels (ADR-014).
  expect(decoded['mName'], 'chat');
  expect(decoded['mEchoStart'], 'OK:listening');
  expect(decoded['mSend'], 'OK:null');
  expect(decoded['mEcho'], contains('echo:ping'));
  expect(decoded['mAnnounce'], 'OK:sent');
  expect(decoded['mHello'], isTrue);
  expect(decoded['mDuplicate'], 'DwiChannelStateException');
  expect(decoded['mAfterClose'], 'DwiChannelClosedException');
  expect(decoded['mReopen'], 'chat');
  expect(decoded['mRawFirst'], 'OK:null');
  expect(decoded['mRawSecond'], 'DwiChannelBufferException');
  expect(decoded['mState'], 'ready');
}

/// Records one blocked engine with its exact reason (AGENTS.md rule 8).
Future<void> _recordBlocked(BrowserEngine engine, String reason) async {
  await _writeEvidence(engine, <String, Object?>{
    'engine': engine.name,
    'status': 'blocked',
    'reason': reason,
  });
}

/// Records the per-run outcome for [engine] when evidence is requested.
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
    'harness': 'packages/dwi_builder/test/browser_handle_test.dart',
    'command':
        'dart test test/browser_handle_test.dart --plain-name '
            '"handle lifecycle contract in ${engine.name}"',
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
    p.join(directory, 'handle-matrix-${engine.name}-$stamp.json'),
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
}
