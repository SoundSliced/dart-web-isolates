import 'package:test/test.dart';

/// Shared ADR-023 acceptance fixture: two handles connected by
/// `DwiWorker.link`, run on native isolates and in every browser host/worker
/// combination.

/// `lib/link_tasks.dart`. Tasks find their end of a link by name.
const String linkTasks = r'''
import 'dart:async';
import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_core.dart';

/// Sends 1..count on link `args[0]`, then closes it.
@DwiTask()
Future<int> emit(List<Object?> args) async {
  final channel = DwiWorkerChannels.find(args[0]! as String)!;
  final count = (args[1]! as num).toInt();
  for (var value = 1; value <= count; value++) {
    await channel.send(value);
  }
  await channel.close();
  return count;
}

/// Sends 1..3 on link `name`, then never finishes.
@DwiTask()
Future<int> emitThenHang(String name) async {
  final channel = DwiWorkerChannels.find(name)!;
  for (var value = 1; value <= 3; value++) {
    await channel.send(value);
  }
  return Completer<int>().future;
}

/// Collects every message on link `name` until it closes.
@DwiTask()
Future<List<int>> collect(String name) async {
  final channel = DwiWorkerChannels.find(name)!;
  return <int>[await for (final value in channel.messages) (value! as num).toInt()];
}

/// Like [collect], but pauses every 25 messages, so a fast writer must wait.
@DwiTask()
Future<List<int>> collectSlowly(String name) async {
  final channel = DwiWorkerChannels.find(name)!;
  final values = <int>[];
  await for (final value in channel.messages) {
    values.add((value! as num).toInt());
    if (values.length % 25 == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }
  return values;
}

/// Sends a question on link `chat` and returns the peer's reply.
@DwiTask()
Future<String> ask(String question) async {
  final channel = DwiWorkerChannels.find('chat')!;
  final replies = StreamIterator<Object?>(channel.messages);
  await channel.send(question);
  await replies.moveNext();
  final reply = replies.current! as String;
  await replies.cancel();
  return reply;
}

/// Answers one question on link `chat`.
@DwiTask()
Future<void> answer() async {
  final channel = DwiWorkerChannels.find('chat')!;
  final questions = StreamIterator<Object?>(channel.messages);
  await questions.moveNext();
  await channel.send('re: ${questions.current}');
  await questions.cancel();
}

/// Reports which link names are open in this worker.
@DwiTask()
List<String> openLinks() => DwiWorkerChannels.names.toList()..sort();
''';

/// Statements that fill `result` (a `Map<String, Object?>`) from a `main`
/// that imports `package:dwi` and configures `channelBufferSize: 4`. Every
/// handle is closed by `Dwi.close()` after.
const String linkCalls = r'''
    List<int> ints(Object? value) =>
        <int>[for (final item in value! as List) (item! as num).toInt()];

    // A generated proxy call registers the native implementations before any
    // handle is spawned (a handle copies the registry when it starts).
    result['registered'] = await DwiTasks.openLinks();
    final producer = await DwiWorker.spawn();
    final consumer = await DwiWorker.spawn();

    // 200 ordered messages from one worker to another through the host.
    final pipe = await DwiWorker.link(producer, consumer, 'pipe');
    result['openDuring'] = <Object?>[
      await producer.run<Object?>('openLinks'),
      await consumer.run<Object?>('openLinks'),
    ];
    final collected = consumer.run<Object?>('collect', 'pipe');
    await producer.run<Object?>('emit', <Object?>['pipe', 200]);
    final values = ints(await collected);
    var ordered = values.length == 200;
    for (var index = 0; ordered && index < values.length; index++) {
      ordered = values[index] == index + 1;
    }
    result['pipe'] = <Object?>[values.length, ordered];
    await pipe.done;
    result['pipeClosed'] = pipe.isClosed;

    // A slow reader paces an awaiting writer through a 4-message window: the
    // writer waits instead of failing, and nothing is lost or reordered.
    final slow = await DwiWorker.link(producer, consumer, 'slow');
    final slowly = consumer.run<Object?>('collectSlowly', 'slow');
    await producer.run<Object?>('emit', <Object?>['slow', 150]);
    final slowValues = ints(await slowly);
    var slowOrdered = slowValues.length == 150;
    for (var index = 0; slowOrdered && index < slowValues.length; index++) {
      slowOrdered = slowValues[index] == index + 1;
    }
    result['slow'] = <Object?>[slowValues.length, slowOrdered];
    await slow.done;

    // Request and reply over one link, reusing both handles.
    final chat = await DwiWorker.link(producer, consumer, 'chat');
    final answered = consumer.run<Object?>('answer');
    result['chat'] = await producer.run<Object?>('ask', 'ping');
    await answered;
    await chat.close();
    await chat.done;
    result['openAfter'] = <Object?>[
      await producer.run<Object?>('openLinks'),
      await consumer.run<Object?>('openLinks'),
    ];

    // Closing one handle closes the link: the other side keeps what it got
    // and `done` reports the typed failure.
    final tail = await DwiWorker.link(producer, consumer, 'tail');
    final partial = consumer.run<Object?>('collect', 'tail');
    final hanging = producer.run<Object?>('emitThenHang', 'tail');
    hanging.ignore();
    // The consumer only returns once the link closes, so give the three
    // messages time to arrive before closing the producer.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await producer.close();
    result['partial'] = ints(await partial);
    try {
      await tail.done;
      result['tailDone'] = 'completed';
    } on DwiException catch (error) {
      result['tailDone'] = error.runtimeType.toString();
    }
    result['consumerUsable'] = consumer.isUsable;

    // Misuse is rejected before anything opens.
    try {
      await DwiWorker.link(consumer, consumer, 'self');
      result['self'] = 'accepted';
    } on DwiChannelStateException {
      result['self'] = true;
    }
    final other = await DwiWorker.spawn();
    final busy = await consumer.openChannel('busy');
    try {
      await DwiWorker.link(other, consumer, 'busy');
      result['duplicate'] = 'accepted';
    } on DwiChannelStateException {
      result['duplicate'] = await other.run<Object?>('openLinks');
    }
    await busy.close();
''';

/// Asserts the values produced by [linkCalls].
void expectLinkResults(Map<String, dynamic> decoded) {
  expect(decoded['registered'], <String>[]);
  expect(decoded['openDuring'], <Object?>[
    <String>['pipe'],
    <String>['pipe'],
  ]);
  expect(decoded['pipe'], <Object?>[200, true]);
  expect(decoded['pipeClosed'], isTrue);
  expect(decoded['slow'], <Object?>[150, true]);
  expect(decoded['chat'], 're: ping');
  expect(decoded['openAfter'], <Object?>[<String>[], <String>[]]);
  expect(decoded['partial'], <int>[1, 2, 3]);
  expect(decoded['tailDone'], 'DwiWorkerClosedException');
  expect(decoded['consumerUsable'], isTrue);
  expect(decoded['self'], isTrue);
  // The first end opened on `other` was closed again when the second failed.
  expect(decoded['duplicate'], <String>[]);
}
