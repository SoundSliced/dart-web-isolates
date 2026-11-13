import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:test/test.dart';

@DwiTask()
int plainTask(int input) => input * 2;

@DwiTask(name: 'renamed')
String namedTask() => 'value';

@DwiPayload()
class _Range {
  const _Range(this.start, {required this.end});
  final int start;
  final int end;
}

void main() {
  test('is a const-constructible marker', () {
    const marker = DwiTask();
    expect(marker.name, isNull);
    const renamed = DwiTask(name: 'custom');
    expect(renamed.name, 'custom');
  });

  test('DwiPayload is a const marker for classes', () {
    const marker = DwiPayload();
    expect(marker, isA<DwiPayload>());
    expect(const _Range(1, end: 2).end, 2);
  });

  test('can annotate top-level functions without runtime behaviour', () {
    expect(plainTask(21), 42);
    expect(namedTask(), 'value');
  });
}
