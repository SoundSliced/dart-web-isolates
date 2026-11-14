import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:convert';

import 'package:dwi_flutter/dwi_flutter.dart';
import 'package:flutter/material.dart';

import 'dwi_tasks.g.dart';

// Written to document.title when the automatic run finishes, so the browser
// probe can read the result (the same convention as the browser matrix page).
@JS('document')
external JSObject get _document;

void main() {
  runApp(const CounterApp());
}

class CounterApp extends StatelessWidget {
  const CounterApp({super.key, this.autoRun = true});

  /// Whether the page runs the parallel count on start. Tests pass false, so
  /// no worker is started.
  final bool autoRun;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Kept as the probe placeholder until the run has written its result;
      // the visible heading below names the app.
      title: 'pending',
      home: CounterPage(autoRun: autoRun),
    );
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key, this.autoRun = true});

  final bool autoRun;

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  static const List<int> _limits = <int>[100000, 200000, 300000, 400000];

  int _count = 0;
  String _status = 'idle';

  @override
  void initState() {
    super.initState();
    if (widget.autoRun) _countAll(report: true);
  }

  Future<void> _countAll({bool report = false}) async {
    setState(() => _status = 'counting...');
    try {
      final results = await computeParallel(DwiTasks.countPrimes, _limits);
      final text = results.join(', ');
      setState(() => _status = 'primes: $text');
      if (report) _finish(<String, Object?>{'status': 'ok', 'primes': results});
    } catch (error) {
      setState(() => _status = 'error: $error');
      if (report) _finish(<String, Object?>{'status': 'error', 'error': '$error'});
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
      appBar: AppBar(title: const Text('DWI counter')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('$_count', style: Theme.of(context).textTheme.displayMedium),
            FilledButton(
              onPressed: () => setState(() => _count++),
              child: const Text('+1'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _countAll(),
              child: const Text('Count primes in parallel'),
            ),
            const SizedBox(height: 8),
            Text(_status),
          ],
        ),
      ),
    );
  }
}
