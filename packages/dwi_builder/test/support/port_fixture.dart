import 'package:test/test.dart';

/// Shared ADR-032 acceptance fixture: a host port bound to a worker, run in every
/// browser host/worker combination. The worker reaches the port by name through
/// `DwiWorkerChannels.find('port:<name>')`.

/// `lib/port_tasks.dart`. Tasks return at once; the listener stays in the worker.
const String portTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_core.dart';

/// Echoes every message received on port channel [name] as `echo:<message>`.
@DwiTask()
String startEcho(String name) {
  final channel = DwiWorkerChannels.find(name);
  if (channel == null) return 'missing';
  channel.messages.listen(
    (message) => channel.send('echo:$message'),
    onError: (Object error, StackTrace stack) {},
  );
  return 'listening';
}

/// Sends `announced:<text>` on port channel `port:chat` to the host.
@DwiTask()
String announce(String text) {
  final channel = DwiWorkerChannels.find('port:chat');
  if (channel == null) return 'missing';
  channel.send('announced:$text');
  return 'sent';
}
''';

/// Checks the decoded result of one port cell.
void expectPortResults(Map<String, dynamic> decoded) {
  expect(
    decoded['ok'],
    isTrue,
    reason: '${decoded['error']}\n${decoded['stack']}',
  );
  expect(decoded['echoed'], <Object?>['echo:ping', 'echo:pong']);
  expect(decoded['announced'], 'announced:hi');
  expect(decoded['startResult'], 'listening');
  expect(decoded['announceResult'], 'sent');
}
