// Worker entrypoint for the DWI M001 proof.
//
// This file is compiled separately from the Flutter app:
//   dart compile js -O1 -o web/dwi/worker.dart.js worker.dart
//
// It intentionally imports nothing from Flutter or from the app: it is a second
// program instance, which is the whole point of the milestone.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'lib/src/primes.dart';

@JS('postMessage')
external void _postMessage(JSAny? message);

@JS('self')
external JSObject get _self;

void _handleMessage(JSAny? event) {
  final data = (event as JSObject).getProperty('data'.toJS) as JSObject;
  final op = (data.getProperty('op'.toJS) as JSString).toDart;
  final id = data.getProperty('id'.toJS) as JSNumber;

  switch (op) {
    case 'primes':
      final limit = (data.getProperty('n'.toJS) as JSNumber).toDartInt;
      final rounds = (data.getProperty('rounds'.toJS) as JSNumber?)?.toDartInt ?? 1;
      final started = DateTime.now();
      var count = 0;
      for (var round = 0; round < rounds; round++) {
        count = countPrimes(limit);
      }
      final elapsed = DateTime.now().difference(started).inMicroseconds / 1000;
      _postMessage(<String, Object?>{
        'type': 'result',
        'id': id.toDartInt,
        'count': count,
        'rounds': rounds,
        'workerMs': elapsed,
      }.jsify());
    case 'echo':
      _postMessage(<String, Object?>{
        'type': 'result',
        'id': id.toDartInt,
        'payload': (data.getProperty('payload'.toJS) as JSString).toDart,
      }.jsify());
    default:
      _postMessage(<String, Object?>{
        'type': 'error',
        'id': id.toDartInt,
        'message': 'unknown operation: $op',
      }.jsify());
  }
}

void main() {
  _self.setProperty('onmessage'.toJS, _handleMessage.toJS);
  _postMessage(<String, Object?>{'type': 'ready'}.jsify());
}
