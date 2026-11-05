// Runner for the DWI browser stress and benchmark harness.
//
// Usage (from `benchmarks/browser_matrix`):
//
//   dart run run.dart --engine=chrome --runs=3
//   dart run run.dart --engine=safari --runs=3
//
// It builds the worker and the page, serves `web/`, loads the page in the
// requested engine `runs` times, and writes environment-stamped JSON evidence.
//
// Chrome is driven over CDP with a private headless profile. Safari is driven
// through `safaridriver` (WebDriver); Safari only accepts a session when
// "Allow remote automation" is enabled in Safari Settings, which is an
// interactive step. When it is not enabled the run fails with that exact
// message and nothing is recorded for Safari.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final engine = _stringArg(args, '--engine=', 'chrome');
  final runs = _intArg(args, '--runs=', 3);
  final out = _stringArg(args, '--out=', '');

  if (engine != 'chrome' && engine != 'safari') {
    stderr.writeln(
      'Engine "$engine" is not automated by this harness. '
      'Supported: chrome, safari.',
    );
    exitCode = 2;
    return;
  }

  String? chrome;
  if (engine == 'chrome') {
    chrome = _chromeExecutable();
    if (chrome == null) {
      stderr.writeln('Google Chrome was not found; nothing was measured.');
      exitCode = 2;
      return;
    }
  }

  final root = Directory.current;
  await _build(root);
  final server = await _serve(p.join(root.path, 'web'));
  final results = <Map<String, dynamic>>[];
  String browserVersion;
  try {
    if (engine == 'chrome') {
      browserVersion = await _chromeVersion(chrome!);
      for (var index = 0; index < runs; index++) {
        results.add(await _runOnce(chrome, server.port));
        stdout.writeln('run ${index + 1}/$runs complete');
      }
    } else {
      final _SafariDriver safari;
      try {
        safari = await _SafariDriver.start();
      } on StateError catch (error) {
        stderr.writeln('${error.message}');
        stderr.writeln(
          'Safari stays unverified; nothing was recorded for it.',
        );
        exitCode = 2;
        return;
      }
      browserVersion = safari.browserVersion;
      try {
        for (var index = 0; index < runs; index++) {
          results.add(await safari.measure(server.port, run: index + 1));
          stdout.writeln('run ${index + 1}/$runs complete');
        }
      } finally {
        await safari.dispose();
      }
    }
  } finally {
    await server.close(force: true);
  }

  final environment = await _environment(browserVersion);
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
  // An empty PUB_CACHE makes pub treat the current directory as the cache root
  // and write into the harness folder. Only forward a real value.
  final environment = <String, String>{};
  final pubCache = Platform.environment['PUB_CACHE'];
  if (pubCache != null && pubCache.isNotEmpty) {
    environment['PUB_CACHE'] = pubCache;
  }
  stdout.writeln('generating and compiling the worker');
  final build = await Process.run(
    dart,
    <String>['run', 'dwi_builder:dwi', 'build', '--force'],
    workingDirectory: root.path,
    environment: environment,
  );
  if (build.exitCode != 0) {
    throw StateError('dwi build failed:\n${build.stdout}\n${build.stderr}');
  }
  stdout.writeln('compiling the page');
  final compile = await Process.run(
    dart,
    <String>['compile', 'js', '-O2', '-o', 'web/main.dart.js', 'web/main.dart'],
    workingDirectory: root.path,
    environment: environment,
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

Future<String> _chromeVersion(String chrome) async {
  final version = await Process.run(chrome, <String>['--version']);
  return (version.stdout as String).trim();
}

Future<Map<String, Object?>> _environment(String browserVersion) async {
  return <String, Object?>{
    'browserVersion': browserVersion,
    'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'dartVersion': Platform.version,
    'machine': await _machine(),
    'cpuCount': Platform.numberOfProcessors,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'timezone': DateTime.now().timeZoneName,
  };
}

/// A Safari session driven through the WebDriver protocol.
///
/// Safari is a visible browser and is driven by `safaridriver`, so the page is
/// loaded with a per-run query string and read back through `execute/sync`.
/// A session is refused until "Allow remote automation" is enabled in Safari
/// Settings; that refusal is surfaced verbatim rather than retried.
class _SafariDriver {
  _SafariDriver._(this._port, this.sessionId, this.browserVersion, this._process);

  final int _port;
  final String sessionId;
  final String browserVersion;
  final Process? _process;

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$_port$path');

  static Future<_SafariDriver> start() async {
    var port = 4466;
    Process? process;
    if (!await _statusReady(port)) {
      port = await _freePort();
      process = await Process.start('safaridriver', <String>[
        '--port',
        '$port',
      ]);
      process.stdout.drain<void>();
      final log = StringBuffer();
      process.stderr.transform(utf8.decoder).listen(log.write);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      var ready = false;
      while (DateTime.now().isBefore(deadline)) {
        if (await _statusReady(port)) {
          ready = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!ready) {
        process.kill();
        throw StateError(
          'safaridriver did not become ready within 30 seconds: $log',
        );
      }
    }

    final created = await _request(
      'POST',
      Uri.parse('http://127.0.0.1:$port/session'),
      <String, Object?>{
        'capabilities': <String, Object?>{
          'alwaysMatch': <String, Object?>{'browserName': 'safari'},
        },
      },
    );
    final value = created['value'];
    final id = value is Map ? value['sessionId'] : null;
    if (id is! String) {
      final message = value is Map ? value['message'] : created;
      process?.kill();
      throw StateError('Safari refused a WebDriver session: $message');
    }
    final capabilities = value is Map ? value['capabilities'] : null;
    final version = capabilities is Map
        ? '${capabilities['browserVersion'] ?? capabilities['version'] ?? 'Safari'}'
        : 'Safari';
    return _SafariDriver._(port, id, version, process);
  }

  Future<Map<String, dynamic>> measure(
    int serverPort, {
    required int run,
  }) async {
    await _request(
      'POST',
      _uri('/session/$sessionId/url'),
      <String, Object?>{
        'url': 'http://127.0.0.1:$serverPort/index.html?run=$run',
      },
    );
    final deadline = DateTime.now().add(const Duration(seconds: 240));
    while (DateTime.now().isBefore(deadline)) {
      final result = await _request(
        'POST',
        _uri('/session/$sessionId/execute/sync'),
        <String, Object?>{
          'script': 'return document.title;',
          'args': <Object?>[],
        },
      );
      final value = result['value'];
      if (value is String && value.isNotEmpty && value != 'pending') {
        return jsonDecode(utf8.decode(base64Decode(value)))
            as Map<String, dynamic>;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Safari produced no result within 240 seconds.');
  }

  Future<void> dispose() async {
    try {
      await _request('DELETE', _uri('/session/$sessionId'), null);
    } catch (_) {
      // A session that already died needs no cleanup request.
    }
    _process?.kill();
  }
}

Future<bool> _statusReady(int port) async {
  try {
    final status = await _request(
      'GET',
      Uri.parse('http://127.0.0.1:$port/status'),
      null,
    );
    final value = status['value'];
    return value is Map && value['ready'] == true;
  } catch (_) {
    return false;
  }
}

Future<Map<String, dynamic>> _request(
  String method,
  Uri uri,
  Object? body,
) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (text.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Unexpected WebDriver response from $uri: $text');
    }
    return decoded;
  } finally {
    client.close(force: true);
  }
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
