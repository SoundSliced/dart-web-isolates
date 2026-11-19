# dwi_builder

Discover annotated tasks, generate typed host proxies, and compile browser worker assets.

Add `dwi` and `dwi_annotations` to the host project. Add `dwi_builder`
as a dev dependency for CLI use or a regular dependency for Flutter's
automatic build hook on a supported Flutter version. Mark tasks in
`lib/` with `@DwiTask()`, then run from the project root:

```sh
dart run dwi_builder:dwi build
dart run dwi_builder:dwi check
```

Import `lib/dwi_tasks.g.dart` from the app and deploy `web/dwi/` with a
web build. Use `generate` for source-only output, `watch` for the
development loop and `clean` to remove generated outputs. Check flags with
`dart run dwi_builder:dwi build --help`. Restart or reload the host to
start workers from a rebuilt script. Choose the Wasm target with
`build --target=wasm` or project config, then match the host's worker
configuration.

## Basic example

Generates the worker entrypoint and typed proxies from code, without the CLI.
`compile: false` generates sources only. Pass the annotated project directory
as the first argument, or `.` for the current directory.


```dart
/// Builds a project's worker entrypoint programmatically.
///
/// Equivalent to `dart run dwi_builder:dwi generate`. The
/// `compile: false` setting generates sources without compiling a worker.

import 'package:dwi_builder/dwi_builder.dart';

Future<void> main(List<String> args) async {
  final builder = DwiBuilder(
    DwiBuildConfig(
      projectRoot: args.isEmpty ? '.' : args.single,
      compile: false,
    ),
  );

  final result = await builder.build();
  print('package: ${result.discovery.packageName}');
  print('tasks: ${result.discovery.tasks.map((task) => task.name).join(', ')}');
  print('generated worker: ${result.workerSourcePath}');
  print('generated proxies: ${result.proxiesPath}');
  print('content hash: ${result.hash}');
  print('compiled: ${result.compiled}, cache hit: ${result.cacheHit}');
  print('took ${result.duration.inMilliseconds} ms');
}
```

## Advanced example

Builds the project twice. The second build reports a cache hit when nothing
has changed. Pass the annotated project directory as the only argument.


```dart
import 'package:dwi_builder/dwi_builder.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the directory containing your annotated project');
  }
  final builder = DwiBuilder(DwiBuildConfig(projectRoot: args.single));
  final first = await builder.build();
  final second = await builder.build();
  print('First build compiled: ${first.compiled}');
  print('Second build cache hit: ${second.cacheHit}');
}
```

## Clean-checkout first build

On a clean checkout with no generated proxy, run the combined command once. It
generates the proxy and worker, compiles the worker, and then runs
`flutter build web` with any arguments after `--`:

```bash
dart run dwi_builder:dwi build --flutter-build -- --release
```

The worker is built first, so a worker failure stops the command before Flutter
starts. Flutter's exit code is returned unchanged. A later run with unchanged
sources reuses the cached worker.

Other commands:

- `dart run dwi_builder:dwi generate` writes the proxy and worker sources only.
- `dart run dwi_builder:dwi watch` rebuilds the worker when Dart sources change.
- `dart run dwi_builder:dwi check` fails when generated sources or the artifact are
  stale. Use it as a CI freshness gate for checked-in artifacts.

Plain Dart host compilation stays explicit. The worker's target comes from
`dwi.yaml`, and the host's Wasm flags are independent of it.

Verified: the command ordering and forwarding are read from `bin/dwi.dart`
(`_build`, `_runFlutterBuild`). An end-to-end Flutter build was not run in this
pass; see the release report.

## Programmatic build options

`DwiBuildConfig(projectRoot: ...)` selects the project. `compile: false`
generates sources without compiling the worker. The CLI commands above call
the same build.

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
