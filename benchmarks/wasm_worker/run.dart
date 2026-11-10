// Reproducible JS-worker vs Wasm-worker benchmark harness.
//
// Usage (from `benchmarks/wasm_worker` after `dart pub get`):
//
//   dart run run.dart
//
// It creates a throwaway app with the same task code, builds the worker with
// `target=js` and `target=wasm`, compiles one dart2js host, serves both and
// loads each in headless Chrome. Every measurement is a distribution; the
// report records the machine, browser and Dart versions. Results go to
// `audit/evidence/wasm-worker-benchmark-<date>.json`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:path/path.dart' as p;

const String tasksSource = r'''
import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_core.dart';
import 'dart:typed_data';

@DwiTask()
int noop(int value) => value;

@DwiTask()
int cpu(int limit) {
  final composite = List<bool>.filled(limit + 1, true);
  var count = 0;
  for (var candidate = 2; candidate <= limit; candidate++) {
    if (!composite[candidate]) continue;
    count++;
    for (var multiple = candidate * candidate;
        multiple <= limit;
        multiple += candidate) {
      composite[multiple] = false;
    }
  }
  return count;
}

@DwiTask()
Uint8List echo(Uint8List input) => input;

@DwiTask()
DwiTransferableBytes echoBytes(DwiTransferableBytes input) => input;
''';

const String pageSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dwi/dwi.dart';
import 'package:web/web.dart' as web;

@JS('performance.memory.usedJSHeapSize')
external num? get _heapUsed;

final _r = <String, Object?>{};

int _sieve(int limit) {
  final composite = List<bool>.filled(limit + 1, true);
  var count = 0;
  for (var candidate = 2; candidate <= limit; candidate++) {
    if (!composite[candidate]) continue;
    count++;
    for (var multiple = candidate * candidate;
        multiple <= limit;
        multiple += candidate) {
      composite[multiple] = false;
    }
  }
  return count;
}

void _add(String key, double value) {
  ((_r[key] ??= <double>[]) as List<double>).add(value);
}

Future<double> _time(Future<void> Function() body) async {
  final watch = Stopwatch()..start();
  await body();
  watch.stop();
  return watch.elapsedMicroseconds / 1000.0;
}

Future<void> run() async {
  final query = Uri.splitQueryString(
    web.window.location.search.replaceFirst(RegExp(r'^\?'), ''),
  );
  final target = query['target'] == 'js' ? 'js' : 'wasm';
  _r['target'] = target;
  final backend = target == 'js' ? DwiWorkerBackend.js : DwiWorkerBackend.wasm;
  final script = target == 'js'
      ? DwiConfig.defaultWorkerScript
      : DwiConfig.defaultWasmWorkerScript;

  await Dwi.configure(DwiConfig(
    workerBackend: backend,
    workerScript: script,
    maxWorkers: 1,
    startupTimeout: const Duration(seconds: 20),
    taskTimeout: const Duration(seconds: 30),
  ));

  // Cold start: spawn (including ready) then close, ten times.
  for (var index = 0; index < 10; index++) {
    late DwiWorker worker;
    _add('coldStartMs', await _time(() async {
      worker = await DwiWorker.spawn();
    }));
    await worker.close();
  }

  final worker = await DwiWorker.spawn();
  for (var index = 0; index < 5; index++) {
    await worker.run<int>('noop', index);
  }
  // Warm dispatch: 50 round trips on one handle.
  for (var index = 0; index < 50; index++) {
    _add('warmDispatchMs', await _time(() => worker.run<int>('noop', index)));
  }

  // CPU-heavy work, with a 16 ms main-thread timer as the UI control.
  for (var index = 0; index < 5; index++) {
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => ticks++,
    );
    final elapsed = await _time(() => worker.run<int>('cpu', 2000000));
    timer.cancel();
    _add('cpuMs', elapsed);
    _add('cpuUiTicks', ticks.toDouble());
  }

  // UI responsiveness: a longer CPU task in the worker, with the same work on
  // the main thread as the control.
  for (var index = 0; index < 3; index++) {
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => ticks++,
    );
    final elapsed = await _time(() => worker.run<int>('cpu', 10000000));
    timer.cancel();
    _add('uiWorkerCpuMs', elapsed);
    _add('uiWorkerTicks', ticks.toDouble());
  }
  for (var index = 0; index < 3; index++) {
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => ticks++,
    );
    final watch = Stopwatch()..start();
    _sieve(10000000);
    watch.stop();
    timer.cancel();
    _add('uiMainCpuMs', watch.elapsedMicroseconds / 1000.0);
    _add('uiMainTicks', ticks.toDouble());
  }

  final small = Uint8List(1024)..fillRange(0, 1024, 7);
  for (var index = 0; index < 10; index++) {
    _add('payloadSmallMs', await _time(() async {
      await worker.run<Uint8List>('echo', small);
    }));
  }

  final large = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 11);
  for (var index = 0; index < 5; index++) {
    _add('payloadLargeMs', await _time(() async {
      await worker.run<Uint8List>('echo', large);
    }));
  }

  for (var index = 0; index < 5; index++) {
    final bytes = DwiTransferableBytes(
      Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 13),
    );
    _add('transferLargeMs', await _time(() async {
      final echoed = await worker.run<DwiTransferableBytes>('echoBytes', bytes);
      _r['transferLength'] = echoed.lengthInBytes;
    }));
    _r['transferDetached'] = bytes.isDetached;
  }

  try {
    final heap = _heapUsed;
    if (heap != null) _r['heapUsedBytes'] = heap.toInt();
  } catch (_) {
    _r['heapUsedBytes'] = null;
  }

  _r['workerBackend'] = (await Dwi.capabilities()).workerBackend;
  await worker.close();
  await Dwi.close();
  _r['ok'] = true;
}

