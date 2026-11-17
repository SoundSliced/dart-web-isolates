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
