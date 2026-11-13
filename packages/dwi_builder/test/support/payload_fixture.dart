import 'package:test/test.dart';

/// Shared ADR-021 acceptance fixture: the same model, tasks and calls run on
/// native isolates and in every browser host/worker combination.

/// `lib/model.dart`: an enum and two `@DwiPayload` classes, one recursive.
const String payloadModel = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

enum Color { red, green, blue }

@DwiPayload()
class Range {
  const Range(this.start, {required this.end, this.label});
  final int start;
  final int end;
  final String? label;
}

@DwiPayload()
class Node {
  Node(this.value, this.children, {this.color = Color.red, this.at});
  final int value;
  final List<Node> children;
  final Color color;
  final DateTime? at;
}
''';

/// `lib/tasks.dart`: one task per payload shape.
const String payloadTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';
import 'model.dart';

@DwiTask()
Color nextColor(Color color) =>
    Color.values[(color.index + 1) % Color.values.length];
@DwiTask()
List<Color?> colors(Set<Color> input) => <Color?>[...input, null];
@DwiTask()
DateTime addDay(DateTime time) => time.add(const Duration(days: 1));
@DwiTask()
Duration twice(Duration value) => value * 2;
@DwiTask()
BigInt square(BigInt value) => value * value;
@DwiTask()
Uri withPath(Uri uri) => uri.replace(path: '/worker');
@DwiTask()
(int, String, {bool flag}) swap((String, int, {bool flag}) value) =>
    (value.$2, value.$1, flag: !value.flag);
@DwiTask()
(int,) one((int,) value) => (value.$1 + 1,);
@DwiTask()
Future<Range> widen(Range range) async =>
    Range(range.start - 1, end: range.end + 1, label: range.label);
@DwiTask()
int sumTree(Node node) =>
    node.value + node.children.fold(0, (sum, child) => sum + sumTree(child));
@DwiTask()
Node? maybe(Node? node) => node;
@DwiTask()
Map<String, List<(Color, Duration)>> group(List<(Color, Duration)> items) {
  final result = <String, List<(Color, Duration)>>{};
  for (final item in items) {
    (result[item.$1.name] ??= <(Color, Duration)>[]).add(item);
  }
  return result;
}
@DwiTask()
({DateTime at, BigInt big}) stamp() => (
  at: DateTime.utc(2026, 11, 12, 1, 2, 3, 4, 5),
  big: BigInt.parse('123456789012345678901234567890'),
);
''';

