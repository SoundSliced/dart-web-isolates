# flutter_counter

A Flutter web app with a counter and one parallel DWI call. It shows
`computeParallel` from `dwi_flutter` over a generated typed proxy (ADR-025).

Backend exercised: JS worker (dart2js), built by the DWI build hook.

## Run

```bash
cd examples/flutter_counter
flutter pub get
dart run dwi_builder:dwi build   # generates lib/dwi_tasks.g.dart and the worker
flutter run -d chrome
```

`flutter build web` also runs the DWI build step (ADR-009). The first build of a
fresh typed-proxy app can fail on Flutter's hook ordering; run `dart run
dwi_builder:dwi build` first, as above.

## Test

```bash
flutter test --platform chrome
```

The widget test runs with `autoRun: false`, so no worker starts during tests.
The VM cannot load this app: it imports `dart:js_interop`.

## Measured

`audit/evidence/flutter-counter-four-engines-2026-11-14.json`: all four engines
produce the same prime counts.
