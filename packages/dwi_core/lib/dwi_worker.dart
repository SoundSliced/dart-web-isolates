/// Worker-side API for task libraries (ADR-014).
///
/// Task code that runs inside a DWI isolate or worker imports this library to
/// find the channels the host opened. It deliberately exposes no host type.
library;

export 'src/channel.dart' show DwiChannel, DwiWorkerChannels;
