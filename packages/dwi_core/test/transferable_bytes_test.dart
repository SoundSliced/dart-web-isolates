import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

void main() {
  group('DwiTransferableBytes', () {
    test('takes ownership of an exact buffer without copying', () {
      final data = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final bytes = DwiTransferableBytes(data);

      expect(bytes.lengthInBytes, 4);
      expect(bytes.isDetached, isFalse);
      expect(bytes.buffer.lengthInBytes, data.buffer.lengthInBytes);
      expect(bytes.bytes, <int>[1, 2, 3, 4]);
      expect(data, <int>[1, 2, 3, 4]);
    });

    test('copies a view that does not span its whole buffer', () {
      final backing = Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5]);
      final view = Uint8List.view(backing.buffer, 2, 3);
      final bytes = DwiTransferableBytes(view);

      expect(bytes.lengthInBytes, 3);
      expect(bytes.bytes, <int>[2, 3, 4]);
      // The copy is exact-size, so transferring it cannot detach the caller's
      // larger buffer.
      expect(bytes.bytes.buffer.lengthInBytes, 3);
      bytes.markSent();
      expect(bytes.isDetached, isTrue);
      expect(backing, <int>[0, 1, 2, 3, 4, 5]);
    });

    test('accepts a typed data view with an offset', () {
      final backing = Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5, 6, 7]);
      final ints = Int32List.view(backing.buffer, 4, 1);
      final bytes = DwiTransferableBytes(ints);

      expect(bytes.lengthInBytes, 4);
      expect(bytes.bytes, <int>[4, 5, 6, 7]);
    });

    test('fromBuffer takes the buffer directly', () {
      final buffer = Uint8List.fromList(<int>[9, 8, 7]).buffer;
      final bytes = DwiTransferableBytes.fromBuffer(buffer);

      expect(bytes.lengthInBytes, 3);
      expect(bytes.buffer, same(buffer));
      expect(bytes.bytes, <int>[9, 8, 7]);
    });

    test('a transferred wrapper refuses a second transfer', () {
      final bytes = DwiTransferableBytes(Uint8List(4));
      bytes.markSent();

      expect(bytes.isDetached, isTrue);
      expect(
        () => bytes.bytes,
        throwsA(isA<DwiSerializationException>()),
      );
      expect(
        () => bytes.buffer,
        throwsA(isA<DwiSerializationException>()),
      );
    });

    test('empty bytes are not treated as detached', () {
      final bytes = DwiTransferableBytes(Uint8List(0));
      expect(bytes.isDetached, isFalse);
      expect(bytes.lengthInBytes, 0);
    });
  });
}
