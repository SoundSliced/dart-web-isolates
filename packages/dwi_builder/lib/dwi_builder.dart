/// Build-time tooling for Dart Web Isolates.
///
/// Discovers `@DwiTask`-annotated top-level functions with the Dart analyzer,
/// emits a deterministic worker entrypoint with static references, emits typed
/// caller proxies, and compiles the worker with `dart compile js`.
library;

export 'src/builder.dart';
export 'src/config.dart';
export 'src/descriptor.dart';
export 'src/diagnostics.dart';
export 'src/discovery.dart';
export 'src/generator.dart';
export 'src/version.dart';
