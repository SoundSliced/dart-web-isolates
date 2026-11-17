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
start workers from a rebuilt script.

The basic programmatic example generates sources and prints discovered
tasks and output paths. The advanced example compiles and reports the
cache result. Pass an annotated project directory when running it from
this package checkout. Choose the Wasm target with `build --target=wasm`
or project config, then match the host's worker configuration.

[Advanced example source](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi_builder/example/dwi_builder_advanced.dart)

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
