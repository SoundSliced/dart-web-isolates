// Runner for the DWI browser stress and benchmark harness.
//
// Usage (from `benchmarks/browser_matrix`):
//
//   dart run run.dart --engine=chrome --runs=3
//
// It builds the worker and the page, serves `web/`, loads the page in the
// requested engine `runs` times, and writes environment-stamped JSON evidence.
//
// Only Chrome is automated here, because it is the only engine whose driver is
// usable without interactive setup on the measurement machine. Safari needs
// "Allow remote automation" enabled in Safari Settings, and Firefox/Edge were
// not installed. Those engines must be recorded as unverified, never inferred
// from Chrome.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final engine = _stringArg(args, '--engine=', 'chrome');
  final runs = _intArg(args, '--runs=', 3);
  final out = _stringArg(args, '--out=', '');

  if (engine != 'chrome') {
    stderr.writeln(
      'Engine "$engine" is not automated by this harness. Supported: chrome.',
    );
    exitCode = 2;
    return;
  }

  final root = Directory.current;
  final chrome = _chromeExecutable();
  if (chrome == null) {
    stderr.writeln('Google Chrome was not found; nothing was measured.');
    exitCode = 2;
    return;
  }

  await _build(root);
  final server = await _serve(p.join(root.path, 'web'));
  final results = <Map<String, dynamic>>[];
  try {
    for (var index = 0; index < runs; index++) {
      results.add(await _runOnce(chrome, server.port));
      stdout.writeln('run ${index + 1}/$runs complete');
    }
  } finally {
    await server.close(force: true);
  }

  final environment = await _environment(chrome);
  final summary = _summarise(results);
  final report = <String, Object?>{
    'methodology':
        'benchmarks/browser_matrix: one page load per run, medians inside a '
            'run, three runs aggregated here. Payload sizes are exact byte '
            'counts; the transfer path detaches the sender every time.',
    'engine': engine,
    'browserVersion': environment['browserVersion'],
    'environment': environment,
    'runs': results,
    'summary': summary,
  };

  final file = File(
    out.isEmpty
        ? p.join(
            '..',
            '..',
            'audit',
            'evidence',
            'browser-matrix-$engine-${_dateStamp()}.json',
          )
        : out,
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln('wrote ${p.normalize(file.path)}');
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
}

Future<void> _build(Directory root) async {
  final dart = Platform.resolvedExecutable;
  stdout.writeln('generating and compiling the worker');
  final build = await Process.run(
    dart,
    <String>['run', 'dwi_builder:dwi', 'build', '--force'],
    workingDirectory: root.path,
    environment: <String, String>{
      'PUB_CACHE': Platform.environment['PUB_CACHE'] ?? '',
    },
  );
  if (build.exitCode != 0) {
    throw StateError('dwi build failed:\n${build.stdout}\n${build.stderr}');
  }
  stdout.writeln('compiling the page');
  final compile = await Process.run(
    dart,
    <String>['compile', 'js', '-O2', '-o', 'web/main.dart.js', 'web/main.dart'],
    workingDirectory: root.path,
    environment: <String, String>{
      'PUB_CACHE': Platform.environment['PUB_CACHE'] ?? '',
    },
  );
  if (compile.exitCode != 0) {
    throw StateError(
      'dart compile js failed:\n${compile.stdout}\n${compile.stderr}',
    );
  }
}

Future<HttpServer> _serve(String root) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.forEach((request) async {
      final relative = request.uri.path.replaceFirst(RegExp('^/'), '');
      final path = p.normalize(
        p.join(root, relative.isEmpty ? 'index.html' : relative),
      );
      if (!p.isWithin(root, path)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final file = File(path);
      if (!await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = _contentType(file.path);
      request.response.add(await file.readAsBytes());
      await request.response.close();
    }),
  );
  return server;
}

