/// The version of the DWI wire protocol implemented by this package.
const int dwiProtocolVersion = 1;

/// Message kinds understood by a DWI runtime.
enum DwiMessageType {
  ready,
  request,
  result,
  error,
  cancel,
  cancelled,
  heartbeat,
  shutdown,
  closed;

  static DwiMessageType? tryParse(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// Machine-readable error categories carried by an [DwiErrorPayload].
enum DwiErrorCode {
  remote,
  timeout,
  protocol,
  unknownTask,
  serialization,
  internal;

  static DwiErrorCode parse(Object? value) {
    for (final code in values) {
      if (code.name == value) return code;
    }
    return DwiErrorCode.protocol;
  }
}

/// The payload of an `error` message.
///
/// Error text and stack are data. They must never be evaluated as code.
class DwiErrorPayload {
  const DwiErrorPayload({
    required this.code,
    required this.message,
    this.remoteType = '',
    this.remoteStack = '',
    this.fatal = false,
    this.taskId,
  });

  final DwiErrorCode code;
  final String message;
  final String remoteType;
  final String remoteStack;
  final bool fatal;
  final int? taskId;

  Map<String, Object?> toMap() => <String, Object?>{
        'code': code.name,
        'message': message,
        'remoteType': remoteType,
        'remoteStack': remoteStack,
        'fatal': fatal,
        'taskId': taskId,
      };

  factory DwiErrorPayload.fromMap(Map<Object?, Object?> map) {
    final message = map['message'];
    if (message is! String) {
      throw const DwiProtocolException('error.message must be a string');
    }
    final rawTaskId = map['taskId'];
    final taskId = rawTaskId == null ? null : _asInt(rawTaskId);
    if (rawTaskId != null && taskId == null) {
      throw const DwiProtocolException('error.taskId must be an int or null');
    }
    return DwiErrorPayload(
      code: DwiErrorCode.parse(map['code']),
      message: message,
      remoteType: map['remoteType'] is String ? map['remoteType']! as String : '',
      remoteStack:
          map['remoteStack'] is String ? map['remoteStack']! as String : '',
      fatal: map['fatal'] == true,
      taskId: taskId,
    );
  }
}

/// A single protocol message.
class DwiEnvelope {
  const DwiEnvelope({
    required this.type,
    this.id,
    this.task,
    this.payload,
    this.error,
    this.meta = const <String, Object?>{},
    this.version = dwiProtocolVersion,
  });

  final int version;
  final DwiMessageType type;
  final int? id;
  final String? task;
  final Object? payload;
  final DwiErrorPayload? error;
  final Map<String, Object?> meta;

  /// Encodes the envelope into a structured-cloneable map.
  Map<String, Object?> toMap() => <String, Object?>{
        'v': version,
        'type': type.name,
        'id': id,
        'task': task,
        'payload': payload,
        'error': error?.toMap(),
        'meta': meta,
      };

  /// Decodes and validates an envelope.
  ///
  /// Throws [DwiProtocolException] for malformed or unsupported messages.
  factory DwiEnvelope.fromMap(Map<Object?, Object?> map) {
    final version = _asInt(map['v']);
    if (version == null) {
      throw const DwiProtocolException('message.v must be an int');
    }
    if (version != dwiProtocolVersion) {
      throw DwiProtocolException(
        'unsupported protocol version $version (expected $dwiProtocolVersion)',
      );
    }
    final typeName = map['type'];
    if (typeName is! String) {
      throw const DwiProtocolException('message.type must be a string');
    }
    final type = DwiMessageType.tryParse(typeName);
    if (type == null) {
      throw DwiProtocolException('unknown message type "$typeName"');
    }
    final rawId = map['id'];
    final id = rawId == null ? null : _asInt(rawId);
    if (rawId != null && (id == null || id < 0)) {
      throw const DwiProtocolException('message.id must be a non-negative int');
    }
    final task = map['task'];
    if (task != null && task is! String) {
      throw const DwiProtocolException('message.task must be a string');
    }
    final rawError = map['error'];
    if (rawError != null && rawError is! Map) {
      throw const DwiProtocolException('message.error must be a map or null');
    }
    final rawMeta = map['meta'];
    if (rawMeta != null && rawMeta is! Map) {
      throw const DwiProtocolException('message.meta must be a map or null');
    }
    return DwiEnvelope(
      version: version,
      type: type,
      id: id,
      task: task as String?,
      payload: map['payload'],
      error: rawError == null
          ? null
          : DwiErrorPayload.fromMap(Map<Object?, Object?>.from(rawError as Map)),
      meta: rawMeta == null
          ? const <String, Object?>{}
          : Map<String, Object?>.from(rawMeta as Map),
    );
  }

  @override
  String toString() => 'DwiEnvelope(${type.name}, id: $id, task: $task)';
}

/// Thrown when a message is malformed or violates the protocol.
class DwiProtocolException implements Exception {
  const DwiProtocolException(this.message);

  final String message;

  @override
  String toString() => 'DwiProtocolException: $message';
}

/// Reads a wire integer that may arrive as an integral `double`.
///
/// A dart2wasm host and a dart2js worker exchange JS numbers, and `dartify()`
/// can surface an integral value as `double` on the wasm side. Rejecting that
/// made the two compilers unable to talk at all (limitations §29). A
/// non-integral number is still a protocol error.
int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}
