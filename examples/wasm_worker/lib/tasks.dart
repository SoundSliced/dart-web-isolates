import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int calculatePrimes(int limit) {
  final composite = List<bool>.filled(limit + 1, true);
  var count = 0;
  for (var candidate = 2; candidate <= limit; candidate++) {
    if (!composite[candidate]) continue;
    count++;
    for (var multiple = candidate * candidate;
        multiple <= limit;
        multiple += candidate) {
      composite[multiple] = false;
    }
  }
  return count;
}
