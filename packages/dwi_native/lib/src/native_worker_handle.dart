import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';

/// Message that starts the persistent isolate belonging to one handle.
class _HandleStart {
  const _HandleStart(this.tasks, this.owner, this.channelBufferSize);

  final Map<String, DwiTaskFunction> tasks;
  final SendPort owner;
  final int channelBufferSize;
}

/// Converts transferable bytes into a real native transfer (ADR-010 §10.2).
Object? _encodeForIsolate(Object? value) {
  if (value is DwiTransferableBytes) {
    return TransferableTypedData.fromList(<Uint8List>[
      value.buffer.asUint8List(),
    ]);
  }
  return value;
}

Object? _decodeFromIsolate(Object? value) {
  if (value is TransferableTypedData) {
    return DwiTransferableBytes.fromBuffer(value.materialize());
  }
  return value;
}

/// Entry point of the persistent isolate owned by a [NativeWorkerHandle].
///
/// Sends its own `SendPort` back to the owner, then serves requests from one
/// receive loop for the lifetime of the handle. The task map is sent once at
/// startup, so isolate-local state captured by a task persists between calls.
void _handleMain(_HandleStart start) {
  final port = ReceivePort();
  start.owner.send(port.sendPort);
  var chain = Future<void>.value();
  port.listen((Object? message) {
    if (message is List && message.isNotEmpty && message[0] == 'request') {
      chain = chain.then<void>((_) => _handleRequest(start, message));
      return;
    }
    // Channel messages are not tasks: handle them immediately so a running
    // asynchronous task cannot block progress or conversation messages
    // (ADR-014). A synchronous task still blocks the isolate event loop.
    _handleChannel(start, message);
  });
}

/// Generations of the channels live in this isolate (name -> generation).
final Map<String, int> _channelGens = <String, int>{};

/// Serves channel traffic for one persistent isolate (ADR-014).
void _handleChannel(_HandleStart start, Object? message) {
  if (message is! List || message.length < 2 || message[0] is! String) {
    _send(start.owner, <Object?>[
      'protocol',
      'isolate received a malformed channel message',
    ]);
    return;
  }
  final kind = message[0]! as String;
  final name = message[1];
  if (name is! String) {
    _send(start.owner, <Object?>[
      'protocol',
      'channel message without a name',
    ]);
    return;
  }
  switch (kind) {
    case 'channelOpen':
      final bufferSize = message.length > 2 && message[2] is int
          ? message[2]! as int
          : start.channelBufferSize;
      final gen = message.length > 3 && message[3] is int
          ? message[3]! as int
          : 0;
      try {
        if (_channelGens.containsKey(name)) {
          throw DwiChannelStateException(
            'channel "$name" is already open in this worker',
          );
        }
        final endpoint = _isolateChannel(start, name, bufferSize, gen);
        DwiWorkerChannels.register(name, endpoint);
        _channelGens[name] = gen;
        endpoint.markOpened();
        _send(start.owner, <Object?>['channelOpened', name, gen, true]);
      } on DwiException catch (error) {
        _send(start.owner, <Object?>[
          'channelOpened',
          name,
          gen,
          false,
          error.message,
        ]);
      } catch (error) {
        _send(start.owner, <Object?>[
          'channelOpened',
          name,
          gen,
          false,
          '$error',
        ]);
      }
      return;
    case 'channelMessage':
      final gen = message.length > 2 ? message[2] : null;
      final seq = message.length > 3 ? message[3] : null;
      if (gen is! int || seq is! int) {
        _send(start.owner, <Object?>[
          'protocol',
          'channel message without a generation or sequence number',
        ]);
        return;
      }
      if (_channelGens[name] != gen) return;
      final endpoint = DwiWorkerChannels.find(name);
      if (endpoint is! DwiChannelEndpoint) {
        _send(start.owner, <Object?>[
          'channelError',
          name,
          gen,
          seq,
          'serialization',
          'channel "$name" is not open',
        ]);
        return;
      }
      Object? value;
      try {
        value = _decodeFromIsolate(message.length > 4 ? message[4] : null);
      } catch (error) {
        _send(start.owner, <Object?>[
          'protocol',
          'could not decode a channel message: $error',
        ]);
        return;
      }
      if (!endpoint.deliver(seq, value)) {
        _send(start.owner, <Object?>[
          'channelError',
          name,
          gen,
          seq,
          'channel',
          'channel "$name" is full',
        ]);
      }
      return;
    case 'channelError':
      final gen = message.length > 2 ? message[2] : null;
      final seq = message.length > 3 ? message[3] : null;
      if (gen is! int || _channelGens[name] != gen) return;
      final endpoint = DwiWorkerChannels.find(name);
      final text = message.length > 5 && message[5] is String
          ? message[5]! as String
          : 'channel "$name" is full';
      if (seq is int && endpoint is DwiChannelEndpoint) {
        endpoint.reject(seq, DwiChannelBufferException(text));
      }
      return;
    case 'channelAck':
      final gen = message.length > 2 ? message[2] : null;
      final seq = message.length > 3 ? message[3] : null;
      if (gen is! int || seq is! int || _channelGens[name] != gen) return;
      final endpoint = DwiWorkerChannels.find(name);
      if (endpoint is DwiChannelEndpoint) endpoint.ack(seq);
      return;
    case 'channelClose':
    case 'channelClosed':
      final gen = message.length > 2 ? message[2] : null;
      if (gen is! int || _channelGens[name] != gen) return;
      final endpoint = DwiWorkerChannels.find(name);
      if (endpoint is DwiChannelEndpoint) endpoint.peerClosed();
      return;
    default:
      _send(start.owner, <Object?>[
        'protocol',
        'unknown channel message "$kind"',
      ]);
  }
}

