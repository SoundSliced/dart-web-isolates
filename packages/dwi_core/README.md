# dwi_core

Platform-independent contracts shared by DWI and its backends.

Most apps import [dwi](https://pub.dev/packages/dwi). Add `dwi_core`
directly for custom backends, worker-side APIs and standalone tooling.

Run `dart run example/dwi_core_example.dart` from the package checkout for
a registry lookup, a validated configuration and capability reporting.
Registry invocation runs in the current context. A backend supplies
parallel execution.

The advanced example shows a native-independent named-port round trip.
For custom integrations start with the `DwiBackend` and `DwiWorkerHandle`
contracts. Use `DwiConfig` for bounds, deadlines and worker selection,
`DwiException` subclasses for failures, and `DwiCapabilities` to surface
supported operations. Worker code can import `dwi_worker.dart` for
channels and cooperative cancellation. See the dwi guide for stream
tasks, transferable bytes, worker stops and metrics.

[Advanced example source](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi_core/example/dwi_core_advanced.dart)

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
