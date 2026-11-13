import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';
import 'support/static_acceptance_sources.dart';

const String _tasks = r'''
import 'dart:async';
import 'package:dwi_annotations/dwi_annotations.dart';
int state = 0;
@DwiTask()
int addOne(int value) => value + 1;
class Ops {
  @DwiTask()
  static int twice(int value) => value * 2;
  @DwiTask()
  static Future<int> twiceAsync(int value) async => value * 2;
  @DwiTask()
  static FutureOr<int> twiceEither(int value) =>
      value.isEven ? value * 2 : Future<int>.value(value * 2);
  @DwiTask()
  static int answer() => 42;
  @DwiTask()
  static void ping() {}
  @DwiTask()
  static Future<void> sink(int value) async {}
  @DwiTask()
  static Future<List<int?>> nullable(List<int?> input) async => input;
  @DwiTask(name: 'ops.renamed')
  static int renamed(int value) => value + 100;
}
enum Scale {
  unit;

  @DwiTask()
  static int triple(int value) => value * 3;
}

@DwiTask()
FutureOr<int> either(int value) =>
    value.isEven ? value + 2 : Future<int>.value(value + 2);
@DwiTask()
Future<int> zeroAsync() async => 7;
@DwiTask()
int identity() => state++;
@DwiTask()
Future<List<int?>> nullable(List<int?> input) async => input;
@DwiTask()
void noInput() {}
@DwiTask()
Future<void> noResult(int input) async {}
@DwiTask()
int explode(int value) => throw StateError('boom');
@DwiTask()
Future<int> slow(int milliseconds) =>
    Future<int>.delayed(Duration(milliseconds: milliseconds), () => milliseconds);
''';

const String _main = r'''
import 'dart:async';
import 'dart:convert';
import 'package:dwi/dwi.dart';
import 'package:sample_app/dwi_tasks.g.dart';
import 'package:sample_app/tasks.dart';
int unregisteredCalls = 0;
int unregistered(int value) { unregisteredCalls++; return value; }
int unregistered0() { unregisteredCalls++; return 0; }
class Receiver {
  int method(int value) => value;
  int method0() => 0;
}
Future<void> main() async {
  final result = <String, Object?>{};
  try {
    final receiver = Receiver();
    final capture = Object();
    final targets = <int Function(int)>[
      unregistered, (int value) => value + 1,
      (int value) => value + capture.hashCode, receiver.method,
    ];
    var rejected = 0;
    for (final target in targets) {
      try { await DwiFunctions.run(target, 1); }
      on DwiUnknownTaskException { rejected++; }
    }
    result['rejected'] = rejected;
    var rejected0 = 0;
    for (final target in <int Function()>[
      unregistered0, () => 1, () => capture.hashCode, receiver.method0,
    ]) {
      try { await DwiFunctions.run0(target); }
      on DwiUnknownTaskException { rejected0++; }
    }
    result['rejected0'] = rejected0;
    // A registered task called through a caller signature its proxy does not
    // have (a nested Future result) is refused before registration or startup.
    var unsupported = 0;
    try { await DwiFunctions.run<int, Future<int>>(slow, 1); }
    on DwiUnsupportedException { unsupported++; }
    try { await DwiFunctions.run<int, Future<int>>(Ops.twiceAsync, 1); }
    on DwiUnsupportedException { unsupported++; }
    try { await DwiFunctions.run0<Future<int>>(zeroAsync); }
    on DwiUnsupportedException { unsupported++; }
    result['unsupported'] = unsupported;
    result['unregisteredCalls'] = unregisteredCalls;
    result['registryBeforeAccepted'] = Dwi.registry.names.toList();
    result['selected'] = <int>[
      for (final target in <int Function(int)>[addOne, Ops.twice, addOne, Ops.twice])
        await DwiFunctions.run(target, 21),
    ];
    state = 1000;
    result['workerState'] = await DwiFunctions.run0(identity);
    result['hostState'] = state;
    result['collections'] = await DwiFunctions.run(nullable, <int?>[1, null, 3]);
    await DwiFunctions.run0<void>(noInput);
    await DwiFunctions.run<int, void>(noResult, 1);
    result['either'] = <int>[
      await DwiFunctions.run(either, 2), await DwiFunctions.run(either, 3),
    ];
    result['zeroAsync'] = await DwiFunctions.run0(zeroAsync);
    result['staticAsync'] = await DwiFunctions.run(Ops.twiceAsync, 21);
    result['staticEither'] = <int>[
      await DwiFunctions.run(Ops.twiceEither, 2),
      await DwiFunctions.run(Ops.twiceEither, 3),
    ];
    result['staticZero'] = await DwiFunctions.run0(Ops.answer);
    await DwiFunctions.run0<void>(Ops.ping);
    await DwiFunctions.run<int, void>(Ops.sink, 1);
    result['staticVoid'] = true;
    result['staticCollections'] =
        await DwiFunctions.run(Ops.nullable, <int?>[1, null, 3]);
    result['staticRenamed'] = await DwiFunctions.run(Ops.renamed, 1);
    result['enumStatic'] = await DwiFunctions.run(Scale.triple, 7);
    result['enumProxy'] = await DwiTasks.Scale$triple(7);
    result['staticRenamedByName'] = await Dwi.run<Object?>('ops.renamed', 1);
    result['registryAfter'] = Dwi.registry.names.toList();
    try { await DwiFunctions.run(explode, 1); }
    on DwiRemoteException catch (error) {
      result['remote'] = error.message.contains('boom') && error.remoteStack.isNotEmpty;
    }
    final capabilities = await Dwi.capabilities();
    result['backend'] = capabilities.backend.name;
    result['protocolVersion'] = capabilities.protocolVersion;
    await Dwi.close();
    result['reused'] = await DwiFunctions.run(Ops.twice, 3);
    await Dwi.close();
    await Dwi.configure(const DwiConfig(taskTimeout: Duration(milliseconds: 50)));
    try { await DwiFunctions.run(slow, 1000); }
    on DwiTimeoutException { result['timeout'] = true; }
  } finally { await Dwi.close(); }
  print(jsonEncode(result));
}
''';

