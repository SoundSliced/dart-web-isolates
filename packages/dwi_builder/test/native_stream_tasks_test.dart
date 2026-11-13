import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';
import 'support/stream_fixture.dart';

const String _main =
    '''
import 'dart:convert';
import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';
import 'package:sample_app/stream_tasks.dart';

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    await Dwi.configure(const DwiConfig(channelBufferSize: 4));
$streamCalls
  } finally {
    await Dwi.close();
  }
  print(jsonEncode(result));
}
''';

void main() {
  test('stream tasks deliver ordered, converted, bounded and cancellable items '
      'natively', () async {
    final project = FixtureProject.create();
    addTearDown(project.dispose);
    project.write('lib/stream_tasks.dart', streamTasks);
    project.write('bin/main.dart', _main);
    await DwiBuilder(project.config()).build();

    // The process exits only when every isolate and port is released, so a
    // leaked stream context fails here instead of hanging the suite.
    final result = await Process.run(Platform.resolvedExecutable, <String>[
      '--packages=.dart_tool/package_config.json',
      'bin/main.dart',
    ], workingDirectory: project.root.path).timeout(const Duration(minutes: 2));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expectStreamResults(
      jsonDecode((result.stdout as String).trim().split('\n').last)
          as Map<String, dynamic>,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
