import 'dart:async';

import 'exceptions.dart';
import 'transferable_bytes.dart';

/// A named, duplex, single-subscriber message channel (ADR-014).
///
/// Host code obtains one with `DwiWorker.openChannel`; task code inside the
/// worker obtains the same channel by name with [DwiWorkerChannels.find].
///
/// Delivery is FIFO per channel and per direction. [messages] accepts exactly
/// one listener; a second `listen` throws `StateError`. A send completes only
/// when the peer has enqueued the message, and at most
/// `DwiConfig.channelBufferSize` sends may be outstanding per channel: a further
/// send throws [DwiChannelBufferException] instead of growing memory. Messages
/// are never dropped, coalesced or reordered.
///
/// Channels are not `SendPort`/`ReceivePort` parity: there are no port objects,
/// no port transfer, no broadcast and no shared memory. A channel belongs to one
/// handle and does not survive `close()` or `restart()`.
abstract interface class DwiChannel {
  /// Logical name, unique among live channels of one handle.
  String get name;

  /// Incoming messages, in send order from the peer.
  ///
  /// Single-subscription. Closes normally when the peer closes the channel, and
  /// emits a typed error when the handle fails or is closed.
  Stream<Object?> get messages;

  /// Sends [message] by copy and completes when the peer enqueued it.
  ///
  /// Throws [DwiChannelClosedException] after close,
  /// [DwiChannelBufferException] when the unacknowledged window is full, and
  /// [DwiSerializationException] when the value cannot cross the boundary.
  Future<void> send(Object? message);

  /// Sends [bytes] by transfer and completes when the peer enqueued it.
  ///
  /// Ownership leaves the caller only after the transport accepted the message
  /// (ADR-010 §10.2). A failure after that means the bytes are gone.
  Future<void> sendBytes(DwiTransferableBytes bytes);

  /// Closes the channel in both directions. Idempotent.
  ///
  /// Pending sends settle with [DwiChannelClosedException]; later sends throw.
  Future<void> close();
}

/// Worker-side registry of channels opened by the host (ADR-014).
///
/// Task code inside an isolate or worker looks a channel up by name. A channel
/// exists only after the host called `DwiWorker.openChannel(name)` and the
/// worker acknowledged it; an unknown name returns `null`. The registry is
/// driven by the backend runtime; it is not host API.
abstract final class DwiWorkerChannels {
  static final Map<String, DwiChannel> _channels = <String, DwiChannel>{};

  /// Channels currently open in this worker context.
  static Iterable<String> get names => _channels.keys;

  /// Returns the channel named [name], or `null` when the host did not open it.
  static DwiChannel? find(String name) => _channels[name];

  /// Registers [channel] for [name] (runtime use).
  ///
  /// Throws [DwiChannelStateException] when the name is already registered.
  static void register(String name, DwiChannel channel) {
    if (_channels.containsKey(name)) {
      throw DwiChannelStateException(
        'channel "$name" is already open in this worker',
      );
    }
    _channels[name] = channel;
  }

  /// Removes and returns the channel named [name] (runtime use).
  static DwiChannel? remove(String name) => _channels.remove(name);

  /// Forgets every registered channel (runtime teardown and tests).
  static void clear() => _channels.clear();
}
