// Build hook entrypoint.
//
// A Flutter app that lists `dwi_builder` as a normal dependency gets its worker
// generated and compiled by `flutter run -d chrome` and `flutter build web`,
// with no separate DWI command. The hook locates the application package from
// the package config the Flutter tool passes to it, then runs the same builder
// as the CLI. See ADR-009 in docs/architecture.md.
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:dwi_builder/src/hook_support.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageConfig = Platform.packageConfig;
    if (packageConfig == null) return;

    final separator = Platform.pathSeparator;
    final root = findDwiAppRoot(
      packageConfig: Uri.parse(packageConfig),
      hasWebEntrypoint: (path) =>
          File('$path${separator}web${separator}index.html').existsSync(),
    );
    if (root == null) return;

    final proxies = File(
      '$root${separator}lib${separator}dwi_tasks.g.dart',
    );
    final hadProxies = proxies.existsSync();
    // The application declares its target once in dwi.yaml; the hook and the
    // CLI read the same file, so neither can silently choose the other backend.
    final config = DwiBuildConfig(
      projectRoot: root,
      target: DwiProjectConfig.resolveTarget(projectRoot: root),
    );
    final result = await DwiBuilder(config).build();

    // Flutter schedules the web build hook and `dart2js` as independent targets,
    // so on a project that has never generated proxies the compiler can start
    // before this hook writes them. The generated files are usable immediately;
    // the current build may still fail to resolve the import. Say so instead of
    // leaving only an unexplained "No such file or directory" from the
    // compiler.
    if (!hadProxies) {
      stderr.writeln(
        'dwi_builder: generated lib/dwi_tasks.g.dart during this build. '
        'Flutter may have started the Dart compiler before this hook ran; if '
        'the build failed to resolve the generated proxies, rerun the build, '
        'or run `dart run dwi_builder:dwi build` before the first Flutter '
        'build.',
      );
    }

    // Declare everything that changes the worker so Flutter's build system
    // re-runs this hook instead of serving a stale artefact. Unchanged builds
    // skip the hook entirely.
    for (final path in result.discovery.dependencyFiles) {
      output.dependencies.add(Uri.file(path));
    }
    // Runtime sources and package resolution are compilation inputs too.
    for (final path in await collectRuntimeDependencies(config)) {
      output.dependencies.add(Uri.file(path));
    }
    output.dependencies.add(Uri.file('$root${separator}pubspec.yaml'));
    output.dependencies.add(Uri.file('$root${separator}pubspec.lock'));
    final projectConfig = File(
      '$root${separator}${DwiProjectConfig.fileName}',
    );
    if (projectConfig.existsSync()) {
      output.dependencies.add(Uri.file(projectConfig.path));
    }
  });
}
