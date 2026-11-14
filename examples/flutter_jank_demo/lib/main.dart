import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi_flutter/dwi_flutter.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import 'dwi_tasks.g.dart';
import 'tasks.dart';

// The probe reads the result from document.title (same convention as the
// browser matrix page).
@JS('document')
external JSObject get _document;

// Heavy enough that the main-thread run blocks frames for a visible time. At
// the counter's smaller limits the whole main-thread run takes about 18 ms, which
// is less than one frame, so no gap could show.
const List<int> _limits = <int>[3000000, 3000000, 3000000, 3000000];

void main() {
  runApp(const JankApp());
}

class JankApp extends StatelessWidget {
  const JankApp({super.key, this.autoRun = true});

  /// Whether the demo runs its measurements on start. Tests pass false.
  final bool autoRun;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Kept as the probe placeholder until the run has written its result;
      // the visible heading below names the app.
      title: 'pending',
      home: JankPage(autoRun: autoRun),
    );
  }
}

class JankPage extends StatefulWidget {
  const JankPage({super.key, this.autoRun = true});

  final bool autoRun;

  @override
  State<JankPage> createState() => _JankPageState();
}

class _JankPageState extends State<JankPage> with TickerProviderStateMixin {
  late final Ticker _ticker;
  final List<int> _frameTimes = <int>[];
  String _status = 'starting';

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _frameTimes.add(DateTime.now().microsecondsSinceEpoch));
    _ticker.start();
    if (widget.autoRun) unawaited(_runAll());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<Map<String, Object?>> _measure(Future<void> Function() work) async {
    // A timestamp taken before the work is the start of the first gap. Without
    // it, a synchronous block shows up as no gap at all, because no frame runs
    // while the block does.
    _frameTimes
      ..clear()
      ..add(DateTime.now().microsecondsSinceEpoch);
    final watch = Stopwatch()..start();
    await work();
    watch.stop();
    // Give the ticker a few frames after the work to settle.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final gaps = <int>[
      for (var i = 1; i < _frameTimes.length; i++)
        _frameTimes[i] - _frameTimes[i - 1],
    ]..sort();
    final maxGapMs = gaps.isEmpty ? 0.0 : gaps.last / 1000;
    final medianGapMs = gaps.isEmpty ? 0.0 : gaps[gaps.length ~/ 2] / 1000;
    return <String, Object?>{
      'totalMs': watch.elapsedMicroseconds / 1000,
      'frames': _frameTimes.length,
      'maxFrameGapMs': maxGapMs,
      'medianFrameGapMs': medianGapMs,
    };
  }

  Future<void> _runAll() async {
    final modes = <String, Object?>{};
    try {
      setState(() => _status = 'main thread');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      modes['mainThread'] = await _measure(() async {
        for (final limit in _limits) {
          countPrimes(limit);
        }
      });

      setState(() => _status = 'computeParallel');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      modes['computeParallel'] = await _measure(() async {
        await computeParallel(DwiTasks.countPrimes, _limits);
      });

      setState(() => _status = "Flutter compute()");
      await Future<void>.delayed(const Duration(milliseconds: 200));
      modes['flutterCompute'] = await _measure(() async {
        for (final limit in _limits) {
          await compute(countPrimes, limit);
        }
      });

      setState(() => _status = 'done');
      _finish(<String, Object?>{'status': 'ok', 'modes': modes});
    } catch (error) {
      setState(() => _status = 'error: $error');
      _finish(<String, Object?>{'status': 'error', 'error': '$error', 'modes': modes});
    }
  }

  void _finish(Map<String, Object?> result) {
    _document.setProperty(
      'title'.toJS,
      base64Encode(utf8.encode(jsonEncode(result))).toJS,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DWI jank demo')),
      body: Center(child: Text(_status, style: Theme.of(context).textTheme.headlineSmall)),
    );
  }
}