void main() {
  run()
      .catchError((Object error, StackTrace stack) {
        _r['ok'] = false;
        _r['error'] = '$error';
        _r['stack'] = '$stack';
      })
      .whenComplete(() {
        web.document.title =
            base64Encode(utf8.encode(jsonEncode(_r)));
      });
}
''';

const String indexSource = '''
<!doctype html>
<html>
<head><meta charset="utf-8"><title>pending</title></head>
<body><script src="main.dart.js"></script></body>
</html>
''';

String _pubspecSource() {
  final packages = p.normalize(
    p.join(Directory.current.path, '..', '..', 'packages'),
  );
  return '''
name: wasm_bench_fixture
environment:
  sdk: ^3.13.0
dependencies:
  dwi: {path: $packages/dwi}
  dwi_annotations: {path: $packages/dwi_annotations}
  dwi_core: {path: $packages/dwi_core}
  dwi_protocol: {path: $packages/dwi_protocol}
  dwi_web: {path: $packages/dwi_web}
  dwi_native: {path: $packages/dwi_native}
  web: ^1.1.2
''';
}

Future<void> main(List<String> args) async {
  final chrome = _chromeExecutable();
  if (chrome == null) {
    stderr.writeln('Google Chrome was not found; nothing was measured.');
    exitCode = 2;
    return;
  }

  final root = Directory.systemTemp.createTempSync('dwi_wasm_bench_');
  try {
    final fixture = Directory(p.join(root.path, 'fixture'));
    _createFixture(fixture);
    final builds = <String, Object?>{};
    for (final target in const <String>['js', 'wasm']) {
      builds[target] = await _buildTarget(fixture, target);
    }
    final host = await _compileHost(fixture);
    final server = await _serve(p.join(fixture.path, 'web'));
    try {
      final runs = <String, Object?>{};
      for (final target in const <String>['js', 'wasm']) {
        stdout.writeln('measuring $target worker...');
        runs[target] = await _runPage(chrome, server.port, target);
      }
      final report = <String, Object?>{
        'methodology':
            'one page load per target; distributions inside the page. '
            'Cold start = DwiWorker.spawn() for 10 fresh workers. Warm = 50 '
            'sequential noop calls on one handle. CPU = 2,000,000 sieve. '
            'Payloads = 1 KiB x10 and 1 MiB x5 copied typed arrays. Transfer '
            '= 1 MiB x5 DwiTransferableBytes. UI ticks = 16 ms timer during '
            'CPU work. Build = in-process DwiBuilder; bytes from the manifest. UI = 3x '
            '10,000,000 sieve in the worker and the same work on the main thread, '
            'with a 16 ms timer.',
        'environment': await _environment(chrome),
        'builds': builds,
        'host': host,
        'runs': runs,
        'summary': <String, Object?>{
          for (final target in const <String>['js', 'wasm'])
            target: _summarise(runs[target] as Map<String, dynamic>),
        },
      };
      final out = File(
        p.join(
          '..',
          '..',
          'audit',
          'evidence',
          'wasm-worker-benchmark-${_dateStamp()}.json',
        ),
      );
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
      stdout.writeln('wrote ${p.normalize(out.path)}');
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(report['summary']),
      );
    } finally {
      await server.close(force: true);
    }
  } finally {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // A browser may still hold a profile file; inert.
    }
  }
}

void _createFixture(Directory fixture) {
  fixture.createSync(recursive: true);
  _write(fixture, 'pubspec.yaml', _pubspecSource());
  _write(fixture, 'lib/tasks.dart', tasksSource);
  _write(fixture, 'web/main.dart', pageSource);
  _write(fixture, 'web/index.html', indexSource);
  _writePackageConfig(fixture);
}

void _write(Directory root, String relative, String content) {
  final file = File(p.join(root.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

/// Copies this package's resolution into the fixture, resolving path roots.
void _writePackageConfig(Directory fixture) {
  final own = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  if (!own.existsSync()) {
    throw StateError('Run `dart pub get` in benchmarks/wasm_worker first.');
  }
  final decoded = jsonDecode(own.readAsStringSync()) as Map<String, dynamic>;
  final base = own.parent.uri;
  final packages = <Map<String, dynamic>>[];
  for (final raw in decoded['packages'] as List<dynamic>) {
    final entry = Map<String, dynamic>.from(raw as Map);
    final rootUri = Uri.parse(entry['rootUri'] as String);
    entry['rootUri'] = (rootUri.hasScheme ? rootUri : base.resolveUri(rootUri))
        .toString();
    packages.add(entry);
  }
  packages.removeWhere((entry) => entry['name'] == 'wasm_bench_fixture');
  packages.add(<String, dynamic>{
    'name': 'wasm_bench_fixture',
    'rootUri': fixture.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.13',
  });
  _write(
    fixture,
    '.dart_tool/package_config.json',
    const JsonEncoder.withIndent(' ').convert(<String, Object?>{
      'configVersion': 2,
      'packages': packages,
    }),
  );
}

Future<Map<String, Object?>> _buildTarget(
  Directory fixture,
  String target,
) async {
  final watch = Stopwatch()..start();
  final result = await DwiBuilder(
    DwiBuildConfig(
      projectRoot: fixture.path,
      target: target,
      compile: true,
      force: true,
    ),
  ).build();
  watch.stop();
  final manifest =
      jsonDecode(
            File(
              p.join(fixture.path, '.dwi/worker_manifest.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  var bytes = 0;
  for (final entry in manifest['artifactFiles'] as List<dynamic>) {
    final path = (entry as Map)['path'] as String;
    bytes += File(p.join(fixture.path, 'web', path)).lengthSync();
  }
  return <String, Object?>{
    'target': target,
    'buildMs': watch.elapsedMicroseconds / 1000.0,
    'workerBytes': bytes,
    'generation': manifest['generation'],
    'files': [
      for (final entry in manifest['artifactFiles'] as List<dynamic>)
        (entry as Map)['path'],
    ],
    'tasks': result.discovery.tasks.length,
  };
}

Future<Map<String, Object?>> _compileHost(Directory fixture) async {
  final watch = Stopwatch()..start();
  final result = await Process.run(
    Platform.resolvedExecutable,
    <String>[
      'compile',
      'js',
      '-O2',
      '-o',
      'web/main.dart.js',
      'web/main.dart',
    ],
    workingDirectory: fixture.path,
  );
  watch.stop();
  if (result.exitCode != 0) {
    throw StateError('host compilation failed:\n${result.stdout}\n${result.stderr}');
  }
  return <String, Object?>{
    'compileMs': watch.elapsedMicroseconds / 1000.0,
    'bytes': File(p.join(fixture.path, 'web/main.dart.js')).lengthSync(),
  };
}

Future<HttpServer> _serve(String root) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.forEach((request) async {
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
    }),
  );
  return server;
}

Future<Map<String, dynamic>> _runPage(
  String chrome,
  int port,
  String target,
) async {
  final profile = Directory.systemTemp.createTempSync('dwi_bench_chrome_');
  final debugPort = await _freePort();
  final process = await Process.start(chrome, <String>[
    '--headless',
    '--no-sandbox',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--user-data-dir=${profile.path}',
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=$debugPort',
    'http://127.0.0.1:$port/index.html?target=$target',
  ]);
  final errors = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(errors.write);
  process.stdout.drain<void>();
  WebSocket? socket;
  try {
    final endpoint = await _waitForPageTarget(debugPort, errors);
    socket = await WebSocket.connect(endpoint);
    final pending = <int, Completer<String>>{};
    var nextId = 0;
    socket.listen((message) {
      final decoded = jsonDecode(message as String) as Map<String, dynamic>;
      final id = decoded['id'];
      if (id is! int) return;
      final completer = pending.remove(id);
      if (completer == null) return;
      final result = decoded['result'] as Map<String, dynamic>?;
      final value = result?['result'] as Map<String, dynamic>?;
      completer.complete(value?['value']?.toString() ?? '');
    });

    Future<String> title() {
      final id = ++nextId;
      final completer = Completer<String>();
      pending[id] = completer;
      socket!.add(
        jsonEncode(<String, Object?>{
          'id': id,
          'method': 'Runtime.evaluate',
          'params': <String, Object?>{
            'expression': 'document.title',
            'returnByValue': true,
          },
        }),
      );
      return completer.future.timeout(const Duration(seconds: 20));
    }

    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      final current = await title();
      if (current.isNotEmpty && current != 'pending') {
        return jsonDecode(utf8.decode(base64Decode(current)))
            as Map<String, dynamic>;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('benchmark page produced no result.\n$errors');
  } finally {
    try {
      await socket?.close().timeout(const Duration(seconds: 5));
    } on Object {
      // Teardown is best effort.
    }
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!profile.existsSync()) break;
      try {
        profile.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

Future<String> _waitForPageTarget(int port, StringBuffer errors) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  final client = HttpClient();
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/json/list'),
        );
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        for (final raw in jsonDecode(body) as List<dynamic>) {
          final map = raw as Map<String, dynamic>;
          final ws = map['webSocketDebuggerUrl'];
          if (ws is String && map['type'] == 'page') return ws;
        }
      } on Object {
        // Chrome is still starting.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  } finally {
    client.close(force: true);
  }
  throw StateError('Chrome did not expose a page target.\n$errors');
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

String? _chromeExecutable() {
  for (final candidate in <String>[
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

Future<Map<String, Object?>> _environment(String chrome) async {
  final version = await Process.run(chrome, <String>['--version']);
  return <String, Object?>{
    'browserVersion': (version.stdout as String).trim(),
    'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'dartVersion': Platform.version,
    'cpuCount': Platform.numberOfProcessors,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
  };
}

Map<String, Object?> _summarise(Map<String, dynamic> run) {
  final metrics = <String, Object?>{};
  for (final entry in run.entries) {
    final value = entry.value;
    if (value is! List || value.isEmpty) continue;
    final numbers = value.whereType<num>().map((n) => n.toDouble()).toList()
      ..sort();
    if (numbers.isEmpty) continue;
    metrics[entry.key] = <String, Object?>{
      'count': numbers.length,
      'min': numbers.first,
      'median': _percentile(numbers, 0.5),
      'p95': _percentile(numbers, 0.95),
      'max': numbers.last,
    };
  }
  return metrics;
}

double _percentile(List<double> sorted, double fraction) {
  final index = ((sorted.length - 1) * fraction).round();
  return sorted[index];
}

String _dateStamp() {
  final now = DateTime.now().toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}
