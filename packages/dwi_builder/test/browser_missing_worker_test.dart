import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

const _main = r'''
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi/dwi.dart';

@JS('document')
external JSObject get document;

Future<void> main() async {
  final result = <String, Object?>{};
  for (final backend in DwiWorkerBackend.values) {
    await Dwi.configure(DwiConfig(
      workerBackend: backend,
      workerScript: backend == DwiWorkerBackend.wasm
          ? 'dwi/missing-worker.mjs'
          : 'dwi/missing-worker.js',
      startupTimeout: const Duration(seconds: 2),
    ));
    try {
      await Dwi.run<Object?>('missing', null);
      result['${backend.name}.pool'] = 'unexpected success';
    } on DwiStartupException {
      result['${backend.name}.pool'] = 'DwiStartupException';
    }
    try {
      await DwiWorker.spawn();
      result['${backend.name}.handle'] = 'unexpected success';
    } on DwiStartupException {
      result['${backend.name}.handle'] = 'DwiStartupException';
    }
    await Dwi.close();
  }
  document.setProperty(
    'title'.toJS,
    base64Encode(utf8.encode(jsonEncode(result))).toJS,
  );
}
''';

void main() {
  late FixtureProject project;
  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'missing JS and Wasm assets settle pool and handle startup in Chrome',
    () async {
      project.write('web/main.dart', _main);
      project.write('web/index.html', '''
<!doctype html><title>pending</title><script defer src="main.dart.js"></script>
''');
      final compiled = await Process.run(Platform.resolvedExecutable, <String>[
        'compile',
        'js',
        '-O1',
        '-o',
        'web/main.dart.js',
        'web/main.dart',
      ], workingDirectory: project.root.path);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}\n${compiled.stderr}',
      );
      final server = await serveDirectory(p.join(project.root.path, 'web'));
      try {
        final result = await probeChrome(
          'http://127.0.0.1:${server.port}/index.html',
        );
        for (final backend in <String>['js', 'wasm']) {
          expect(result['$backend.pool'], 'DwiStartupException');
          expect(result['$backend.handle'], 'DwiStartupException');
        }
      } finally {
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: chromeExecutable() == null
        ? 'Google Chrome is not installed.'
        : false,
  );
}
