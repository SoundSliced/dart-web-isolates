import 'package:dwi_protocol/dwi_protocol.dart' show dwiProtocolVersion;
import 'package:dwi_web/src/protocol_check.dart';
import 'package:test/test.dart';

void main() {
  test('the host protocol version is accepted', () {
    expect(workerProtocolMismatch(dwiProtocolVersion), isNull);
  });

  test('a missing version is a mismatch that says so', () {
    expect(workerProtocolMismatch(null), contains('did not report'));
  });

  test('an older or newer version is a mismatch that names it', () {
    final older = workerProtocolMismatch(dwiProtocolVersion - 1);
    final newer = workerProtocolMismatch(dwiProtocolVersion + 1);
    expect(older, contains('${dwiProtocolVersion - 1}'));
    expect(newer, contains('${dwiProtocolVersion + 1}'));
  });
}
