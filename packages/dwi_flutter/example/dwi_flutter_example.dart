import 'package:dwi/dwi.dart';
import 'package:dwi_flutter/dwi_flutter.dart';

int doubleInput(Object? input) => (input as int) * 2;

Future<void> main() async {
  Dwi.registerTask('double', doubleInput);
  try {
    final result = await computeParallel(
      (int input) => Dwi.run<int>('double', input),
      [1, 2, 3],
    );
    print(result); // [2, 4, 6]
  } finally {
    await Dwi.close();
  }
}
