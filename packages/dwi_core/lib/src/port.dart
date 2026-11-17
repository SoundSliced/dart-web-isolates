import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'channel.dart';
import 'channel_endpoint.dart' show validateDwiChannelName;
import 'exceptions.dart';
import 'transferable_bytes.dart';

/// Who may use a named port (ADR-032, decision 2).
enum DwiPortScope {
  /// Only host code sends and listens. A `hostOnly` port cannot be bound to a
  /// worker.
  hostOnly,

  /// Host code may also bind the port to worker handles. A bound worker reaches
  /// it by name through `DwiWorkerChannels.find('port:<name>')`.
  workers,
}

/// How many host listeners a named port has (ADR-032, decision 3).
enum DwiPortListeners {
  /// Exactly one listener; a second `listen` throws [StateError].
  single,

  /// Any number of listeners; each one receives every message delivered after it
  /// started listening, in send order.
  broadcast,
}

/// Longest port name. The channel name `port:<name>` must stay within the 64
/// unit limit of channel names (ADR-014).
const int dwiPortNameMaxLength = 58;

/// Prefix of the channel that carries a port to a bound worker (ADR-032,
/// decision 7).
const String dwiPortChannelPrefix = 'port:';

/// A host-side named port (ADR-032).
///
/// Create one with `Dwi.createPort` and find it again with `Dwi.port`. Messages
/// are never dropped, coalesced or reordered. A listener whose queue is full
/// slows the senders; it does not lose messages.
abstract interface class DwiPort {
  /// Name, unique among open ports.
  String get name;

  /// Who may use this port.
  DwiPortScope get scope;

  /// How many host listeners this port accepts.
  DwiPortListeners get listeners;

  /// Messages delivered to the host. Single-subscription for
  /// [DwiPortListeners.single]; a broadcast stream otherwise.
  Stream<Object?> get messages;

  /// Sends [message] by copy. On a `hostOnly` port it goes to the host listeners;
  /// on a `workers` port it goes to every bound worker.
  Future<void> send(Object? message);

  /// Sends [bytes] by transfer (ADR-010). Ownership leaves the caller.
  Future<void> sendBytes(DwiTransferableBytes bytes);

  /// Closes the port: ends every listener and binding, and rejects later sends.
  /// Idempotent.
  Future<void> close();
}

/// A worker's attachment to a `workers` port (ADR-032, decision 7).
abstract interface class DwiPortBinding {
  /// Completes when the binding ends normally (the port or the binding closed).
  /// Completes with a typed error when the worker fails or a message cannot be
  /// delivered.
  Future<void> get done;

  /// Ends the binding. Idempotent.
  Future<void> close();
}

/// Validates a port name: channel-name rules plus the length limit
/// [dwiPortNameMaxLength].
void validateDwiPortName(String name) {
  if (name.isEmpty) {
    throw const DwiChannelStateException('port name must not be empty');
  }
  if (name.length > dwiPortNameMaxLength) {
    throw const DwiChannelStateException(
      'port name must be at most $dwiPortNameMaxLength characters',
    );
  }
  validateDwiChannelName('$dwiPortChannelPrefix$name');
}

/// Process-wide registry of open named ports (ADR-032, decision 1).
abstract final class DwiPortRegistry {
  static final Map<String, DwiPortEndpoint> _open = <String, DwiPortEndpoint>{};

  /// Creates and registers a port. Throws [DwiChannelStateException] when the
  /// name is invalid or already open.
  static DwiPortEndpoint create({
    required String name,
    required DwiPortScope scope,
    required DwiPortListeners listeners,
    required int bufferSize,
  }) {
    validateDwiPortName(name);
    if (_open.containsKey(name)) {
      throw DwiChannelStateException('port "$name" is already open');
    }
    if (bufferSize < 1) {
      throw const DwiChannelStateException(
        'port bufferSize must be at least 1',
      );
    }
    final port = DwiPortEndpoint._(
      name: name,
      scope: scope,
      listeners: listeners,
      bufferSize: bufferSize,
      onClosed: () => _open.remove(name),
    );
    _open[name] = port;
    return port;
  }

  /// The open port named [name], or `null`.
  static DwiPort? find(String name) => _open[name];
}

/// Backend-independent implementation of [DwiPort] (ADR-032).
///
/// It owns the listeners, the backlog and the bindings. A worker is reached only
/// through a [DwiChannel] that the caller opened with the name `port:<name>`.
final class DwiPortEndpoint implements DwiPort {
  DwiPortEndpoint._({
    required this.name,
    required this.scope,
    required this.listeners,
    required this.bufferSize,
    required void Function() onClosed,
  }) : _onClosed = onClosed {
    if (listeners == DwiPortListeners.single) {
      _singleController = StreamController<Object?>(
        onListen: _attachSingle,
        onResume: () => _single?.drain(),
        onCancel: _detachSingle,
      );
      _single = _PortListener(
        sink: _singleController!,
        isReady: () =>
            _singleController!.hasListener && !_singleController!.isPaused,
        capacity: bufferSize,
      );
    }
  }

