import 'dart:async';
import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_protocol/dwi_protocol.dart';

import 'payload.dart';

/// Signature of a task executable inside a DWI worker.
///
/// Generated worker entrypoints build a `Map<String, DwiWorkerTask>` with
/// static references so the compiler keeps the task implementations alive.
typedef DwiWorkerTask = FutureOr<Object?> Function(Object? input);

/// Worker-side protocol handling, independent of JavaScript interop.
///
/// This class is deliberately pure Dart so it can be unit-tested on the VM.
/// [DwiWorkerRuntime] wires it to `self.onmessage` and `postMessage`.
class DwiWorkerDispatcher {
  /// Creates a dispatcher for [tasks].
  ///
  /// [workerId] is copied into response metadata to make worker-side logs
  /// attributable to a specific pooled worker. [emit] is the transport hook used
  /// by channels to send messages the dispatcher does not return (ADR-014);
  /// without it a channel can receive but its sends fail with a typed error.
  DwiWorkerDispatcher(
    Map<String, DwiWorkerTask> tasks, {
    this.workerId = '',
    void Function(DwiEnvelope)? emit,
  })  : _tasks = Map<String, DwiWorkerTask>.unmodifiable(tasks),
        _emit = emit;

  final Map<String, DwiWorkerTask> _tasks;
  final void Function(DwiEnvelope)? _emit;
  final Map<String, DwiChannelEndpoint> _channels =
      <String, DwiChannelEndpoint>{};
  final Map<String, int> _channelGens = <String, int>{};

  /// Identifier copied into error/result metadata.
  final String workerId;

  bool _closed = false;

  /// Whether a `shutdown` message has been handled.
  bool get isClosed => _closed;

  /// Task names known to this worker.
  Iterable<String> get taskNames => _tasks.keys;

  /// Handles one decoded [envelope].
  ///
  /// Returns the response envelope, or `null` when no response is required.
  /// A `shutdown` request returns a `closed` envelope and marks the dispatcher
  /// closed; later requests fail with a protocol error.
  Future<DwiEnvelope?> handle(DwiEnvelope envelope) async {
    if (_closed) {
      return _error(envelope.id, DwiErrorCode.protocol, 'worker is closed');
    }
    switch (envelope.type) {
      case DwiMessageType.request:
        return _handleRequest(envelope);
      case DwiMessageType.heartbeat:
        // Liveness probe from the host. Echo the nonce so a late reply cannot
        // be mistaken for a fresh one (ADR-010 §10.3).
        return DwiEnvelope(
          type: DwiMessageType.heartbeat,
          id: envelope.id,
          payload: null,
          meta: <String, Object?>{
            ..._meta(),
            if (envelope.meta['nonce'] != null) 'nonce': envelope.meta['nonce'],
          },
        );
      case DwiMessageType.shutdown:
        _closed = true;
        _failChannels(
          const DwiWorkerClosedException('worker is shutting down'),
        );
        return DwiEnvelope(
          type: DwiMessageType.closed,
          id: envelope.id,
          meta: _meta(),
        );
      case DwiMessageType.channelOpen:
        return _openChannel(envelope);
      case DwiMessageType.channelMessage:
        _handleChannelMessage(envelope);
        return null;
      case DwiMessageType.channelAck:
        _handleChannelAck(envelope);
        return null;
      case DwiMessageType.channelClose:
      case DwiMessageType.channelClosed:
        _handleChannelClose(envelope);
        return null;
      case DwiMessageType.cancel:
        return _error(
          envelope.id,
          DwiErrorCode.protocol,
          'cancellation is not implemented in protocol v1',
        );
      default:
        return _error(
          envelope.id,
          DwiErrorCode.protocol,
          'unexpected ${envelope.type.name} message',
        );
    }
  }

