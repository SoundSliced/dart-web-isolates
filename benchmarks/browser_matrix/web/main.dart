// Browser stress and benchmark page for DWI.
//
// The page measures one engine and writes a base64 JSON blob into
// `document.title`, which `run.dart` reads back. Every measurement uses the
// public DWI API only, so the harness measures the shipped runtime.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dwi/dwi.dart';
import 'package:dwi_browser_matrix/tasks.dart';

/// One workload: the worker call and the same work on the main thread.
class _Case {
  const _Case(this.name, this.viaDwi, this.local);

  final String name;
  final Future<int> Function() viaDwi;
  final int Function() local;
}

/// Deterministic bytes from a small modular generator. Every intermediate value
/// stays far below 2^53, so the bytes are identical on dart2js and the VM.
Uint8List _pseudoBytes(int length, int seed) {
  final out = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state = (state * 75 + 74) % 65537;
    out[i] = state % 256;
  }
  return out;
}

const String workerScript = 'dwi/worker.dart.js';

@JS('document')
external JSObject get _document;

@JS('navigator')
external JSObject get _navigator;

void main() {
  unawaited(_run());
}

void _finish(Map<String, Object?> result) {
  _document.setProperty(
    'title'.toJS,
    base64Encode(utf8.encode(jsonEncode(result))).toJS,
  );
}

@JS('performance')
external JSObject get _performance;

int? _heapBytes() {
  try {
    final memory = _performance.getProperty('memory'.toJS);
    if (memory == null) return null;
    final used = (memory as JSObject).getProperty('usedJSHeapSize'.toJS);
    return (used as JSNumber?)?.toDartDouble.toInt();
  } catch (_) {
    return null;
  }
}

Object? _navigatorValue(String property) {
  try {
    return _navigator.getProperty(property.toJS)?.dartify();
  } catch (_) {
    return null;
  }
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = List<double>.of(values)..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return (sorted[middle - 1] + sorted[middle]) / 2;
}

Future<void> _settle(Future<Object?> future) async {
  try {
    await future;
  } catch (_) {
    // The measurement is about latency, not the outcome.
  }
}

