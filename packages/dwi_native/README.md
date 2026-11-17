# dwi_native

Run work in Dart isolates through the native DWI backend.

Apps that also target the browser should use [dwi](https://pub.dev/packages/dwi)
for platform selection. To use the backend directly add `dwi_native` and
`dwi_core`, register a task in a `DwiTaskRegistry`, then pass it to
`NativeBackend`. Await the result and close the backend in `finally`.

From the checkout, `dart run example/dwi_native_example.dart` runs a
one-off task and prints capabilities. The advanced example configures the
backend and opens a dedicated handle for multiple calls. Close the
handle before closing the backend. The [dwi](https://pub.dev/packages/dwi)
guide covers channels, cancellation, stop events, restart and draining
through the app-facing API.

[Advanced example source](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi_native/example/dwi_native_advanced.dart)

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
