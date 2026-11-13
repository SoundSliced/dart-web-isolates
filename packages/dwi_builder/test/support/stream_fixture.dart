import 'package:test/test.dart';

/// Shared ADR-022 acceptance fixture: the same stream tasks and calls run on
/// native isolates and in every browser host/worker combination.

/// `lib/stream_tasks.dart`.
const String streamTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

enum Phase { start, middle, end }

/// Counts up to [limit] in order.
@DwiTask()
Stream<int> countTo(int limit) async* {
  for (var value = 1; value <= limit; value++) {
    yield value;
  }
}

/// Converted input and converted items (ADR-021 types).
@DwiTask()
Stream<(Phase, Duration)> phases((int, Duration) request) async* {
  for (final phase in Phase.values) {
    yield (phase, request.$2 * (phase.index + request.$1));
  }
}

/// Two items, then a failure.
@DwiTask()
Stream<String> failAfterTwo() async* {
  yield 'one';
  yield 'two';
  throw StateError('stream boom');
}

/// Never ends on its own; the host cancels it.
@DwiTask()
Stream<int> forever() async* {
  var value = 0;
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    yield value++;
  }
}

/// Zero-input stream with nullable items.
@DwiTask()
Stream<String?> maybeItems() async* {
  yield 'a';
  yield null;
  yield 'c';
}
''';

/// Statements that fill `result` (a `Map<String, Object?>`) from a `main` that
/// imports `stream_tasks.dart`, `dwi_tasks.g.dart` and `package:dwi`. The
/// configuration in effect must set `channelBufferSize: 4`.
const String streamCalls = r'''
    result['ordered'] = await DwiTasks.countTo(5).toList();
    // 300 items through a 4-item window, read slowly: the producer must wait
    // instead of dropping or reordering anything.
    var slowCount = 0;
    var slowOrdered = true;
    await for (final value in DwiTasks.countTo(300)) {
      slowCount++;
      if (value != slowCount) slowOrdered = false;
      if (value % 50 == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    result['backpressure'] = <Object?>[slowCount, slowOrdered];
    result['converted'] = <String>[
      await for (final item in DwiTasks.phases((1, const Duration(seconds: 2))))
        '${item.$1.name}:${item.$2.inSeconds}',
    ];
    final delivered = <String>[];
    try {
      await for (final item in DwiTasks.failAfterTwo()) {
        delivered.add(item);
      }
      result['error'] = 'no error';
    } on DwiRemoteException catch (error) {
      result['error'] = <Object?>[
        ...delivered,
        error.message.contains('stream boom'),
      ];
    }
    result['cancelled'] = await DwiTasks.forever().take(3).toList();
    result['afterCancel'] = await DwiTasks.countTo(2).toList();
    result['zeroInput'] = await DwiTasks.maybeItems().toList();
    result['byFunction'] =
        await DwiFunctions.stream(countTo, 3).toList();
    result['byFunction0'] =
        await DwiFunctions.stream0(maybeItems).toList();
    try {
      await DwiFunctions.run(countTo, 3);
      result['runOnStream'] = 'accepted';
    } on DwiUnsupportedException {
      result['runOnStream'] = true;
    }
    try {
      await Dwi.run<Object?>('countTo', 3);
      result['pooledCall'] = 'accepted';
    } on DwiException catch (error) {
      result['pooledCall'] = error.toString().contains('Dwi.runStream');
    }
    result['byName'] = await Dwi.runStream('countTo', 2).toList();
''';

/// Asserts the values produced by [streamCalls].
void expectStreamResults(Map<String, dynamic> decoded) {
  expect(decoded['ordered'], <int>[1, 2, 3, 4, 5]);
  expect(decoded['backpressure'], <Object?>[300, true]);
  expect(decoded['converted'], <String>['start:2', 'middle:4', 'end:6']);
  expect(decoded['error'], <Object?>['one', 'two', true]);
  expect(decoded['cancelled'], <int>[0, 1, 2]);
  expect(decoded['afterCancel'], <int>[1, 2]);
  expect(decoded['zeroInput'], <String?>['a', null, 'c']);
  expect(decoded['byFunction'], <int>[1, 2, 3]);
  expect(decoded['byFunction0'], <String?>['a', null, 'c']);
  expect(decoded['runOnStream'], isTrue);
  expect(decoded['pooledCall'], isTrue);
  expect(decoded['byName'], <int>[1, 2]);
}
