import 'package:dwi_annotations/dwi_annotations.dart';

@DwiPayload()
class Range {
  const Range(this.start, this.end);
  final int start;
  final int end;
}

class RangeTasks {
  @DwiTask()
  static Stream<int> count(Range range) async* {
    for (var value = range.start; value <= range.end; value++) {
      yield value;
    }
  }
}

@DwiTask()
int area((int, int) size) => size.$1 * size.$2;

Future<void> main() async {
  print(area((3, 4)));
  await for (final value in RangeTasks.count(const Range(1, 3))) {
    print(value);
  }
}
