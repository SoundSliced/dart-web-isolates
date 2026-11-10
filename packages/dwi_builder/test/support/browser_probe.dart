import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'browser_engines.dart';

export 'browser_engines.dart'
    show
        BrowserAvailability,
        BrowserBlockedException,
        BrowserEngine,
        BrowserRunResult,
        browserAvailability,
        chromeExecutable,
        edgeExecutable,
        firefoxExecutable,
        probeBrowser;

/// Serves [root] on an ephemeral loopback port.
Future<HttpServer> serveDirectory(String root) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.forEach((request) async {
      // One browser disappearing mid-request must not end the loop: the handle
      // matrix reuses a single server across several engines, and an
      // unhandled write error would otherwise stop serving every later page.
      try {
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
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {
          // The client is gone; nothing left to close.
        }
      }
    }),
  );
  return server;
}

/// Opens [url] in headless Chrome and reads the base64 JSON payload that the
/// page writes into `document.title`.
Future<Map<String, dynamic>> probeChrome(String url) async {
  final result = await probeBrowser(BrowserEngine.chrome, url);
  return result.data;
}

ContentType _contentType(String path) {
  // Module workers are `.mjs`. Serving them as application/octet-stream makes
  // every browser refuse the module script, so a Wasm worker never starts.
  // Regression: test/browser_serve_test.dart.
  if (path.endsWith('.mjs')) return ContentType('text', 'javascript');
  if (path.endsWith('.js')) return ContentType('text', 'javascript');
  if (path.endsWith('.html')) return ContentType.html;
  if (path.endsWith('.json')) return ContentType.json;
  if (path.endsWith('.wasm')) return ContentType('application', 'wasm');
  return ContentType.binary;
}
