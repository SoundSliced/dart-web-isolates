/// Platform-independent DWI abstractions: configuration, capabilities, task
/// registration, the backend interface and the public exception hierarchy.
library;

export 'src/backend.dart';
export 'src/cancellable_task.dart';
export 'src/capabilities.dart';
export 'src/channel.dart';
export 'src/channel_endpoint.dart'
    show DwiChannelEndpoint, validateDwiChannelName;
export 'src/config.dart';
export 'src/exceptions.dart';
export 'src/registry.dart';
export 'src/stream_task.dart';
export 'src/transferable_bytes.dart';
export 'src/worker_handle.dart';
