import 'dart:io';

import 'package:test/test.dart';

import 'support/browser_probe.dart';

// The harness serves the app under test. Browsers refuse to load a module
// worker whose MIME type is not JavaScript, and a Wasm worker is loaded as a
// module worker. Serving `.mjs` as application/octet-stream therefore fails
// every engine with a generic worker startup error, which reads like a DWI
// runtime bug and is not one.
void main() {
  group('serveDirectory content types', () {
    late Directory root;
    late HttpServer server;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('dwi_serve_');
      for (final name in <String>['worker.boot.mjs', 'worker.mjs', 'worker.js']) {
        File('${root.path}/$name').writeAsStringSync('export const value = 1;\n');
      }
      File('${root.path}/worker.wasm').writeAsBytesSync(<int>[0, 97, 115, 109]);
      File('${root.path}/index.html').writeAsStringSync('<html></html>');
      server = await serveDirectory(root.path);
    });

    tearDown(() async {
      await server.close(force: true);
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<String?> contentTypeOf(String name) async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/$name'),
        );
        final response = await request.close();
        await response.drain<void>();
        return response.headers.contentType?.mimeType;
      } finally {
        client.close(force: true);
      }
    }

    test('module workers are served as JavaScript', () async {
      expect(await contentTypeOf('worker.boot.mjs'), 'text/javascript');
      expect(await contentTypeOf('worker.mjs'), 'text/javascript');
      expect(await contentTypeOf('worker.js'), 'text/javascript');
    });

    test('the Wasm module keeps its own type', () async {
      expect(await contentTypeOf('worker.wasm'), 'application/wasm');
    });

    test('the page is served as HTML', () async {
      expect(await contentTypeOf('index.html'), 'text/html');
    });
  });
}