/// Statements that fill `result` (a `Map<String, Object?>`) from a `main` that
/// imports `model.dart`, `tasks.dart`, `dwi_tasks.g.dart` and `package:dwi`.
const String payloadCalls = r'''
    result['enum'] = (await DwiTasks.nextColor(Color.blue)).name;
    result['enumByFunction'] =
        (await DwiFunctions.run(nextColor, Color.red)).name;
    result['enumCollection'] = <String?>[
      for (final color in await DwiTasks.colors(<Color>{Color.green, Color.red}))
        color?.name,
    ];
    final local = DateTime(2026, 3, 1, 12, 30, 15, 123, 456);
    final nextLocal = await DwiTasks.addDay(local);
    result['dateLocal'] = <Object?>[
      nextLocal.isAtSameMomentAs(local.add(const Duration(days: 1))),
      nextLocal.isUtc,
      nextLocal.microsecond,
    ];
    final nextUtc = await DwiTasks.addDay(DateTime.utc(2026, 3, 1));
    result['dateUtc'] = <Object?>[nextUtc.isUtc, nextUtc.toIso8601String()];
    result['duration'] =
        (await DwiTasks.twice(const Duration(microseconds: 1234567)))
            .inMicroseconds;
    result['bigInt'] =
        (await DwiTasks.square(BigInt.parse('12345678901234567890')))
            .toString();
    result['uri'] =
        (await DwiTasks.withPath(Uri.parse('https://example.com/a?q=1#f')))
            .toString();
    final swapped = await DwiTasks.swap(('a', 7, flag: true));
    result['record'] = <Object?>[swapped.$1, swapped.$2, swapped.flag];
    result['recordOne'] = (await DwiTasks.one((41,))).$1;
    final widened = await DwiTasks.widen(const Range(5, end: 9, label: 'x'));
    result['payload'] = <Object?>[widened.start, widened.end, widened.label];
    result['payloadNullField'] =
        (await DwiTasks.widen(const Range(0, end: 0))).label;
    final tree = Node(1, <Node>[
      Node(2, <Node>[]),
      Node(
        3,
        <Node>[Node(4, <Node>[])],
        color: Color.blue,
        at: DateTime.utc(2020),
      ),
    ]);
    result['recursive'] = await DwiTasks.sumTree(tree);
    final echoed = await DwiTasks.maybe(tree);
    final deep = echoed!.children[1];
    result['recursiveEcho'] = <Object?>[
      identical(echoed, tree),
      echoed.color.name,
      deep.color.name,
      deep.at?.toIso8601String(),
      deep.children.single.value,
    ];
    result['nullable'] = await DwiTasks.maybe(null) == null;
    final grouped = await DwiTasks.group(<(Color, Duration)>[
      (Color.red, const Duration(seconds: 1)),
      (Color.blue, const Duration(seconds: 2)),
      (Color.red, const Duration(seconds: 3)),
    ]);
    result['nested'] = <String, Object?>{
      for (final entry in grouped.entries)
        entry.key: <int>[for (final item in entry.value) item.$2.inSeconds],
    };
    final stamped = await DwiFunctions.run0(stamp);
    result['zeroInput'] = <Object?>[
      stamped.at.toIso8601String(),
      stamped.big.toString(),
    ];
    // A value the worker cannot rebuild is a typed failure, not a wrong value.
    try {
      await Dwi.run<Object?>('nextColor', 'purple');
      result['badEnum'] = 'accepted';
    } on DwiException catch (error) {
      result['badEnum'] = error.toString().contains('expected a Color name');
    }
    try {
      await Dwi.run<Object?>('swap', <Object?>['a', 7]);
      result['badRecord'] = 'accepted';
    } on DwiException catch (error) {
      result['badRecord'] = error.toString().contains('expected (String, int');
    }
''';

/// Asserts the values produced by [payloadCalls].
void expectPayloadResults(Map<String, dynamic> decoded) {
  expect(decoded['enum'], 'red');
  expect(decoded['enumByFunction'], 'green');
  expect(decoded['enumCollection'], <String?>['green', 'red', null]);
  expect(decoded['dateLocal'], <Object?>[true, false, 456]);
  expect(decoded['dateUtc'], <Object?>[true, '2026-03-02T00:00:00.000Z']);
  expect(decoded['duration'], 2469134);
  expect(decoded['bigInt'], '152415787532388367501905199875019052100');
  expect(decoded['uri'], 'https://example.com/worker?q=1#f');
  expect(decoded['record'], <Object?>[7, 'a', false]);
  expect(decoded['recordOne'], 42);
  expect(decoded['payload'], <Object?>[4, 10, 'x']);
  expect(decoded['payloadNullField'], isNull);
  expect(decoded['recursive'], 10);
  expect(decoded['recursiveEcho'], <Object?>[
    false,
    'red',
    'blue',
    '2020-01-01T00:00:00.000Z',
    4,
  ]);
  expect(decoded['nullable'], isTrue);
  expect(decoded['nested'], <String, Object?>{
    'red': <int>[1, 3],
    'blue': <int>[2],
  });
  expect(decoded['zeroInput'], <Object?>[
    '2026-11-12T01:02:03.004005Z',
    '123456789012345678901234567890',
  ]);
  expect(decoded['badEnum'], isTrue);
  expect(decoded['badRecord'], isTrue);
}