DwiChannelEndpoint _isolateChannel(
  _HandleStart start,
  String name,
  int bufferSize,
  int gen,
) {
  return DwiChannelEndpoint(
    name: name,
    bufferSize: bufferSize,
    onSend: (seq, message, transfer) {
      final payload = transfer ? _encodeForIsolate(message) : message;
      start.owner.send(<Object?>['channelMessage', name, gen, seq, payload]);
      if (transfer && message is DwiTransferableBytes) message.markSent();
    },
    onAck: (seq) => start.owner.send(<Object?>['channelAck', name, gen, seq]),
    onClose: () => start.owner.send(<Object?>['channelClose', name, gen]),
    onClosed: () => start.owner.send(<Object?>['channelClosed', name, gen]),
    onTerminated: () {
      if (_channelGens[name] == gen) {
        _channelGens.remove(name);
        DwiWorkerChannels.remove(name);
      }
    },
  );
}

Future<void> _handleRequest(_HandleStart start, Object? message) async {
  if (message is! List || message.length < 4 || message[0] != 'request') {
    _send(start.owner, <Object?>['protocol', 'isolate received a malformed request']);
    return;
  }
  final id = message[1];
  final task = message[2];
  if (id is! int || task is! String) {
    _send(start.owner, <Object?>['protocol', 'request id or task has the wrong type']);
    return;
  }
  final implementation = start.tasks[task];
  if (implementation == null) {
    _send(start.owner, <Object?>[
      id,
      false,
      'unknownTask',
      'unknown task "$task"',
      '',
      '',
    ]);
    return;
  }

  Object? input;
  try {
    input = _decodeFromIsolate(message[3]);
  } catch (error) {
    _send(start.owner, <Object?>[
      id,
      false,
      'serialization',
      'could not decode the task input: $error',
      '',
      '',
    ]);
    return;
  }

  try {
    final value = await Future<Object?>.sync(
      () => implementation(input),
    );
    _send(start.owner, <Object?>[id, true, _encodeForIsolate(value)]);
  } catch (error, stack) {
    _send(start.owner, <Object?>[
      id,
      false,
      'remote',
      error.toString(),
      error.runtimeType.toString(),
      stack.toString(),
    ]);
  }
}

