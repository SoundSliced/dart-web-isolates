import 'dart:async';
import 'dart:convert';
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

/// Ignores cancellation: it never looks at a token and replies after [ms].
/// Used to observe a late reply after the caller was cancelled (A4).
@DwiTask()
Future<String> ignoreCancel(int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  return 'late';
}

/// A6 workloads. Each returns a checksum so the page can check that the worker
/// and the main thread computed the same result.
@DwiTask()
int sortChecksum(Uint8List input) {
  final copy = Uint8List.fromList(input)..sort();
  var sum = 0;
  for (var i = 0; i < copy.length; i++) {
    sum = (sum + i * copy[i]) % 1000000007;
  }
  return sum;
}

@DwiTask()
int jsonChecksum(String text) {
  var total = 0;
  void walk(Object? node) {
    if (node is num) {
      total = (total + node.toInt()) % 1000000007;
    } else if (node is List) {
      node.forEach(walk);
    } else if (node is Map) {
      node.values.forEach(walk);
    }
  }

  walk(jsonDecode(text));
  return total;
}

/// Adler-32 over the bytes. Additions only, so the result is exact on dart2js.
@DwiTask()
int adler32(Uint8List input) {
  const mod = 65521;
  var a = 1;
  var b = 0;
  for (final byte in input) {
    a = (a + byte) % mod;
    b = (b + a) % mod;
  }
  return (b << 16) | a;
}

/// Run-length encoding size. This is RLE, not DEFLATE or gzip: it measures a
/// compression-shaped scan of the bytes, nothing more.
@DwiTask()
int rleSize(Uint8List input) {
  if (input.isEmpty) return 0;
  var runs = 1;
  for (var i = 1; i < input.length; i++) {
    if (input[i] != input[i - 1]) runs++;
  }
  return runs * 2;
}

/// Width of the grayscale image that [boxBlurSum] reads, in pixels.
const int blurWidth = 512;

/// 3x3 box blur over a grayscale image, row-major, [blurWidth] pixels wide.
/// Returns the sum of the blurred pixels.
@DwiTask()
int boxBlurSum(Uint8List pixels) {
  const width = blurWidth;
  final height = pixels.length ~/ width;
  var sum = 0;
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      var acc = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          acc += pixels[(y + dy) * width + (x + dx)];
        }
      }
      sum += acc ~/ 9;
    }
  }
  return sum;
}

/// G6 chunked strategy: one call does [items] units of 2 ms busy work in one
/// worker, so the call's cost is items x 2 ms on a single context.
@DwiTask()
String spinBatch(int items) {
  final until = DateTime.now().add(Duration(milliseconds: items * 2));
  while (DateTime.now().isBefore(until)) {}
  return 'batch';
}

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
