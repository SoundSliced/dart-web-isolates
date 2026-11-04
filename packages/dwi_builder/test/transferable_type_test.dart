import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

const String transferableTasks = r'''
import 'package:dwi_annotations/dwi_annotations.dart';
import 'package:dwi_core/dwi_core.dart';

@DwiTask()
DwiTransferableBytes echoTransferable(DwiTransferableBytes input) => input;

@DwiTask()
int sizeOf(DwiTransferableBytes input) => input.lengthInBytes;
''';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test('accepts DwiTransferableBytes as a task parameter and result', () async {
    project.write('lib/tasks.dart', transferableTasks);

    final result = await DwiBuilder(project.config()).build();

    expect(
      result.discovery.diagnostics
          .where((item) => item.severity == DwiDiagnosticSeverity.error),
      isEmpty,
      reason: result.discovery.diagnostics.map((item) => item.format()).join(),
    );

    final worker = project.read('.dwi/generated_worker.dart');
    final proxies = project.read('lib/dwi_tasks.g.dart');

    // The transport already produces the wrapper, so the generated codec only
    // has to check the type (ADR-010 §10.2).
    expect(worker, contains('DwiTransferableBytes'));
    expect(worker, contains('expected DwiTransferableBytes'));
    expect(
      proxies,
      contains('Future<dwi_t0.DwiTransferableBytes> echoTransferable('),
    );
    expect(
      proxies,
      contains('Future<int> sizeOf(dwi_t0.DwiTransferableBytes input)'),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
