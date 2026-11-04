/// A resolved Dart type that can cross the DWI worker boundary.
///
/// Types are captured from the analyzer's resolved element model rather than
/// from declaration source text, so the generator knows which library defines
/// each name and can emit deterministic imports and qualified references.
class DwiTypeDescriptor {
  const DwiTypeDescriptor({
    required this.name,
    this.libraryUri,
    this.arguments = const <DwiTypeDescriptor>[],
    this.nullable = false,
    this.isDynamic = false,
  });

  /// The runtime placeholder used when discovery already reported an error.
  static const DwiTypeDescriptor dynamicType = DwiTypeDescriptor(
    name: 'dynamic',
    isDynamic: true,
  );

  /// The declared type name, such as `List`, `int` or `Uint8List`.
  final String name;

  /// URI of the library that declares [name]; `null` for `dynamic` and `void`.
  final String? libraryUri;

  /// Resolved type arguments, in declaration order.
  final List<DwiTypeDescriptor> arguments;

  /// Whether the source declared the type with `?`.
  final bool nullable;

  /// Whether this is the `dynamic` type.
  final bool isDynamic;

  /// Whether the declared type is `void`.
  bool get isVoid => name == 'void' && libraryUri == null;

  /// Whether the type is declared by `dart:core`.
  bool get isCore => libraryUri == 'dart:core';

  /// Whether this is `Object`.
  bool get isObject => isCore && name == 'Object';

  /// Library-independent text, used as a stable identity for generated codecs.
  String get canonical {
    if (isDynamic) return 'dynamic';
    if (isVoid) return 'void';
    final renderedArguments = arguments.isEmpty
        ? ''
        : '<${arguments.map((argument) => argument.canonical).join(', ')}>';
    return '$name$renderedArguments${nullable ? '?' : ''}';
  }

  /// A copy with [nullable] forced to `false`.
  DwiTypeDescriptor get nonNullable => DwiTypeDescriptor(
    name: name,
    libraryUri: libraryUri,
    arguments: arguments,
    isDynamic: isDynamic,
  );

  /// Renders the type for generated source.
  ///
  /// `dart:core` types render bare; every other library is referenced through
  /// the prefix in [prefixes] so two libraries with the same type name cannot
  /// collide.
  String render(Map<String, String> prefixes) {
    if (isDynamic) return 'dynamic';
    if (isVoid) return 'void';
    final prefix = isCore ? '' : '${prefixes[libraryUri]}.';
    final renderedArguments = arguments.isEmpty
        ? ''
        : '<${arguments.map((argument) => argument.render(prefixes)).join(', ')}>';
    return '$prefix$name$renderedArguments${nullable ? '?' : ''}';
  }

  @override
  String toString() => canonical;
}

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
    this.input,
    required this.output,
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

  /// Resolved input type, or `null` for a zero-argument task.
  final DwiTypeDescriptor? input;

  /// Unwrapped result type: `T` for `T`, `Future<T>` and `FutureOr<T>`.
  final DwiTypeDescriptor output;

  /// Whether the declared return type was `Future` or `FutureOr`.
  final bool returnsFuture;

  /// Whether the task produces no value.
  bool get returnsVoid => output.isVoid;

  /// Whether the task accepts an input value.
  bool get takesInput => input != null;

  /// Canonical input type text, or `null` for a zero-argument task.
  String? get inputType => input?.canonical;

  /// Canonical result type text.
  String get outputType => output.canonical;

  /// The return type of the generated proxy method.
  String get proxyReturnType =>
      returnsVoid ? 'Future<void>' : 'Future<$outputType>';
}