  @override
  final String name;

  @override
  final DwiPortScope scope;

  @override
  final DwiPortListeners listeners;

  /// Bound on undelivered messages per listener and on the backlog kept while no
  /// listener is attached.
  final int bufferSize;

  final void Function() _onClosed;
  StreamController<Object?>? _singleController;
  _PortListener? _single;
  final List<_PortListener> _broadcast = <_PortListener>[];
  final Queue<Object?> _backlog = Queue<Object?>();
  final List<_PortBinding> _bindings = <_PortBinding>[];
  bool _closed = false;

  /// Whether the port is closed.
  bool get isClosed => _closed;

  @override
  Stream<Object?> get messages {
    if (listeners == DwiPortListeners.single) return _singleController!.stream;
    return Stream<Object?>.multi((controller) {
      final listener = _PortListener(
        sink: controller,
        isReady: () => controller.hasListener && !controller.isPaused,
        capacity: bufferSize,
      );
      controller.onResume = listener.drain;
      controller.onCancel = () => _removeBroadcast(listener);
      _broadcast.add(listener);
      if (_backlog.isNotEmpty) _flushBacklogInto(listener);
    });
  }

  @override
  Future<void> send(Object? message) async {
    _checkOpen();
    if (scope == DwiPortScope.hostOnly) {
      await _deliver(copyPortValue(message));
      return;
    }
    _checkBound();
    await Future.wait<void>(<Future<void>>[
      for (final binding in List<_PortBinding>.of(_bindings))
        binding._channel.send(message),
    ]);
  }

  @override
  Future<void> sendBytes(DwiTransferableBytes bytes) async {
    _checkOpen();
    if (scope == DwiPortScope.hostOnly) {
      await _deliver(bytes);
      return;
    }
    _checkBound();
    await Future.wait<void>(<Future<void>>[
      for (final binding in List<_PortBinding>.of(_bindings))
        binding._channel.sendBytes(bytes),
    ]);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _onClosed();
    final bindings = List<_PortBinding>.of(_bindings);
    _bindings.clear();
    await Future.wait<void>(<Future<void>>[
      for (final binding in bindings) binding.close(),
    ]);
    final single = _singleController;
    if (single != null) {
      _single?.close();
      // Not awaited: a single-subscription controller completes its close
      // future only once someone listens, and close must not wait for that.
      unawaited(single.close());
    }
    for (final listener in List<_PortListener>.of(_broadcast)) {
      listener.close();
      listener.sink.close();
    }
    _broadcast.clear();
    _backlog.clear();
  }

  /// Throws unless a worker may be bound to this port (ADR-032, decision 2).
  void ensureBindable() {
    _checkOpen();
    if (scope == DwiPortScope.hostOnly) {
      throw DwiUnsupportedException(
        'port "$name" is hostOnly and cannot be bound to a worker',
      );
    }
  }

  /// Attaches an open worker [channel] to this port and returns the binding.
  /// The caller opens [channel] with the name `port:<name>` and
  /// acknowledge-on-consume (ADR-023), after calling [ensureBindable].
  DwiPortBinding attach(DwiChannel channel) {
    ensureBindable();
    final binding = _PortBinding(this, channel);
    _bindings.add(binding);
    return binding;
  }

  void _checkOpen() {
    if (_closed) throw DwiChannelClosedException('port "$name" is closed');
  }

  void _checkBound() {
    if (_bindings.isEmpty) {
      throw DwiChannelStateException('no worker is bound to port "$name"');
    }
  }

  /// Delivers [message] to the host listeners, or holds it in the backlog while
  /// there is none. Used for host sends and for messages from bound workers.
  Future<void> _deliver(Object? message) async {
    final targets = _activeListeners();
    if (targets.isEmpty) {
      if (_backlog.length >= bufferSize) {
        throw DwiChannelBufferException(
          'port "$name" has $bufferSize undelivered messages and no listener',
        );
      }
      _backlog.add(message);
      return;
    }
    await Future.wait<void>(<Future<void>>[
      for (final listener in targets) listener.offer(message),
    ]);
  }

  List<_PortListener> _activeListeners() {
    if (listeners == DwiPortListeners.single) {
      final single = _single;
      return single != null && _singleController!.hasListener
          ? <_PortListener>[single]
          : const <_PortListener>[];
    }
    return List<_PortListener>.of(_broadcast);
  }

