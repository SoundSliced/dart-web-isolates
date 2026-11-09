// Drives the four supported engines against a served directory and prints one
// JSON object per engine. Reuses the package's tested browser support instead
// of duplicating CDP/WebDriver code; the relative import is intentional because
// this is internal tooling, not a shipped package.
//
// Usage:
//   dart run bin/probe.dart --root <dir> --mount <path> [--engines chrome,...]
//
// Exit codes:
//   0  every available engine reported status "ok" (blocked engines are
//      recorded with their verbatim reason and do not fail the run)
//   1  at least one available engine reported "failed"
//   64 bad arguments
import 'dart:convert';
import 'dart:io';

import '../../../../packages/dwi_builder/test/support/browser_probe.dart';

Future<void> main(List<String> arguments) async {
  final root = _option(arguments, '--root');
  final mount = _option(arguments, '--mount') ?? '/';
  final engineNames =
      (_option(arguments, '--engines') ?? 'chrome,safari,firefox,edge')
          .split(',')
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toList();

  if (root == null) {
    stderr.writeln('usage: probe.dart --root <dir> [--mount /] '
        '[--engines chrome,safari,firefox,edge]');
    exit(64);
  }

  final engines = <BrowserEngine>[];
  for (final name in engineNames) {
    final engine = BrowserEngine.values
        .where((candidate) => candidate.name == name)
        .firstOrNull;
    if (engine == null) {
      stderr.writeln('unknown engine: $name');
      exit(64);
    }
    engines.add(engine);
  }

  final server = await serveDirectory(root);
  final origin = 'http://${server.address.address}:${server.port}';
  final url = '$origin$mount';
  final results = <Map<String, Object?>>[];

  for (final engine in engines) {
    try {
      final run = await probeBrowser(engine, url);
      results.add(<String, Object?>{
        'engine': engine.name,
        'version': run.browserVersion,
        'url': url,
        'status': 'ok',
        'data': run.data,
      });
    } on BrowserBlockedException catch (error) {
      results.add(<String, Object?>{
        'engine': engine.name,
        'url': url,
        'status': 'blocked',
        'reason': error.reason,
      });
    } catch (error, stack) {
      results.add(<String, Object?>{
        'engine': engine.name,
        'url': url,
        'status': 'failed',
        'error': '$error',
        'stack': '$stack',
      });
    }
  }

  await server.close(force: true);
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(results));
  if (results.any((result) => result['status'] == 'failed')) exitCode = 1;
}

String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index == -1 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}
