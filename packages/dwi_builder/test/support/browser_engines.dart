import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Browser engines the DWI browser harnesses can drive on this machine.
///
/// Every engine is measured independently (AGENTS.md rule 8): a result from one
/// engine is never copied into another engine's cell.
enum BrowserEngine { chrome, safari, firefox, edge }

/// Whether [engine] can be automated here, and why not when it cannot.
class BrowserAvailability {
  const BrowserAvailability.available(this.engine, String this.executable)
      : reason = null;

  const BrowserAvailability.blocked(this.engine, String this.reason)
      : executable = null;

  final BrowserEngine engine;
  final String? executable;

  /// Exact reason the engine cannot run; `null` when it is available.
  final String? reason;

  bool get available => reason == null;
}

/// One successful page load in one engine.
class BrowserRunResult {
  const BrowserRunResult({
    required this.engine,
    required this.browserVersion,
    required this.data,
  });

  final BrowserEngine engine;
  final String browserVersion;

  /// Decoded payload the page wrote into `document.title`.
  final Map<String, dynamic> data;
}

/// The engine exists but cannot be driven in this environment.
///
/// Harnesses report this as a *blocked* engine with the verbatim reason instead
/// of failing or silently omitting it.
class BrowserBlockedException implements Exception {
  BrowserBlockedException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Google Chrome (or Chromium) on this machine, if any.
String? chromeExecutable() => _firstExisting(<String>[
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/usr/bin/google-chrome',
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
    ]);

/// Microsoft Edge on this machine, if any.
///
/// `DWI_EDGE_BINARY` allows a build unpacked outside `/Applications` (for
/// example from the Edge `.pkg` payload in a sandbox).
String? edgeExecutable() {
  final override = Platform.environment['DWI_EDGE_BINARY'];
  return _firstExisting(<String>[
    if (override != null && override.isNotEmpty) override,
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '${Platform.environment['HOME']}/Applications/'
        'Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  ]);
}

/// Mozilla Firefox on this machine, if any.
String? firefoxExecutable() {
  final override = Platform.environment['DWI_FIREFOX_BINARY'];
  return _firstExisting(<String>[
    if (override != null && override.isNotEmpty) override,
    '/Applications/Firefox.app/Contents/MacOS/firefox',
    '${Platform.environment['HOME']}/Applications/'
        'Firefox.app/Contents/MacOS/firefox',
  ]);
}

/// `safaridriver`, which ships with macOS, if present.
String? safariDriverExecutable() => _firstExisting(<String>[
      '/System/Cryptexes/App/usr/bin/safaridriver',
      '/usr/bin/safaridriver',
    ]);

/// Reports whether [engine] can be started on this machine.
BrowserAvailability browserAvailability(BrowserEngine engine) {
  switch (engine) {
    case BrowserEngine.chrome:
      final executable = chromeExecutable();
      return executable == null
          ? const BrowserAvailability.blocked(
              BrowserEngine.chrome,
              'Google Chrome is not installed.',
            )
          : BrowserAvailability.available(BrowserEngine.chrome, executable);
    case BrowserEngine.edge:
      final executable = edgeExecutable();
      return executable == null
          ? const BrowserAvailability.blocked(
              BrowserEngine.edge,
              'Microsoft Edge is not installed (set DWI_EDGE_BINARY to a '
                  'usable Microsoft Edge binary).',
            )
          : BrowserAvailability.available(BrowserEngine.edge, executable);
    case BrowserEngine.firefox:
      final executable = firefoxExecutable();
      return executable == null
          ? const BrowserAvailability.blocked(
              BrowserEngine.firefox,
              'Mozilla Firefox is not installed (set DWI_FIREFOX_BINARY to a '
                  'usable firefox binary).',
            )
          : BrowserAvailability.available(BrowserEngine.firefox, executable);
    case BrowserEngine.safari:
      final executable = safariDriverExecutable();
      return executable == null
          ? const BrowserAvailability.blocked(
              BrowserEngine.safari,
              'safaridriver is not installed.',
            )
          : BrowserAvailability.available(BrowserEngine.safari, executable);
  }
}

/// Loads [url] in [engine] and returns the decoded `document.title` payload.
///
/// Throws [BrowserBlockedException] when the engine exists but cannot be
/// automated here; any other exception is a genuine harness or product failure.
Future<BrowserRunResult> probeBrowser(BrowserEngine engine, String url) async {
  final availability = browserAvailability(engine);
  if (!availability.available) {
    throw BrowserBlockedException(availability.reason!);
  }
  final executable = availability.executable!;
  switch (engine) {
    case BrowserEngine.chrome:
    case BrowserEngine.edge:
      return _probeChromium(engine, executable, url);
    case BrowserEngine.safari:
      return _probeSafari(executable, url);
    case BrowserEngine.firefox:
      return _probeFirefox(executable, url);
  }
}

String? _firstExisting(List<String> candidates) {
  for (final candidate in candidates) {
    if (candidate.isNotEmpty && File(candidate).existsSync()) return candidate;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Chromium engines (Chrome, Edge) over CDP.
// ---------------------------------------------------------------------------

Future<BrowserRunResult> _probeChromium(
  BrowserEngine engine,
  String executable,
  String url,
) async {
  final name = engine == BrowserEngine.chrome ? 'Chrome' : 'Edge';
  final version = await _executableVersion(executable, name);
  final profile = Directory.systemTemp.createTempSync('dwi_${engine.name}_');
  final port = await _freePort();
  final process = await Process.start(executable, <String>[
    if (engine == BrowserEngine.chrome) '--headless' else '--headless=new',
    '--no-sandbox',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--no-first-run',
    '--no-default-browser-check',
    '--user-data-dir=${profile.path}',
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=$port',
    url,
  ]);
  final errors = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(errors.write);

  WebSocket? socket;
  try {
    final target = await _waitForCdpPageTarget(port, name, errors);
    socket = await WebSocket.connect(target);
    final pending = <int, Completer<Map<String, dynamic>>>{};
    var nextId = 0;
    socket.listen((message) {
      final decoded = jsonDecode(message as String) as Map<String, dynamic>;
      final id = decoded['id'];
      if (id is! int) return;
      final completer = pending.remove(id);
      completer?.complete(decoded);
    });

    Future<String> title() async {
      final id = ++nextId;
      final completer = Completer<Map<String, dynamic>>();
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
      final response = await completer.future.timeout(
        const Duration(seconds: 20),
      );
      final error = response['error'];
      if (error != null) {
        throw StateError('$name rejected Runtime.evaluate: $error');
      }
      final result = response['result'] as Map<String, dynamic>?;
      final value = result?['result'] as Map<String, dynamic>?;
      return value?['value']?.toString() ?? '';
    }

    final data = await _pollTitle(
      title,
      engine: engine,
      browserVersion: version,
      log: errors,
    );
    return BrowserRunResult(
      engine: engine,
      browserVersion: version,
      data: data,
    );
  } finally {
    await socket?.close();
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    _deleteProfile(profile);
  }
}

Future<String> _waitForCdpPageTarget(
  int port,
  String name,
  StringBuffer errors,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  final client = HttpClient();
  try {
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
        // The browser is still starting.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  } finally {
    client.close(force: true);
  }
  throw StateError('$name did not expose a page target within 30 seconds.\n$errors');
}

// ---------------------------------------------------------------------------
// Safari over `safaridriver` (WebDriver).
// ---------------------------------------------------------------------------

Future<BrowserRunResult> _probeSafari(String driver, String url) async {
  final port = await _freePort();
  final process = await Process.start(driver, <String>['--port', '$port']);
  final log = StringBuffer();
  process.stdout.transform(utf8.decoder).listen(log.write);
  process.stderr.transform(utf8.decoder).listen(log.write);
  String? sessionId;
  String version = 'Safari';
  try {
    if (!await _waitForSafariDriver(port)) {
      throw BrowserBlockedException(
        'safaridriver did not become ready within 30 seconds: $log',
      );
    }

    final created = await _webDriver(
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
      throw BrowserBlockedException(
        'Safari refused a WebDriver session: $message '
        '(enable Safari → Develop → Allow Remote Automation and restart Safari)',
      );
    }
    sessionId = id;
    final capabilities = value is Map ? value['capabilities'] : null;
    if (capabilities is Map) {
      version =
          '${capabilities['browserVersion'] ?? capabilities['version'] ?? 'Safari'}';
    }

    await _webDriver(
      'POST',
      Uri.parse('http://127.0.0.1:$port/session/$sessionId/url'),
      <String, Object?>{'url': url},
    );

    Future<String> title() async {
      final result = await _webDriver(
        'POST',
        Uri.parse('http://127.0.0.1:$port/session/$sessionId/execute/sync'),
        <String, Object?>{
          'script': 'return document.title;',
          'args': <Object?>[],
        },
      );
      final current = result['value'];
      if (current is Map && current['error'] != null) {
        throw StateError('Safari rejected execute/sync: $current');
      }
      return current?.toString() ?? '';
    }

    final data = await _pollTitle(
      title,
      engine: BrowserEngine.safari,
      browserVersion: version,
      log: log,
    );
    return BrowserRunResult(
      engine: BrowserEngine.safari,
      browserVersion: version,
      data: data,
    );
  } finally {
    if (sessionId != null) {
      try {
        await _webDriver(
          'DELETE',
          Uri.parse('http://127.0.0.1:$port/session/$sessionId'),
          null,
        );
      } catch (_) {
        // A session that already died needs no cleanup request.
      }
    }
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  }
}

Future<bool> _waitForSafariDriver(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final status = await _webDriver(
        'GET',
        Uri.parse('http://127.0.0.1:$port/status'),
        null,
      );
      final value = status['value'];
      if (value is Map && value['ready'] == true) return true;
    } catch (_) {
      // safaridriver is still starting.
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

Future<Map<String, dynamic>> _webDriver(
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

// ---------------------------------------------------------------------------
// Firefox over WebDriver BiDi.
// ---------------------------------------------------------------------------

Future<BrowserRunResult> _probeFirefox(String executable, String url) async {
  final version = await _executableVersion(executable, 'Firefox');
  final profile = Directory.systemTemp.createTempSync('dwi_firefox_');
  final port = await _freePort();
  final process = await Process.start(executable, <String>[
    '--headless',
    '--no-remote',
    '--new-instance',
    '--profile',
    profile.path,
    '--remote-debugging-port=$port',
    'about:blank',
  ], environment: <String, String>{
    // Firefox's own content-process sandbox cannot initialise inside a
    // restricted (seatbelt) host session; it would crash every content process
    // with `sandbox_init() failed with error "Operation not permitted"`.
    'MOZ_DISABLE_CONTENT_SANDBOX': '1',
    'MOZ_DISABLE_GMP_SANDBOX': '1',
    'MOZ_DISABLE_RDD_SANDBOX': '1',
  });
  final log = StringBuffer();
  process.stdout.transform(utf8.decoder).listen(log.write);
  process.stderr.transform(utf8.decoder).listen(log.write);
  _BiDiClient? client;
  try {
    client = await _connectBiDi(port, log);
    await client.send('session.new', <String, Object?>{
      'capabilities': <String, Object?>{},
    });
    final created = await client.send('browsingContext.create', <String, Object?>{
      'type': 'tab',
    });
    final context = created['context'];
    if (context is! String) {
      throw StateError('Firefox did not return a browsing context: $created');
    }
    final navigation = await client.send(
      'browsingContext.navigate',
      <String, Object?>{
        'context': context,
        'url': url,
        'wait': 'complete',
      },
    );
    if (navigation['navigation'] == null) {
      throw StateError('Firefox refused to navigate to $url: $navigation');
    }

    Future<String> title() async {
      final evaluated = await client!.send('script.evaluate', <String, Object?>{
        'expression': 'document.title',
        'target': <String, Object?>{'context': context},
        'awaitPromise': true,
        'resultOwnership': 'none',
      });
      final value = evaluated['result'];
      if (evaluated['type'] != 'success') {
        throw StateError('Firefox rejected script.evaluate: $evaluated');
      }
      final remoteValue = value is Map ? value['value'] : null;
      return remoteValue?.toString() ?? '';
    }

    final data = await _pollTitle(
      title,
      engine: BrowserEngine.firefox,
      browserVersion: version,
      log: log,
    );
    return BrowserRunResult(
      engine: BrowserEngine.firefox,
      browserVersion: version,
      data: data,
    );
  } finally {
    try {
      await client?.close();
    } catch (_) {
      // A dead session needs no `session.end`.
    }
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    _deleteProfile(profile);
  }
}

Future<_BiDiClient> _connectBiDi(int port, StringBuffer log) async {
  // Firefox serves the WebDriver BiDi endpoint directly at `/session`; unlike
  // Chromium it has no `/json/version` discovery document.
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    try {
      return await _BiDiClient.connect('ws://127.0.0.1:$port/session');
    } catch (_) {
      // Firefox is still starting its remote agent.
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw BrowserBlockedException(
    'Firefox did not expose its WebDriver BiDi endpoint on port $port within '
    '30 seconds. Log: $log',
  );
}

/// A minimal WebDriver BiDi client: numbered commands over one WebSocket.
class _BiDiClient {
  _BiDiClient._(this._socket) {
    _socket.listen(
      (message) {
        final decoded = jsonDecode(message as String) as Map<String, dynamic>;
        final id = decoded['id'];
        if (id is! int) return; // An event, not a command reply.
        final completer = _pending.remove(id);
        if (completer == null) return;
        final error = decoded['error'];
        if (error != null) {
          completer.completeError(StateError('BiDi command failed: $error'));
          return;
        }
        final result = decoded['result'];
        completer.complete(
          result is Map<String, dynamic> ? result : <String, dynamic>{},
        );
      },
      onError: (Object error) {
        for (final completer in _pending.values) {
          if (!completer.isCompleted) {
            completer.completeError(StateError('BiDi socket error: $error'));
          }
        }
        _pending.clear();
      },
    );
  }

  static Future<_BiDiClient> connect(String endpoint) async {
    final socket = await WebSocket.connect(endpoint);
    return _BiDiClient._(socket);
  }

  final WebSocket _socket;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;

  Future<Map<String, dynamic>> send(
    String method,
    Map<String, Object?> params,
  ) {
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(
      jsonEncode(<String, Object?>{
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.timeout(const Duration(seconds: 30));
  }

  Future<void> close() async {
    try {
      await send('session.end', <String, Object?>{});
    } catch (_) {
      // The session may already be gone; closing the socket is enough.
    }
    await _socket.close();
  }
}

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _pollTitle(
  Future<String> Function() title, {
  required BrowserEngine engine,
  required String browserVersion,
  required StringBuffer log,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(deadline)) {
    final current = await title();
    if (current.isNotEmpty && current != 'pending') {
      return jsonDecode(utf8.decode(base64Decode(current)))
          as Map<String, dynamic>;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError(
    '${engine.name} ($browserVersion) produced no result within 120 seconds.\n'
    '$log',
  );
}

Future<String> _executableVersion(String executable, String name) async {
  try {
    final version = await Process.run(executable, <String>['--version']);
    final text = '${version.stdout}${version.stderr}'.trim();
    return text.isEmpty ? name : text;
  } on ProcessException {
    return name;
  }
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void _deleteProfile(Directory profile) {
  // A browser may still be releasing lock files.
  for (var attempt = 0; attempt < 20; attempt++) {
    if (!profile.existsSync()) return;
    try {
      profile.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      sleep(const Duration(milliseconds: 100));
    }
  }
}
