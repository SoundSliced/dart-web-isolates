# Draft comment for dart-lang/sdk#56512

Status: **posted 2026-11-10** as
[issuecomment-6777658158](https://github.com/dart-lang/sdk/issues/56512#issuecomment-6777658158).
No maintainer guidance has been received yet. Evidence:
`../../audit/evidence/flutter-web-hook-ordering-2026-11-10.txt` and
[`flutter-web-hook-ordering.md`](flutter-web-hook-ordering.md).

---

Thanks for the `hook/generate.dart` design discussion. We have a measured case
where the absence of a pre-compilation source-generation contract breaks a
first build, and we would like guidance on which contract you prefer before
investing further.

**Case.** A Flutter Web app imports a Dart file produced by a dependency's web
build hook. On a genuinely fresh project, the ordinary first
`flutter build web --release` fails with `No such file or directory` for the
generated import; the hook writes the file seconds later and the second build
succeeds. On Flutter 3.47.6 we measured exit 1 for `--release`, `--wasm` and
`--debug`, with the hook reporting generation at +8.5 s, +6.0 s and +7.7 s
respectively, after `dart2js`/`dart2wasm` had already failed.
`flutter run -d chrome` (debug) succeeds because the resident runner awaits the
hooks before its DDC compile. On Flutter 3.47.6, clean first builds were
measured to fail. We inspected the 3.47.9 and current `master` build graphs and
found the same missing compiler-to-hook dependency; we have not run the
clean-build fixture on those newer revisions. On both, `Dart2WebTarget.dependencies`
is `[WebEntrypointTarget, GenerateLocalizationsTarget]`, while
`BuildHooks(platform: web)` is reachable only through `LinkHooks`, whose
outputs feed linking after compilation. A hook cannot declare a Dart source as a
compiler input; its only declared output is `build_hooks_result.json`.

**Minimal reproduction (no DWI).** Create a web app, add `hooks: ^2.2.0`, add a
`hook/build.dart` that writes `lib/generated.g.dart`, import that file from
`lib/main.dart`, delete the generated file, and run
`flutter build web --release` once. It fails on the missing import; the hook
still runs during that build.

**Prototype, Flutter-only.** Making the common web compile target depend on
`BuildHooks(platform: HookPlatform.web)` closes the race for both dart2js and
dart2wasm. In a disposable 3.47.6 SDK: release, Wasm, debug and profile first
builds all exit 0 on fresh fixtures; the `flutter_tools` web target suite passes
(623 tests); an integration fixture whose hook generates an imported Dart file
builds on its first command. Verbose logs show `build_hooks: Complete` before
`dart2js: Starting`. The trade-off is that every web build waits for every
dependency's web hook; for apps without hooks it was not measurable (cold
20.1 s vs 21.0 s; unchanged ~17–18 s on both), and for a slow hook the cost
moves before compilation instead of overlapping it. A failing hook aborts the
build and compilation does not start.

**Request for guidance.** Which direction should a package like ours target?

1. Order existing web build hooks before the web compiler (the prototype
   above). Does that become a supported contract for generated Dart sources, or
   is it only a build-race fix that IDEs and analyzers cannot rely on?
2. The `hook/generate.dart` phase discussed here. What would its input/output
   declarations, cache invalidation, package ordering, and analyzer/IDE timing
   be?
3. Letting existing hooks declare generated Dart outputs, so only projects that
   generate source pay for ordering. Is that feasible in the hooks API and the
   compiler/build graph?

We are not proposing that the Flutter patch be merged as-is, and we will keep
our documented one-time pre-build step until a released SDK supports one of
these contracts.

Full evidence, including the prototype diff, first-build matrix, browser runs
and build costs:
https://github.com/SoundSliced/dart-web-isolates/blob/main/docs/upstream/flutter-web-hook-ordering.md
