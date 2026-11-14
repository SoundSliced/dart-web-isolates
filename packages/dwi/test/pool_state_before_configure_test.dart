import 'package:dwi/dwi.dart';
import 'package:test/test.dart';

void main() {
  test('poolState and metrics before any configure are empty and zero', () {
    final pool = Dwi.poolState();
    expect(pool.workers, isEmpty);
    expect(pool.queued, 0);
    expect(pool.maxWorkers, const DwiConfig().maxWorkers);

    final metrics = Dwi.metrics();
    expect(metrics.callsStarted, 0);
    expect(metrics.callsRunning, 0);
  });
}
