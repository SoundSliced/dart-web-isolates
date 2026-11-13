import 'dart:convert';
import 'dart:io';

import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';
import 'support/payload_fixture.dart';

const String _main =
    '''
import 'dart:convert';
import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';
import 'package:sample_app/model.dart';
import 'package:sample_app/tasks.dart';

Future<void> main() async {
  final result = <String, Object?>{};
  try {
$payloadCalls
    result['backend'] = (await Dwi.capabilities()).backend.name;
  } finally {
    await Dwi.close();
  }
  print(jsonEncode(result));
}
''';

void main() {
  late FixtureProject project;
  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test(
    'enums, core value types, records and payload classes round-trip natively',
    () async {
      project.write('lib/model.dart', payloadModel);
      project.write('lib/tasks.dart', payloadTasks);
      project.write('bin/main.dart', _main);
      await DwiBuilder(project.config()).build();

      final result = await Process.run(
        Platform.resolvedExecutable,
        <String>['--packages=.dart_tool/package_config.json', 'bin/main.dart'],
        workingDirectory: project.root.path,
      ).timeout(const Duration(minutes: 2));
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final decoded = jsonDecode(
        (result.stdout as String).trim().split('\n').last,
      ) as Map<String, dynamic>;
      expectPayloadResults(decoded);
      expect(decoded['backend'], 'isolate');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
