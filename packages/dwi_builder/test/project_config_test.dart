import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  String target({String? cli}) => DwiProjectConfig.resolveTarget(
    projectRoot: project.root.path,
    cliTarget: cli,
  );

  group('DwiProjectConfig', () {
    test('defaults to js without a dwi.yaml', () {
      expect(DwiProjectConfig.load(project.root.path).target, isNull);
      expect(target(), 'js');
    });

    test('reads wasm from dwi.yaml', () {
      project.write('dwi.yaml', 'target: wasm\n');
      expect(DwiProjectConfig.load(project.root.path).target, 'wasm');
      expect(target(), 'wasm');
    });

    test('an explicit CLI target overrides the file', () {
      project.write('dwi.yaml', 'target: wasm\n');
      expect(target(cli: 'js'), 'js');
      project.write('dwi.yaml', 'target: js\n');
      expect(target(cli: 'wasm'), 'wasm');
    });

    test('rejects an unsupported target', () {
      project.write('dwi.yaml', 'target: native\n');
      expect(
        () => DwiProjectConfig.load(project.root.path),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an unknown key', () {
      project.write('dwi.yaml', 'target: wasm\nworker: other\n');
      expect(
        () => DwiProjectConfig.load(project.root.path),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects malformed YAML and a non-map document', () {
      project.write('dwi.yaml', 'target: [unclosed\n');
      expect(
        () => DwiProjectConfig.load(project.root.path),
        throwsA(isA<ArgumentError>()),
      );
      project.write('dwi.yaml', '- target\n- wasm\n');
      expect(
        () => DwiProjectConfig.load(project.root.path),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test(
    'switches an application between js and wasm through dwi.yaml',
    () async {
      project.write(
        'lib/tasks.dart',
        '''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int twice(int value) => value * 2;
''',
      );

      DwiBuildConfig config() => project.config(compile: true).copyWith(
        target: DwiProjectConfig.resolveTarget(
          projectRoot: project.root.path,
        ),
      );

      project.write('dwi.yaml', 'target: js\n');
      final js = await DwiBuilder(config()).build();
      expect(js.artifactPath, endsWith('worker.dart.js'));
      expect(project.exists('web/dwi/worker.dart.js'), isTrue);
      var manifest =
          File(
                p.join(project.root.path, '.dwi/worker_manifest.json'),
              ).readAsStringSync();
      expect(manifest, contains('"target": "js"'));
      expect(
        (await DwiBuilder(config()).check()).ok,
        isTrue,
      );

      // Switch to wasm: the hook and CLI resolve the same file.
      project.write('dwi.yaml', 'target: wasm\n');
      final wasm = await DwiBuilder(config()).build();
      expect(wasm.compiled, isTrue);
      expect(wasm.artifactPath, endsWith('worker.boot.mjs'));
      manifest = File(
        p.join(project.root.path, '.dwi/worker_manifest.json'),
      ).readAsStringSync();
      expect(manifest, contains('"target": "wasm"'));
      expect(manifest, contains('"generation"'));
      expect(project.exists('web/dwi/worker.boot.mjs'), isTrue);
      expect((await DwiBuilder(config()).check()).ok, isTrue);

      // Switch back: the js artefact is rebuilt and check follows the file.
      project.write('dwi.yaml', 'target: js\n');
      final jsAgain = await DwiBuilder(config()).build();
      expect(jsAgain.compiled, isTrue);
      expect(jsAgain.artifactPath, endsWith('worker.dart.js'));
      manifest = File(
        p.join(project.root.path, '.dwi/worker_manifest.json'),
      ).readAsStringSync();
      expect(manifest, contains('"target": "js"'));
      expect((await DwiBuilder(config()).check()).ok, isTrue);

      // clean uses the same resolution.
      await DwiBuilder(config()).clean();
      expect(project.exists('web/dwi/worker.dart.js'), isFalse);
      expect(project.exists('web/dwi/worker.boot.mjs'), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
