import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File dependency;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dwi_hash_test_');
    dependency = File(p.join(root.path, 'lib', 'tasks.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('int twice(int value) => value * 2;\n');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  DwiBuildConfig config({String optimization = 'O1'}) =>
      DwiBuildConfig(projectRoot: root.path, optimization: optimization);

  Future<String> hash({
    DwiBuildConfig? buildConfig,
    String workerSource = 'worker source',
    String proxiesSource = 'proxy source',
    Iterable<String>? dependencies,
  }) {
    return computeWorkerHash(
      config: buildConfig ?? config(),
      workerSource: workerSource,
      proxiesSource: proxiesSource,
      dependencyFiles: dependencies ?? <String>[dependency.path],
    );
  }

  test('is stable for identical inputs', () async {
    expect(await hash(), await hash());
  });

  test('changes when a dependency changes', () async {
    final before = await hash();
    dependency.writeAsStringSync('int twice(int value) => value + value;\n');
    expect(await hash(), isNot(before));
  });

  test('changes when generated source changes', () async {
    final before = await hash();
    expect(await hash(workerSource: 'different'), isNot(before));
    expect(await hash(proxiesSource: 'different'), isNot(before));
  });

  test('changes when compiler options change', () async {
    final before = await hash();
    expect(await hash(buildConfig: config(optimization: 'O2')), isNot(before));
  });

  test('includes every dependency path exactly once', () async {
    final second = File(p.join(root.path, 'lib', 'helper.dart'))
      ..writeAsStringSync('int one() => 1;\n');
    final one = await hash(
      dependencies: <String>[dependency.path, second.path],
    );
    final two = await hash(
      dependencies: <String>[second.path, dependency.path, dependency.path],
    );
    expect(one, two);
  });

  test('changes with the selected compiler identity', () async {
    final withDart = await hash(
      buildConfig: DwiBuildConfig(
        projectRoot: root.path,
        dartExecutable: Platform.resolvedExecutable,
      ),
    );
    final withOther = await hash(
      buildConfig: DwiBuildConfig(
        projectRoot: root.path,
        dartExecutable: '/bin/false',
      ),
    );
    expect(withOther, isNot(withDart));
  });

  test('collects runtime sources and package resolution', () async {
    final lib = Directory(p.join(root.path, 'lib'))..createSync(recursive: true);
    final packages = Directory(p.join(root.path, '.dart_tool'))
      ..createSync(recursive: true);
    final dwiWeb = Directory(p.join(Directory.current.parent.path, 'dwi_web'));
    File(p.join(packages.path, 'package_config.json')).writeAsStringSync(
      '{"configVersion":2,"packages":['
      '{"name":"dwi_web","rootUri":"${dwiWeb.uri}","packageUri":"lib/",'
      '"languageVersion":"3.13"}]}',
    );

    final dependencies = await collectRuntimeDependencies(
      DwiBuildConfig(projectRoot: root.path),
    );

    expect(lib.existsSync(), isTrue);
    expect(
      dependencies.any((path) => path.endsWith('worker_runtime.dart')),
      isTrue,
    );
    expect(
      dependencies.any((path) => path.endsWith('package_config.json')),
      isTrue,
    );
  });

  test('fileDigest distinguishes content', () async {
    final first = await fileDigest(dependency.path);
    dependency.writeAsStringSync('int twice(int value) => value + 1;\n');
    expect(await fileDigest(dependency.path), isNot(first));
    expect(await fileDigest(p.join(root.path, 'missing.dart')), '');
  });
}
