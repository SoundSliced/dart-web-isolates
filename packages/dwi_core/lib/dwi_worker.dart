/// Worker-side API for task libraries (ADR-014, ADR-027).
///
/// Task code that runs inside a DWI isolate or worker imports this library to
/// find the channels the host opened and to observe cancellation. It
/// deliberately exposes no host type.
library;

export 'src/cancel_token.dart' show DwiCancelToken;
export 'src/channel.dart' show DwiChannel, DwiWorkerChannels;
export 'src/exceptions.dart' show DwiCancelledException;
