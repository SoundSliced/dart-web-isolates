import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:test/test.dart';

@DwiTask()
int plainTask(int input) => input * 2;

@DwiTask(name: 'renamed')
String namedTask() => 'value';

void main() {
  test('is a const-constructible marker', () {
    const marker = DwiTask();
    expect(marker.name, isNull);
    const renamed = DwiTask(name: 'custom');
    expect(renamed.name, 'custom');
  });

  test('can annotate top-level functions without runtime behaviour', () {
    expect(plainTask(21), 42);
    expect(namedTask(), 'value');
  });
}
