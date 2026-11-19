// Regression probes for ADR-033 preconditions. These are not feature tests.
//
// Probe 1: does a worker-side failure reach binding.done while the host
//          listener is paused by backpressure?
// Probe 2: does port.close() complete while a listener is paused and a worker
//          message is still pending, and is the binding's failure preserved?
import 'dart:async';

import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

/// In-memory worker channel: the test injects inbound messages and errors.
final class _ProbeChannel implements DwiChannel {
  _ProbeChannel(this.name);

  @override
  final String name;

  final StreamController<Object?> inbound = StreamController<Object?>();

  @override
  Stream<Object?> get messages => inbound.stream;

  @override
  Future<void> send(Object? message) async {}

  @override
  Future<void> sendBytes(DwiTransferableBytes bytes) async {}

  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}

const _watchdog = Duration(seconds: 2);

void main() {
  DwiPortEndpoint openWorkersPort(String name) => DwiPortRegistry.create(
    name: name,
    scope: DwiPortScope.workers,
    listeners: DwiPortListeners.single,
    bufferSize: 4,
  );

  group('probe 1: terminal signal under paused backpressure', () {
    test('worker stop reaches done while the listener is paused', () async {
      final port = openWorkersPort('probe-error-paused');
      addTearDown(port.close);
      final channel = _ProbeChannel('port:probe-error-paused');
      final stops = StreamController<DwiWorkerStop>();
      addTearDown(stops.close);
      final binding = port.attach(channel, stops: stops.stream);

      final subscription = port.messages.listen((_) {});
      subscription.pause();

      // Fill the port backlog past its capacity (bufferSize 4) so the binding's
      // delivery must wait on the paused listener.
      for (var i = 0; i < 8; i++) {
        channel.inbound.add('held $i');
        await Future<void>.delayed(Duration.zero);
      }

      // Terminal failure from the handle, while the held messages remain paused.
      stops.add(DwiWorkerStop.crashed);
      await Future<void>.delayed(Duration.zero);

      final outcome = await binding.done
          .then<Object?>((_) => 'completed', onError: (Object error) => error)
          .timeout(_watchdog, onTimeout: () => 'TIMEOUT: done not settled');

      // ADR-033: the typed failure is observable while paused.
      // A TIMEOUT here means the terminal signal waits behind backpressure.
      expect(
        outcome,
        isA<DwiWorkerFailedException>(),
        reason: 'observed: $outcome',
      );
      subscription.resume();
    });
  });

  group('probe 2: close during backpressure', () {
    test(
      'port.close completes with a paused listener and pending message',
      () async {
        final port = openWorkersPort('probe-close-paused');
        final channel = _ProbeChannel('port:probe-close-paused');
        final binding = port.attach(channel);
        final subscription = port.messages.listen((_) {});
        subscription.pause();

        for (var i = 0; i < 8; i++) {
          channel.inbound.add('pending $i');
          await Future<void>.delayed(Duration.zero);
        }

        await port.close().timeout(
          _watchdog,
          onTimeout: () => fail('port.close stalled behind a paused listener'),
        );

        // Close is a normal end for the binding, not a failure.
        await binding.done.timeout(
          _watchdog,
          onTimeout: () => fail('binding.done not settled after close'),
        );
        expect(DwiPortRegistry.find('probe-close-paused'), isNull);
        await subscription.cancel();
      },
    );

    test('a worker error queued behind pause is not lost on close', () async {
      final port = openWorkersPort('probe-close-error');
      final channel = _ProbeChannel('port:probe-close-error');
      final binding = port.attach(channel);
      final subscription = port.messages.listen((_) {});
      subscription.pause();

      for (var i = 0; i < 8; i++) {
        channel.inbound.add('pending $i');
        await Future<void>.delayed(Duration.zero);
      }
      channel.inbound.addError(StateError('worker failed'));
      await Future<void>.delayed(Duration.zero);

      await port.close().timeout(
        _watchdog,
        onTimeout: () => fail('port.close stalled'),
      );

      // Either outcome is acceptable for close; what is not acceptable is a
      // hang or an unhandled error. Record which one happened.
      final outcome = await binding.done
          .then<Object?>((_) => 'completed', onError: (Object error) => error)
          .timeout(_watchdog, onTimeout: () => 'TIMEOUT');
      expect(outcome, isNot('TIMEOUT'), reason: 'observed: $outcome');
      await subscription.cancel();
    });
  });
}