/// Sends [message]; a value that cannot cross the boundary becomes a typed
/// serialization error, and an unsendable error terminates the isolate so the
/// owner fails instead of waiting for a reply that cannot arrive.
void _send(SendPort port, List<Object?> message) {
  try {
    port.send(message);
  } catch (error) {
    // A result reply is [id, ok, payload]; its id is element 0. Reusing
    // element 1 (the success flag) as the id would make the owner read a
    // malformed reply and fail the whole handle.
    final id = message.isNotEmpty && message[0] is int ? message[0] : null;
    try {
      port.send(<Object?>[
        id,
        false,
        'serialization',
        'could not send the result: $error',
        '',
        '',
      ]);
    } catch (_) {
      Isolate.exit();
    }
  }
}

/// One live channel on the host side, tagged with its generation.
class _HostChannel {
  const _HostChannel(this.gen, this.endpoint);

  final int gen;
  final DwiChannelEndpoint endpoint;
}

/// One call waiting for, or holding, the dedicated isolate.
class _Call {
  _Call(this.task, this.input);

  final String task;
  final Object? input;
  late final DwiCancellableTask<Object?> handle;
  Completer<Object?>? reply;
  Timer? queueTimer;
  int? id;
  bool queued = true;
}

/// A handle backed by one persistent Dart isolate (ADR-013).
///
/// Created through [spawn]. The isolate is started once and answers from a
/// receive loop; it is terminated by [close] or by a failure. All calls run one
/// at a time in FIFO order.
class NativeWorkerHandle implements DwiWorkerHandle {
  NativeWorkerHandle._(this._registry, this._config, this._onClosed);

  /// Starts an isolate and waits until it answered with its `SendPort`.
  ///
  /// Throws [DwiStartupException] when the isolate cannot start or does not
  /// become ready within `DwiConfig.startupTimeout`.
  static Future<NativeWorkerHandle> spawn(
    DwiTaskRegistry registry,
    DwiConfig config, {
    void Function()? onClosed,
  }) async {
    final handle = NativeWorkerHandle._(
      registry,
      config.validated(),
      onClosed,
    );
    await handle._start();
    return handle;
  }

  final DwiTaskRegistry _registry;
  final DwiConfig _config;
  final void Function()? _onClosed;

  DwiWorkerState _state = DwiWorkerState.created;
  Isolate? _isolate;
  ReceivePort? _port;
  SendPort? _workerPort;
  Completer<SendPort>? _ready;
  final List<_Call> _queue = <_Call>[];
  _Call? _activeCall;
  Completer<Object?>? _activeReply;
  int _nextId = 1;
  int _nextChannelGen = 1;
  final Map<String, _HostChannel> _channels = <String, _HostChannel>{};

  @override
  DwiWorkerState get state => _state;

  @override
  bool get isUsable => _state == DwiWorkerState.ready;

  @override
  Future<Object?> run(String task, Object? input) => start(task, input).result;

  @override
  DwiCancellableTask<Object?> start(String task, Object? input) {
    final call = _Call(task, input);
    final handle = DwiCancellableTask<Object?>(
      cancel: () => _cancel(call),
    );
    call.handle = handle;
    handle.result.ignore();

    if (!isUsable) {
      handle.completeError(_stateError());
      return handle;
    }
    if (_activeCall != null && _queue.length >= _config.maxQueuedTasks) {
      handle.completeError(
        DwiUnsupportedException(
          'worker queue is full (${_config.maxQueuedTasks} waiting)',
        ),
      );
      return handle;
    }
    _queue.add(call);
    call.queueTimer = Timer(_config.queueTimeout, () {
      if (!call.queued) return;
      if (_queue.remove(call)) {
        call.queued = false;
        _settle(
          call,
          error: DwiTimeoutException(
            'task "$task" waited more than '
            '${_config.queueTimeout.inMilliseconds} ms in the queue',
          ),
        );
      }
    });
    _pump();
    return handle;
  }

