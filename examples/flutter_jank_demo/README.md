# flutter_jank_demo

A Flutter web page that runs the same prime-sieve work three ways and records
the longest gap between animation frames for each: on the main thread,
through `computeParallel` (DWI), and through Flutter's `compute()` (ADR-025).

Backend exercised: JS worker (dart2js) for DWI, and Flutter's own `compute()`.

## Run

```bash
cd examples/flutter_jank_demo
flutter pub get
dart run dwi_builder:dwi build
flutter run -d chrome
```

The page runs all three measurements on start and writes the result to
`document.title`. Set `JankApp(autoRun: false)` to skip them.

## Measured

`audit/evidence/flutter-jank-demo-four-engines-2026-11-14.json`. The main-thread
run blocks frames for its whole duration in every engine. `computeParallel`
keeps the longest gap to about 18 to 27 ms. On web, Flutter's `compute()` blocks
frames for about as long as its work in Chrome, Firefox and Edge. See
`docs/browser-matrix.md` for the figures and a note on the Safari first pass.
