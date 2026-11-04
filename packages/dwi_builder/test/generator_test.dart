import 'package:dwi_builder/dwi_builder.dart';
import 'package:test/test.dart';

void main() {
  DwiTaskDescriptor descriptor(
    String name, {
    String functionName = '',
    String? inputType,
    String outputType = 'int',
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
      inputType: inputType,
      outputType: outputType,
      returnsFuture: returnsFuture,
    );
  }

  test('emits static task references in deterministic order', () {
    final tasks = <DwiTaskDescriptor>[
      descriptor('zeta', inputType: 'String', outputType: 'void'),
      descriptor('alpha', inputType: 'int'),
      descriptor('middle', inputType: 'int?', outputType: 'String'),
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
      contains("'alpha': (Object? input) => task0.alpha(input! as int)"),
    );
    expect(
      first.worker,
      contains("'middle': (Object? input) => task0.middle(input as int?)"),
    );
    expect(
      first.worker,
      contains(
        "'zeta': (Object? input) { task0.zeta(input! as String); "
        'return null; }',
      ),
    );
  });

  test('wraps asynchronous void tasks', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor(
        'flush',
        inputType: 'String',
        outputType: 'void',
        returnsFuture: true,
      ),
    ], workerId: 'default');

    expect(
      sources.worker,
      contains(
        "'flush': (Object? input) async { await task0.flush(input! as String); "
        'return null; }',
      ),
    );
    expect(
      sources.proxies,
      contains('static Future<void> flush(String input) async'),
    );
    expect(
      sources.proxies,
      contains("await Dwi.run<Object?>('flush', input);"),
    );
  });

  test('emits typed proxies, no-input overloads and metadata', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor('calculatePrimes', inputType: 'int', outputType: 'int'),
      descriptor('noInput', inputType: null, outputType: 'void'),
      descriptor(
        'greet',
        functionName: 'greet',
        inputType: 'String',
        outputType: 'String',
      ),
    ], workerId: 'poolA');

    expect(sources.proxies, contains('abstract final class DwiTasks'));
    expect(
      sources.proxies,
      contains('static Future<int> calculatePrimes(int input)'),
    );
    expect(
      sources.proxies,
      contains("return Dwi.run<int>('calculatePrimes', input);"),
    );
    expect(sources.proxies, contains('static Future<void> noInput() async'));
    expect(sources.proxies, contains("await Dwi.run<Object?>('noInput');"));
    expect(sources.proxies, contains("'greet': 'greet'"));
    expect(sources.proxies, contains("dwiGeneratedWorkerId = 'poolA'"));
  });

  test('passes dynamic and Object? inputs without a redundant cast', () {
    expect(descriptor('a', inputType: 'dynamic').inputExpression, 'input');
    expect(descriptor('b', inputType: 'Object?').inputExpression, 'input');
    expect(
      descriptor('c', inputType: 'Object').inputExpression,
      'input! as Object',
    );
  });

  test('groups tasks from the same library behind one import prefix', () {
    final sources = DwiGenerator.generate(<DwiTaskDescriptor>[
      descriptor('one', inputType: 'int'),
      descriptor('two', inputType: 'int'),
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
