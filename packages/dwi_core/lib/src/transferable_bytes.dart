import 'dart:typed_data';

import 'exceptions.dart';

/// Binary payload whose buffer is transferred instead of copied.
///
/// A `DwiTransferableBytes` is sent as the underlying `ArrayBuffer` (web) or
/// `TransferableTypedData` (native), so the bytes are moved rather than
/// duplicated. Ownership rules (ADR-010 §10.2):
///
/// * the wrapper owns its buffer; after a successful send it is detached and
///   [isDetached] becomes `true`;
/// * sending the same wrapper twice throws [DwiSerializationException] before
///   anything leaves the caller;
/// * a view whose `offsetInBytes`/`lengthInBytes` does not span its whole buffer
///   is copied into exact-size bytes at construction, so transferring it never
///   detaches unrelated memory;
/// * after a successful send the bytes belong to the worker: a timeout, cancel
///   or crash means they are gone, and retrying requires a fresh wrapper.
///
/// On native the move uses `TransferableTypedData`, which does not detach the
/// sender's memory: [isDetached] is DWI bookkeeping there, not a memory state.
class DwiTransferableBytes {
  /// Wraps [data], copying only when [data] is a view of a larger buffer.
  DwiTransferableBytes(TypedData data) : _buffer = _claim(data);

  /// Takes ownership of [buffer] without copying.
  ///
  /// The caller must not keep using [buffer] after a successful send.
  DwiTransferableBytes.fromBuffer(ByteBuffer buffer) : _buffer = buffer;

  ByteBuffer _buffer;
  bool _sent = false;

  /// Byte length at construction, so a genuinely empty buffer is not mistaken
  /// for a buffer the browser detached (`byteLength == 0`).
  late final int _initialLength = _buffer.lengthInBytes;

  static ByteBuffer _claim(TypedData data) {
    final buffer = data.buffer;
    if (data.offsetInBytes == 0 &&
        data.lengthInBytes == buffer.lengthInBytes) {
      return buffer;
    }
    final copy = Uint8List(data.lengthInBytes);
    copy.setRange(
      0,
      copy.length,
      Uint8List.view(buffer, data.offsetInBytes, data.lengthInBytes),
    );
    return copy.buffer;
  }

  /// Number of bytes this wrapper transfers.
  int get lengthInBytes => _buffer.lengthInBytes;

  /// Whether the bytes have been handed to a transport.
  ///
  /// On web this also becomes `true` when the browser detached the buffer
  /// (`byteLength == 0` after having been non-empty). A buffer that was created
  /// empty is never reported as detached.
  bool get isDetached =>
      _sent || (_initialLength > 0 && _buffer.lengthInBytes == 0);

  /// The bytes, as long as they have not been transferred.
  ///
  /// Throws [DwiSerializationException] once [isDetached] is `true`.
  Uint8List get bytes {
    _checkAvailable();
    return _buffer.asUint8List();
  }

  /// The buffer to hand to the transport. Backend-facing.
  ///
  /// Throws [DwiSerializationException] once [isDetached] is `true`.
  ByteBuffer get buffer {
    _checkAvailable();
    return _buffer;
  }

  /// Records that the buffer was handed to the transport. Backend-facing.
  ///
  /// Called by a backend after a successful send; application code never calls
  /// this.
  void markSent() {
    _sent = true;
  }

  void _checkAvailable() {
    if (isDetached) {
      throw const DwiSerializationException(
        'transferable bytes were already transferred; create a new '
        'DwiTransferableBytes for another send',
      );
    }
  }
}
