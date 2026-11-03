import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:web/web.dart' as web;

import 'src/primes.dart';

void main() {
  runApp(const DwiPocApp());
}

class DwiPocApp extends StatelessWidget {
  const DwiPocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DWI — M001',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F51B5),
        useMaterial3: true,
      ),
      home: const PocHomePage(),
    );
  }
}

/// One measured execution of the CPU task.
class RunResult {
  const RunResult({
    required this.mode,
    required this.primes,
    required this.taskMs,
    required this.framesDuring,
    required this.droppedFrames,
    required this.worstFrameMs,
    this.startupMs,
    this.messageMs,
    this.error,
  });

  final String mode;
  final int primes;
  final double taskMs;
  final int framesDuring;
  final int droppedFrames;
  final double worstFrameMs;
  final double? startupMs;
  final double? messageMs;
  final String? error;
}

class PocHomePage extends StatefulWidget {
  const PocHomePage({super.key});

  @override
  State<PocHomePage> createState() => _PocHomePageState();
}

class _PocHomePageState extends State<PocHomePage>
    with SingleTickerProviderStateMixin {
  static const int _taskLimit = 5000000;
  static const int _taskRounds = 40;

  late final AnimationController _animation;
  late final Ticker _ticker;
  int _tickerCount = 0;

  double _worstSinceTask = 0;
  int _taskStartTick = 0;
  int _snapshotFrames = 0;
  bool _measuring = false;

  int _totalFrames = 0;
  int _totalJanky = 0;
  double _lastFrameMs = 0;

  RunResult? _mainResult;
  RunResult? _workerResult;
  RunResult? _lastResult;
  bool _busy = false;
  String _status = 'idle';
  Map<String, Object?>? _errorProbe;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _ticker = createTicker((_) {
      _tickerCount++;
      if (mounted) setState(() {});
    })..start();
    if (Uri.base.queryParameters['auto'] == '1') {
      unawaited(_runAuto());
    }
  }

  /// Self-driving mode used by headless measurement runs.
  Future<void> _runAuto() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    await _runOnWorker();
    _errorProbe = await _probeWorkerError();
    await Future<void>.delayed(const Duration(seconds: 1));
    await _runOnMainThread();
    await Future<void>.delayed(const Duration(seconds: 1));
    await _postResults();
  }

  /// Sends an unknown operation and verifies the worker returns a typed error
  /// envelope instead of failing silently.
  Future<Map<String, Object?>> _probeWorkerError() async {
    web.Worker? worker;
    try {
      worker = web.Worker('dwi/worker.dart.js?v=2'.toJS);
      final ready = Completer<void>();
      final error = Completer<String>();
      worker.onmessage = ((web.MessageEvent event) {
        final data = (event.data as JSObject?)?.dartify();
        if (data is! Map) return;
        if (data['type'] == 'ready' && !ready.isCompleted) ready.complete();
        if (data['type'] == 'error' && !error.isCompleted) {
          error.complete('${data['message']}');
        }
      }).toJS;
      await ready.future.timeout(const Duration(seconds: 10));
      worker.postMessage(<String, Object?>{'op': 'nope', 'id': 1}.jsify());
      final message = await error.future.timeout(const Duration(seconds: 5));
      return <String, Object?>{'propagated': true, 'message': message};
    } catch (error) {
      return <String, Object?>{'propagated': false, 'message': '$error'};
    } finally {
      worker?.terminate();
    }
  }

  Map<String, Object?>? _resultJson(RunResult? result) {
    if (result == null) return null;
    return <String, Object?>{
      'mode': result.mode,
      'primes': result.primes,
      'taskMs': result.taskMs,
      'framesDuring': result.framesDuring,
      'droppedFrames': result.droppedFrames,
      'worstFrameMs': result.worstFrameMs,
      'startupMs': result.startupMs,
      'messageMs': result.messageMs,
      'error': result.error,
    };
  }

  Future<void> _postResults() async {
    final payload = <String, Object?>{
      'userAgent': web.window.navigator.userAgent,
      'hardwareConcurrency': web.window.navigator.hardwareConcurrency,
      'taskLimit': _taskLimit,
      'taskRounds': _taskRounds,
      'main': _resultJson(_mainResult),
      'worker': _resultJson(_workerResult),
      'workerErrorProbe': _errorProbe,
    };
    final body = jsonEncode(payload);
    await web.window
        .fetch(
          '/result'.toJS,
          web.RequestInit(method: 'POST', body: body.toJS),
        )
        .toDart;
    _status = 'auto: results posted';
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    _animation.dispose();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final totalMs = timing.totalSpan.inMicroseconds / 1000.0;
      _lastFrameMs = totalMs;
      _totalFrames++;
      if (totalMs > 1000 / 60) {
        _totalJanky++;
      }
      if (_measuring && totalMs > _worstSinceTask) {
        _worstSinceTask = totalMs;
      }
    }
  }

  Future<void> _runOnMainThread() async {
    setState(() {
      _busy = true;
      _status = 'main: starting';
      _lastResult = null;
    });
    _beginMeasurement();
    final stopwatch = Stopwatch()..start();
    var count = 0;
    for (var round = 0; round < _taskRounds; round++) {
      count = countPrimes(_taskLimit);
    }
    stopwatch.stop();
    _snapshotTicker();
    if (mounted) {
      setState(() =>
          _status = 'main: computed in ${stopwatch.elapsedMilliseconds} ms');
    }
    // Let the frame timings for the blocked period arrive before finalising.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final result = _finishMeasurement('main thread', count, stopwatch.elapsed);
    if (!mounted) return;
    setState(() {
      _mainResult = result;
      _lastResult = result;
      _busy = false;
      _status = 'main: done';
    });
  }

  Future<void> _runOnWorker() async {
    setState(() {
      _busy = true;
      _status = 'worker: starting';
      _lastResult = null;
    });
    _beginMeasurement();

    web.Worker? worker;
    final total = Stopwatch()..start();
    try {
      final startup = Stopwatch()..start();
      worker = web.Worker('dwi/worker.dart.js?v=2'.toJS);
      final ready = Completer<void>();

      late final JSFunction onMessage;
      onMessage = ((web.MessageEvent event) {
        final data = (event.data as JSObject?)?.dartify();
        if (data is! Map) return;
        final type = data['type'];
        if (type == 'ready' && !ready.isCompleted) {
          ready.complete();
        }
      }).toJS;
      worker.onmessage = onMessage;
      if (mounted) setState(() => _status = 'worker: constructed, awaiting ready');

      final errorEvent = Completer<Object?>();
      worker.onerror = ((web.ErrorEvent event) {
        final message = event.message;
        if (!ready.isCompleted) {
          ready.completeError(StateError('worker failed: $message'));
        }
        if (!errorEvent.isCompleted) errorEvent.complete(message);
      }).toJS;

      await ready.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('worker did not become ready'),
      );
      startup.stop();
      if (mounted) setState(() => _status = 'worker: ready, sending task');
      final startupMs = startup.elapsedMicroseconds / 1000.0;

      final id = DateTime.now().microsecondsSinceEpoch;
      final response = Completer<Map<Object?, Object?>>();
      worker.onmessage = ((web.MessageEvent event) {
        final data = (event.data as JSObject?)?.dartify();
        if (data is! Map) return;
        if (data['type'] == 'result' && data['id'] == id) {
          if (!response.isCompleted) {
            response.complete(Map<Object?, Object?>.from(data));
          }
        }
      }).toJS;

      final messageStopwatch = Stopwatch()..start();
      worker.postMessage(<String, Object?>{
        'op': 'primes',
        'id': id,
        'n': _taskLimit,
        'rounds': _taskRounds,
      }.jsify());
      final payload = await response.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('worker task did not finish'),
      );
      messageStopwatch.stop();
      total.stop();
      _snapshotTicker();

      await Future<void>.delayed(const Duration(milliseconds: 400));
      final result = _finishMeasurement(
        'dwi worker',
        payload['count'] as int,
        total.elapsed,
        startupMs: startupMs,
        messageMs: messageStopwatch.elapsedMicroseconds / 1000.0,
      );
      if (!mounted) return;
      setState(() {
        _workerResult = result;
        _lastResult = result;
        _busy = false;
      });
    } catch (error) {
      total.stop();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final result = _finishMeasurement(
        'dwi worker',
        0,
        total.elapsed,
        error: '$error',
      );
      if (!mounted) return;
      setState(() {
        _workerResult = result;
        _lastResult = result;
        _busy = false;
      });
    } finally {
      worker?.terminate();
    }
  }

  void _beginMeasurement() {
    _worstSinceTask = 0;
    _taskStartTick = _tickerCount;
    _snapshotFrames = 0;
    _measuring = true;
  }

  void _snapshotTicker() {
    _snapshotFrames = _tickerCount - _taskStartTick;
  }

  RunResult _finishMeasurement(
    String mode,
    int primes,
    Duration elapsed, {
    double? startupMs,
    double? messageMs,
    String? error,
  }) {
    _measuring = false;
    final taskMs = elapsed.inMicroseconds / 1000.0;
    final expectedFrames = (taskMs / (1000 / 60)).floor();
    final dropped = expectedFrames > _snapshotFrames
        ? expectedFrames - _snapshotFrames
        : 0;
    return RunResult(
      mode: mode,
      primes: primes,
      taskMs: taskMs,
      framesDuring: _snapshotFrames,
      droppedFrames: dropped,
      worstFrameMs: _worstSinceTask,
      startupMs: startupMs,
      messageMs: messageMs,
      error: error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fps = _lastFrameMs <= 0
        ? 0.0
        : (1000 / _lastFrameMs).clamp(0, 999).toDouble();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dart Web Isolates — M001'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: Text('Dart-in-Worker proof')),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AnimatingBanner(animation: _animation),
                const SizedBox(height: 16),
                _LiveFrameStats(
                  fps: fps,
                  totalFrames: _totalFrames,
                  totalJanky: _totalJanky,
                  lastFrameMs: _lastFrameMs,
                ),
                const SizedBox(height: 24),
                Text(
                  'CPU task: count primes below '
                  '${_taskLimit.toString()} (sieve, single thread).',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _runOnMainThread,
                        icon: const Icon(Icons.memory),
                        label: const Text('RUN ON MAIN THREAD'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _runOnWorker,
                        icon: const Icon(Icons.hub),
                        label: const Text('RUN ON DWI WORKER'),
                      ),
                    ),
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 4),
                  Text(_status, style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: 24),
                if (_lastResult != null) _ResultCard(result: _lastResult!),
                const SizedBox(height: 24),
                _ComparisonTable(main: _mainResult, worker: _workerResult),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatingBanner extends StatelessWidget {
  const _AnimatingBanner({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 96,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              final travel = constraints.maxWidth - 48;
              final x = Curves.easeInOut.transform(animation.value) * travel;
              return Stack(
                children: [
                  Positioned(
                    left: x,
                    top: 24,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.directions_run, color: Colors.white),
                    ),
                  ),
                  const Positioned(
                    left: 16,
                    bottom: 10,
                    child: Text('This animation must stay smooth during the task.'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _LiveFrameStats extends StatelessWidget {
  const _LiveFrameStats({
    required this.fps,
    required this.totalFrames,
    required this.totalJanky,
    required this.lastFrameMs,
  });

  final double fps;
  final int totalFrames;
  final int totalJanky;
  final double lastFrameMs;

  @override
  Widget build(BuildContext context) {
    final jankPercent =
        totalFrames == 0 ? 0.0 : (totalJanky * 100 / totalFrames);
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: [
        _Stat(label: 'live FPS', value: fps.toStringAsFixed(0)),
        _Stat(label: 'frames', value: '$totalFrames'),
        _Stat(label: 'janky frames', value: '${jankPercent.toStringAsFixed(1)}%'),
        _Stat(label: 'last frame', value: '${lastFrameMs.toStringAsFixed(1)} ms'),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final RunResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = result.error == null
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.errorContainer;
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Last run: ${result.mode}',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (result.error != null)
              Text('ERROR: ${result.error}')
            else ...[
              Text('primes found: ${result.primes}'),
              Text('task wall time: ${result.taskMs.toStringAsFixed(1)} ms'),
              Text('frames during task: ${result.framesDuring} '
                  '(${result.droppedFrames} dropped at 60 Hz)'),
              Text('worst frame around task: '
                  '${result.worstFrameMs.toStringAsFixed(1)} ms'),
              if (result.startupMs != null)
                Text('worker startup: ${result.startupMs!.toStringAsFixed(1)} ms'),
              if (result.messageMs != null)
                Text('message round trip: '
                    '${result.messageMs!.toStringAsFixed(1)} ms'),
            ],
          ],
        ),
      ),
    );
  }
}

class _ComparisonTable extends StatelessWidget {
  const _ComparisonTable({required this.main, required this.worker});

  final RunResult? main;
  final RunResult? worker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String cell(RunResult? r, String Function(RunResult) pick) =>
        r == null ? '—' : pick(r);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Comparison', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Table(
              border: TableBorder.all(color: theme.dividerColor),
              columnWidths: const {
                0: FlexColumnWidth(2),
                1: FlexColumnWidth(1.4),
                2: FlexColumnWidth(1.4),
              },
              children: [
                _row('metric', 'main thread', 'dwi worker', header: true),
                _row('task time', cell(main, (r) => '${r.taskMs.toStringAsFixed(1)} ms'),
                    cell(worker, (r) => '${r.taskMs.toStringAsFixed(1)} ms')),
                _row('janky frames', cell(main, (r) => '${r.droppedFrames}'),
                    cell(worker, (r) => '${r.droppedFrames}')),
                _row('frames rendered', cell(main, (r) => '${r.framesDuring}'),
                    cell(worker, (r) => '${r.framesDuring}')),
                _row('worst frame', cell(main, (r) => '${r.worstFrameMs.toStringAsFixed(1)} ms'),
                    cell(worker, (r) => '${r.worstFrameMs.toStringAsFixed(1)} ms')),
                _row('startup', '—', cell(worker, (r) => '${r.startupMs?.toStringAsFixed(1) ?? '—'} ms')),
                _row('message RTT', '—', cell(worker, (r) => '${r.messageMs?.toStringAsFixed(1) ?? '—'} ms')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Measurements are real: frame timings come from '
              'SchedulerBinding.addTimingsCallback, and task time is wall-clock '
              'in the page. No illustrative numbers.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  TableRow _row(String a, String b, String c, {bool header = false}) {
    return TableRow(
      children: [
        _cell(a, bold: header),
        _cell(b, bold: header),
        _cell(c, bold: header),
      ],
    );
  }

  Widget _cell(String text, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        text,
        style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal),
      ),
    );
  }
}
