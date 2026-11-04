import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture.dart';

const String watchTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:sample_helper/helper.dart';

@DwiTask()
int add(int value) => addOne(value);
''';

void main() {
  late FixtureProject project;
  late Directory helper;

  setUp(() {
    project = FixtureProject.create();
    helper = Directory(p.join(project.root.path, 'sample_helper', 'lib'))
      ..createSync(recursive: true);
    File(p.join(helper.path, 'helper.dart'))
        .writeAsStringSync('int addOne(int value) => value + 1;\n');
    _addHelperPackage(project, helper);
    project.write('lib/tasks.dart', watchTasks);
  });

  tearDown(() => project.dispose());

  test(
    'watch rebuilds when a dependency outside --include changes',
    () async {
      final builderConfig = File(
        p.join(
          Directory.current.path,
          '.dart_tool',
          'package_config.json',
        ),
      ).absolute.path;
      expect(File(builderConfig).existsSync(), isTrue);

      final process = await Process.start(
        Platform.resolvedExecutable,
        <String>[
          '--packages=$builderConfig',
          p.join(Directory.current.path, 'bin', 'dwi.dart'),
          'watch',
          '--project-root',
          project.root.path,
        ],
        workingDirectory: project.root.path,
        environment: <String, String>{
          'PUB_CACHE': Platform.environment['PUB_CACHE'] ?? '',
        },
      );
      final output = StringBuffer();
      final rebuilds = <String>[];
      final watched = Completer<void>();
      final rebuilt = Completer<void>();

      void onLine(String line) {
        output.writeln(line);
        if (line.contains('DWI: watching') && !watched.isCompleted) {
          watched.complete();
        }
        if (line.contains('worker compiled')) {
          rebuilds.add(line);
          if (rebuilds.length >= 2 && !rebuilt.isCompleted) rebuilt.complete();
        }
      }

      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);

      try {
        await watched.future.timeout(const Duration(minutes: 2));
        // The helper lives in another package, outside the configured include
        // path; only the dependency closure knows about it.
        File(p.join(helper.path, 'helper.dart'))
            .writeAsStringSync('int addOne(int value) => value + 2;\n');
        await rebuilt.future.timeout(const Duration(minutes: 2));
        expect(rebuilds.length, greaterThanOrEqualTo(2), reason: '$output');
      } finally {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _addHelperPackage(FixtureProject project, Directory lib) {
  final config = File(
    p.join(project.root.path, '.dart_tool', 'package_config.json'),
  );
  final decoded = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final packages = (decoded['packages'] as List)
      .map((entry) => Map<String, dynamic>.from(entry as Map))
      .toList();
  packages.removeWhere((entry) => entry['name'] == 'sample_helper');
  packages.add(<String, dynamic>{
    'name': 'sample_helper',
    'rootUri': Directory(p.dirname(lib.path)).uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.13',
  });
  decoded['packages'] = packages;
  config.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(decoded)}\n',
  );
}
