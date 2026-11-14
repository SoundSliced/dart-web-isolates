import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    Dwi.registerTask('echo', (Object? input) => input);
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  test('metrics are off by default and count nothing', () async {
    expect(await Dwi.run<Object?>('echo', 1), 1);
    final metrics = Dwi.metrics();
    expect(metrics.callsStarted, 0);
    expect(metrics.callsCompleted, 0);
    expect(metrics.callsFailed, 0);
    expect(metrics.totalCallTime, Duration.zero);
  });
}
