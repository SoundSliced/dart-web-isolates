import 'dart:async';

import 'package:dwi/dwi.dart';
import 'package:dwi_core/dwi_worker.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    // Task code finds the port channel by name, as ADR-032 describes.
    Dwi.registerTask('portEcho', (Object? input) {
      final channel = DwiWorkerChannels.find(input! as String);
      if (channel == null) return 'missing';
      channel.messages.listen(
        (message) => channel.send('echo:$message'),
        onError: (Object error, StackTrace stack) {},
      );
      return 'listening';
    });
    Dwi.registerTask('portAnnounce', (Object? input) {
      final channel = DwiWorkerChannels.find(input! as String);
      if (channel == null) return 'missing';
      channel.send('hello from worker');
      return 'sent';
    });
    await Dwi.configure(const DwiConfig());
  });

  tearDownAll(() => Dwi.close());

  Future<T> withPort<T>(
    String name, {
    DwiPortScope scope = DwiPortScope.workers,
    DwiPortListeners listeners = DwiPortListeners.single,
    required Future<T> Function(DwiPort port) body,
  }) async {
    final port = Dwi.createPort(name, scope: scope, listeners: listeners);
    try {
      return await body(port);
    } finally {
      await port.close();
    }
  }

  test('a host-only port cannot be bound to a worker', () async {
    await withPort(
      'localOnly',
      scope: DwiPortScope.hostOnly,
      body: (port) async {
        final worker = await DwiWorker.spawn();
        try {
          await expectLater(
            worker.bindPort(port),
            throwsA(isA<DwiUnsupportedException>()),
          );
        } finally {
          await worker.close();
        }
      },
    );
  });

  test('a worker echoes host sends through a bound port', () async {
    await withPort(
      'echoPort',
      body: (port) async {
        final worker = await DwiWorker.spawn();
        try {
          final binding = await worker.bindPort(port);
          expect(
            await worker.run<String>('portEcho', 'port:echoPort'),
            'listening',
          );
          final reply = port.messages.first;
          await port.send('ping');
          expect(await reply, 'echo:ping');
          await binding.close();
        } finally {
          await worker.close();
        }
      },
    );
  });

  test('a worker sends a message to the host through a bound port', () async {
    await withPort(
      'announcePort',
      body: (port) async {
        final worker = await DwiWorker.spawn();
        try {
          await worker.bindPort(port);
          final heard = port.messages.first;
          expect(
            await worker.run<String>('portAnnounce', 'port:announcePort'),
            'sent',
          );
          expect(await heard, 'hello from worker');
        } finally {
          await worker.close();
        }
      },
    );
  });

  test('broadcast gives every host listener the worker message', () async {
    await withPort(
      'fanoutPort',
      listeners: DwiPortListeners.broadcast,
      body: (port) async {
        final worker = await DwiWorker.spawn();
        try {
          await worker.bindPort(port);
          final first = port.messages.first;
          final second = port.messages.first;
          expect(
            await worker.run<String>('portAnnounce', 'port:fanoutPort'),
            'sent',
          );
          expect(await first, 'hello from worker');
          expect(await second, 'hello from worker');
        } finally {
          await worker.close();
        }
      },
    );
  });

  test('closing the port ends its binding', () async {
    final port = Dwi.createPort('endingPort', scope: DwiPortScope.workers);
    final worker = await DwiWorker.spawn();
    try {
      final binding = await worker.bindPort(port);
      await port.close();
      await binding.done;
      expect(Dwi.port('endingPort'), isNull);
    } finally {
      await worker.close();
    }
  });

  test('a name longer than 58 characters is refused', () {
    expect(
      () => Dwi.createPort('x' * 59, scope: DwiPortScope.workers),
      throwsA(isA<DwiChannelStateException>()),
    );
  });
}