  DwiException _stateError() {
    switch (_state) {
      case DwiWorkerState.failed:
        return const DwiWorkerFailedException(
          'worker handle has failed; call restart() or spawn a new handle',
        );
      case DwiWorkerState.closed:
        return const DwiWorkerClosedException('worker handle is closed');
      case DwiWorkerState.closing:
        return const DwiWorkerStateException('worker handle is closing');
      case DwiWorkerState.starting:
      case DwiWorkerState.created:
        return const DwiWorkerStateException('worker handle is starting');
      case DwiWorkerState.ready:
        return const DwiWorkerStateException('worker handle is not usable');
    }
  }

  void _pump() {
    if (_state != DwiWorkerState.ready ||
        _activeCall != null ||
        _queue.isEmpty) {
      return;
    }
    final call = _queue.removeAt(0);
    call.queued = false;
    call.queueTimer?.cancel();
    _activeCall = call;
    unawaited(_dispatch(call));
  }

  Future<void> _dispatch(_Call call) async {
    final reply = Completer<Object?>();
    final id = _nextId++;
    call.id = id;
    call.reply = reply;
    _activeReply = reply;
    final workerPort = _workerPort;
    if (workerPort == null) {
      _settle(
        call,
        error: const DwiWorkerFailedException(
          'worker isolate is not available',
        ),
      );
      _clearActive(call);
      return;
    }

    final transferable = call.input is DwiTransferableBytes
        ? call.input! as DwiTransferableBytes
        : null;
    Object? payload;
    try {
      payload = transferable == null
          ? call.input
          : _encodeForIsolate(transferable);
    } catch (error) {
      _settle(
        call,
        error: DwiSerializationException(
          'could not send task "${call.task}": $error',
        ),
      );
      _clearActive(call);
      return;
    }

    try {
      workerPort.send(<Object?>['request', id, call.task, payload]);
      // Ownership leaves the caller only after the isolate accepted the send.
      transferable?.markSent();
    } catch (error) {
      _settle(
        call,
        error: DwiSerializationException(
          'could not send task "${call.task}": $error',
        ),
      );
      _clearActive(call);
      return;
    }

    try {
      final value = await reply.future.timeout(_config.taskTimeout);
      _settle(call, value: value);
    } on TimeoutException {
      final error = DwiTimeoutException(
        'task "${call.task}" exceeded '
        '${_config.taskTimeout.inMilliseconds} ms',
      );
      _settle(call, error: error);
      _fail(
        DwiWorkerFailedException(
          'worker handle failed after a task timeout',
        ),
      );
    } catch (error) {
      if (error is DwiException) {
        _settle(call, error: error);
      } else {
        _settle(
          call,
          error: DwiRemoteException(
            message: error.toString(),
            remoteType: error.runtimeType.toString(),
          ),
        );
      }
    } finally {
      _clearActive(call);
    }
  }

  void _clearActive(_Call call) {
    if (identical(_activeCall, call)) {
      _activeCall = null;
      _activeReply = null;
      _pump();
    }
  }

  void _settle(_Call call, {Object? value, DwiException? error}) {
    call.queueTimer?.cancel();
    call.queued = false;
    if (call.handle.isDone) return;
    if (error != null) {
      call.handle.completeError(error);
    } else {
      call.handle.complete(value);
    }
  }

  Future<bool> _cancel(_Call call) async {
    if (call.handle.isDone) return false;
    final error = DwiCancelledException(
      'task "${call.task}" was cancelled',
    );
    if (call.queued && _queue.remove(call)) {
      // Queued cancellation keeps the isolate: nothing has been sent yet.
      _settle(call, error: error);
      return true;
    }
    if (identical(_activeCall, call)) {
      // A running task cannot observe a message, so the context is killed.
      _settle(call, error: error);
      _fail(
        const DwiWorkerFailedException(
          'worker handle failed after cancelling a running task',
        ),
      );
      return true;
    }
    return false;
  }

