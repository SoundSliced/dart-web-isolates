import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:dwi_builder/src/toolchain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Files left behind by a failed or interrupted atomic write.
List<String> leftoverTemporaryFiles(Directory root) {
  if (!root.existsSync()) return const <String>[];
  final temporary = RegExp(r'\.tmp(\.|$)');
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.path)
      .where(
        (path) => path.endsWith('.bak') || temporary.hasMatch(p.basename(path)),
      )
      .toList(growable: false);
}

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
    'static task edits invalidate compiled registries and cached sources',
    () async {
      const source = r'''
import 'package:dwi_annotations/dwi_annotations.dart';
class Ops {
  @DwiTask()
  static int twice(int value) => value * 2;
}
''';
      project.write('lib/tasks.dart', source);
      final config = project.config(compile: true);
      final first = await DwiBuilder(config).build();
      final second = await DwiBuilder(config).build();
      expect(second.cacheHit, isTrue);
      expect(
        project.read('lib/dwi_tasks.g.dart'),
        contains(r'task0.Ops.twice: DwiTasks.Ops$twice'),
      );
      project.write(
        'lib/tasks.dart',
        source.replaceFirst('value * 2', 'value * 3'),
      );
      final changed = await DwiBuilder(config).build();
      expect(changed.cacheHit, isFalse);
      expect(changed.hash, isNot(first.hash));
      final checked = await DwiBuilder(config).check();
      expect(checked.ok, isTrue, reason: checked.issues.join('\n'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'builds, checks and cleans a content-addressed wasm generation',
    () async {
      project.write('lib/tasks.dart', simpleTasks);
      final wasmConfig = project.config(compile: true).copyWith(target: 'wasm');

      final first = await DwiBuilder(wasmConfig).build();
      expect(first.compiled, isTrue);
      expect(first.cacheHit, isFalse);
      expect(first.artifactPath, endsWith('worker.boot.mjs'));
      expect(project.exists('web/dwi/worker.boot.mjs'), isTrue);

      final manifest = jsonDecode(
        project.read('.dwi/worker_manifest.json'),
      ) as Map<String, dynamic>;
      expect(manifest['target'], 'wasm');
      expect(manifest['artifactDigest'], isA<String>());
      final generation = manifest['generation'] as String;
      expect(generation, first.hash);
      expect(project.exists('web/dwi/gen-$generation/worker.wasm'), isTrue);
      expect(project.exists('web/dwi/gen-$generation/worker.mjs'), isTrue);
      expect(
        project.exists('web/dwi/gen-$generation/worker.wasm.map'),
        isFalse,
      );
      final files = manifest['artifactFiles'] as List<dynamic>;
      expect(files.length, 3);
      expect(
        files.map((entry) => (entry as Map)['path']),
        containsAll(<String>[
          'dwi/worker.boot.mjs',
          'dwi/gen-$generation/worker.mjs',
          'dwi/gen-$generation/worker.wasm',
        ]),
      );

      final check = await DwiBuilder(project.config().copyWith(target: 'wasm'))
          .check();
      expect(check.ok, isTrue, reason: check.issues.join('\n'));

      final second = await DwiBuilder(wasmConfig).build();
      expect(second.compiled, isFalse);
      expect(second.cacheHit, isTrue);

      // A missing companion must fail the check instead of being ignored.
      File(p.join(project.root.path, 'web/dwi/gen-$generation/worker.mjs'))
          .deleteSync();
      final broken = await DwiBuilder(project.config().copyWith(target: 'wasm'))
          .check();
      expect(broken.ok, isFalse);
      expect(broken.issues.join('\n'), contains('artefact'));

      await DwiBuilder(project.config().copyWith(target: 'wasm')).clean();
      expect(project.exists('web/dwi/worker.boot.mjs'), isFalse);
      expect(project.exists('web/dwi/gen-$generation'), isFalse);
      expect(project.exists('.dwi/worker_manifest.json'), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a failed generation publication leaves the previous entry usable',
    () async {
      project.write('lib/tasks.dart', simpleTasks);
      final config = project.config(compile: true).copyWith(target: 'wasm');
      final first = await DwiBuilder(config).build();
      final entry = File(first.artifactPath);
      final oldEntry = entry.readAsStringSync();
      final oldGeneration =
          (jsonDecode(project.read('.dwi/worker_manifest.json'))
                  as Map<String, dynamic>)['generation']
              as String;

      project.write(
        'lib/tasks.dart',
        simpleTasks.replaceAll('value * 2', 'value * 3'),
      );
      debugPublicationStep = (step) async {
        if (step == 'generation') throw StateError('injected generation');
      };
      try {
        await expectLater(
          DwiBuilder(config).build(),
          throwsA(isA<DwiBuildException>()),
        );
      } finally {
        debugPublicationStep = null;
      }

      // The old entry and its generation are untouched: a live worker can
      // still load the last valid pair.
      expect(entry.readAsStringSync(), oldEntry);
      expect(project.exists('web/dwi/gen-$oldGeneration/worker.mjs'), isTrue);
      expect(project.exists('web/dwi/gen-$oldGeneration/worker.wasm'), isTrue);

      // A later build publishes the new pair and keeps the previous generation.
      final rebuilt = await DwiBuilder(config).build();
      expect(rebuilt.compiled, isTrue);
      final newGeneration =
          (jsonDecode(project.read('.dwi/worker_manifest.json'))
                  as Map<String, dynamic>)['generation']
              as String;
      expect(newGeneration, isNot(oldGeneration));
      expect(entry.readAsStringSync(), contains(newGeneration));
      expect(project.exists('web/dwi/gen-$newGeneration/worker.wasm'), isTrue);
      expect(project.exists('web/dwi/gen-$oldGeneration/worker.wasm'), isTrue);
      final check = await DwiBuilder(project.config().copyWith(target: 'wasm'))
          .check();
      expect(check.ok, isTrue, reason: check.issues.join('\n'));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a failure after the entry switch is reported by check and recovered',
    () async {
      project.write('lib/tasks.dart', simpleTasks);
      final config = project.config(compile: true).copyWith(target: 'wasm');
      final first = await DwiBuilder(config).build();
      final entry = File(first.artifactPath);
      final oldEntry = entry.readAsStringSync();

      project.write(
        'lib/tasks.dart',
        simpleTasks.replaceAll('value * 2', 'value * 5'),
      );
      debugPublicationStep = (step) async {
        if (step == 'entry') throw StateError('injected after entry');
      };
      try {
        await expectLater(
          DwiBuilder(config).build(),
          throwsA(isA<DwiBuildException>()),
        );
      } finally {
        debugPublicationStep = null;
      }

      // The entry already points at the complete new generation, but the
      // manifest was not written. check must reject that state.
      expect(entry.readAsStringSync(), isNot(oldEntry));
      final stale = await DwiBuilder(project.config().copyWith(target: 'wasm'))
          .check();
      expect(stale.ok, isFalse);

      final recovered = await DwiBuilder(config).build();
      expect(recovered.compiled, isTrue);
      final check = await DwiBuilder(project.config().copyWith(target: 'wasm'))
          .check();
      expect(check.ok, isTrue, reason: check.issues.join('\n'));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('retains every generation across A, B and C builds', () async {
    project.write('lib/tasks.dart', simpleTasks);
    final config = project.config(compile: true).copyWith(target: 'wasm');
    final generations = <String>[];

    Future<void> buildVariant(String replacement) async {
      if (replacement.isNotEmpty) {
        project.write(
          'lib/tasks.dart',
          simpleTasks.replaceAll('value * 2', replacement),
        );
      }
      final result = await DwiBuilder(config).build();
      expect(result.hash, isNotEmpty);
      generations.add(
        (jsonDecode(project.read('.dwi/worker_manifest.json'))
                as Map<String, dynamic>)['generation']
            as String,
      );
    }

    await buildVariant('');
    await buildVariant('value * 6');
    await buildVariant('value * 7');
    await buildVariant('value * 8');

    expect(generations.toSet(), hasLength(4));
    // A cached bootstrap can still name any generation the project served,
    // so every complete generation stays on disk (ADR-018).
    for (final generation in generations) {
      expect(
        project.exists('web/dwi/gen-$generation/worker.wasm'),
        isTrue,
        reason: 'generation $generation was removed',
      );
      expect(
        project.exists('web/dwi/gen-$generation/worker.mjs'),
        isTrue,
        reason: 'generation $generation was removed',
      );
    }
    final entry = project.read('web/dwi/worker.boot.mjs');
    expect(entry, contains(generations.last));
    for (final generation in generations.take(3)) {
      expect(entry, isNot(contains(generation)));
    }
    final check = await DwiBuilder(project.config().copyWith(target: 'wasm'))
        .check();
    expect(check.ok, isTrue, reason: check.issues.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('rebuilding an existing content hash reuses its generation', () async {
    project.write('lib/tasks.dart', simpleTasks);
    final config = project.config(compile: true).copyWith(target: 'wasm');
    await DwiBuilder(config).build();
    final generationA =
        (jsonDecode(project.read('.dwi/worker_manifest.json'))
                as Map<String, dynamic>)['generation']
            as String;

    project.write(
      'lib/tasks.dart',
      simpleTasks.replaceAll('value * 2', 'value * 9'),
    );
    await DwiBuilder(config).build();
    final generationB =
        (jsonDecode(project.read('.dwi/worker_manifest.json'))
                as Map<String, dynamic>)['generation']
            as String;

    // Revert to the earlier content: its generation is rebuilt, not
    // duplicated, and both generations remain available.
    project.write('lib/tasks.dart', simpleTasks);
    await DwiBuilder(config).build();
    final generations = Directory(p.join(project.root.path, 'web/dwi'))
        .listSync()
        .whereType<Directory>()
        .map((entity) => p.basename(entity.path))
        .toSet();
    expect(generations, <String>{'gen-$generationA', 'gen-$generationB'});
    final check = await DwiBuilder(project.config().copyWith(target: 'wasm'))
        .check();
    expect(check.ok, isTrue, reason: check.issues.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
    'a corrupt module or an interrupted temp directory is handled',
    () async {
      project.write('lib/tasks.dart', simpleTasks);
      final config = project.config(compile: true).copyWith(target: 'wasm');
      final first = await DwiBuilder(config).build();
      final generation =
          (jsonDecode(project.read('.dwi/worker_manifest.json'))
                  as Map<String, dynamic>)['generation']
              as String;

      // Simulate an interrupted publication from an earlier process.
      final leftover = Directory(
        p.join(project.root.path, 'web/dwi/.dwi-wasm-leftover.tmp'),
      )..createSync(recursive: true);

      File(p.join(project.root.path, 'web/dwi/gen-$generation/worker.wasm'))
          .writeAsBytesSync(<int>[0, 1, 2]);
      final corrupt = await DwiBuilder(
        project.config().copyWith(target: 'wasm'),
      ).check();
      expect(corrupt.ok, isFalse);
      expect(corrupt.issues.join('\n'), contains('artefact'));

      // A rebuild repairs the generation and removes the abandoned temporary
      // directory; it never removes a published generation.
      await DwiBuilder(config).build();
      expect(leftover.existsSync(), isFalse);
      expect(project.exists('web/dwi/gen-$generation/worker.wasm'), isTrue);
      expect(
        (await DwiBuilder(
          project.config().copyWith(target: 'wasm'),
        ).check()).ok,
        isTrue,
      );
      await DwiBuilder(project.config().copyWith(target: 'wasm')).clean();
      expect(
        Directory(p.join(project.root.path, 'web/dwi/gen-$generation'))
            .existsSync(),
        isFalse,
      );
      expect(first.hash, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a missing current generation is reported by check and rebuilt',
    () async {
      project.write('lib/tasks.dart', simpleTasks);
      final config = project.config(compile: true).copyWith(target: 'wasm');
      await DwiBuilder(config).build();
      final generation =
          (jsonDecode(project.read('.dwi/worker_manifest.json'))
                  as Map<String, dynamic>)['generation']
              as String;

      final directory = Directory(
        p.join(project.root.path, 'web/dwi/gen-$generation'),
      );
      directory.deleteSync(recursive: true);

      final missing = await DwiBuilder(
        project.config().copyWith(target: 'wasm'),
      ).check();
      expect(missing.ok, isFalse);
      expect(missing.issues.join('\n'), contains('artefact'));

      await DwiBuilder(config).build();
      expect(project.exists('web/dwi/gen-$generation/worker.wasm'), isTrue);
      expect(
        (await DwiBuilder(
          project.config().copyWith(target: 'wasm'),
        ).check()).ok,
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

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
      expect(manifest, contains('"artifactDigest": "'));
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
    expect(check.issues.join('\n'), contains('Manifest hash does not match'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('force recompiles an unchanged worker', () async {
    project.write('lib/tasks.dart', simpleTasks);

    await DwiBuilder(project.config(compile: true)).build();
    final forced = await DwiBuilder(project.config(compile: true, force: true))
        .build();

    expect(forced.compiled, isTrue);
    expect(forced.cacheHit, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('generated output is byte-identical for identical inputs', () async {
    project.write('lib/tasks.dart', goodTasks);

    await DwiBuilder(project.config()).build();
    final worker = project.read('.dwi/generated_worker.dart');
    final proxies = project.read('lib/dwi_tasks.g.dart');

    await DwiBuilder(project.config()).build();

    expect(project.read('.dwi/generated_worker.dart'), worker);
    expect(project.read('lib/dwi_tasks.g.dart'), proxies);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('rejects a corrupt artefact and rebuilds it', () async {
    project.write('lib/tasks.dart', simpleTasks);
    final first = await DwiBuilder(project.config(compile: true)).build();
    File(first.artifactPath).writeAsStringSync('corrupt artefact');

    final corrupt = await DwiBuilder(project.config()).check();
    expect(corrupt.ok, isFalse);
    expect(
      corrupt.issues.join('\n'),
      contains('artefact set does not match the manifest'),
    );

    final rebuilt = await DwiBuilder(project.config(compile: true)).build();
    expect(rebuilt.compiled, isTrue);
    expect(rebuilt.cacheHit, isFalse);

    final after = await DwiBuilder(project.config()).check();
    expect(after.ok, isTrue, reason: after.issues.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('rejects a deleted artefact and rebuilds it', () async {
    project.write('lib/tasks.dart', simpleTasks);
    final first = await DwiBuilder(project.config(compile: true)).build();
    File(first.artifactPath).deleteSync();

    final missing = await DwiBuilder(project.config()).check();
    expect(missing.ok, isFalse);
    expect(missing.issues.join('\n'), contains('artefact is missing'));

    final rebuilt = await DwiBuilder(project.config(compile: true)).build();
    expect(rebuilt.compiled, isTrue);
    expect((await DwiBuilder(project.config()).check()).ok, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a failed compilation leaves the previous artefact intact', () async {
    project.write('lib/tasks.dart', simpleTasks);
    final built = await DwiBuilder(project.config(compile: true)).build();
    final before = await fileDigest(built.artifactPath);

    project.write('.dwi/generated_worker.dart', 'void main( {');
    await expectLater(
      compileWorker(project.config(compile: true)),
      throwsA(isA<DwiBuildException>()),
    );

    expect(await fileDigest(built.artifactPath), before);
    expect(leftoverTemporaryFiles(project.root), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a publication failure keeps the previous artefact and manifest',
    () async {
      project.write('lib/tasks.dart', simpleTasks);
      final built = await DwiBuilder(project.config(compile: true)).build();
      final beforeArtifact = await fileDigest(built.artifactPath);
      final beforeManifest = project.read('.dwi/worker_manifest.json');

      // A valid, different worker source forces a real compilation whose
      // publication then fails.
      project.write(
        '.dwi/generated_worker.dart',
        '${project.read('.dwi/generated_worker.dart')}\n// changed\n',
      );

      debugPublishOverride = (temporary, artifact) async {
        throw const FileSystemException('simulated publication failure');
      };
      addTearDown(() => debugPublishOverride = null);

      await expectLater(
        compileWorker(project.config(compile: true)),
        throwsA(
          isA<DwiBuildException>().having(
            (error) => error.summary,
            'summary',
            contains('Could not publish'),
          ),
        ),
      );

      expect(await fileDigest(built.artifactPath), beforeArtifact);
      expect(project.read('.dwi/worker_manifest.json'), beforeManifest);
      expect(leftoverTemporaryFiles(project.root), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a builder publication failure leaves the last verified state',
    () async {
      project.write('lib/tasks.dart', simpleTasks);
      final built = await DwiBuilder(project.config(compile: true)).build();
      final beforeArtifact = await fileDigest(built.artifactPath);
      final beforeManifest = project.read('.dwi/worker_manifest.json');

      debugPublishOverride = (temporary, artifact) async {
        throw const FileSystemException('simulated publication failure');
      };
      addTearDown(() => debugPublishOverride = null);

      await expectLater(
        DwiBuilder(project.config(compile: true, force: true)).build(),
        throwsA(isA<DwiBuildException>()),
      );

      expect(await fileDigest(built.artifactPath), beforeArtifact);
      expect(project.read('.dwi/worker_manifest.json'), beforeManifest);
      expect(leftoverTemporaryFiles(project.root), isEmpty);

      final check = await DwiBuilder(project.config()).check();
      expect(check.ok, isTrue, reason: check.issues.join('\n'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a published build exposes a complete artefact and matching digest',
    () async {
      project.write('lib/tasks.dart', simpleTasks);
      final built = await DwiBuilder(project.config(compile: true)).build();

      final artifact = File(built.artifactPath);
      final content = await artifact.readAsString();
      expect(content, isNotEmpty);
      expect(content, contains('dart2js'));
      expect(leftoverTemporaryFiles(project.root), isEmpty);

      final manifest = jsonDecode(
        project.read('.dwi/worker_manifest.json'),
      ) as Map<String, Object?>;
      expect(manifest['artifactDigest'], await fileDigest(built.artifactPath));

      final check = await DwiBuilder(project.config()).check();
      expect(check.ok, isTrue, reason: check.issues.join('\n'));
      expect(check.hash, built.hash);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('overlapping builds publish one consistent set of outputs', () async {
    project.write('lib/tasks.dart', simpleTasks);

    final results = await Future.wait(<Future<DwiBuildResult>>[
      DwiBuilder(project.config(compile: true)).build(),
      DwiBuilder(project.config(compile: true)).build(),
      DwiBuilder(project.config(compile: true)).build(),
    ]);

    // Serialized builds: the first compiles and the rest reuse its outputs.
    expect(results.where((result) => result.compiled).length, 1);
    final hashes = results.map((result) => result.hash).toSet();
    expect(hashes, hasLength(1));

    final check = await DwiBuilder(project.config()).check();
    expect(check.ok, isTrue, reason: check.issues.join('\n'));

    final manifest = jsonDecode(
      project.read('.dwi/worker_manifest.json'),
    ) as Map<String, Object?>;
    expect(manifest['hash'], check.hash);
    expect(
      manifest['artifactDigest'],
      await fileDigest(project.config().absoluteArtifact),
    );

    final proxies = project.read('lib/dwi_tasks.g.dart');
    final worker = project.read('.dwi/generated_worker.dart');
    for (final name in <String>['twice', 'hello']) {
      expect(proxies, contains(name));
      expect(worker, contains(name));
    }

    expect(leftoverTemporaryFiles(project.root), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('editing a dependency of the task file invalidates the cache', () async {
    project.write('lib/helper.dart', 'int offset() => 1;\n');
    project.write('lib/tasks.dart', r'''
import 'helper.dart';
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int shifted(int value) => value + offset();
''');

    final first = await DwiBuilder(project.config(compile: true)).build();
    expect(first.compiled, isTrue);

    final hit = await DwiBuilder(project.config(compile: true)).build();
    expect(hit.cacheHit, isTrue);
    expect(hit.compiled, isFalse);

    project.write('lib/helper.dart', 'int offset() => 2;\n');
    final stale = await DwiBuilder(project.config()).check();
    expect(stale.ok, isFalse);

    final rebuilt = await DwiBuilder(project.config(compile: true)).build();
    expect(rebuilt.compiled, isTrue);
    expect(rebuilt.hash, isNot(first.hash));

    final after = await DwiBuilder(project.config()).check();
    expect(after.ok, isTrue, reason: after.issues.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('package-resolution changes invalidate the cache', () async {
    project.write('lib/tasks.dart', simpleTasks);
    await DwiBuilder(project.config(compile: true)).build();

    final packageConfig = File(
      p.join(project.root.path, '.dart_tool', 'package_config.json'),
    );
    packageConfig.writeAsStringSync('${packageConfig.readAsStringSync()}\n');

    final check = await DwiBuilder(project.config()).check();
    expect(check.ok, isFalse);
    expect(check.issues.join('\n'), contains('Manifest hash does not match'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
