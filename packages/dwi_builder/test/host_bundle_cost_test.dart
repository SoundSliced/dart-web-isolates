import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

// Measures what the host application pays for importing the generated file
// (ADR-020): the generated registry holds static references to every task, so
// the host bundle retains the task library that the worker also contains.
//
// The task below embeds a marker string and a table that cannot be folded
// away, which makes its presence in a compiled host visible and measurable.
const String _tasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';

const String marker = 'DWI_HOST_BUNDLE_MARKER';

@DwiTask()
int heavy(int seed) {
  final table = <String>[
    for (var index = 0; index < 64; index++) '$marker-$index-${seed + index}',
  ];
  var sum = 0;
  for (final entry in table) {
    sum = (sum * 31 + entry.hashCode) & 0x3fffffff;
  }
  return sum;
}
''';

const Map<String, String> _hosts = <String, String>{
  // Name-based call only: the host never imports the task library.
  'named': r'''
import 'package:dwi/dwi.dart';
Future<void> main() async {
  print(await Dwi.run<Object?>('heavy', 1));
}
''',
  // Generated typed proxy.
  'proxy': r'''
import 'package:sample_app/dwi_tasks.g.dart';
Future<void> main() async {
  print(await DwiTasks.heavy(1));
}
''',
  // Registered static selection through the generated adapter.
  'function': r'''
import 'package:sample_app/dwi_tasks.g.dart';
import 'package:sample_app/tasks.dart';
Future<void> main() async {
  print(await DwiFunctions.run(heavy, 1));
}
''',
};

void main() {
  test('host bundle cost of the generated registry is measured', () async {
    final project = FixtureProject.create();
    addTearDown(project.dispose);
    project.write('lib/tasks.dart', _tasks);
    await DwiBuilder(project.config()).build();

    final sizes = <String, Map<String, int>>{};
    final retained = <String, bool>{};
    for (final entry in _hosts.entries) {
      project.write('web/${entry.key}.dart', entry.value);
      sizes[entry.key] = <String, int>{};
      for (final target in <String>['js', 'wasm']) {
        final output = target == 'js'
            ? 'web/${entry.key}.dart.js'
            : 'web/${entry.key}.wasm';
        final compiled = await Process.run(
          Platform.resolvedExecutable,
          <String>[
            'compile',
            target,
            if (target == 'js') '-O2',
            '-o',
            output,
            'web/${entry.key}.dart',
          ],
          workingDirectory: project.root.path,
          environment: <String, String>{
            'PUB_CACHE': Platform.environment['PUB_CACHE'] ?? '',
          },
        );
        expect(
          compiled.exitCode,
          0,
          reason: '${compiled.stdout}\n${compiled.stderr}',
        );
        final bytes = File('${project.root.path}/$output').readAsBytesSync();
        sizes[entry.key]![target] = bytes.length;
        if (target == 'js') {
          retained[entry.key] = latin1
              .decode(bytes, allowInvalid: true)
              .contains('DWI_HOST_BUNDLE_MARKER');
        }
      }
    }

    final report = <String, Object?>{
      'sdk': Platform.version,
      'optimization': <String, String>{'js': '-O2', 'wasm': 'default'},
      'bytes': sizes,
      'taskCodeRetainedInJsHost': retained,
      'deltaVsNamed': <String, Map<String, int>>{
        for (final host in <String>['proxy', 'function'])
          host: <String, int>{
            for (final target in <String>['js', 'wasm'])
              target: sizes[host]![target]! - sizes['named']![target]!,
          },
      },
    };
    // Evidence line: exact measured sizes for the audit record.
    print('dwi-host-bundle-cost: ${jsonEncode(report)}');
    final path = Platform.environment['DWI_BUNDLE_COST_EVIDENCE'];
    if (path != null) {
      File(path).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
    }

    // A name-only host never contains the task library.
    expect(retained['named'], isFalse);
    // Both generated paths retain it: this is the documented, measured cost.
    expect(retained['proxy'], isTrue);
    expect(retained['function'], isTrue);
    for (final target in <String>['js', 'wasm']) {
      expect(sizes['proxy']![target], greaterThan(sizes['named']![target]!));
      // Selecting by tear-off adds only the adapter lookup on top of a proxy.
      expect(
        sizes['function']![target]! - sizes['proxy']![target]!,
        lessThan(4096),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