Future<void> _run() async {
  final result = <String, Object?>{};
  try {
    result['userAgent'] = _navigatorValue('userAgent');
    result['hardwareConcurrency'] = _navigatorValue('hardwareConcurrency');
    result['baseUri'] = Uri.base.toString();

    // A: cold start — the first call pays worker spawn and protocol ready.
    // maxPayloadBytes is raised from the 64 MiB default so the 100 MiB case can
    // run; every other phase uses this same configuration.
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxPayloadBytes: 128 * 1024 * 1024,
      ),
    );
    final cold = Stopwatch()..start();
    await Dwi.run<int>('tiny', 1);
    result['coldStartMs'] = cold.elapsedMilliseconds;

    // B: warm dispatch — sequential round trips on a live worker.
    final warm = <double>[];
    for (var i = 0; i < 50; i++) {
      final watch = Stopwatch()..start();
      await Dwi.run<int>('tiny', i);
      warm.add(watch.elapsedMicroseconds / 1000);
    }
    result['warmDispatch'] = <String, Object?>{
      'samplesMs': warm,
      'medianMs': _median(warm),
    };

    // C: copying versus transfer at three payload sizes.
    const sizes = <String, int>{
      '1KiB': 1024,
      '100KiB': 100 * 1024,
      '64KiB': 64 * 1024,
      '1MiB': 1024 * 1024,
      '8MiB': 8 * 1024 * 1024,
      '10MiB': 10 * 1024 * 1024,
      '100MiB': 100 * 1024 * 1024,
    };
    for (final entry in sizes.entries) {
      final length = entry.value;
      final copySamples = <double>[];
      final data = Uint8List(length)..fillRange(0, length, 7);
      for (var i = 0; i < 7; i++) {
        final watch = Stopwatch()..start();
        final sum = await Dwi.run<int>('sumTyped', data);
        copySamples.add(watch.elapsedMicroseconds / 1000);
        if (sum != length * 7) {
          throw StateError('copy checksum mismatch at $length bytes');
        }
      }
      final transferSamples = <double>[];
      for (var i = 0; i < 7; i++) {
        final bytes = DwiTransferableBytes(
          Uint8List(length)..fillRange(0, length, 7),
        );
        final watch = Stopwatch()..start();
        final sum = await Dwi.run<int>('sumTransferable', bytes);
        transferSamples.add(watch.elapsedMicroseconds / 1000);
        if (sum != length * 7) {
          throw StateError('transfer checksum mismatch at $length bytes');
        }
        if (!bytes.isDetached) {
          throw StateError('transfer did not detach the sender at $length');
        }
      }
      result['transfer_${entry.key}'] = <String, Object?>{
        'bytes': length,
        'copySamplesMs': copySamples,
        'copyMedianMs': _median(copySamples),
        'transferSamplesMs': transferSamples,
        'transferMedianMs': _median(transferSamples),
      };
    }

    // D: cancellation latency — queued and running.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 1,
        maxQueuedTasks: 4,
      ),
    );
    final queuedSamples = <double>[];
    final runningSamples = <double>[];
    for (var i = 0; i < 5; i++) {
      final blocker = Dwi.runCancellable<String>('slow', 300);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final waiting = Dwi.runCancellable<String>('echo', 'queued');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final queuedWatch = Stopwatch()..start();
      final queuedCancelled = await waiting.cancel();
      await _settle(waiting.result);
      queuedSamples.add(queuedWatch.elapsedMicroseconds / 1000);
      if (!queuedCancelled) {
        throw StateError('queued cancellation was not honoured');
      }
      await _settle(blocker.result);

      final running = Dwi.runCancellable<String>('spin', 3000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final runningWatch = Stopwatch()..start();
      final runningCancelled = await running.cancel();
      await _settle(running.result);
      runningSamples.add(runningWatch.elapsedMicroseconds / 1000);
      if (!runningCancelled) {
        throw StateError('running cancellation was not honoured');
      }
    }
    result['cancelQueued'] = <String, Object?>{
      'samplesMs': queuedSamples,
      'medianMs': _median(queuedSamples),
    };
    result['cancelRunning'] = <String, Object?>{
      'samplesMs': runningSamples,
      'medianMs': _median(runningSamples),
    };

    // E: sustained load — 100 calls through a bounded pool.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 4,
        maxQueuedTasks: 128,
      ),
    );
    final loadWatch = Stopwatch()..start();
    final values = await Future.wait(<Future<int>>[
      for (var i = 0; i < 100; i++) Dwi.run<int>('tiny', i),
    ]);
    result['sustained'] = <String, Object?>{
      'tasks': 100,
      'settled': values.length,
      'totalMs': loadWatch.elapsedMilliseconds,
      'workers': (await Dwi.capabilities()).workerCount,
      'correct': values.indexed.every((pair) => pair.$2 == pair.$1 + 1),
    };

    // E2: 1,000-task burst through the same bounded pool.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 4,
        maxQueuedTasks: 1024,
      ),
    );
    final burstWatch = Stopwatch()..start();
    final burstValues = await Future.wait(<Future<int>>[
      for (var i = 0; i < 1000; i++) Dwi.run<int>('tiny', i),
    ]);
    result['burst1000'] = <String, Object?>{
      'tasks': 1000,
      'settled': burstValues.length,
      'totalMs': burstWatch.elapsedMilliseconds,
      'workers': (await Dwi.capabilities()).workerCount,
      'correct': burstValues.indexed.every((pair) => pair.$2 == pair.$1 + 1),
    };

    // E3: sustained leak check — 20 rounds of 100 calls on one pool. Main-thread
    // heap is read where the engine exposes performance.memory (Chromium only);
    // other engines record null, never an estimate.
    final heapStart = _heapBytes();
    final roundMs = <int>[];
    var leakCorrect = true;
    for (var round = 0; round < 20; round++) {
      final watch = Stopwatch()..start();
      final values = await Future.wait(<Future<int>>[
        for (var i = 0; i < 100; i++) Dwi.run<int>('tiny', i),
      ]);
      roundMs.add(watch.elapsedMilliseconds);
      if (!values.indexed.every((pair) => pair.$2 == pair.$1 + 1)) {
        leakCorrect = false;
      }
    }
    result['leak'] = <String, Object?>{
      'rounds': 20,
      'tasksPerRound': 100,
      'correct': leakCorrect,
      'roundMs': roundMs,
      'heapStartBytes': heapStart,
      'heapEndBytes': _heapBytes(),
      'workers': (await Dwi.capabilities()).workerCount,
    };

    // F: crash and restart — an idle worker that dies without an error event.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 1,
        heartbeatInterval: Duration(milliseconds: 200),
        heartbeatMisses: 2,
        taskTimeout: Duration(seconds: 5),
      ),
    );
    result['crashFirst'] = await Dwi.run<String>('dieAfter', 'alive');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final restartWatch = Stopwatch()..start();
    result['crashNext'] = await Dwi.run<String>('echo', 'next');
    result['crashNextMs'] = restartWatch.elapsedMilliseconds;
    result['crashWorkers'] = (await Dwi.capabilities()).workerCount;

    // G: UI responsiveness — timer ticks while a worker spins, with a
    // main-thread spin as the control.
    var workerTicks = 0;
    final workerTimer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => workerTicks++,
    );
    await Dwi.run<String>('spin', 300);
    workerTimer.cancel();
    result['uiTicksDuringWorkerCpu'] = workerTicks;

    var localTicks = 0;
    final localTimer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => localTicks++,
    );
    final until = DateTime.now().add(const Duration(milliseconds: 300));
    while (DateTime.now().isBefore(until)) {}
    localTimer.cancel();
    result['uiTicksDuringLocalCpu'] = localTicks;

    // H: late reply after cancellation (A4). A grace period keeps the worker
    // alive while the cancelled task finishes, so its reply arrives after the
    // caller settled. The next call must still get its own result.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 1,
        maxQueuedTasks: 4,
        cancelGracePeriod: Duration(milliseconds: 500),
      ),
    );
    final late = Dwi.runCancellable<String>('ignoreCancel', 300);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final lateCancelled = await late.cancel();
    await _settle(late.result);
    final afterLate = await Dwi.run<int>('tiny', 5);
    result['lateReply'] = <String, Object?>{
      'cancelled': lateCancelled,
      'nextValue': afterLate,
      'correct': lateCancelled && afterLate == 6,
    };

    // I: workloads (A6). Each runs on the worker and on the main thread with
    // the same input; every checksum must match.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 1,
        maxQueuedTasks: 4,
      ),
    );
    final bytes = _pseudoBytes(256 * 1024, 1);
    final rleInput = Uint8List.fromList(
      List<int>.generate(256 * 1024, (i) => (i ~/ 37) % 4),
    );
    final pixels = _pseudoBytes(blurWidth * blurWidth, 2);
    final jsonText = jsonEncode(<Map<String, Object?>>[
      for (var i = 0; i < 2000; i++)
        <String, Object?>{
          'id': i,
          'v': i * 7 % 1000,
          'tags': <int>[i % 5, i % 3],
        },
    ]);
    final cases = <_Case>[
      _Case(
        'sortChecksum',
        () => Dwi.run<int>('sortChecksum', bytes),
        () => sortChecksum(bytes),
      ),
      _Case(
        'jsonChecksum',
        () => Dwi.run<int>('jsonChecksum', jsonText),
        () => jsonChecksum(jsonText),
      ),
      _Case(
        'adler32',
        () => Dwi.run<int>('adler32', bytes),
        () => adler32(bytes),
      ),
      _Case(
        'rleSize',
        () => Dwi.run<int>('rleSize', rleInput),
        () => rleSize(rleInput),
      ),
      _Case(
        'boxBlurSum',
        () => Dwi.run<int>('boxBlurSum', pixels),
        () => boxBlurSum(pixels),
      ),
    ];
    final workloads = <String, Object?>{};
    for (final c in cases) {
      await c.viaDwi(); // warm-up, unmeasured
      final dwiMs = <double>[];
      final localMs = <double>[];
      var dwiValue = 0;
      var localValue = 0;
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        dwiValue = await c.viaDwi();
        dwiMs.add(watch.elapsedMicroseconds / 1000);
      }
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        localValue = c.local();
        localMs.add(watch.elapsedMicroseconds / 1000);
      }
      workloads[c.name] = <String, Object?>{
        'dwiMedianMs': _median(dwiMs),
        'localMedianMs': _median(localMs),
        'checksum': dwiValue,
        'correct': dwiValue == localValue,
      };
    }
    result['workloads'] = workloads;

    // J: pool sizing (A10). 200 tasks of 5 ms each through maxWorkers 1, 2, 4
    // and 8. Only the makespan is recorded; all results are checked.
    final sizing = <String, Object?>{};
    for (final workers in const <int>[1, 2, 4, 8]) {
      await Dwi.close();
      await Dwi.configure(
        DwiConfig(
          workerScript: workerScript,
          maxWorkers: workers,
          maxQueuedTasks: 1024,
        ),
      );
      final makespans = <double>[];
      var allCorrect = true;
      for (var rep = 0; rep < 3; rep++) {
        final watch = Stopwatch()..start();
        final values = await Future.wait(<Future<String>>[
          for (var i = 0; i < 200; i++) Dwi.run<String>('spin', 5),
        ]);
        makespans.add(watch.elapsedMicroseconds / 1000);
        allCorrect = allCorrect && values.every((v) => v == 'spun');
      }
      sizing['$workers'] = <String, Object?>{
        'makespanMs': makespans,
        'medianMs': _median(makespans),
        'correct': allCorrect,
      };
    }
    result['poolSizing'] = sizing;

    // K: metrics and pool state on the web backend (ADR-026 G1, G2). A small
    // pool, 20 calls, one failing call, then a busy snapshot and an idle one.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 2,
        maxQueuedTasks: 32,
        metrics: true,
      ),
    );
    final beforeCalls = Dwi.metrics();
    final kValues = await Future.wait(<Future<int>>[
      for (var i = 0; i < 20; i++) Dwi.run<int>('tiny', i),
    ]);
    var unknownFailed = false;
    try {
      await Dwi.run<Object?>('noSuchTask');
    } catch (_) {
      unknownFailed = true;
    }
    final afterCalls = Dwi.metrics();
    final spinning = Dwi.run<String>('spin', 200);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final busyPool = Dwi.poolState();
    await spinning;
    final idlePool = Dwi.poolState();
    result['metricsWeb'] = <String, Object?>{
      'started': afterCalls.callsStarted - beforeCalls.callsStarted,
      'completed': afterCalls.callsCompleted - beforeCalls.callsCompleted,
      'failed': afterCalls.callsFailed - beforeCalls.callsFailed,
      'correct':
          kValues.indexed.every((pair) => pair.$2 == pair.$1 + 1) &&
          unknownFailed,
      'maxWorkers': busyPool.maxWorkers,
      'busyWorkersDuringSpin': busyPool.workers.where((w) => w.busy).length,
      'workersDuringSpin': busyPool.workers.length,
      'queuedDuringSpin': busyPool.queued,
      'busyWorkersIdle': idlePool.workers.where((w) => w.busy).length,
      'workersIdle': idlePool.workers.length,
    };

    // L: worker-use strategies (ADR-026 G6). 200 units of 2 ms work, split three
    // ways: a shared pool of 4 workers (200 calls), chunks of 50 on that pool
    // (4 calls), and one worker running all 200 units in a single call. Per-task
    // fresh workers (runFresh) are measured on 50 units only, because spawning
    // 200 workers is far slower; their figure is per call, not comparable as a
    // makespan.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: workerScript,
        maxWorkers: 4,
        maxQueuedTasks: 1024,
      ),
    );
    final strategies = <String, Object?>{};
    Future<double> timed(Future<Object?> Function() body) async {
      final watch = Stopwatch()..start();
      await body();
      return watch.elapsedMicroseconds / 1000;
    }

    strategies['pool200Calls'] = <String, Object?>{
      'units': 200,
      'calls': 200,
      'makespanMs': await timed(
        () => Future.wait(<Future<String>>[
          for (var i = 0; i < 200; i++) Dwi.run<String>('spinBatch', 1),
        ]),
      ),
    };
    strategies['pool4Chunks'] = <String, Object?>{
      'units': 200,
      'calls': 4,
      'makespanMs': await timed(
        () => Future.wait(<Future<String>>[
          for (var i = 0; i < 4; i++) Dwi.run<String>('spinBatch', 50),
        ]),
      ),
    };
    strategies['singleWorkerOneCall'] = <String, Object?>{
      'units': 200,
      'calls': 1,
      'makespanMs': await timed(() => Dwi.run<String>('spinBatch', 200)),
    };
    final freshMs = await timed(
      () => Future.wait(<Future<String>>[
        for (var i = 0; i < 50; i++) Dwi.runFresh<String>('spinBatch', 1),
      ]),
    );
    strategies['freshWorkerPerTask'] = <String, Object?>{
      'units': 50,
      'calls': 50,
      'makespanMs': freshMs,
    };
    result['strategies'] = strategies;

    // M: G3 end to end. Loads a worker whose ready message reports another
    // protocol version. The probe serves a patched copy under dwi-mismatch/ in
    // one run; in the unpatched root the file is missing and the message says so.
    await Dwi.close();
    await Dwi.configure(
      const DwiConfig(
        workerScript: 'dwi-mismatch/worker.dart.js',
        maxWorkers: 1,
      ),
    );
    String protocolMessage;
    try {
      await Dwi.run<int>('tiny', 1);
      protocolMessage = 'no error';
    } catch (error) {
      protocolMessage = error.toString();
    }
    result['protocolMismatch'] = <String, Object?>{'message': protocolMessage};

    await Dwi.close();
    result['status'] = 'ok';
  } catch (error, stack) {
    result['status'] = 'error';
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  }
  _finish(result);
}
