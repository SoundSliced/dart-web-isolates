import 'package:dwi/dwi.dart';
import 'package:dwi_core/dwi_core.dart' show DwiWorkerChannels;

/// Runs in the producer: sends the squares of 1..count on link `squares`,
/// then closes its end, which closes the link.
Future<Object?> produce(Object? input) async {
  final link = DwiWorkerChannels.find('squares')!;
  final count = input! as int;
  for (var value = 1; value <= count; value++) {
    await link.send(value * value);
  }
  await link.close();
  return count;
}

/// Runs in the consumer: adds up whatever arrives on link `squares`.
Future<Object?> consume(Object? input) async {
  final link = DwiWorkerChannels.find('squares')!;
  var sum = 0;
  await for (final value in link.messages) {
    sum += value! as int;
  }
  return sum;
}

Future<void> main() async {
  Dwi.registerTask('produce', produce);
  Dwi.registerTask('consume', consume);
  await Dwi.configure(const DwiConfig());

  final producer = await DwiWorker.spawn();
  final consumer = await DwiWorker.spawn();
  try {
    // Opens channel `squares` in both workers and relays between them.
    final link = await DwiWorker.link(producer, consumer, 'squares');
    final sum = consumer.run<int>('consume');
    final sent = await producer.run<int>('produce', 100);
    print('sent $sent squares, consumer summed ${await sum}'); // 338350
    await link.done; // completes once either side closed its end
  } finally {
    await producer.close();
    await consumer.close();
    await Dwi.close();
  }
}
