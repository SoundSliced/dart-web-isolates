import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_worker.dart';

/// Worker-local state. Every fresh worker starts at zero, and a persistent
/// handle moves it forward, which is what the fixture asserts.
int _counter = 0;

/// Generated typed proxy: `DwiTasks.counter(...)`.
@DwiTask()
int counter(int input) => ++_counter;

/// A typed remote failure that leaves the pooled worker healthy.
@DwiTask()
String boom(String value) => throw StateError('hosted fixture boom');

/// Returns its input unchanged.
@DwiTask()
String echo(String value) => value;

/// Worker half of the channel exchange. The host opens the named channel, runs
/// this once, then sends a message and expects `echo:<message>` back.
@DwiTask()
String channelEcho(String name) {
  final channel = DwiWorkerChannels.find(name);
  if (channel == null) return 'missing';
  channel.messages.listen(
    (message) => channel.send('echo:$message'),
    onError: (Object error, StackTrace stack) {},
  );
  return 'listening';
}