  Future<DwiEnvelope> _handleRequest(DwiEnvelope envelope) async {
    final task = envelope.task;
    if (task == null) {
      return _error(
        envelope.id,
        DwiErrorCode.protocol,
        'request without a task name',
      );
    }
    final implementation = _tasks[task];
    if (implementation == null) {
      return _error(
        envelope.id,
        DwiErrorCode.unknownTask,
        'unknown task "$task"',
      );
    }

    try {
      final limit = _metaInt(envelope.meta['maxPayloadBytes']);
      final maxBytes = limit != null && limit > 0 ? limit : null;
      Object? input = envelope.payload;
      if (envelope.meta['payloadKind'] == 'transferableBytes' &&
          input is ByteBuffer) {
        // The host transferred ownership of the buffer to this worker.
        input = DwiTransferableBytes.fromBuffer(input);
      }
      validateDwiPayload(input, path: 'input', maxBytes: maxBytes);
      final result = await Future<Object?>.sync(() => implementation(input));
      validateDwiPayload(result, path: 'result', maxBytes: maxBytes);
      return DwiEnvelope(
        type: DwiMessageType.result,
        id: envelope.id,
        payload: result,
        meta: _meta(),
      );
    } on DwiSerializationException catch (error) {
      return _error(
        envelope.id,
        DwiErrorCode.serialization,
        error.message,
      );
    } catch (error, stack) {
      return _error(
        envelope.id,
        DwiErrorCode.remote,
        error.toString(),
        remoteType: error.runtimeType.toString(),
        remoteStack: stack.toString(),
      );
    }
  }

  DwiEnvelope _error(
    int? id,
    DwiErrorCode code,
    String message, {
    String remoteType = '',
    String remoteStack = '',
    String? channel,
    int? seq,
    int? gen,
  }) {
    return DwiEnvelope(
      type: DwiMessageType.error,
      id: id,
      error: DwiErrorPayload(
        code: code,
        message: message,
        remoteType: remoteType,
        remoteStack: remoteStack,
        taskId: id,
      ),
      meta: <String, Object?>{
        ..._meta(),
        if (channel != null) 'channel': channel,
        if (seq != null) 'seq': seq,
        if (gen != null) 'gen': gen,
      },
    );
  }

  DwiEnvelope _openChannel(DwiEnvelope envelope) {
    final name = envelope.channel;
    if (name == null) {
      return _error(
        envelope.id,
        DwiErrorCode.channel,
        'channelOpen without a channel name',
      );
    }
    final rawBuffer = _metaInt(envelope.meta['bufferSize']);
    final bufferSize = rawBuffer != null && rawBuffer > 0 ? rawBuffer : 64;
    final gen = _metaInt(envelope.meta['gen']) ?? 0;
    try {
      validateDwiChannelName(name);
      final endpoint = DwiChannelEndpoint(
        name: name,
        bufferSize: bufferSize,
        onSend: (seq, message, transfer) =>
            _emitChannelMessage(name, gen, seq, message, transfer),
        onAck: (seq) => _emit?.call(
          DwiEnvelope(
            type: DwiMessageType.channelAck,
            meta: <String, Object?>{'channel': name, 'seq': seq, 'gen': gen},
          ),
        ),
        onClose: () => _emit?.call(
          DwiEnvelope(
            type: DwiMessageType.channelClose,
            meta: <String, Object?>{'channel': name, 'gen': gen},
          ),
        ),
        onClosed: () => _emit?.call(
          DwiEnvelope(
            type: DwiMessageType.channelClosed,
            meta: <String, Object?>{'channel': name, 'gen': gen},
          ),
        ),
        onTerminated: () {
          if (_channelGens[name] == gen) {
            _channelGens.remove(name);
            _channels.remove(name);
            DwiWorkerChannels.remove(name);
          }
        },
      );
      DwiWorkerChannels.register(name, endpoint);
      _channels[name] = endpoint;
      _channelGens[name] = gen;
      endpoint.markOpened();
      return DwiEnvelope(
        type: DwiMessageType.channelOpened,
        meta: <String, Object?>{
          ..._meta(),
          'channel': name,
          'gen': gen,
          'opened': true,
        },
      );
    } on DwiException catch (error) {
      return _error(
        envelope.id,
        DwiErrorCode.channel,
        error.message,
        channel: name,
      );
    }
  }

