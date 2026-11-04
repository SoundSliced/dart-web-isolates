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

    final result = await DwiBuilder(DwiBuildConfig(projectRoot: root)).build();

    // Declare everything that changes the worker so Flutter's build system
    // re-runs this hook instead of serving a stale artefact. Unchanged builds
    // skip the hook entirely.
    for (final path in result.discovery.dependencyFiles) {
      output.dependencies.add(Uri.file(path));
    }
    // Runtime sources and package resolution are compilation inputs too.
    for (final path in await collectRuntimeDependencies(
      DwiBuildConfig(projectRoot: root),
    )) {
      output.dependencies.add(Uri.file(path));
    }
    output.dependencies.add(Uri.file('$root${separator}pubspec.yaml'));
    output.dependencies.add(Uri.file('$root${separator}pubspec.lock'));
  });
}
