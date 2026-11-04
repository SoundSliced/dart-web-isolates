/// Worker-side runtime for generated DWI worker entrypoints.
///
/// Import this library from a generated worker `main()`; application code uses
/// `package:dwi/dwi.dart` instead.
library;

export 'src/worker_dispatcher.dart' show DwiWorkerDispatcher, DwiWorkerTask;
export 'src/worker_runtime.dart' show DwiWorkerRuntime;
