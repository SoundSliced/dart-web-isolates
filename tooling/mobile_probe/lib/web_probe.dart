import 'dart:convert';
import 'dart:js_interop';

import 'package:dwi/dwi.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'dwi_tasks.g.dart';
import 'tasks.dart';

@JS('fetch')
external JSPromise<JSAny?> _fetch(JSString url, JSAny? init);

@JS('navigator.userAgent')
external JSString get _userAgent;

@JS('location.origin')
external JSString get _origin;

/// Browser probe: the same checks as `integration_test/native_probe_test.dart`,
/// run in the page and posted back to the server that served it (same origin).
Future<void> main() async {
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('DWI web probe running'))),
    ),
  );
  final results = <String, Object?>{
    'platform': 'web',
    'userAgent': _userAgent.toDart,
  };
  final stopwatch = Stopwatch()..start();
  try {
    results['primes'] = await DwiTasks.countPrimes(3000000);
    results['joined'] = await DwiTasks.joinParts(3, 'x');
    results['spread'] = await DwiTasks.spread(1, 3);
    results['streamed'] = await DwiTasks.countBetween(1, 3).toList();
    results['reference'] = await callTwiceByReference(21);
    results['ok'] = results['primes'] == 216816 &&
        results['joined'] == 'x3' &&
        results['reference'] == 42;
  } catch (error, stack) {
    results['ok'] = false;
    results['error'] = '$error';
    results['stack'] = '$stack';
  } finally {
    await Dwi.close();
  }
  results['ms'] = stopwatch.elapsedMilliseconds;
  final body = jsonEncode(results);
  await _fetch(
    '${_origin.toDart}/result'.toJS,
    <String, Object?>{
      'method': 'POST',
      'headers': <String, String>{'content-type': 'text/plain'},
      'body': body,
    }.jsify(),
  ).toDart;
}
