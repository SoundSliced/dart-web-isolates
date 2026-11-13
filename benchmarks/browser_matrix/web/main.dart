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

    await Dwi.close();
    result['status'] = 'ok';
  } catch (error, stack) {
    result['status'] = 'error';
    result['error'] = error.toString();
    result['stack'] = stack.toString();
  }
  _finish(result);
}