  /// Routes one channel message from the isolate (ADR-014).
  ///
  /// Every channel message carries the generation assigned when the channel was
  /// opened, so a reply for a closed channel can never be routed to a channel
  /// that later reused the same name.
  void _onChannelMessage(List<Object?> message) {
    if (message.length < 3 || message[1] is! String || message[2] is! int) {
      _fail(
        const DwiWorkerFailedException(
          'worker isolate sent a malformed channel message',
        ),
      );
      return;
    }
    final name = message[1]! as String;
    final gen = message[2]! as int;
    final entry = _channels[name];
    if (entry == null || entry.gen != gen) {
      // A stale message for a channel this handle already closed.
      return;
    }
    final channel = entry.endpoint;
    switch (message[0]) {
      case 'channelOpened':
        final ok = message.length > 3 && message[3] == true;
        if (ok) {
          channel.markOpened();
        } else {
          final reason = message.length > 4 && message[4] is String
              ? message[4]! as String
              : '';
          _channels.remove(name);
          channel.failOpen(
            DwiChannelStateException(
              reason.isEmpty ? 'worker refused channel "$name"' : reason,
            ),
          );
        }
      case 'channelMessage':
        final seq = message.length > 3 ? message[3] : null;
        if (seq is! int) {
          _fail(
            const DwiWorkerFailedException(
              'worker isolate sent a channel message without a sequence number',
            ),
          );
          return;
        }
        Object? value;
        try {
          value = _decodeFromIsolate(message.length > 4 ? message[4] : null);
        } catch (error) {
          _fail(
            DwiRemoteException(
              message: 'could not decode a channel message: $error',
            ),
          );
          return;
        }
        if (!channel.deliver(seq, value)) {
          _workerPort?.send(<Object?>[
            'channelError',
            name,
            gen,
            seq,
            'channel',
            'channel "$name" is full',
          ]);
        }
      case 'channelAck':
        final seq = message.length > 3 ? message[3] : null;
        if (seq is int) channel.ack(seq);
      case 'channelClose':
      case 'channelClosed':
        channel.peerClosed();
      case 'channelError':
        final seq = message.length > 3 ? message[3] : null;
        final text = message.length > 5 && message[5] is String
            ? message[5]! as String
            : '';
        if (seq is int) {
          channel.reject(
            seq,
            DwiChannelBufferException(
              text.isEmpty ? 'channel "$name" is full' : text,
            ),
          );
        } else {
          channel.fail(
            DwiSerializationException(
              text.isEmpty ? 'worker could not send on channel "$name"' : text,
            ),
          );
        }
      default:
        _fail(
          DwiWorkerFailedException(
            'worker isolate sent an unexpected channel message "${message[0]}"',
          ),
        );
    }
  }

  @override
  Future<DwiChannel> openChannel(String name) async {
    validateDwiChannelName(name);
    if (!isUsable) throw _stateError();
    if (_channels.containsKey(name)) {
      throw DwiChannelStateException(
        'channel "$name" is already open on this handle',
      );
    }
    final workerPort = _workerPort;
    if (workerPort == null) {
      throw const DwiWorkerFailedException('worker isolate is not available');
    }
    final gen = _nextChannelGen++;
    final channel = _createChannel(name, gen);
    _channels[name] = _HostChannel(gen, channel);
    try {
      workerPort.send(<Object?>[
        'channelOpen',
        name,
        _config.channelBufferSize,
        gen,
      ]);
    } catch (error) {
      _channels.remove(name);
      final failure = DwiSerializationException(
        'could not open channel "$name": $error',
      );
      channel.failOpen(failure);
      throw failure;
    }
    try {
      await channel.open();
    } catch (_) {
      _channels.remove(name);
      rethrow;
    }
    return channel;
  }

