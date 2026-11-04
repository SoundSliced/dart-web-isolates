import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

const String simpleTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int twice(int value) => value * 2;

@DwiTask()
String hello(String name) => 'Hello $name';
''';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test('generates sources and typed proxies without compiling', () async {
    project.write('lib/tasks.dart', goodTasks);

    final result = await DwiBuilder(project.config()).build();

    expect(result.compiled, isFalse);
    expect(result.cacheHit, isFalse);
    expect(result.discovery.tasks.length, 4);
    expect(project.exists('.dwi/generated_worker.dart'), isTrue);
    expect(project.exists('lib/dwi_tasks.g.dart'), isTrue);
    expect(project.exists('.dwi/worker_manifest.json'), isFalse);

    final worker = project.read('.dwi/generated_worker.dart');
    expect(worker, contains("'calculatePrimes': (Object? input) =>"));
    expect(worker, contains('package:dwi_web/dwi_worker.dart'));
    expect(worker, contains("workerId: 'default'"));

    final proxies = project.read('lib/dwi_tasks.g.dart');
    expect(proxies, contains('abstract final class DwiTasks'));
    expect(proxies, contains('static Future<void> noInput() async'));
  });

  test(
    'compiles, reuses the cache, recompiles on change, checks and cleans',
    () async {
      project.write('lib/tasks.dart', simpleTasks);

      final first = await DwiBuilder(project.config(compile: true)).build();
      expect(first.compiled, isTrue);
      expect(first.cacheHit, isFalse);
      expect(File(first.artifactPath).existsSync(), isTrue);
      expect(project.exists('web/dwi/worker.dart.js'), isTrue);

      final manifest = project.read('.dwi/worker_manifest.json');
      expect(manifest, contains('"protocol": 1'));
      expect(manifest, contains('"artifact": "dwi/worker.dart.js"'));
      expect(manifest, contains('"compiled": true'));
      expect(manifest, contains('"tasks": ['));
      expect(manifest, contains('"twice"'));

      final check = await DwiBuilder(project.config()).check();
      expect(check.ok, isTrue, reason: check.issues.join('\n'));

      final second = await DwiBuilder(project.config(compile: true)).build();
      expect(second.compiled, isFalse);
      expect(second.cacheHit, isTrue);
      expect(second.hash, first.hash);

      project.write('lib/tasks.dart', '$simpleTasks\n// changed dependency\n');
      final stale = await DwiBuilder(project.config()).check();
      expect(stale.ok, isFalse);

      final third = await DwiBuilder(project.config(compile: true)).build();
      expect(third.compiled, isTrue);
      expect(third.hash, isNot(first.hash));

      await DwiBuilder(project.config()).clean();
      expect(project.exists('.dwi/generated_worker.dart'), isFalse);
      expect(project.exists('lib/dwi_tasks.g.dart'), isFalse);
      expect(project.exists('web/dwi/worker.dart.js'), isFalse);
      expect(project.exists('.dwi/worker_manifest.json'), isFalse);

      final afterClean = await DwiBuilder(project.config()).check();
      expect(afterClean.ok, isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('compilation-disabled builds do not claim a compiled manifest', () async {
    project.write('lib/tasks.dart', simpleTasks);

    await DwiBuilder(project.config(compile: true)).build();
    final compiled = project.read('.dwi/worker_manifest.json');

    project.write('lib/tasks.dart', '$simpleTasks\n// changed\n');
    final generated = await DwiBuilder(project.config()).build();
    expect(generated.compiled, isFalse);

    // The old manifest is intentionally left untouched; check must report the
    // mismatch instead of silently treating the generated sources as compiled.
    expect(project.read('.dwi/worker_manifest.json'), compiled);
    final check = await DwiBuilder(project.config()).check();
    expect(check.ok, isFalse);
    expect(
      check.issues.join('\n'),
      contains('Manifest hash does not match'),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('force recompiles an unchanged worker', () async {
    project.write('lib/tasks.dart', simpleTasks);

    await DwiBuilder(project.config(compile: true)).build();
    final forced = await DwiBuilder(project.config(compile: true, force: true))
        .build();

    expect(forced.compiled, isTrue);
    expect(forced.cacheHit, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
