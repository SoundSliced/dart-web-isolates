import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

void main() {
  DwiTypeDescriptor type(
    String name, {
    List<DwiTypeDescriptor> arguments = const <DwiTypeDescriptor>[],
    bool nullable = false,
    String? library,
  }) {
    if (name == 'dynamic') return DwiTypeDescriptor.dynamicType;
    if (name == 'void') return const DwiTypeDescriptor(name: 'void');
    return DwiTypeDescriptor(
      name: name,
      libraryUri:
          library ??
          (name == 'Uint8List' || name == 'ByteData'
              ? 'dart:typed_data'
              : 'dart:core'),
      arguments: arguments,
      nullable: nullable,
    );
  }

  DwiTaskDescriptor descriptor(
    String name, {
    String functionName = '',
    DwiTypeDescriptor? input,
    DwiTypeDescriptor? output,
    bool returnsFuture = false,
    String importUri = 'package:app/tasks.dart',
  }) {
    return DwiTaskDescriptor(
      name: name,
      functionName: functionName.isEmpty ? name : functionName,
      importUri: importUri,
      sourcePath: '/app/lib/tasks.dart',
      line: 1,
      column: 1,
      input: input,
      output: output ?? type('int'),
      returnsFuture: returnsFuture,
    );
  }

  test('emits static task references in deterministic order', () {
    final tasks = <DwiTaskDescriptor>[
      descriptor('zeta', input: type('String'), output: type('void')),
      descriptor('alpha', input: type('int')),
      descriptor(
        'middle',
        input: type('int', nullable: true),
        output: type('String'),
      ),
    ];

    final first = DwiGenerator.generate(tasks, workerId: 'w1');
    final second = DwiGenerator.generate(
      tasks.reversed.toList(),
      workerId: 'w1',
    );

    expect(first.worker, second.worker);
    expect(first.proxies, second.proxies);
    expect(
      first.worker.indexOf("'alpha'"),
      lessThan(first.worker.indexOf("'middle'")),
    );
    expect(
      first.worker.indexOf("'middle'"),
      lessThan(first.worker.indexOf("'zeta'")),
    );
    expect(first.worker, contains('package:dwi_web/dwi_worker.dart'));
    expect(first.worker, contains('DwiWorkerRuntime.start('));
    expect(first.worker, contains("workerId: 'w1'"));
    expect(
      first.worker,
      contains("'alpha': (Object? input) => task0.alpha(_dwiDecode"),
    );
    expect(
      first.worker,
      contains("'zeta': (Object? input) { task0.zeta(_dwiDecode"),
    );
    expect(first.worker, contains('// --- Generated payload decoders ---'));
    expect(first.worker, contains('int _dwiDecode'));
  });

  test('wraps asynchronous void tasks', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor(
        'flush',
        input: type('String'),
        output: type('void'),
        returnsFuture: true,
      ),
    ], workerId: 'default');

    expect(
      sources.worker,
      contains("'flush': (Object? input) async { await task0.flush(_dwiDecode"),
    );
    expect(
      sources.proxies,
      contains('static Future<void> flush(String input)'),
    );
    expect(sources.proxies, contains("await Dwi.run<Object?>('flush', input)"));
  });

  test('emits typed proxies, native registration and metadata', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor(
        'calculatePrimes',
        input: type('int'),
        output: type('int'),
      ),
      descriptor('noInput', output: type('void')),
      descriptor(
        'greet',
        input: type('String'),
        output: type('String'),
      ),
    ], workerId: 'poolA');

    expect(sources.proxies, contains('abstract final class DwiTasks'));
    expect(
      sources.proxies,
      contains('static Future<int> calculatePrimes(int input)'),
    );
    expect(
      sources.proxies,
      contains("final value = await Dwi.run<Object?>('calculatePrimes', input)"),
    );
    expect(sources.proxies, contains("return _dwiDecode"));
    expect(
      sources.proxies,
      contains("Dwi.registerTask('calculatePrimes', (Object? input) =>"),
    );
    expect(sources.proxies, contains("Dwi.registerTask('noInput',"));
    expect(sources.proxies, contains('static Future<void> noInput()'));
    expect(sources.proxies, contains("'greet': 'greet'"));
    expect(sources.proxies, contains("dwiGeneratedWorkerId = 'poolA'"));
  });

  test('imports and qualifies resolved library types', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor(
        'echo',
        input: type('Uint8List'),
        output: type('Uint8List'),
      ),
    ], workerId: 'default');

    for (final source in <String>[sources.worker, sources.proxies]) {
      expect(source, contains("import 'dart:typed_data' as dwi_t0;"));
      expect(source, contains('_dwiDecode'));
    }
    expect(sources.proxies, contains('dwi_t0.Uint8List input'));
    expect(sources.proxies, contains('Future<dwi_t0.Uint8List> echo'));
  });

  test('generates decoders for nested nullable collections', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor(
        'nested',
        input: type(
          'List',
          nullable: true,
          arguments: <DwiTypeDescriptor>[
            type('List', arguments: <DwiTypeDescriptor>[type('int')]),
          ],
        ),
        output: type(
          'Map',
          arguments: <DwiTypeDescriptor>[type('String'), type('List')],
        ),
      ),
    ], workerId: 'default');

    expect(sources.proxies, contains('static Future<Map<String, List>>'));
    expect(sources.worker, contains('List<List<int>>? _dwiDecode'));
    expect(sources.worker, contains('final result = <List<int>>[];'));
    expect(sources.worker, contains('if (value == null) return null;'));
  });

  test('accepts an integral double for an int (wasm boundary)', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor('one', input: type('int')),
    ], workerId: 'default');
    expect(sources.worker, contains('value == value.truncateToDouble()'));
    expect(sources.worker, contains('return value.toInt();'));
  });

  test('declares the worker compiler in the ready backend field', () {
    final js = DwiGenerator.generate(
      <DwiTaskDescriptor>[descriptor('one', input: type('int'))],
      workerId: 'default',
    );
    expect(js.worker, contains("backend: 'dart2js',"));

    final wasm = DwiGenerator.generate(
      <DwiTaskDescriptor>[descriptor('one', input: type('int'))],
      workerId: 'default',
      target: 'wasm',
    );
    expect(wasm.worker, contains("backend: 'dart2wasm',"));
  });

  test('groups tasks from the same library behind one import prefix', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor('one', input: type('int')),
      descriptor('two', input: type('int')),
    ], workerId: 'default');

    expect(
      RegExp("import 'package:app/tasks.dart' as task0;")
          .allMatches(sources.worker)
          .length,
      1,
    );
    expect(sources.worker, contains('task0.one'));
    expect(sources.worker, contains('task0.two'));
  });
}
