import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';
import 'support/link_fixture.dart';

const String _main =
    '''
import 'dart:convert';
import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';

Future<void> main() async {
  final result = <String, Object?>{};
  try {
    await Dwi.configure(const DwiConfig(channelBufferSize: 4));
$linkCalls
  } finally {
    await Dwi.close();
  }
  print(jsonEncode(result));
}
''';

void main() {
  test('linked handles exchange ordered messages and close together '
      'natively', () async {
    final project = FixtureProject.create();
    addTearDown(project.dispose);
    project.write('lib/link_tasks.dart', linkTasks);
    project.write('bin/main.dart', _main);
    await DwiBuilder(project.config()).build();

    // The process exits only when every isolate and port is released, so a
    // leaked stream context fails here instead of hanging the suite.
    final result = await Process.run(Platform.resolvedExecutable, <String>[
      '--packages=.dart_tool/package_config.json',
      'bin/main.dart',
    ], workingDirectory: project.root.path).timeout(const Duration(minutes: 2));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expectLinkResults(
      jsonDecode((result.stdout as String).trim().split('\n').last)
          as Map<String, dynamic>,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
