import 'dart:async';
import 'dart:convert';
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
  // Long enough to cover three successive deployments while spawning.
  for (var index = 0; index < 100; index++) {
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

/// Serves [root] with the deployment headers ADR-018 requires.
///
/// The entry must be revalidated so a reload observes a deployment, and
/// generation files are immutable and content-addressed.
Future<HttpServer> _serveRealistic(
  String root,
  Completer<void> firstWorkerRequest,
) async {
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
        request.response.headers.set(
          'cache-control',
          p.basename(path) == 'worker.boot.mjs'
              ? 'no-cache'
              : path.contains('/gen-')
                  ? 'public, max-age=31536000, immutable'
                  : 'no-cache',
        );
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
        if (p.basename(path) == 'worker.boot.mjs') {
          if (!firstWorkerRequest.isCompleted) firstWorkerRequest.complete();
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

String _generationOf(FixtureProject project) =>
    (jsonDecode(project.read('.dwi/worker_manifest.json'))
        as Map<String, dynamic>)['generation'] as String;

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  for (final engine in BrowserEngine.values) {
    test(
      'loads workers across three deployments in ${engine.name}',
      () async {
        final availability = browserAvailability(engine);
        if (!availability.available) {
          markTestSkipped(availability.reason!);
          return;
        }

        project.write('lib/tasks.dart', publicationTasks);
        project.write('web/main.dart', publicationMain);
        project.write('web/index.html', publicationIndex);

        final config = project.config(compile: true).copyWith(target: 'wasm');
        await DwiBuilder(config).build();
        final generations = <String>[_generationOf(project)];

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

        // The page signals readiness by requesting the bootstrap. Deployments
        // are triggered by that observation, not by a fixed startup delay, so
        // a slower engine still observes every deployment.
        final firstWorkerRequest = Completer<void>();
        final server = await _serveRealistic(
          p.join(project.root.path, 'web'),
          firstWorkerRequest,
        );
        try {
          final page = probeBrowser(
            engine,
            'http://127.0.0.1:${server.port}/index.html',
          );

          // Deploy A, then B and C while the page keeps spawning workers.
          await firstWorkerRequest.future.timeout(
            const Duration(seconds: 90),
          );
          await Future<void>.delayed(const Duration(seconds: 1));
          project.write(
            'lib/tasks.dart',
            publicationTasks.replaceFirst("=> 'A'", "=> 'B'"),
          );
          await DwiBuilder(config).build();
          generations.add(_generationOf(project));

          await Future<void>.delayed(const Duration(seconds: 3));
          project.write(
            'lib/tasks.dart',
            publicationTasks.replaceFirst("=> 'A'", "=> 'C'"),
          );
          await DwiBuilder(config).build();
          generations.add(_generationOf(project));

          final decoded = (await page).data;
          final errors = (decoded['errors'] as List<dynamic>).cast<String>();
          final values = (decoded['values'] as List<dynamic>).cast<String>();
          expect(errors, isEmpty, reason: 'a worker failed during the switch');
          expect(
            values,
            containsAll(<String>['A', 'B', 'C']),
            reason: 'every deployment must be observed',
          );
          expect(
            values.every((value) => <String>{'A', 'B', 'C'}.contains(value)),
            isTrue,
            reason: 'a worker returned a mixed or unknown value: $values',
          );
          // Every generation the page used is still on disk: a build does not
          // delete what a cached bootstrap can name.
          for (final generation in generations) {
            expect(
              project.exists('web/dwi/gen-$generation/worker.wasm'),
              isTrue,
              reason: 'generation $generation was removed during the run',
            );
          }
        } finally {
          await server.close(force: true);
        }
      },
      // Four engines each build three generations and compile a host.
      timeout: const Timeout(Duration(minutes: 15)),
    );
  }
}