  void _attachSingle() {
    final single = _single;
    if (single != null && _backlog.isNotEmpty) _flushBacklogInto(single);
  }

  void _detachSingle() {
    // The single listener stays registered so a later `listen` reuses it; the
    // StreamController rejects a second subscription on its own.
  }

  void _removeBroadcast(_PortListener listener) {
    listener.close();
    _broadcast.remove(listener);
  }

  void _flushBacklogInto(_PortListener listener) {
    while (_backlog.isNotEmpty) {
      listener.queue.add(_backlog.removeFirst());
    }
    listener.drain();
  }

  void _removeBinding(_PortBinding binding) {
    _bindings.remove(binding);
  }
}

/// Deep-copies a host-only message so that listeners never share mutable state
/// (AGENTS.md rule 10). Accepts the value kinds that tasks accept; anything else
/// is a [DwiSerializationException].
Object? copyPortValue(Object? value) {
  switch (value) {
    case null:
    case bool():
    case num():
    case String():
    case DateTime():
    case Duration():
    case BigInt():
    case Uri():
    case Enum():
      return value;
    case Uint8List():
      return Uint8List.fromList(value);
    case List():
      return <Object?>[for (final item in value) copyPortValue(item)];
    case Map():
      return <Object?, Object?>{
        for (final entry in value.entries)
          copyPortValue(entry.key): copyPortValue(entry.value),
      };
    case DwiTransferableBytes():
      throw const DwiSerializationException(
        'transferable bytes must be sent with sendBytes',
      );
    default:
      throw DwiSerializationException(
        'a port cannot carry a value of type ${value.runtimeType}',
      );
  }
}

/// One host listener with its bounded queue (ADR-032, decision 4).
final class _PortListener {
  _PortListener({
    required this.sink,
    required this.isReady,
    required this.capacity,
  });

  final EventSink<Object?> sink;
  final bool Function() isReady;
  final int capacity;
  final Queue<Object?> queue = Queue<Object?>();
  final List<Completer<void>> _roomWaiters = <Completer<void>>[];
  bool _closed = false;

  /// Emits queued messages while the listener accepts them, then wakes senders
  /// waiting for room.
  void drain() {
    while (queue.isNotEmpty && isReady()) {
      sink.add(queue.removeFirst());
    }
    if (queue.length < capacity) {
      for (final waiter in _roomWaiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _roomWaiters.clear();
    }
  }

  /// Queues [message], waiting while the queue is full. Never drops it.
  Future<void> offer(Object? message) async {
    while (queue.length >= capacity && !_closed) {
      final waiter = Completer<void>();
      _roomWaiters.add(waiter);
      await waiter.future;
    }
    if (_closed) return;
    queue.add(message);
    drain();
  }

  void close() {
    _closed = true;
    queue.clear();
    for (final waiter in _roomWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _roomWaiters.clear();
  }
}

/// One worker's channel to a `workers` port.
final class _PortBinding implements DwiPortBinding {
  _PortBinding(this._port, this._channel) {
    // A failure nobody awaits must not be reported as unhandled; callers that
    // await [done] still receive the error.
    _done.future.ignore();
    _subscription = _channel.messages.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  final DwiPortEndpoint _port;
  final DwiChannel _channel;
  late final StreamSubscription<Object?> _subscription;
  final Completer<void> _done = Completer<void>();
  bool _ended = false;

  @override
  Future<void> get done => _done.future;

  void _onMessage(Object? message) {
    final delivery = _port._deliver(message);
    // The worker's next message waits until this one reached the listeners, so
    // a slow listener slows the worker instead of growing a queue.
    delivery.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) => _fail(error, stack),
    );
    _subscription.pause(delivery.then<void>((_) {}, onError: (_) {}));
  }

  void _onError(Object error, StackTrace stack) => _fail(error, stack);

  void _onDone() {
    _end();
    if (!_done.isCompleted) _done.complete();
  }

  void _fail(Object error, StackTrace stack) {
    if (!_done.isCompleted) _done.completeError(error, stack);
    unawaited(_endQuietly());
  }

  @override
  Future<void> close() async {
    await _endQuietly();
    if (!_done.isCompleted) _done.complete();
  }

  /// Ends the binding without completing [done] (used by the port on close).
  Future<void> _endQuietly() async {
    if (_ended) return;
    _end();
    try {
      await _channel.close();
    } on DwiException {
      // The channel may already be closed by the worker side; that is fine.
    }
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    _port._removeBinding(this);
    unawaited(_subscription.cancel());
  }
}
