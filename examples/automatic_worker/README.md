# Automatic worker example

Shows the v0.3 zero-boilerplate path:

```dart
@DwiTask()
int calculatePrimes(int limit) { ... }
```

```dart
final count = await DwiTasks.calculatePrimes(2000000);
```

It also selects a registered task at run time by its tear-off (ADR-020,
since 0.9.0):

```dart
final greeting = await DwiFunctions.run(Greetings.describe, 'DWI');
```

and passes several typed values, including an enum, as one record (ADR-021,
since 0.9.0):

```dart
final summary = await DwiFunctions.run(summarise, (100000, Detail.full));
```

and streams progress from a task that returns `Stream<int>` (ADR-022, checkout
only):

```dart
await for (final found in DwiTasks.primeProgress(100000)) {
  print(found);
}
```

There is no `worker.dart`, no manual registry, no manifest to maintain and no
`Dwi.configure(workerScript: ...)` call. `dwi_builder` discovers the annotation,
generates `.dwi/generated_worker.dart` with static references, generates
`lib/dwi_tasks.g.dart`, compiles the worker and writes the manifest.

## Run

```bash
cd examples/automatic_worker
dart pub get

# Discover, generate, compile and place the worker in web/dwi/.
dart run dwi_builder:dwi build

# Compile the application itself.
dart compile js -O1 -o web/main.dart.js lib/main.dart

# Serve web/ (the worker and app must be same-origin).
python3 -m http.server 8080 --directory web
# open http://localhost:8080/
```

Generated files (`lib/dwi_tasks.g.dart`, `.dwi/`, `web/dwi/`, `web/main.dart.js`)
are gitignored.

## Development loop

For a **Flutter** app on Flutter 3.47+, no watcher is needed: add
`dwi_builder` as a normal dependency and the build hook regenerates the worker
during `flutter run -d chrome` and `flutter build web` (ADR-009). Hot reload
does not rebuild a running worker; hot restart or reload the page.

This Dart-only example has no Flutter build hook, so run the worker watcher in
one terminal and your normal app command in another:

```bash
dart run dwi_builder:dwi watch
```

The watcher polls `lib/` (excluding generated files), regenerates and
recompiles on change. Existing workers keep their old script; reload the page
after a rebuild. This is documented in `docs/limitations.md`.

## Verify

```bash
dart run dwi_builder:dwi check
```

`check` fails when generated sources, the manifest hash or the compiled
artefact are stale.
