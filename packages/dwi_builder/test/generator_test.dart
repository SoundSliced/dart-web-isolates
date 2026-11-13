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
    String? declaringType,
    DwiTypeDescriptor? input,
    DwiTypeDescriptor? output,
    bool returnsFuture = false,
    String importUri = 'package:app/tasks.dart',
  }) {
    return DwiTaskDescriptor(
      name: name,
      functionName: functionName.isEmpty ? name : functionName,
      declaringType: declaringType,
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

  test(
    'static references and caller adapters share deterministic typed proxies',
    () {
      final tasks = <DwiTaskDescriptor>[
        descriptor(
          'Ops.twice',
          functionName: 'twice',
          declaringType: 'Ops',
          input: type('int'),
        ),
        descriptor('answer'),
      ];
      final sources = DwiGenerator.generate(tasks, workerId: 'default');
      final reversed = DwiGenerator.generate(
        tasks.reversed.toList(),
        workerId: 'default',
      );
      expect(sources.worker, reversed.worker);
      expect(sources.proxies, reversed.proxies);
      expect(sources.worker, contains('task0.Ops.twice('));
      expect(
        sources.proxies,
        contains(r'static Future<int> Ops$twice(int input)'),
      );
      expect(sources.proxies, contains(r'task0.Ops.twice: DwiTasks.Ops$twice'));
      expect(sources.proxies, contains('task0.answer: DwiTasks.answer'));
    },
  );

  test('emits typed proxies, native registration and metadata', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor('calculatePrimes', input: type('int'), output: type('int')),
      descriptor('noInput', output: type('void')),
      descriptor('greet', input: type('String'), output: type('String')),
    ], workerId: 'poolA');

    expect(sources.proxies, contains('abstract final class DwiTasks'));
    expect(
      sources.proxies,
      contains('static Future<int> calculatePrimes(int input)'),
    );
    expect(
      sources.proxies,
      contains(
        "final value = await Dwi.run<Object?>('calculatePrimes', input)",
      ),
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
      descriptor('echo', input: type('Uint8List'), output: type('Uint8List')),
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
    final js = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor('one', input: type('int')),
    ], workerId: 'default');
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
  test('emits encoders only for types that are converted (ADR-021)', () {
    final plain = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor(
        'plain',
        input: type('List', arguments: <DwiTypeDescriptor>[type('int')]),
      ),
    ], workerId: 'default');
    // Types sent as-is keep the code they always had.
    expect(plain.proxies, isNot(contains('_dwiEncode')));
    expect(plain.worker, isNot(contains('_dwiEncode')));
    expect(plain.proxies, contains("Dwi.run<Object?>('plain', input)"));

    const model = 'package:app/model.dart';
    const color = DwiTypeDescriptor(
      name: 'Color',
      libraryUri: model,
      kind: DwiTypeKind.enumeration,
    );
    // Same name in another library: a separate codec, not a collision.
    const otherColor = DwiTypeDescriptor(
      name: 'Color',
      libraryUri: 'package:app/other.dart',
      kind: DwiTypeKind.enumeration,
    );
    final shape = DwiPayloadShape();
    final node = DwiTypeDescriptor(
      name: 'Node',
      libraryUri: model,
      kind: DwiTypeKind.payload,
      shape: shape,
    );
    shape.fields.addAll(<DwiPayloadField>[
      DwiPayloadField(name: 'value', type: type('int'), isNamed: false),
      DwiPayloadField(
        name: 'children',
        type: type('List', arguments: <DwiTypeDescriptor>[node]),
        isNamed: false,
      ),
      const DwiPayloadField(name: r'co$t', type: color, isNamed: true),
    ]);
    final record = DwiTypeDescriptor(
      name: 'Record',
      kind: DwiTypeKind.record,
      positional: <DwiTypeDescriptor>[type('DateTime')],
      named: <String, DwiTypeDescriptor>{'other': otherColor},
    );
    final tasks = <DwiTaskDescriptor>[
      descriptor('tree', input: node, output: record, returnsFuture: true),
      descriptor('sync', input: color, output: color),
    ];
    final sources = DwiGenerator.generate(tasks, workerId: 'default');
    expect(
      DwiGenerator.generate(
        tasks.reversed.toList(),
        workerId: 'default',
      ).proxies,
      sources.proxies,
    );

    expect(sources.proxies, contains("import 'package:app/model.dart' as"));
    expect(sources.proxies, contains("import 'package:app/other.dart' as"));
    expect(
      sources.proxies,
      contains(RegExp(r"Dwi\.run<Object\?>\('tree', _dwiEncode\d+\(input\)\)")),
    );
    // The worker converts an awaited result before it is posted.
    expect(
      sources.worker,
      contains(RegExp(r'async => _dwiEncode\d+\(await task0\.tree\(')),
    );
    expect(
      sources.worker,
      contains(RegExp(r'=> _dwiEncode\d+\(task0\.sync\(')),
    );
    // `$` in a field name must not start an interpolation in generated code.
    expect(sources.proxies, contains(r"'co\$t': "));
    expect(sources.proxies, contains(r"value['co\$t']"));
    expect(sources.proxies, contains('value.microsecondsSinceEpoch'));
    expect(
      RegExp(
        r'_dwiDecode\d+\(Object\? value, String path\) \{\n'
        r'  if \(value is String\) \{\n'
        r'    for \(final item in dwi_t\d+\.Color\.values\)',
      ).allMatches(sources.proxies).length,
      2,
    );
  });
  test('stream tasks get a Stream proxy and a credit-driven worker entry', () {
    final stream = DwiTaskDescriptor(
      name: 'counts',
      functionName: 'counts',
      importUri: 'package:app/tasks.dart',
      sourcePath: '/app/lib/tasks.dart',
      line: 1,
      column: 1,
      input: type('int'),
      output: type('int'),
      returnsFuture: false,
      returnsStream: true,
    );
    const color = DwiTypeDescriptor(
      name: 'Color',
      libraryUri: 'package:app/model.dart',
      kind: DwiTypeKind.enumeration,
    );
    final converted = DwiTaskDescriptor(
      name: 'colors',
      functionName: 'colors',
      importUri: 'package:app/tasks.dart',
      sourcePath: '/app/lib/tasks.dart',
      line: 2,
      column: 1,
      output: color,
      returnsFuture: false,
      returnsStream: true,
    );
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      stream,
      converted,
    ], workerId: 'default');

    expect(sources.proxies, contains('static Stream<int> counts(int input) {'));
    expect(
      sources.proxies,
      contains("return Dwi.runStream('counts', input).map("),
    );
    expect(sources.proxies, contains('static Stream<'));
    expect(sources.proxies, contains("Dwi.runStream('colors')"));
    expect(
      sources.proxies,
      contains('static Stream<T> stream<I, T>(Stream<T> Function(I) function'),
    );
    expect(
      sources.worker,
      contains(
        "'counts': (Object? request) => DwiStreamTask.serve(request, "
        '(Object? input) => task0.counts(',
      ),
    );
    // Converted items are encoded one by one before they are sent.
    expect(
      sources.worker,
      contains(
        RegExp(r'task0\.colors\(\)\.map\(\(item\) => _dwiEncode\d+\(item\)\)'),
      ),
    );
  });
}