  DwiChannelEndpoint _createChannel(String name, int gen) {
    return DwiChannelEndpoint(
      name: name,
      bufferSize: _config.channelBufferSize,
      onSend: (seq, message, transfer) {
        final workerPort = _workerPort;
        if (workerPort == null) {
          throw const DwiWorkerFailedException(
            'worker isolate is not available',
          );
        }
        final payload = transfer ? _encodeForIsolate(message) : message;
        workerPort.send(<Object?>['channelMessage', name, gen, seq, payload]);
        if (transfer && message is DwiTransferableBytes) message.markSent();
      },
      onAck: (seq) =>
          _workerPort?.send(<Object?>['channelAck', name, gen, seq]),
      onClose: () => _workerPort?.send(<Object?>['channelClose', name, gen]),
      onClosed: () => _workerPort?.send(<Object?>['channelClosed', name, gen]),
      onTerminated: () {
        final entry = _channels[name];
        if (entry != null && entry.gen == gen) _channels.remove(name);
      },
    );
  }

  @override
  Future<void> restart() async {
    if (_state != DwiWorkerState.failed) {
      throw const DwiWorkerStateException(
        'only a failed worker handle can be restarted',
      );
    }
    await _start();
  }

  Future<void> _start() async {
    _state = DwiWorkerState.starting;
    _queue.clear();
    _channels.clear();
    final port = ReceivePort();
    _port = port;
    port.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        _fail(
          DwiRemoteException(
            message: 'isolate port error: $error',
            remoteStack: stack.toString(),
          ),
        );
      },
    );

    final ready = Completer<SendPort>();
    _ready = ready;
    final names = _registry.names.toList(growable: false);
    final tasks = <String, DwiTaskFunction>{
      for (final name in names) name: _registry.lookup(name),
    };

    Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _handleMain,
        _HandleStart(tasks, port.sendPort, _config.channelBufferSize),
        debugName: 'dwi-handle',
      );
    } catch (error) {
      _state = DwiWorkerState.failed;
      _port = null;
      _ready = null;
      port.close();
      throw DwiStartupException('could not start the worker isolate: $error');
    }
    _isolate = isolate;
    isolate.addOnExitListener(port.sendPort, response: 'exit');

    try {
      _workerPort = await ready.future.timeout(_config.startupTimeout);
      _ready = null;
      _state = DwiWorkerState.ready;
      _pump();
    } on TimeoutException {
      _state = DwiWorkerState.failed;
      _ready = null;
      _workerPort = null;
      _isolate = null;
      _port = null;
      port.close();
      isolate.kill(priority: Isolate.immediate);
      throw DwiStartupException(
        'worker isolate did not become ready within '
        '${_config.startupTimeout.inMilliseconds} ms',
      );
    } catch (error) {
      _state = DwiWorkerState.failed;
      _ready = null;
      _workerPort = null;
      _isolate = null;
      _port = null;
      port.close();
      isolate.kill(priority: Isolate.immediate);
      if (error is DwiException) rethrow;
      throw DwiStartupException('worker isolate failed to start: $error');
    }
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete(message);
      return;
    }
    if (message is String && message == 'exit') {
      _onIsolateExit();
      return;
    }
    if (_state == DwiWorkerState.closed || _state == DwiWorkerState.closing) {
      return;
    }
    if (message is! List || message.isEmpty) {
      _fail(
        const DwiWorkerFailedException(
          'worker isolate sent a malformed message',
        ),
      );
      return;
    }

    if (message[0] is String) {
      if (message[0] == 'protocol') {
        _fail(
          DwiWorkerFailedException(
            message.length > 1
                ? 'worker isolate reported a protocol error: ${message[1]}'
                : 'worker isolate reported a protocol error',
          ),
        );
        return;
      }
      _onChannelMessage(message);
      return;
    }

    final id = message[0];
    if (id is! int) {
      _fail(
        const DwiWorkerFailedException(
          'worker isolate reported a protocol error',
        ),
      );
      return;
    }
    final call = _activeCall;
    final reply = _activeReply;
    if (call == null || call.id != id || reply == null || reply.isCompleted) {
      // A late reply for a call that already settled is ignored.
      return;
    }

    if (message.length >= 3 && message[1] == true) {
      try {
        reply.complete(_decodeFromIsolate(message[2]));
      } catch (error) {
        _fail(
          DwiRemoteException(
            message: 'could not decode the task result: $error',
            taskId: id,
          ),
        );
      }
      return;
    }

    if (message.length < 4) {
      _fail(
        const DwiWorkerFailedException(
          'worker isolate sent a malformed error reply',
        ),
      );
      return;
    }
    final code = message[2];
    final text = message[3] is String ? message[3]! as String : '';
    final remoteType = message.length > 4 && message[4] is String
        ? message[4]! as String
        : '';
    final remoteStack = message.length > 5 && message[5] is String
        ? message[5]! as String
        : '';
    switch (code) {
      case 'unknownTask':
        reply.completeError(DwiUnknownTaskException(text));
      case 'serialization':
        reply.completeError(DwiSerializationException(text));
      case 'remote':
        reply.completeError(
          DwiRemoteException(
            message: text,
            remoteType: remoteType,
            remoteStack: remoteStack,
            taskId: id,
          ),
        );
      default:
        _fail(
          DwiRemoteException(
            message: 'worker isolate reported "$code": $text',
            remoteType: remoteType,
            remoteStack: remoteStack,
            taskId: id,
          ),
        );
    }
  }

  void _onIsolateExit() {
    if (_state == DwiWorkerState.closing ||
        _state == DwiWorkerState.closed ||
        _state == DwiWorkerState.failed) {
      return;
    }
    _fail(
      const DwiWorkerFailedException(
        'worker isolate exited unexpectedly',
      ),
    );
  }

  /// Moves the handle to `failed`, settles every caller, and kills the isolate.
  void _fail(DwiException error) {
    if (_state == DwiWorkerState.failed ||
        _state == DwiWorkerState.closing ||
        _state == DwiWorkerState.closed) {
      return;
    }
    _state = DwiWorkerState.failed;

    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(DwiStartupException(error.message));
    }
    final reply = _activeReply;
    _activeReply = null;
    if (reply != null && !reply.isCompleted) reply.completeError(error);

    final waiting = List<_Call>.of(_queue);
    _queue.clear();
    for (final call in waiting) {
      _settle(
        call,
        error: DwiWorkerFailedException(
          'worker handle failed before the call ran: ${error.message}',
        ),
      );
    }

    _workerPort = null;
    final channels =
        _channels.values.map((entry) => entry.endpoint).toList();
    _channels.clear();
    for (final channel in channels) {
      channel.fail(error);
    }
    final port = _port;
    _port = null;
    final isolate = _isolate;
    _isolate = null;
    port?.close();
    isolate?.kill(priority: Isolate.immediate);
  }

  @override
  Future<void> close() async {
    if (_state == DwiWorkerState.closed ||
        _state == DwiWorkerState.closing) {
      return;
    }
    _state = DwiWorkerState.closing;
    const error = DwiWorkerClosedException('worker handle was closed');

    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    final reply = _activeReply;
    _activeReply = null;
    if (reply != null && !reply.isCompleted) reply.completeError(error);

    final active = _activeCall;
    _activeCall = null;
    if (active != null) _settle(active, error: error);
    final waiting = List<_Call>.of(_queue);
    _queue.clear();
    for (final call in waiting) {
      _settle(call, error: error);
    }

    _workerPort = null;
    final channels =
        _channels.values.map((entry) => entry.endpoint).toList();
    _channels.clear();
    for (final channel in channels) {
      channel.fail(error);
    }
    final port = _port;
    _port = null;
    final isolate = _isolate;
    _isolate = null;
    port?.close();
    isolate?.kill(priority: Isolate.immediate);
    _state = DwiWorkerState.closed;
    _onClosed?.call();
  }
}
