# dwi_protocol

Wire envelopes, message types and error payloads for DWI integrations.

Add `dwi_protocol` to build or inspect wire messages. For app tasks use
[dwi](https://pub.dev/packages/dwi).

Keep the envelope version, type and ID intact when relaying a message.
Consult the API reference for lifecycle, stream and channel message types.
An envelope represents a message. Sending it and settling the corresponding
call are backend responsibilities.

## Basic example

Encodes and decodes a request, then a typed error payload, without a backend.


```dart
/// Encodes and decodes wire envelopes without a backend.
///
/// Envelopes are plain maps, so they cross `postMessage` and isolate ports
/// unchanged. Showing the round trip in isolation is useful when debugging a
/// worker or writing a protocol test.

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
```

## Advanced example

Correlates a success response with its request ID.


```dart
import 'package:dwi_protocol/dwi_protocol.dart';

void main() {
  const request = DwiEnvelope(
    type: DwiMessageType.request,
    task: 'double',
    id: 7,
    payload: 21,
  );
  final received = DwiEnvelope.fromMap(request.toMap());
  final response = DwiEnvelope(
    type: DwiMessageType.result,
    id: received.id,
    payload: (received.payload as int) * 2,
  );
  final reply = DwiEnvelope.fromMap(response.toMap());
  if (reply.id != request.id || reply.type != DwiMessageType.result) {
    throw StateError('Unexpected response');
  }
  print(reply.payload);
}
```

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