  void _handleChannelMessage(DwiEnvelope envelope) {
    final name = envelope.channel;
    final seq = envelope.seq;
    if (name == null || seq == null) {
      _emit?.call(
        _error(
          null,
          DwiErrorCode.protocol,
          'channelMessage without a channel name or sequence',
        ),
      );
      return;
    }
    final channel = _channels[name];
    if (channel == null || _channelGens[name] != _metaInt(envelope.meta['gen'])) {
      return;
    }
    Object? payload = envelope.payload;
    if (envelope.meta['payloadKind'] == 'transferableBytes' &&
        payload is ByteBuffer) {
      payload = DwiTransferableBytes.fromBuffer(payload);
    }
    final limit = _metaInt(envelope.meta['maxPayloadBytes']);
    try {
      validateDwiPayload(
        payload,
        path: 'channel message',
        maxBytes: limit is int && limit > 0 ? limit : null,
      );
    } on DwiSerializationException catch (error) {
      channel.fail(error);
      return;
    }
    if (!channel.deliver(seq, payload)) {
      _emit?.call(
        _error(
          null,
          DwiErrorCode.channel,
          'channel "$name" is full',
          channel: name,
          seq: seq,
          gen: _channelGens[name],
        ),
      );
    }
  }

  void _handleChannelAck(DwiEnvelope envelope) {
    final channel = envelope.channel;
    final seq = envelope.seq;
    if (channel == null || seq == null) return;
    if (_channelGens[channel] != _metaInt(envelope.meta['gen'])) return;
    _channels[channel]?.ack(seq);
  }

  void _handleChannelClose(DwiEnvelope envelope) {
    final channel = envelope.channel;
    if (channel == null) return;
    if (_channelGens[channel] != _metaInt(envelope.meta['gen'])) return;
    _channels[channel]?.peerClosed();
  }

  void _emitChannelMessage(
    String name,
    int gen,
    int seq,
    Object? message,
    bool transfer,
  ) {
    final emit = _emit;
    if (emit == null) {
      throw const DwiChannelException(
        'worker runtime has no channel transport',
      );
    }
    if (transfer) {
      final bytes = message! as DwiTransferableBytes;
      validateDwiPayload(bytes, path: 'channel message');
      emit(
        DwiEnvelope(
          type: DwiMessageType.channelMessage,
          meta: <String, Object?>{
            'channel': name,
            'seq': seq,
            'gen': gen,
            'payloadKind': 'transferableBytes',
          },
          payload: bytes.buffer,
        ),
      );
      bytes.markSent();
    } else {
      validateDwiPayload(message, path: 'channel message');
      emit(
        DwiEnvelope(
          type: DwiMessageType.channelMessage,
          meta: <String, Object?>{'channel': name, 'seq': seq, 'gen': gen},
          payload: message,
        ),
      );
    }
  }

  void _failChannels(DwiException error) {
    final channels = List<DwiChannelEndpoint>.of(_channels.values);
    _channels.clear();
    _channelGens.clear();
    for (final channel in channels) {
      channel.fail(error);
    }
  }

  /// Reads a meta integer that may arrive as an integral `double`.
  ///
  /// A dart2wasm worker receives every JS number as `double`, including the
  /// `gen`, `seq`, `bufferSize` and `maxPayloadBytes` fields. Rejecting them
  /// made channel opens and acknowledgements silently never match (ADR-018).
  static int? _metaInt(Object? value) {
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.truncateToDouble()) {
      return value.toInt();
    }
    return null;
  }

  Map<String, Object?> _meta() => workerId.isEmpty
      ? const <String, Object?>{}
      : <String, Object?>{'workerId': workerId};
}
