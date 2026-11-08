/// Encodes and decodes wire envelopes without a backend.
///
/// Envelopes are plain maps, so they cross `postMessage` and isolate ports
/// unchanged. Showing the round trip in isolation is useful when debugging a
/// worker or writing a protocol test.
library;

import 'package:dwi_protocol/dwi_protocol.dart';

void main() {
  // A request from host to worker.
  const request = DwiEnvelope(
    type: DwiMessageType.request,
    id: 7,
    task: 'sum',
    payload: 100,
  );
  final wire = request.toMap();
  print('wire: $wire');

  final decoded = DwiEnvelope.fromMap(wire);
  print(
    'decoded: type=${decoded.type.name}, id=${decoded.id}, '
    'task=${decoded.task}, payload=${decoded.payload}, '
    'protocol=v${decoded.version}',
  );

  // Failures travel as typed error payloads on the same envelope shape.
  final failure = DwiEnvelope(
    type: DwiMessageType.error,
    id: 7,
    task: 'sum',
    error: const DwiErrorPayload(
      code: DwiErrorCode.remote,
      message: 'input must be a positive integer',
    ),
  );
  final roundTripped = DwiEnvelope.fromMap(failure.toMap());
  print(
    'error: ${roundTripped.error?.code.name}: '
    '${roundTripped.error?.message}',
  );
}
