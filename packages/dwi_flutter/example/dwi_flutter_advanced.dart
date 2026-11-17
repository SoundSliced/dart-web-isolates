import 'package:dwi/dwi.dart';
import 'package:dwi_flutter/dwi_flutter.dart';

int square(Object? input) {
  final value = input as int;
  if (value < 0) throw ArgumentError.value(value, 'input');
  return value * value;
}

Future<void> main() async {
  Dwi.registerTask('square', square);
  await Dwi.configure(const DwiConfig(maxWorkers: 2));
  Future<int> runSquare(int value) => Dwi.run<int>('square', value);
  try {
    print(await computeParallel(runSquare, [3, 1, 2]));
    print(await computeParallel(runSquare, <int>[]));
    await computeParallel(runSquare, [3, -1, 2]);
  } on DwiException catch (error) {
    print('Batch failed: $error');
  } finally {
    await Dwi.close(drain: true);
  }
}
