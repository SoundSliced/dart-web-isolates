/// A discovered `@DwiTask` function and the data needed to generate a worker
/// entrypoint and a typed caller proxy.
class DwiTaskDescriptor {
  const DwiTaskDescriptor({
    required this.name,
    required this.functionName,
    required this.importUri,
    required this.sourcePath,
    required this.line,
    required this.column,
    this.inputType,
    required this.outputType,
    required this.returnsFuture,
  });

  /// Task name delivered to `Dwi.run`.
  final String name;

  /// Declared Dart function name.
  final String functionName;

  /// Import URI used by the generated worker (`package:` or relative).
  final String importUri;

  /// Absolute source path, used for diagnostics and dependency hashing.
  final String sourcePath;

  /// One-based declaration line.
  final int line;

  /// One-based declaration column.
  final int column;

  /// Source text of the single input type, or `null` for a zero-argument task.
  final String? inputType;

  /// Unwrapped result type: `T` for `T`, `Future<T>` and `FutureOr<T>`.
  final String outputType;

  /// Whether the declared return type was `Future` or `FutureOr`.
  final bool returnsFuture;

  /// Whether the task produces no value.
  bool get returnsVoid => outputType == 'void';

  /// Whether the task accepts an input value.
  bool get takesInput => inputType != null;

  /// The expression passed to the task implementation inside the worker.
  String get inputExpression {
    final type = inputType;
    if (type == null) return '';
    if (type == 'dynamic' || type == 'Object?') return 'input';
    if (type.endsWith('?')) return 'input as $type';
    return 'input! as $type';
  }

  /// The return type of the generated proxy method.
  String get proxyReturnType =>
      returnsVoid ? 'Future<void>' : 'Future<$outputType>';
}
