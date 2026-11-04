import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Google Chrome (or Chromium) on this machine, if any.
String? chromeExecutable() {
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

/// Serves [root] on an ephemeral loopback port.
Future<HttpServer> serveDirectory(String root) async {
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

/// Opens [url] in headless Chrome and reads the base64 JSON payload that the
/// page writes into `document.title`.
Future<Map<String, dynamic>> probeChrome(String url) async {
  final chrome = chromeExecutable()!;
  final profile = Directory.systemTemp.createTempSync('dwi_chrome_');
  final port = await _freePort();
  final process = await Process.start(chrome, <String>[
    '--headless',
    '--no-sandbox',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--user-data-dir=${profile.path}',
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=$port',
    url,
  ]);
  final errors = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(errors.write);

  try {
    final target = await _waitForPageTarget(port);
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

    Future<String> title() async {
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

    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      final current = await title();
      if (current.isNotEmpty && current != 'pending') {
        await socket.close();
        return jsonDecode(utf8.decode(base64Decode(current)))
            as Map<String, dynamic>;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await socket.close();
    throw StateError('Chrome produced no result within 90 seconds.\n$errors');
  } finally {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    // Chrome may still be releasing profile lock files.
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

ContentType _contentType(String path) {
  if (path.endsWith('.js')) return ContentType('text', 'javascript');
  if (path.endsWith('.html')) return ContentType.html;
  if (path.endsWith('.json')) return ContentType.json;
  if (path.endsWith('.wasm')) return ContentType('application', 'wasm');
  return ContentType.binary;
}
