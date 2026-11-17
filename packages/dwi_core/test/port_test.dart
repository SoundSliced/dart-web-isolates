import 'dart:async';
import 'dart:typed_data';

import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

/// In-memory stand-in for a worker channel: records sends and lets the test
/// inject inbound messages.
final class _FakeChannel implements DwiChannel {
  _FakeChannel(this.name);

  @override
  final String name;

  final StreamController<Object?> inbound = StreamController<Object?>();
  final List<Object?> sent = <Object?>[];
  final List<DwiTransferableBytes> sentBytes = <DwiTransferableBytes>[];
  bool closed = false;

  @override
  Stream<Object?> get messages => inbound.stream;

  @override
  Future<void> send(Object? message) async => sent.add(message);

  @override
  Future<void> sendBytes(DwiTransferableBytes bytes) async =>
      sentBytes.add(bytes);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!inbound.isClosed) await inbound.close();
  }
}

DwiPortEndpoint _port(
  String name, {
  DwiPortScope scope = DwiPortScope.hostOnly,
  DwiPortListeners listeners = DwiPortListeners.single,
  int bufferSize = 4,
}) => DwiPortRegistry.create(
  name: name,
  scope: scope,
  listeners: listeners,
  bufferSize: bufferSize,
);

void main() {
  final opened = <DwiPortEndpoint>[];

  DwiPortEndpoint open(
    String name, {
    DwiPortScope scope = DwiPortScope.hostOnly,
    DwiPortListeners listeners = DwiPortListeners.single,
    int bufferSize = 4,
  }) {
    final port = _port(
      name,
      scope: scope,
      listeners: listeners,
      bufferSize: bufferSize,
    );
    opened.add(port);
    return port;
  }

  tearDown(() async {
    for (final port in opened) {
      await port.close();
    }
    opened.clear();
  });

  group('names and registry', () {
    test('rejects empty, too long and control-character names', () {
      expect(() => open(''), throwsA(isA<DwiChannelStateException>()));
      expect(
        () => open('x' * (dwiPortNameMaxLength + 1)),
        throwsA(isA<DwiChannelStateException>()),
      );
      expect(
        () => open('bad\u0001name'),
        throwsA(isA<DwiChannelStateException>()),
      );
    });

    test('accepts the longest allowed name', () {
      final port = open('n' * dwiPortNameMaxLength);
      expect(port.name.length, dwiPortNameMaxLength);
    });

    test('a second open port with the same name is refused', () {
      open('dup');
      expect(() => open('dup'), throwsA(isA<DwiChannelStateException>()));
    });

    test('find returns the open port and forgets it after close', () async {
      final port = open('lookup');
      expect(DwiPortRegistry.find('lookup'), same(port));
      await port.close();
      expect(DwiPortRegistry.find('lookup'), isNull);
      // The name is free again after close.
      opened.add(open('lookup'));
    });
  });

  group('host-only port', () {
    test(
      'delivers a copy, so the listener never shares the sender value',
      () async {
        final port = open('copy');
        final received = port.messages.first;
        final original = <Object?>[1, 2];
        await port.send(original);
        original.add(3);
        final value = await received;
        expect(value, <Object?>[1, 2]);
        expect(identical(value, original), isFalse);
      },
    );

    test('refuses values outside the task value kinds', () async {
      final port = open('refuse');
      await expectLater(
        port.send(Object()),
        throwsA(isA<DwiSerializationException>()),
      );
    });

    test('cannot be bound to a worker', () {
      final port = open('local');
      expect(port.ensureBindable, throwsA(isA<DwiUnsupportedException>()));
    });

    test('a second listen on a single port throws StateError', () {
      final port = open('single');
      port.messages.listen((_) {});
      expect(() => port.messages.listen((_) {}), throwsStateError);
    });
  });

  group('single listener', () {
    test(
      'keeps messages sent before listen and delivers them in order',
      () async {
        final port = open('backlog', bufferSize: 3);
        await port.send('a');
        await port.send('b');
        final got = <Object?>[];
        final done = Completer<void>();
        port.messages.listen(got.add, onDone: done.complete);
        await port.send('c');
        await port.close();
        await done.future;
        expect(got, <Object?>['a', 'b', 'c']);
      },
    );

    test(
      'throws a buffer exception when the backlog is full and no listener',
      () async {
        final port = open('full', bufferSize: 2);
        await port.send(1);
        await port.send(2);
        await expectLater(
          port.send(3),
          throwsA(isA<DwiChannelBufferException>()),
        );
      },
    );
  });

  group('broadcast listeners', () {
    test('every listener receives each message in send order', () async {
      final port = open(
        'fanout',
        listeners: DwiPortListeners.broadcast,
        bufferSize: 8,
      );
      final first = <Object?>[];
      final second = <Object?>[];
      port.messages.listen(first.add);
      port.messages.listen(second.add);
      for (var i = 0; i < 5; i++) {
        await port.send(i);
      }
      await Future<void>.delayed(Duration.zero);
      expect(first, <Object?>[0, 1, 2, 3, 4]);
      expect(second, <Object?>[0, 1, 2, 3, 4]);
    });

    test('a paused listener makes senders wait and loses nothing', () async {
      final port = open(
        'pause',
        listeners: DwiPortListeners.broadcast,
        bufferSize: 2,
      );
      final got = <Object?>[];
      late StreamSubscription<Object?> subscription;
      subscription = port.messages.listen(got.add);
      subscription.pause();

      final sends = <Future<void>>[];
      for (var i = 0; i < 6; i++) {
        sends.add(port.send(i));
      }
      await Future<void>.delayed(Duration.zero);
      // Only the queue capacity was accepted while paused; the rest waits.
      expect(got, isEmpty);
      subscription.resume();
      await Future.wait(sends);
      await Future<void>.delayed(Duration.zero);
      expect(got, <Object?>[0, 1, 2, 3, 4, 5]);
    });

    test('a cancelled listener is removed and others keep receiving', () async {
      final port = open(
        'cancel',
        listeners: DwiPortListeners.broadcast,
        bufferSize: 4,
      );
      final kept = <Object?>[];
      final dropped = port.messages.listen((_) {});
      port.messages.listen(kept.add);
      await dropped.cancel();
      await port.send('after');
      await Future<void>.delayed(Duration.zero);
      expect(kept, <Object?>['after']);
    });
  });

  group('close', () {
    test('ends listeners, rejects later sends and clears bindings', () async {
      final port = open('closing');
      final done = Completer<void>();
      port.messages.listen((_) {}, onDone: done.complete);
      await port.close();
      await done.future;
      await expectLater(
        port.send('late'),
        throwsA(isA<DwiChannelClosedException>()),
      );
    });

    test('close is idempotent', () async {
      final port = open('twice');
      await port.close();
      await port.close();
      expect(port.isClosed, isTrue);
    });
  });

  group('workers port and bindings', () {
    test('a send with no bound worker is a state error', () async {
      final port = open('unbound', scope: DwiPortScope.workers);
      await expectLater(
        port.send('nobody'),
        throwsA(isA<DwiChannelStateException>()),
      );
    });

    test('a host send reaches the bound worker channel', () async {
      final port = open('out', scope: DwiPortScope.workers);
      final channel = _FakeChannel('port:out');
      port.attach(channel);
      await port.send({'frame': 1});
      expect(channel.sent, <Object?>[
        <String, Object?>{'frame': 1},
      ]);
    });

    test('a host byte transfer reaches the bound worker as transfer', () async {
      final port = open('bytes', scope: DwiPortScope.workers);
      final channel = _FakeChannel('port:bytes');
      port.attach(channel);
      final bytes = DwiTransferableBytes(Uint8List.fromList(<int>[1, 2, 3]));
      await port.sendBytes(bytes);
      expect(channel.sentBytes, hasLength(1));
      expect(identical(channel.sentBytes.single, bytes), isTrue);
    });

    test('a message from the worker reaches the host listener', () async {
      final port = open('in', scope: DwiPortScope.workers);
      final channel = _FakeChannel('port:in');
      final received = port.messages.first;
      port.attach(channel);
      channel.inbound.add('from worker');
      expect(await received, 'from worker');
    });

    test('binding ends with done when the worker side closes', () async {
      final port = open('ends', scope: DwiPortScope.workers);
      final channel = _FakeChannel('port:ends');
      final binding = port.attach(channel);
      await channel.inbound.close();
      await binding.done;
    });

    test(
      'closing the port completes bindings and closes their channels',
      () async {
        final port = open('bound', scope: DwiPortScope.workers);
        final channel = _FakeChannel('port:bound');
        final binding = port.attach(channel);
        await port.close();
        await binding.done;
        expect(channel.closed, isTrue);
      },
    );
  });
}
