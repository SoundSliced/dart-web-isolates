import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

import 'package:dwi_web/src/payload.dart';

void main() {
  group('validateDwiPayload', () {
    test('accepts primitives and null', () {
      expect(() => validateDwiPayload(null), returnsNormally);
      expect(() => validateDwiPayload(1), returnsNormally);
      expect(() => validateDwiPayload(1.5), returnsNormally);
      expect(() => validateDwiPayload('text'), returnsNormally);
      expect(() => validateDwiPayload(true), returnsNormally);
    });

    test('accepts nested lists, string-keyed maps and sets', () {
      expect(
        () => validateDwiPayload(<Object?>[
          1,
          <String, Object?>{'a': <Object?>[true, null]},
          <Object?>{1, 2},
        ]),
        returnsNormally,
      );
    });

    test('accepts typed data', () {
      expect(() => validateDwiPayload(Uint8List(4)), returnsNormally);
      expect(() => validateDwiPayload(ByteData(4)), returnsNormally);
    });

    test('rejects closures and arbitrary objects', () {
      expect(
        () => validateDwiPayload((int value) => value),
        throwsA(isA<DwiSerializationException>()),
      );
      expect(
        () => validateDwiPayload(_Point(1)),
        throwsA(isA<DwiSerializationException>()),
      );
    });

    test('rejects a non-cloneable value nested in a collection', () {
      expect(
        () => validateDwiPayload(<Object?>[1, <String, Object?>{'bad': _Point(2)}]),
        throwsA(
          isA<DwiSerializationException>().having(
            (error) => error.message,
            'message',
            contains('payload[1][bad]'),
          ),
        ),
      );
    });

    test('rejects non-String map keys', () {
      expect(
        () => validateDwiPayload(<Object?, Object?>{1: 'value'}),
        throwsA(
          isA<DwiSerializationException>().having(
            (error) => error.message,
            'message',
            contains('map keys must be String'),
          ),
        ),
      );
    });

    test('enforces an approximate payload budget', () {
      expect(
        () => validateDwiPayload('short', maxBytes: 1024),
        returnsNormally,
      );
      expect(
        () => validateDwiPayload(<Object?>[
          'x' * 50,
          <String, Object?>{'key': 'y' * 50},
        ], maxBytes: 64),
        throwsA(
          isA<DwiSerializationException>().having(
            (error) => error.message,
            'message',
            contains('exceeds maxPayloadBytes'),
          ),
        ),
      );
      expect(
        () => validateDwiPayload(Uint8List(100), maxBytes: 16),
        throwsA(isA<DwiSerializationException>()),
      );
    });
  });
}

class _Point {
  _Point(this.x);

  final int x;
}
