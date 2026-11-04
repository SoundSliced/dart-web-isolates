import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';

/// Validates that [value] can cross the DWI structured-clone boundary.
///
/// DWI v0.3 uses `Map.jsify()` and `JSAny.dartify()` for transport. Those
/// functions do not reject unsupported Dart values: a closure becomes `{}` and
/// a class instance loses its type. Sending such a value silently corrupts the
/// payload, so every value is checked before it reaches `postMessage`.
///
/// Supported values are `null`, `num`, `String`, `bool`, `List`, `Set`, `Map`
/// with `String` keys, and typed-data values. Everything else fails with
/// [DwiSerializationException].
///
/// When [maxBytes] is set, the walk also enforces an approximate payload budget.
/// Strings are counted by UTF-16 code units and containers carry a small
/// per-entry overhead; the budget is a resource guard, not an exact wire size.
void validateDwiPayload(
  Object? value, {
  String path = 'payload',
  int? maxBytes,
}) {
  _validate(value, path, _ByteBudget(maxBytes));
}

void _validate(Object? value, String path, _ByteBudget budget) {
  budget.add(8, path);
  if (value == null || value is num || value is bool) return;
  if (value is DwiTransferableBytes) {
    // Detached wrappers throw here, before anything reaches postMessage.
    budget.add(value.lengthInBytes, path);
    value.buffer;
    return;
  }
  if (value is String) {
    budget.add(value.length, path);
    return;
  }
  if (value is ByteData) {
    budget.add(value.lengthInBytes, path);
    return;
  }
  if (value is TypedData) {
    budget.add(value.lengthInBytes, path);
    return;
  }
  if (value is ByteBuffer) {
    budget.add(value.lengthInBytes, path);
    return;
  }
  if (value is List) {
    for (var index = 0; index < value.length; index++) {
      _validate(value[index], '$path[$index]', budget);
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw DwiSerializationException(
          '$path: map keys must be String, got ${entry.key.runtimeType}',
        );
      }
      budget.add((entry.key! as String).length, '$path[${entry.key}]');
      _validate(entry.value, '$path[${entry.key}]', budget);
    }
    return;
  }
  if (value is Set) {
    var index = 0;
    for (final element in value) {
      _validate(element, '$path{$index}', budget);
      index++;
    }
    return;
  }
  throw DwiSerializationException(
    '$path: ${value.runtimeType} is not structured-cloneable by DWI. '
    'Use primitives, List, Map with String keys, Set or typed data.',
  );
}

class _ByteBudget {
  _ByteBudget(this.limit);

  final int? limit;
  int used = 0;

  void add(int bytes, String path) {
    used += bytes;
    final limit = this.limit;
    if (limit != null && used > limit) {
      throw DwiSerializationException(
        '$path exceeds maxPayloadBytes ($limit bytes, estimated $used)',
      );
    }
  }
}
