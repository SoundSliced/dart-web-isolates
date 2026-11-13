import 'dart:async';

import 'channel.dart';
import 'exceptions.dart';

/// Worker-side support for tasks that return a `Stream` (ADR-022).
///
/// Generated workers call [serve]; application code does not. The host side
/// is `Dwi.runStream`, which spawns a dedicated handle, opens
/// [channelName] on it, and calls the task with
/// `[channelName, input, window]`.
///
/// Flow control is by credit on the same channel: the worker may have at most
/// `window` items that the host has not yet handed to its listener, and the
/// host returns credit (an `int`) as its listener takes items. The channel's
/// receive buffer therefore never fills, and a slow listener pauses the
/// producer instead of failing it with `DwiChannelBufferException`.
abstract final class DwiStreamTask {
  /// Name of the channel that carries the items of one streamed call.
  static const String channelName = 'dwi.stream';

  /// Sends every item of the stream returned by [body] over the request's
  /// channel, then closes the channel.
  ///
  /// [request] must be `[channelName, input, window]` from `Dwi.runStream`;
  /// anything else, such as a call through the pooled `Dwi.run`, throws
  /// [DwiUnsupportedException]. When the credit is used up the producer waits
  /// for the host; if the host closes the channel the producer stops. An error
  /// from the stream closes the channel and fails the call, which the host
  /// reports after the items already delivered.
  static Future<Object?> serve(
    Object? request,
    Stream<Object?> Function(Object? input) body,
  ) async {
    final channel = request is List && request.length == 3
        ? switch (request[0]) {
            final String name => DwiWorkerChannels.find(name),
            _ => null,
          }
        : null;
    final window = channel == null ? null : _positiveInt((request as List)[2]);
    if (channel == null || window == null) {
      throw const DwiUnsupportedException(
        'a stream task must be called with Dwi.runStream or its generated '
        'proxy',
      );
    }
    final credits = StreamIterator<Object?>(channel.messages);
    var available = window;
    try {
      await for (final item in body((request as List)[1])) {
        while (available == 0) {
          // The host closed the channel: nobody will read further items.
          if (!await credits.moveNext()) return null;
          available += _positiveInt(credits.current) ?? 0;
        }
        available--;
        await channel.send(item);
      }
    } finally {
      await credits.cancel();
      await channel.close();
    }
    return null;
  }

  /// [value] as a positive whole number, accepting the `double` a Wasm or JS
  /// boundary may produce for an `int`.
  static int? _positiveInt(Object? value) {
    if (value is int && value > 0) return value;
    if (value is double && value > 0 && value == value.roundToDouble()) {
      return value.toInt();
    }
    return null;
  }
}