void main() {
  test('generated static adapters execute natively with typed results and rejection', () async {
    final project = FixtureProject.create();
    addTearDown(project.dispose);
    project.write('lib/tasks.dart', _tasks);
    project.write('bin/main.dart', _main);
    await DwiBuilder(project.config()).build();
    // Cleanup: the process only exits once every isolate and port opened by
    // the adapter path is released, so a leak fails here instead of hanging.
    final result = await Process.run(Platform.resolvedExecutable, <String>[
      '--packages=.dart_tool/package_config.json',
      'bin/main.dart',
    ], workingDirectory: project.root.path).timeout(const Duration(minutes: 2));
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final decoded =
        jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>;
    expect(decoded['rejected'], 4);
    expect(decoded['rejected0'], 4);
    expect(decoded['unsupported'], 3);
    expect(decoded['unregisteredCalls'], 0);
    expect(decoded['registryBeforeAccepted'], isEmpty);
    expect(decoded['selected'], <int>[22, 42, 22, 42]);
    expect(decoded['workerState'], 0);
    expect(decoded['hostState'], 1000);
    expect(decoded['collections'], <int?>[1, null, 3]);
    expect(decoded['remote'], isTrue);
    expect(decoded['either'], <int>[4, 5]);
    expect(decoded['zeroAsync'], 7);
    expect(decoded['staticAsync'], 42);
    expect(decoded['staticEither'], <int>[4, 6]);
    expect(decoded['staticZero'], 42);
    expect(decoded['staticVoid'], isTrue);
    expect(decoded['staticCollections'], <int?>[1, null, 3]);
    expect(decoded['staticRenamed'], 101);
    expect(decoded['staticRenamedByName'], 101);
    expect(decoded['enumStatic'], 21);
    expect(decoded['enumProxy'], 21);
    expect(
      decoded['registryAfter'],
      allOf(
        containsAll(<String>['Ops.twice', 'ops.renamed', 'Scale.triple']),
        isNot(contains('Ops.renamed')),
      ),
    );
    expect(decoded['backend'], 'isolate');
    expect(decoded['protocolVersion'], 1);
    expect(decoded['reused'], 6);
    expect(decoded['timeout'], isTrue);

    final evidencePath = Platform.environment['DWI_STATIC_NATIVE_EVIDENCE'];
    if (evidencePath != null) {
      final revision = await Process.run('git', <String>['rev-parse', 'HEAD']);
      if (revision.exitCode != 0) throw StateError('${revision.stderr}');
      File(evidencePath).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'sdk': Platform.version,
          'revision': (revision.stdout as String).trim(),
          'sourceState': 'local ADR-020 implementation, uncommitted',
          'sourceDigests': <String, String>{for (final source in staticAcceptanceSources) source: sha256.convert(File(source).readAsBytesSync()).toString()},
          'fixture': 'packages/dwi_builder/test/native_static_registry_test.dart',
          'command': 'dart test test/native_static_registry_test.dart -r expanded',
          'result': decoded,
          'status': 'pass',
        })}\n',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('generated adapter rejects a statically incompatible input', () async {
    final project = FixtureProject.create();
    addTearDown(project.dispose);
    project.write('lib/tasks.dart', _tasks);
    await DwiBuilder(project.config()).build();
    project.write('bin/invalid.dart', r'''
import 'package:sample_app/dwi_tasks.g.dart';
import 'package:sample_app/tasks.dart';
void main() { DwiFunctions.run<int, int>(addOne, 'not an int'); }
''');
    final result = await Process.run(Platform.resolvedExecutable, <String>[
      'analyze',
      'bin/invalid.dart',
    ], workingDirectory: project.root.path);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('argument_type_not_assignable'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
