/// How the generator moves a type across the worker boundary (ADR-021).
enum DwiTypeKind {
  /// Sent as-is and checked on arrival: primitives, collections, typed data.
  value,

  /// A user enum, sent as its constant name.
  enumeration,

  /// A record, sent as a list of its positional then named fields.
  record,

  /// A `@DwiPayload` class, sent as a map of its constructor parameters.
  payload,
}

/// One constructor parameter of a `@DwiPayload` class.
class DwiPayloadField {
  const DwiPayloadField({
    required this.name,
    required this.type,
    required this.isNamed,
  });

  /// Parameter name; also the name of the getter that supplies its value.
  final String name;

  /// Resolved parameter type.
  final DwiTypeDescriptor type;

  /// Whether the constructor takes this parameter by name.
  final bool isNamed;
}

/// The constructor parameters of a `@DwiPayload` class, in declaration order.
///
/// The list is filled after the shape is created so that a class may refer to
/// itself (a tree node holding child nodes) without infinite recursion.
class DwiPayloadShape {
  /// Constructor parameters, in declaration order.
  final List<DwiPayloadField> fields = <DwiPayloadField>[];
}

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
    this.kind = DwiTypeKind.value,
    this.positional = const <DwiTypeDescriptor>[],
    this.named = const <String, DwiTypeDescriptor>{},
    this.shape,
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

  /// How the type crosses the boundary.
  final DwiTypeKind kind;

  /// Positional fields of a record type.
  final List<DwiTypeDescriptor> positional;

  /// Named fields of a record type, sorted by name.
  final Map<String, DwiTypeDescriptor> named;

  /// Constructor parameters of a `@DwiPayload` class.
  final DwiPayloadShape? shape;

  /// Whether this is `dart:core`'s `DateTime`.
  bool get isDateTime => isCore && name == 'DateTime';

  /// Whether this is `dart:core`'s `Duration`.
  bool get isDuration => isCore && name == 'Duration';

  /// Whether this is `dart:core`'s `BigInt`.
  bool get isBigInt => isCore && name == 'BigInt';

  /// Whether this is `dart:core`'s `Uri`.
  bool get isUri => isCore && name == 'Uri';

  /// Whether a value of this type must be converted before it is sent.
  ///
  /// Types that are sent as-is keep the generated code they always had.
  bool get needsEncoding =>
      kind != DwiTypeKind.value ||
      isDateTime ||
      isDuration ||
      isBigInt ||
      isUri ||
      arguments.any((argument) => argument.needsEncoding);

  /// Whether the declared type is `void`.
  bool get isVoid => name == 'void' && libraryUri == null;

  /// Whether the type is declared by `dart:core`.
  bool get isCore => libraryUri == 'dart:core';

  /// Whether this is `Object`.
  bool get isObject => isCore && name == 'Object';

  /// Library-independent text, as the type is written in source.
  String get canonical => _text((type) => type.canonical, (type) => type.name);

  /// Identity of the generated codec for this type.
  ///
  /// Equal to [canonical] except that enums and payload classes carry their
  /// library, so two libraries declaring the same name get separate codecs.
  String get codecKey => _text(
    (type) => type.codecKey,
    (type) => type.kind == DwiTypeKind.value
        ? type.name
        : '${type.libraryUri}#${type.name}',
  );

  String _text(
    String Function(DwiTypeDescriptor) nested,
    String Function(DwiTypeDescriptor) named_,
  ) {
    if (isDynamic) return 'dynamic';
    if (isVoid) return 'void';
    final suffix = nullable ? '?' : '';
    if (kind == DwiTypeKind.record) {
      return '${_recordText(nested, (name) => name)}$suffix';
    }
    final renderedArguments = arguments.isEmpty
        ? ''
        : '<${arguments.map(nested).join(', ')}>';
    return '${named_(this)}$renderedArguments$suffix';
  }

  String _recordText(
    String Function(DwiTypeDescriptor) nested,
    String Function(String) fieldName,
  ) {
    final parts = <String>[
      ...positional.map(nested),
      if (named.isNotEmpty)
        '{${named.entries.map((entry) => '${nested(entry.value)} ${fieldName(entry.key)}').join(', ')}}',
    ];
    final single = positional.length == 1 && named.isEmpty;
    return '(${parts.join(', ')}${single ? ',' : ''})';
  }

  /// A copy with [nullable] forced to `false`.
  DwiTypeDescriptor get nonNullable => DwiTypeDescriptor(
    name: name,
    libraryUri: libraryUri,
    arguments: arguments,
    isDynamic: isDynamic,
    kind: kind,
    positional: positional,
    named: named,
    shape: shape,
  );

  /// Renders the type for generated source.
  ///
  /// `dart:core` types render bare; every other library is referenced through
  /// the prefix in [prefixes] so two libraries with the same type name cannot
  /// collide.
  String render(Map<String, String> prefixes) {
    if (isDynamic) return 'dynamic';
    if (isVoid) return 'void';
    if (kind == DwiTypeKind.record) {
      final text = _recordText((type) => type.render(prefixes), (name) => name);
      return '$text${nullable ? '?' : ''}';
    }
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
    this.declaringType,
    required this.importUri,
    required this.sourcePath,
    required this.line,
    required this.column,
    this.input,
    required this.output,
    required this.returnsFuture,
    this.returnsStream = false,
  });

  /// Task name delivered to `Dwi.run`.
  final String name;

  /// Declared Dart function name.
  final String functionName;

  /// Public class declaring a static method, or `null` for a top-level task.
  final String? declaringType;

  /// Dart reference within the imported task library.
  String get qualifiedName =>
      declaringType == null ? functionName : '$declaringType.$functionName';

  /// Collision-checked method name in the generated `DwiTasks` class.
  String get proxyName =>
      declaringType == null ? functionName : '$declaringType\$$functionName';

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

  /// Unwrapped result type: `T` for `T`, `Future<T>`, `FutureOr<T>` and the
  /// item type of `Stream<T>`.
  final DwiTypeDescriptor output;

  /// Whether the declared return type was `Future` or `FutureOr`.
  final bool returnsFuture;

  /// Whether the declared return type was `Stream<T>` (ADR-022).
  final bool returnsStream;

  /// Whether the task produces no value.
  bool get returnsVoid => output.isVoid;

  /// Whether the task accepts an input value.
  bool get takesInput => input != null;

  /// Canonical input type text, or `null` for a zero-argument task.
  String? get inputType => input?.canonical;

  /// Canonical result type text.
  String get outputType => output.canonical;

  /// The return type of the generated proxy method.
  String get proxyReturnType => returnsStream
      ? 'Stream<$outputType>'
      : returnsVoid
      ? 'Future<void>'
      : 'Future<$outputType>';
}