Future<Map<String, dynamic>> _runOnce(String chrome, int port) async {
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
    'http://127.0.0.1:$port/index.html',
  ]);
  final errors = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(errors.write);
  try {
    final target = await _waitForPageTarget(debugPort);
    final socket = await WebSocket.connect(target);
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
      socket.add(
        jsonEncode(<String, Object?>{
          'id': id,
          'method': 'Runtime.evaluate',
          'params': <String, Object?>{
            'expression': 'document.title',
            'returnByValue': true,
          },
        }),
      );
      return completer.future;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 180));
    while (DateTime.now().isBefore(deadline)) {
      final current = await title();
      if (current.isNotEmpty && current != 'pending') {
        await socket.close();
        return jsonDecode(utf8.decode(base64Decode(current)))
            as Map<String, dynamic>;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await socket.close();
    throw StateError('Chrome produced no result within 180 seconds.\n$errors');
  } finally {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!profile.existsSync()) break;
      try {
        profile.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

Future<String> _waitForPageTarget(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  final client = HttpClient();
  while (DateTime.now().isBefore(deadline)) {
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/json/list'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final targets = jsonDecode(body) as List<dynamic>;
      for (final target in targets) {
        final map = target as Map<String, dynamic>;
        final ws = map['webSocketDebuggerUrl'];
        if (ws is String && map['type'] == 'page') return ws;
      }
    } catch (_) {
      // Chrome is still starting.
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  client.close(force: true);
  throw StateError('Chrome did not expose a page target.');
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<Map<String, Object?>> _environment(String chrome) async {
  final version = await Process.run(chrome, <String>['--version']);
  return <String, Object?>{
    'browserVersion': (version.stdout as String).trim(),
    'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'dartVersion': Platform.version,
    'machine': await _machine(),
    'cpuCount': Platform.numberOfProcessors,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'timezone': DateTime.now().timeZoneName,
  };
}

Future<String> _machine() async {
  if (!Platform.isMacOS) return Platform.localHostname;
  try {
    final cpu = await Process.run('sysctl', <String>[
      '-n',
      'machdep.cpu.brand_string',
    ]);
    final memory = await Process.run('sysctl', <String>['-n', 'hw.memsize']);
    final bytes = int.tryParse((memory.stdout as String).trim());
    final gigabytes = bytes == null
        ? '?'
        : (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
    return '${(cpu.stdout as String).trim()}, $gigabytes GiB RAM';
  } on ProcessException {
    return Platform.localHostname;
  }
}

Map<String, Object?> _summarise(List<Map<String, dynamic>> runs) {
  const metrics = <String>[
    'coldStartMs',
    'warmDispatch.medianMs',
    'transfer_64KiB.copyMedianMs',
    'transfer_64KiB.transferMedianMs',
    'transfer_1MiB.copyMedianMs',
    'transfer_1MiB.transferMedianMs',
    'transfer_8MiB.copyMedianMs',
    'transfer_8MiB.transferMedianMs',
    'cancelQueued.medianMs',
    'cancelRunning.medianMs',
    'sustained.totalMs',
    'crashNextMs',
    'uiTicksDuringWorkerCpu',
    'uiTicksDuringLocalCpu',
  ];
  final summary = <String, Object?>{'runs': runs.length};
  for (final metric in metrics) {
    final values = <double>[];
    for (final run in runs) {
      final value = _dig(run, metric);
      if (value is num) values.add(value.toDouble());
    }
    if (values.isEmpty) continue;
    final sorted = List<double>.of(values)..sort();
    summary[metric] = <String, Object?>{
      'values': values,
      'median': sorted[sorted.length ~/ 2],
      'min': sorted.first,
      'max': sorted.last,
    };
  }
  final failures = runs.where((run) => run['status'] != 'ok').length;
  summary['failedRuns'] = failures;
  return summary;
}

Object? _dig(Map<String, dynamic> map, String path) {
  Object? current = map;
  for (final segment in path.split('.')) {
    if (current is! Map) return null;
    current = current[segment];
  }
  return current;
}

String _stringArg(List<String> args, String prefix, String fallback) {
  for (final arg in args) {
    if (arg.startsWith(prefix)) return arg.substring(prefix.length);
  }
  return fallback;
}

int _intArg(List<String> args, String prefix, int fallback) =>
    int.tryParse(_stringArg(args, prefix, '$fallback')) ?? fallback;

String _dateStamp() {
  final now = DateTime.now().toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}

String? _chromeExecutable() {
  const candidates = <String>[
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

ContentType _contentType(String path) {
  if (path.endsWith('.js')) return ContentType('text', 'javascript');
  if (path.endsWith('.html')) return ContentType.html;
  if (path.endsWith('.json')) return ContentType.json;
  return ContentType.binary;
}
