import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_core.dart';

@JS('self')
external JSObject get _self;

/// Minimal task used to measure cold-start and warm dispatch latency.
@DwiTask()
int tiny(int value) => value + 1;

/// Copy path: a typed list is structured-cloned.
@DwiTask()
int sumTyped(Uint8List input) {
  var sum = 0;
  for (final byte in input) {
    sum += byte;
  }
  return sum;
}

/// Transfer path: the buffer arrives as `DwiTransferableBytes`.
@DwiTask()
int sumTransferable(DwiTransferableBytes input) {
  var sum = 0;
  for (final byte in input.bytes) {
    sum += byte;
  }
  return sum;
}

/// Synchronous CPU work, for cancellation and UI-responsiveness measurements.
@DwiTask()
String spin(int milliseconds) {
  final until = DateTime.now().add(Duration(milliseconds: milliseconds));
  while (DateTime.now().isBefore(until)) {}
  return 'spun';
}

/// Asynchronous work, so a queued caller can be cancelled while it waits.
@DwiTask()
Future<String> slow(int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  return 'slow';
}

@DwiTask()
String echo(String value) => value;

/// Answers, then closes the worker's global scope so the pool sees an idle
/// worker that can never reply again.
@DwiTask()
String dieAfter(String value) {
  Timer(const Duration(milliseconds: 100), () {
    try {
      _self.callMethod('close'.toJS);
    } catch (_) {
      // Already closing.
    }
  });
  return value;
}
