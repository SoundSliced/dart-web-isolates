import 'dart:async';

import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

class _Transport {
  final List<(int, Object?, bool)> sends = <(int, Object?, bool)>[];
  final List<int> acks = <int>[];
  int closes = 0;
  int closedReplies = 0;
  int terminations = 0;

  DwiChannelEndpoint endpoint({int bufferSize = 4, String name = 'chat'}) {
    return DwiChannelEndpoint(
      name: name,
      bufferSize: bufferSize,
      onSend: (seq, message, transfer) => sends.add((seq, message, transfer)),
      onAck: acks.add,
      onClose: () => closes++,
      onClosed: () => closedReplies++,
      onTerminated: () => terminations++,
    );
  }
}

void main() {
  group('channel names', () {
    test('accept an ordinary name', () {
      expect(() => validateDwiChannelName('progress'), returnsNormally);
    });

    test('reject empty, long and control-character names', () {
      expect(
        () => validateDwiChannelName(''),
        throwsA(isA<DwiChannelStateException>()),
      );
      expect(
        () => validateDwiChannelName('x' * 65),
        throwsA(isA<DwiChannelStateException>()),
      );
      expect(
        () => validateDwiChannelName('a\nb'),
        throwsA(isA<DwiChannelStateException>()),
      );
    });
  });

  group('DwiChannelEndpoint', () {
    test('sends only after opening and completes on ack', () async {
      final transport = _Transport();
      final channel = transport.endpoint();

      await expectLater(
        channel.send('early'),
        throwsA(isA<DwiChannelStateException>()),
      );

      channel.markOpened();
      final sent = channel.send(<String, Object?>{'step': 1});
      expect(transport.sends, hasLength(1));
      expect(transport.sends.single.$1, 1);
      expect(transport.sends.single.$2, <String, Object?>{'step': 1});
      expect(transport.sends.single.$3, isFalse);

      var completed = false;
      unawaited(sent.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      channel.ack(1);
      await sent;
    });

    test('acknowledges on enqueue and delivers in order to the listener',
        () async {
      final transport = _Transport();
      final channel = transport.endpoint();

      expect(channel.deliver(1, 'a'), isTrue);
      expect(channel.deliver(2, 'b'), isTrue);
      expect(transport.acks, <int>[1, 2]);

      final received = <Object?>[];
      final done = Completer<void>();
      channel.messages.listen(
        received.add,
        onDone: done.complete,
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, <Object?>['a', 'b']);

      await channel.close();
      await done.future;
    });

    test('refuses a delivery when the receive buffer is full', () {
      final transport = _Transport();
      final channel = transport.endpoint(bufferSize: 1);
      expect(channel.deliver(1, 'a'), isTrue);
      expect(channel.deliver(2, 'b'), isFalse);
      expect(transport.acks, <int>[1]);
    });

    test('rejects a send the peer refused', () async {
      final transport = _Transport();
      final channel = transport.endpoint();
      channel.markOpened();
      final pending = channel.send('a');
      final error = expectLater(
        pending,
        throwsA(isA<DwiChannelBufferException>()),
      );
      channel.reject(1, const DwiChannelBufferException('full'));
      await error;
      expect(channel.isOpen, isTrue);
    });

    test('refuses a send beyond the unacknowledged window', () async {
      final transport = _Transport();
      final channel = transport.endpoint(bufferSize: 2);
      channel.markOpened();

      final first = channel.send('a');
      final second = channel.send('b');
      await expectLater(
        channel.send('c'),
        throwsA(isA<DwiChannelBufferException>()),
      );

      channel.ack(1);
      channel.ack(2);
      await first;
      await second;
      final third = channel.send('c');
      channel.ack(3);
      await third;
    });

    test('peer close ends the stream normally and settles pending sends',
        () async {
      final transport = _Transport();
      final channel = transport.endpoint();
      channel.markOpened();
      final pending = channel.send('x');
      final done = Completer<void>();
      channel.messages.listen((_) {}, onDone: done.complete);

      channel.peerClosed();
      await expectLater(
        pending,
        throwsA(isA<DwiChannelClosedException>()),
      );
      await done.future;
      expect(transport.closedReplies, 1);
      await expectLater(
        channel.send('after'),
        throwsA(isA<DwiChannelClosedException>()),
      );
    });

    test('failure errors the stream and settles pending sends once', () async {
      final transport = _Transport();
      final channel = transport.endpoint();
      channel.markOpened();
      final pending = channel.send('x');
      final pendingError = expectLater(
        pending,
        throwsA(isA<DwiWorkerFailedException>()),
      );
      final streamError = expectLater(
        channel.messages,
        emitsError(isA<DwiWorkerFailedException>()),
      );

      const failure = DwiWorkerFailedException('context died');
      channel.fail(failure);

      await pendingError;
      await streamError;
      // A second failure must not double-settle or re-error.
      channel.fail(const DwiWorkerFailedException('again'));
      expect(transport.terminations, 1);
    });

    test('close is idempotent and later sends are rejected', () async {
      final transport = _Transport();
      final channel = transport.endpoint();
      channel.markOpened();

      await channel.close();
      await channel.close();
      expect(transport.closes, 1);
      await expectLater(
        channel.send('x'),
        throwsA(isA<DwiChannelClosedException>()),
      );
    });

    test('a serialization failure from the transport settles that send',
        () async {
      final channel = DwiChannelEndpoint(
        name: 'chat',
        bufferSize: 2,
        onSend: (seq, message, transfer) {
          throw const DwiSerializationException('unsendable');
        },
        onAck: (_) {},
        onClose: () {},
        onClosed: () {},
      );
      channel.markOpened();
      await expectLater(
        channel.send(Object()),
        throwsA(isA<DwiSerializationException>()),
      );
      // The failed send does not consume the window.
      expect(channel.isOpen, isTrue);
    });
  });
}
