import 'dart:async';
import 'dart:collection';

import 'channel.dart';
import 'exceptions.dart';
import 'transferable_bytes.dart';

/// Validates a channel name (ADR-014): non-empty, at most 64 UTF-16 units and
/// no control characters.
void validateDwiChannelName(String name) {
  if (name.isEmpty) {
    throw const DwiChannelStateException('channel name must not be empty');
  }
  if (name.length > 64) {
    throw const DwiChannelStateException(
      'channel name must be at most 64 characters',
    );
  }
  for (final unit in name.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) {
      throw const DwiChannelStateException(
        'channel name must not contain control characters',
      );
    }
  }
}

/// Backend-facing implementation of [DwiChannel] (ADR-014).
///
/// It owns the buffering, the acknowledgement window and the lifecycle; a
/// backend only supplies transport callbacks. Native and web share this class
/// so both enforce identical bounds and settlement rules.
class DwiChannelEndpoint implements DwiChannel {
  DwiChannelEndpoint({
    required this.name,
    required this.bufferSize,
    required void Function(int seq, Object? message, bool transfer) onSend,
    required void Function(int seq) onAck,
    required void Function() onClose,
    required void Function() onClosed,
    void Function()? onTerminated,
  })  : _onSend = onSend,
        _onAck = onAck,
        _onClose = onClose,
        _onClosed = onClosed,
        _onTerminated = onTerminated {
    _controller = StreamController<Object?>(
      onListen: _drain,
      onResume: _drain,
    );
  }

  /// Channel name.
  @override
  final String name;

  /// Bound on buffered incoming messages and on unacknowledged sends.
  final int bufferSize;

  final void Function(int seq, Object? message, bool transfer) _onSend;
  final void Function(int seq) _onAck;
  final void Function() _onClose;
  final void Function() _onClosed;
  final void Function()? _onTerminated;
  late final StreamController<Object?> _controller;
  final Queue<_Incoming> _incoming = Queue<_Incoming>();
  final Map<int, Completer<void>> _pendingSends = <int, Completer<void>>{};
  int _nextSeq = 1;
  bool _closed = false;
  bool _opened = false;
  Completer<void>? _openCompleter;

  /// Whether the channel is open (not closing or closed).
  bool get isOpen => !_closed;

  @override
  Stream<Object?> get messages => _controller.stream;

  /// Resolves when the peer acknowledged the channel.
  Future<void> open() => (_openCompleter ??= Completer<void>()).future;

  /// Marks the channel open after the peer acknowledged it.
  void markOpened() {
    if (_closed || _opened) return;
    _opened = true;
    final completer = _openCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Fails an opening channel.
  void failOpen(DwiException error) {
    final completer = _openCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  @override
  Future<void> send(Object? message) async => _send(message, transfer: false);

  @override
  Future<void> sendBytes(DwiTransferableBytes bytes) async =>
      _send(bytes, transfer: true);

  Future<void> _send(Object? message, {required bool transfer}) async {
    if (_closed) {
      throw DwiChannelClosedException('channel "$name" is closed');
    }
    if (!_opened) {
      throw DwiChannelStateException('channel "$name" is still opening');
    }
    if (_pendingSends.length >= bufferSize) {
      throw DwiChannelBufferException(
        'channel "$name" has $bufferSize unacknowledged sends',
      );
    }
    final seq = _nextSeq++;
    final completer = Completer<void>();
    _pendingSends[seq] = completer;
    try {
      _onSend(seq, message, transfer);
    } on DwiException {
      _pendingSends.remove(seq);
      rethrow;
    } catch (error) {
      _pendingSends.remove(seq);
      throw DwiSerializationException(
        'could not send on channel "$name": $error',
      );
    }
    return completer.future;
  }

  /// Delivers an inbound message from the transport.
  ///
  /// Accepts and acknowledges the message when the receive buffer has room, and
  /// returns `false` when it is full: the transport must then reject that send
  /// so the sender gets a typed [DwiChannelBufferException] instead of waiting
  /// for an acknowledgement that will never come.
  bool deliver(int seq, Object? message) {
    if (_closed) return false;
    if (_incoming.length >= bufferSize) return false;
    _incoming.add(_Incoming(seq, message));
    _onAck(seq);
    _drain();
    return true;
  }

  /// Rejects a send the peer refused because its buffer was full.
  void reject(int seq, DwiException error) {
    final completer = _pendingSends.remove(seq);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  /// Records that the peer acknowledged our send [seq].
  void ack(int seq) {
    final completer = _pendingSends.remove(seq);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// The peer closed the channel: close the stream normally and settle sends.
  void peerClosed() {
    if (_closed) return;
    _closed = true;
    _notifyTerminated();
    _completeOpenError(
      DwiChannelClosedException('channel "$name" was closed by the peer'),
    );
    _settleSends(
      DwiChannelClosedException('channel "$name" was closed by the peer'),
    );
    _incoming.clear();
    unawaited(_controller.close());
    try {
      _onClosed();
    } catch (_) {
      // Replying to a close on a dying transport is best effort.
    }
  }

  /// Moves the channel to closed after a handle failure or handle close.
  void fail(DwiException error) {
    if (_closed) return;
    _closed = true;
    _notifyTerminated();
    _completeOpenError(error);
    _settleSends(error);
    _incoming.clear();
    _controller.addError(error);
    unawaited(_controller.close());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _notifyTerminated();
    _completeOpenError(
      DwiChannelClosedException('channel "$name" was closed'),
    );
    try {
      _onClose();
    } catch (_) {
      // The transport may already be gone; local settlement still applies.
    }
    _settleSends(DwiChannelClosedException('channel "$name" was closed'));
    _incoming.clear();
    unawaited(_controller.close());
  }

  void _drain() {
    if (_closed) return;
    while (_incoming.isNotEmpty &&
        _controller.hasListener &&
        !_controller.isPaused) {
      final item = _incoming.removeFirst();
      _controller.add(item.message);
    }
  }

  void _settleSends(DwiException error) {
    final pending = List<Completer<void>>.of(_pendingSends.values);
    _pendingSends.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  void _completeOpenError(DwiException error) {
    final completer = _openCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  bool _terminated = false;

  void _notifyTerminated() {
    if (_terminated) return;
    _terminated = true;
    try {
      _onTerminated?.call();
    } catch (_) {
      // Registry cleanup must not mask the closure.
    }
  }
}

class _Incoming {
  const _Incoming(this.seq, this.message);

  final int seq;
  final Object? message;
}
