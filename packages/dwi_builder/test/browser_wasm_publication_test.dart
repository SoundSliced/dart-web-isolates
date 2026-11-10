import 'dart:async';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

const String publicationTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
String version() => 'A';
''';

const String publicationMain = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dwi/dwi.dart';

@JS('document')
external JSObject get _document;

Future<void> main() async {
  final values = <String>[];
  final errors = <String>[];
  await Dwi.configure(const DwiConfig(
    workerBackend: DwiWorkerBackend.wasm,
    workerScript: DwiConfig.defaultWasmWorkerScript,
    startupTimeout: Duration(seconds: 15),
  ));
  for (var index = 0; index < 40; index++) {
    try {
      final worker = await DwiWorker.spawn();
      values.add(await worker.run<String>('version'));
      await worker.close();
    } catch (error) {
      errors.add(error.runtimeType.toString());
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  await Dwi.close();
  _document.setProperty(
    'title'.toJS,
    base64Encode(utf8.encode(jsonEncode(<String, Object?>{
      'values': values,
      'errors': errors,
    }))).toJS,
  );
}
''';

const String publicationIndex = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body><script defer src="main.dart.js"></script></body>
</html>
''';

/// Serves [root] with `Cache-Control: no-store` so a rebuilt entry is observed.
Future<HttpServer> _serveNoStore(String root) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.forEach((request) async {
      try {
        final relative = request.uri.path.replaceFirst(RegExp('^/'), '');
        final path = p.normalize(
          p.join(root, relative.isEmpty ? 'index.html' : relative),
        );
        final file = File(path);
        if (!p.isWithin(root, path) || !await file.exists()) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        request.response.headers.set('cache-control', 'no-store');
        final name = p.basename(path);
        if (name.endsWith('.html')) {
          request.response.headers.contentType = ContentType.html;
        } else if (name.endsWith('.wasm')) {
          request.response.headers.set('content-type', 'application/wasm');
        } else if (name.endsWith('.mjs') || name.endsWith('.js')) {
          request.response.headers.set(
            'content-type',
            'text/javascript; charset=utf-8',
          );
        }
        request.response.add(await file.readAsBytes());
        await request.response.close();
      } catch (_) {
        try {
          await request.response.close();
        } on Object {
          // The client is gone.
        }
      }
    }),
  );
  return server;
}

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'loads workers while a wasm generation is rebuilt',
    () async {
      project.write('lib/tasks.dart', publicationTasks);
      project.write('web/main.dart', publicationMain);
      project.write('web/index.html', publicationIndex);

      final config = project.config(compile: true).copyWith(target: 'wasm');
      await DwiBuilder(config).build();

      final compiled = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'compile',
          'js',
          '-O1',
          '-o',
          'web/main.dart.js',
          'web/main.dart',
        ],
        workingDirectory: project.root.path,
      );
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}\n${compiled.stderr}',
      );

      final server = await _serveNoStore(p.join(project.root.path, 'web'));
      try {
        final page = probeChrome(
          'http://127.0.0.1:${server.port}/index.html',
        );

        // Rebuild while the page keeps spawning workers.
        await Future<void>.delayed(const Duration(milliseconds: 4000));
        project.write(
          'lib/tasks.dart',
          publicationTasks.replaceFirst("=> 'A'", "=> 'B'"),
        );
        await DwiBuilder(config).build();
        final manifest =
            (await File(
                      p.join(
                        project.root.path,
                        '.dwi/worker_manifest.json',
                      ),
                    ).readAsString());
        expect(manifest, contains('"generation"'));

        final decoded = await page;
        final errors = (decoded['errors'] as List<dynamic>).cast<String>();
        final values = (decoded['values'] as List<dynamic>).cast<String>();
        expect(errors, isEmpty, reason: 'a worker failed during the switch');
        expect(values, contains('A'));
        expect(values, contains('B'));
        expect(values.every((value) => value == 'A' || value == 'B'), isTrue);
      } finally {
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: chromeExecutable() == null ? 'Google Chrome is not installed.' : false,
  );
}
