import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/browser_probe.dart';
import 'support/fixture.dart';

const String cachedBootstrapTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
String version() => 'A';
''';

const String cachedBootstrapMain = r'''
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
    startupTimeout: Duration(seconds: 10),
  ));
  try {
    final worker = await DwiWorker.spawn();
    values.add(await worker.run<String>('version'));
    await worker.close();
  } catch (error) {
    errors.add(error.runtimeType.toString());
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

const String cachedBootstrapIndex = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body><script defer src="main.dart.js"></script></body>
</html>
''';

/// A deployment tree a browser is served from.
class _Deployment {
  _Deployment(this.root);

  final Directory root;

  /// Copies [source] into this deployment, dropping every generation directory.
  void publish(String source, {bool keepGenerations = false}) {
    if (root.existsSync()) root.deleteSync(recursive: true);
    _copy(Directory(source), root);
    if (!keepGenerations) {
      final artifactDir = Directory(p.join(root.path, 'dwi'));
      for (final entity in artifactDir.listSync()) {
        if (entity is Directory && p.basename(entity.path).startsWith('gen-')) {
          entity.deleteSync(recursive: true);
        }
      }
    }
  }

  /// Overwrites the published entry with exactly [bootstrap] bytes.
  void serveCachedEntry(String bootstrap) {
    File(p.join(root.path, 'dwi/worker.boot.mjs')).writeAsStringSync(bootstrap);
  }

  void removeGeneration(String generation) {
    final directory = Directory(p.join(root.path, 'dwi/gen-$generation'));
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

void _copy(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: from.path);
    if (entity is Directory) {
      Directory(p.join(to.path, relative)).createSync(recursive: true);
    } else if (entity is File) {
      final destination = File(p.join(to.path, relative));
      destination.parent.createSync(recursive: true);
      entity.copySync(destination.path);
    }
  }
}

/// Serves [root] and records every requested path.
Future<HttpServer> _serve(Directory root, List<String> requests) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.forEach((request) async {
      try {
        final relative = request.uri.path.replaceFirst(RegExp('^/'), '');
        final path = p.normalize(
          p.join(root.path, relative.isEmpty ? 'index.html' : relative),
        );
        final file = File(path);
        if (!p.isWithin(root.path, path) || !await file.exists()) {
          requests.add('${request.method} ${request.uri.path} -> 404');
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
        requests.add('${request.method} ${request.uri.path} -> 200');
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
            as Map<String, dynamic>)['generation']
        as String;

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  Future<String> compileHost() async {
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
    project.write('web/index.html', cachedBootstrapIndex);
    return p.join(project.root.path, 'web');
  }

  for (final engine in BrowserEngine.values) {
    test('a client holding generation A keeps loading it across B, C and D builds '
        'in ${engine.name}', () async {
      final availability = browserAvailability(engine);
      if (!availability.available) {
        markTestSkipped(availability.reason!);
        return;
      }
      project.write('lib/tasks.dart', cachedBootstrapTasks);
      project.write('web/main.dart', cachedBootstrapMain);
      final config = project.config(compile: true).copyWith(target: 'wasm');

      await DwiBuilder(config).build();
      final web = await compileHost();
      final generationA = _generationOf(project);
      final cachedBootstrap = project.read('web/dwi/worker.boot.mjs');
      expect(cachedBootstrap, contains(generationA));

      for (final label in <String>['B', 'C', 'D']) {
        project.write(
          'lib/tasks.dart',
          cachedBootstrapTasks.replaceFirst("=> 'A'", "=> '$label'"),
        );
        await DwiBuilder(config).build();
      }
      final generationD = _generationOf(project);
      expect(generationD, isNot(generationA));

      final deployment = _Deployment(
        Directory(p.join(project.root.path, 'deploy')),
      );
      // The deployment publishes every generation the build produced; only the
      // entry is replaced on a deployment.
      deployment.publish(web, keepGenerations: true);
      // The browser still has the bootstrap it cached during deployment A.
      deployment.serveCachedEntry(cachedBootstrap);
      // A sub-path deployment serves the same tree under `sub/app/`.
      _copy(
        deployment.root,
        Directory(p.join(deployment.root.path, 'sub/app')),
      );

      final observed = <String, Map<String, dynamic>>{};
      final observedRequests = <String, List<String>>{};
      for (final prefix in <String>['', 'sub/app/']) {
        final requests = <String>[];
        final server = await _serve(deployment.root, requests);
        try {
          final url = 'http://127.0.0.1:${server.port}/${prefix}index.html';
          final run = await probeBrowser(engine, url);
          observed[prefix] = run.data;
          observedRequests[prefix] = requests;
        } finally {
          await server.close(force: true);
        }
      }
      for (final prefix in <String>['', 'sub/app/']) {
        // Printed so the observation for both prefixes is recorded even when
        // the assertion below fails on the first one.
        // ignore: avoid_print
        print(
          'cached-bootstrap[$prefix]: '
          'values=${observed[prefix]!['values']} '
          'errors=${observed[prefix]!['errors']} '
          'requests=${observedRequests[prefix]}',
        );
      }
      for (final prefix in <String>['', 'sub/app/']) {
        expect(
          observed[prefix]!['values'],
          <String>['A'],
          reason:
              'at "/$prefix" generation A must still load; '
              'got ${observed[prefix]}; requests: ${observedRequests[prefix]}',
        );
        expect(
          observed[prefix]!['errors'],
          isEmpty,
          reason:
              'got ${observed[prefix]}; '
              'requests: ${observedRequests[prefix]}',
        );
        expect(
          observedRequests[prefix]!.any(
            (path) => path.contains('gen-$generationA'),
          ),
          isTrue,
          reason: 'the cached bootstrap must fetch generation A at "/$prefix"',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 15)));

    test('a cached bootstrap whose generation was removed fails with a typed error '
        'in ${engine.name}', () async {
      final availability = browserAvailability(engine);
      if (!availability.available) {
        markTestSkipped(availability.reason!);
        return;
      }
      project.write('lib/tasks.dart', cachedBootstrapTasks);
      project.write('web/main.dart', cachedBootstrapMain);
      final config = project.config(compile: true).copyWith(target: 'wasm');

      await DwiBuilder(config).build();
      final web = await compileHost();
      final generationA = _generationOf(project);
      final cachedBootstrap = project.read('web/dwi/worker.boot.mjs');

      project.write(
        'lib/tasks.dart',
        cachedBootstrapTasks.replaceFirst("=> 'A'", "=> 'B'"),
      );
      await DwiBuilder(config).build();

      final deployment = _Deployment(
        Directory(p.join(project.root.path, 'deploy')),
      );
      // The deployment keeps every generation a normal build publishes, and
      // maintenance removes only the one a cached client still references.
      deployment.publish(web, keepGenerations: true);
      deployment.serveCachedEntry(cachedBootstrap);
      deployment.removeGeneration(generationA);
      _copy(
        deployment.root,
        Directory(p.join(deployment.root.path, 'sub/app')),
      );

      final observed = <String, Map<String, dynamic>>{};
      final observedRequests = <String, List<String>>{};
      for (final prefix in <String>['', 'sub/app/']) {
        final requests = <String>[];
        final server = await _serve(deployment.root, requests);
        try {
          final run = await probeBrowser(
            engine,
            'http://127.0.0.1:${server.port}/${prefix}index.html',
          );
          observed[prefix] = run.data;
          observedRequests[prefix] = requests;
        } finally {
          await server.close(force: true);
        }
      }
      for (final prefix in <String>['', 'sub/app/']) {
        expect(
          observed[prefix]!['values'],
          isEmpty,
          reason:
              'a removed generation must not start at "/$prefix"; '
              'got ${observed[prefix]}; requests: ${observedRequests[prefix]}',
        );
        expect(
          observed[prefix]!['errors'],
          <String>['DwiStartupException'],
          reason:
              'got ${observed[prefix]}; '
              'requests: ${observedRequests[prefix]}',
        );
        // The failure is the missing generation, not a mixed load: the client
        // never requests another generation's files.
        expect(
          observedRequests[prefix]!.where((path) => path.contains('/dwi/gen-')),
          everyElement(contains('gen-$generationA')),
          reason: 'a mixed generation was requested at "/$prefix"',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  }
}
