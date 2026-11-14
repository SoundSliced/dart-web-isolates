import 'package:dwi_protocol/dwi_protocol.dart' show dwiProtocolVersion;

/// Why a worker's reported protocol version is not acceptable, or `null` when
/// it matches the host (ADR-026 G3).
///
/// [reported] is the `protocolVersion` in the worker's `ready` capabilities. A
/// missing value is a mismatch: a silent accept would let an incompatible
/// worker run calls it cannot decode.
String? workerProtocolMismatch(Object? reported) {
  if (reported == dwiProtocolVersion) return null;
  if (reported == null) {
    return 'worker ready message did not report a protocol version; '
        'the host speaks protocol $dwiProtocolVersion';
  }
  return 'worker reported protocol version $reported; the host speaks '
      'protocol $dwiProtocolVersion';
}
