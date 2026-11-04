import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'descriptor.dart';
import 'diagnostics.dart';

/// The result of scanning a project for `@DwiTask` declarations.
class DwiDiscoveryResult {
  DwiDiscoveryResult({
    required this.packageName,
    required this.projectRoot,
    required this.tasks,
    required this.diagnostics,
    required this.dependencyFiles,
  });

  /// Package name read from `pubspec.yaml`.
  final String packageName;

  /// Absolute, normalised project root.
  final String projectRoot;

  /// Discovered task descriptors, in source order.
  final List<DwiTaskDescriptor> tasks;

  /// Diagnostics collected during discovery.
  final List<DwiDiagnostic> diagnostics;

  /// Absolute source paths of every library reachable from a task library.
  final Set<String> dependencyFiles;

  /// Whether any diagnostic prevents generation.
  bool get hasErrors => diagnostics.any(
    (diagnostic) => diagnostic.severity == DwiDiagnosticSeverity.error,
  );

  /// Tasks sorted by task name, giving deterministic generated output.
  List<DwiTaskDescriptor> get sortedTasks {
    final sorted = List<DwiTaskDescriptor>.of(tasks);
    sorted.sort((a, b) {
      final byName = a.name.compareTo(b.name);
      if (byName != 0) return byName;
      return a.sourcePath.compareTo(b.sourcePath);
    });
    return sorted;
  }
}

/// Discovers `@DwiTask`-annotated top-level functions in [config]'s project.
///
/// Discovery uses the analyzer's resolved AST; it never parses source text with
/// regular expressions. Errors are returned as diagnostics rather than thrown,
/// so the CLI can print every problem in one run.
Future<DwiDiscoveryResult> discoverTasks(DwiBuildConfig config) async {
  final cfg = config.validated();
  final root = cfg.absoluteProjectRoot;
  final packageName = await _readPackageName(root);
  final diagnostics = <DwiDiagnostic>[];
  final files = _collectDartFiles(cfg, diagnostics);

  final tasks = <DwiTaskDescriptor>[];
  final dependencyFiles = <String>{};
  final visitedLibraries = <String>{};

  if (files.isEmpty) {
    diagnostics.add(
      DwiDiagnostic(
        code: 'DWI005',
        severity: DwiDiagnosticSeverity.warning,
        message: 'No Dart files found under ${cfg.includePaths.join(', ')}.',
        file: _displayPath(root, root),
        hint: 'Check --include or add a @DwiTask function.',
      ),
    );
  }

  if (files.isNotEmpty) {
    final includedRoots = <String>{};
    for (final include in cfg.absoluteIncludePaths) {
      final type = FileSystemEntity.typeSync(include);
      if (type == FileSystemEntityType.directory) {
        includedRoots.add(include);
      } else if (type == FileSystemEntityType.file) {
        includedRoots.add(p.dirname(include));
      }
    }

    final collection = AnalysisContextCollection(
      includedPaths: includedRoots.toList(growable: false),
      excludedPaths: cfg.absoluteExcludePaths,
    );

    try {
      for (final file in files) {
        await _scanFile(
          file: file,
          config: cfg,
          root: root,
          packageName: packageName,
          collection: collection,
          tasks: tasks,
          diagnostics: diagnostics,
          dependencyFiles: dependencyFiles,
          visitedLibraries: visitedLibraries,
        );
      }
    } finally {
      await collection.dispose();
    }
  }

  _checkDuplicateNames(tasks, root, diagnostics);
  if (tasks.isEmpty &&
      !diagnostics.any(
        (diagnostic) => diagnostic.severity == DwiDiagnosticSeverity.error,
      )) {
    diagnostics.add(
      DwiDiagnostic(
        code: 'DWI005',
        severity: DwiDiagnosticSeverity.warning,
        message:
            'No @DwiTask functions found under '
            '${cfg.includePaths.join(', ')}.',
        file: _displayPath(root, root),
        hint: 'Annotate a top-level function with @DwiTask().',
      ),
    );
  }

  return DwiDiscoveryResult(
    packageName: packageName,
    projectRoot: root,
    tasks: tasks,
    diagnostics: diagnostics,
    dependencyFiles: dependencyFiles,
  );
}

Future<void> _scanFile({
  required String file,
  required DwiBuildConfig config,
  required String root,
  required String packageName,
  required AnalysisContextCollection collection,
  required List<DwiTaskDescriptor> tasks,
  required List<DwiDiagnostic> diagnostics,
  required Set<String> dependencyFiles,
  required Set<String> visitedLibraries,
}) async {
  final display = _displayPath(file, root);
  ResolvedUnitResult result;
  try {
    final context = collection.contextFor(file);
    final resolved = await context.currentSession.getResolvedUnit(file);
    if (resolved is! ResolvedUnitResult) {
      diagnostics.add(
        DwiDiagnostic(
          code: 'DWI005',
          severity: DwiDiagnosticSeverity.error,
          message: 'Could not resolve $display.',
          file: display,
        ),
      );
      return;
    }
    result = resolved;
  } catch (error) {
    diagnostics.add(
      DwiDiagnostic(
        code: 'DWI005',
        severity: DwiDiagnosticSeverity.error,
        message: 'Could not analyze $display: $error',
        file: display,
      ),
    );
    return;
  }

  final errors = result.diagnostics
      .where((diagnostic) => diagnostic.severity == Severity.error)
      .toList(growable: false);

  final library = result.libraryElement;
  var foundTask = false;

  for (final declaration in result.unit.declarations) {
    if (declaration is FunctionDeclaration &&
        _hasDwiTask(declaration.metadata)) {
      foundTask = true;
      final descriptor = _readFunction(
        declaration: declaration,
        library: library,
        file: file,
        display: display,
        root: root,
        packageName: packageName,
        config: config,
        lineInfo: result.lineInfo,
        diagnostics: diagnostics,
      );
      if (descriptor != null) tasks.add(descriptor);
    } else if (declaration is FunctionDeclaration) {
      // No task marker: nothing to do.
    } else if (declaration is ClassDeclaration) {
      final body = declaration.body;
      if (body is BlockClassBody) {
        _scanMembers(
          body.members,
          lineInfo: result.lineInfo,
          display: display,
          diagnostics: diagnostics,
        );
      }
    } else if (declaration is MixinDeclaration) {
      _scanMembers(
        declaration.body.members,
        lineInfo: result.lineInfo,
        display: display,
        diagnostics: diagnostics,
      );
    } else if (declaration is TopLevelVariableDeclaration &&
        _hasDwiTask(declaration.metadata)) {
      diagnostics.add(
        DwiDiagnostic(
          code: 'DWI003',
          severity: DwiDiagnosticSeverity.error,
          message:
              '@DwiTask must annotate a top-level function, not a variable.',
          file: display,
          line: _lineOf(result, declaration.offset),
          column: _columnOf(result, declaration.offset),
        ),
      );
    }
  }

  if (errors.isNotEmpty) {
    // The analyzer also reports unresolved imports in ordinary application
    // code (for example a file that imports the not-yet-generated proxy file).
    // Those files are outside the worker's task closure, so they must not block
    // generation. Errors in a file that declares a task are fatal.
    if (foundTask) {
      for (final error in errors) {
        final location = result.lineInfo.getLocation(error.offset);
        diagnostics.add(
          DwiDiagnostic(
            code: 'DWI005',
            severity: DwiDiagnosticSeverity.error,
            message: error.message,
            file: display,
            line: location.lineNumber,
            column: location.columnNumber,
          ),
        );
      }
    }
  }

  if (foundTask) {
    _collectDependencies(
      library,
      display: display,
      root: root,
      dependencyFiles: dependencyFiles,
      visitedLibraries: visitedLibraries,
      diagnostics: diagnostics,
    );
  }
}

void _scanMembers(
  List<ClassMember> members, {
  required LineInfo lineInfo,
  required String display,
  required List<DwiDiagnostic> diagnostics,
}) {
  for (final member in members) {
    if (member is MethodDeclaration && _hasDwiTask(member.metadata)) {
      diagnostics.add(
        DwiDiagnostic(
          code: 'DWI003',
          severity: DwiDiagnosticSeverity.error,
          message: '@DwiTask must annotate a top-level function, not a method.',
          file: display,
          line: lineInfo.getLocation(member.name.offset).lineNumber,
          column: lineInfo.getLocation(member.name.offset).columnNumber,
          hint: 'Move the function to the top level of a library.',
        ),
      );
    }
  }
}

DwiTaskDescriptor? _readFunction({
  required FunctionDeclaration declaration,
  required LibraryElement library,
  required String file,
  required String display,
  required String root,
  required String packageName,
  required DwiBuildConfig config,
  required LineInfo lineInfo,
  required List<DwiDiagnostic> diagnostics,
}) {
  final functionName = declaration.name.lexeme;
  final location = lineInfo.getLocation(declaration.name.offset);
  final line = location.lineNumber;
  final column = location.columnNumber;

  void error(String code, String message, {String? hint}) {
    diagnostics.add(
      DwiDiagnostic(
        code: code,
        severity: DwiDiagnosticSeverity.error,
        message: message,
        file: display,
        line: line,
        column: column,
        hint: hint,
      ),
    );
  }

  if (functionName == 'main') {
    error('DWI003', '@DwiTask cannot annotate `main`.');
    return null;
  }
  if (functionName.startsWith('_')) {
    error(
      'DWI003',
      '@DwiTask function `$functionName` is private.',
      hint: 'Generated proxies live in another library; make the task public.',
    );
    return null;
  }
  if (declaration.propertyKeyword != null) {
    error('DWI003', '@DwiTask cannot annotate a getter or setter.');
    return null;
  }
  if (declaration.functionExpression.typeParameters != null) {
    error(
      'DWI003',
      '@DwiTask function `$functionName` is generic.',
      hint:
          'Use a concrete function; a worker task has one concrete signature.',
    );
    return null;
  }

  final parameters =
      declaration.functionExpression.parameters?.parameters ??
      const <FormalParameter>[];
  if (parameters.length > 1) {
    error(
      'DWI003',
      '@DwiTask function `$functionName` has ${parameters.length} parameters.',
      hint: 'A task accepts at most one required positional input.',
    );
    return null;
  }
  if (parameters.length == 1) {
    final parameter = parameters.single;
    if (parameter.isNamed) {
      error(
        'DWI003',
        '@DwiTask function `$functionName` uses a named parameter.',
        hint: 'Use one required positional parameter instead.',
      );
      return null;
    }
    if (parameter.isOptional) {
      error(
        'DWI003',
        '@DwiTask function `$functionName` has an optional parameter.',
        hint: 'Use one required positional parameter instead.',
      );
      return null;
    }
  }

  final overrideName = _readTaskName(
    declaration,
    display,
    line,
    column,
    diagnostics,
  );
  if (overrideName == _invalidTaskName) return null;
  final taskName = overrideName ?? functionName;
  if (taskName.trim().isEmpty || taskName.contains(RegExp(r'\s'))) {
    error(
      'DWI004',
      'Task name "$taskName" must be non-empty and contain no whitespace.',
    );
    return null;
  }

  final element = declaration.declaredFragment?.element;
  if (element == null) {
    error(
      'DWI005',
      'Could not resolve the signature of `$functionName`.',
      hint: 'Make sure the file and its imports resolve without errors.',
    );
    return null;
  }
  final parameterElement = element.formalParameters.isNotEmpty
      ? element.formalParameters.first
      : null;
  final input = parameterElement == null
      ? null
      : _describeType(parameterElement.type);
  final returnType = _unwrapReturnType(element.returnType);
  final output = _describeType(returnType);
  final returnsFuture =
      element.returnType.isDartAsyncFuture ||
      element.returnType.isDartAsyncFutureOr;

  if (parameterElement != null) {
    final issues = <_TypeIssue>[];
    _collectTypeIssues(
      parameterElement.type,
      isReturn: false,
      label: 'input',
      issues: issues,
    );
    for (final issue in issues) {
      error(
        'DWI001',
        'Task `$taskName` input cannot cross the worker '
            'boundary: ${issue.message}',
        hint: issue.hint,
      );
    }
  }

  final issues = <_TypeIssue>[];
  _collectTypeIssues(
    returnType,
    isReturn: true,
    label: 'result',
    issues: issues,
  );
  for (final issue in issues) {
    error(
      'DWI001',
      'Task `$taskName` result cannot cross the worker '
          'boundary: ${issue.message}',
      hint: issue.hint,
    );
  }

  final importUri = _importUri(
    library: library,
    file: file,
    root: root,
    packageName: packageName,
    config: config,
  );
  if (importUri == null) {
    error(
      'DWI010',
      'Task `$taskName` is declared in a library that cannot be imported by '
          'the generated worker.',
      hint: 'Move the task under lib/ of the project package.',
    );
    return null;
  }

  return DwiTaskDescriptor(
    name: taskName,
    functionName: functionName,
    importUri: importUri,
    sourcePath: file,
    line: line,
    column: column,
    input: input,
    output: output,
    returnsFuture: returnsFuture,
  );
}

/// Captures a resolved type as a library-qualified descriptor.
///
/// Typedefs are transparent: the analyzer keeps the underlying type's element
/// and type arguments when an alias is present, so a typedef resolves to the
/// shape the generator can decode.
DwiTypeDescriptor _describeType(DartType type) {
  if (type is DynamicType) return DwiTypeDescriptor.dynamicType;
  if (type is VoidType) return const DwiTypeDescriptor(name: 'void');
  if (type is InterfaceType) {
    return DwiTypeDescriptor(
      name: type.element.name ?? 'Object',
      libraryUri: type.element.library.uri.toString(),
      nullable: type.nullabilitySuffix == NullabilitySuffix.question,
      arguments: type.typeArguments
          .map(_describeType)
          .toList(growable: false),
    );
  }
  return DwiTypeDescriptor.dynamicType;
}

const _invalidTaskName = '\u0000';

String? _readTaskName(
  FunctionDeclaration declaration,
  String display,
  int line,
  int column,
  List<DwiDiagnostic> diagnostics,
) {
  for (final annotation in declaration.metadata) {
    if (!_isDwiTaskAnnotation(annotation)) continue;
    final arguments = annotation.arguments?.arguments ?? const [];
    String? name;
    for (final argument in arguments) {
      if (argument is NamedExpression &&
          argument.name.label.name == 'name' &&
          argument.expression is SimpleStringLiteral) {
        name = (argument.expression as SimpleStringLiteral).value;
        continue;
      }
      diagnostics.add(
        DwiDiagnostic(
          code: 'DWI009',
          severity: DwiDiagnosticSeverity.error,
          message: '@DwiTask only accepts a constant `name:` string.',
          file: display,
          line: line,
          column: column,
        ),
      );
      return _invalidTaskName;
    }
    return name;
  }
  return null;
}

bool _hasDwiTask(NodeList<Annotation> metadata) =>
    metadata.any(_isDwiTaskAnnotation);

/// Whether [annotation] resolves to `package:dwi_annotations`' `DwiTask`.
///
/// Matching the simple name alone would treat an unrelated annotation called
/// `DwiTask` from another package as a task. When the analyzer could not
/// resolve the annotation, the syntactic name is the only available signal.
bool _isDwiTaskAnnotation(Annotation annotation) {
  final element = annotation.element;
  if (element == null) {
    final name = annotation.name.toSource();
    return name.split('.').last == 'DwiTask';
  }
  final enclosing = element.enclosingElement;
  if (enclosing is! InterfaceElement) return false;
  return enclosing.name == 'DwiTask' &&
      enclosing.library.uri.toString() ==
          'package:dwi_annotations/dwi_annotations.dart';
}

DartType _unwrapReturnType(DartType type) {
  if (type.isDartAsyncFuture || type.isDartAsyncFutureOr) {
    if (type is InterfaceType && type.typeArguments.isNotEmpty) {
      return type.typeArguments.first;
    }
    return type;
  }
  return type;
}

class _TypeIssue {
  const _TypeIssue(this.message, {this.hint});

  final String message;
  final String? hint;
}

const Set<String> _supportedTypedData = <String>{
  'ByteBuffer',
  'ByteData',
  'Int8List',
  'Uint8List',
  'Uint8ClampedList',
  'Int16List',
  'Uint16List',
  'Int32List',
  'Uint32List',
  'Int64List',
  'Uint64List',
  'Float32List',
  'Float64List',
};

void _collectTypeIssues(
  DartType type, {
  required bool isReturn,
  required String label,
  required List<_TypeIssue> issues,
}) {
  if (type is DynamicType || type.isDartCoreObject || type.isDartCoreNull) {
    return;
  }
  if (type is VoidType) {
    if (!isReturn) {
      issues.add(
        const _TypeIssue('`void` is not a value that can be sent to a worker.'),
      );
    }
    return;
  }
  if (type is NeverType) {
    issues.add(const _TypeIssue('`Never` cannot be transferred.'));
    return;
  }
  if (type is FunctionType || type.isDartCoreFunction) {
    issues.add(
      const _TypeIssue(
        'function values and closures cannot be structured-cloned.',
        hint: 'Move transferable data into the task instead.',
      ),
    );
    return;
  }
  if (type.isDartAsyncFuture || type.isDartAsyncFutureOr) {
    issues.add(
      const _TypeIssue(
        'a Future is not a transferable value.',
        hint:
            'Return the value from an async task; DWI awaits it in the worker.',
      ),
    );
    return;
  }
  if (type.isDartAsyncStream) {
    issues.add(
      const _TypeIssue(
        'a Stream cannot be structured-cloned.',
        hint:
            'Use a single transferred value; stream ports are a later feature.',
      ),
    );
    return;
  }
  if (type is RecordType || type.isDartCoreRecord) {
    issues.add(
      const _TypeIssue(
        'record types are not supported by DWI serialization yet.',
        hint: 'Use a List or Map payload.',
      ),
    );
    return;
  }
  if (type is TypeParameterType) {
    issues.add(
      const _TypeIssue(
        'generic type parameters are not concrete worker types.',
      ),
    );
    return;
  }
  if (type.isDartCoreInt ||
      type.isDartCoreDouble ||
      type.isDartCoreNum ||
      type.isDartCoreString ||
      type.isDartCoreBool) {
    return;
  }
  if (type.isDartCoreList || type.isDartCoreSet) {
    final arguments = (type as InterfaceType).typeArguments;
    if (arguments.length == 1) {
      _collectTypeIssues(
        arguments.first,
        isReturn: isReturn,
        label: label,
        issues: issues,
      );
    }
    return;
  }
  if (type.isDartCoreMap) {
    final arguments = (type as InterfaceType).typeArguments;
    if (arguments.length == 2) {
      final key = arguments[0];
      if (!(key is DynamicType ||
          key.isDartCoreObject ||
          key.isDartCoreString)) {
        issues.add(
          _TypeIssue(
            'map keys must be String; `${key.getDisplayString()}` cannot be '
            'preserved across the worker boundary.',
            hint: 'Use Map<String, V> so keys survive structured cloning.',
          ),
        );
      }
      _collectTypeIssues(
        arguments[1],
        isReturn: isReturn,
        label: label,
        issues: issues,
      );
    }
    return;
  }
  if (type.isDartCoreIterable) {
    issues.add(
      const _TypeIssue(
        'Iterable is not necessarily structured-cloneable.',
        hint: 'Use List or Set.',
      ),
    );
    return;
  }
  if (type.isDartCoreEnum) {
    issues.add(
      const _TypeIssue(
        'enum values are objects and are not structured-cloned by DWI.',
        hint: 'Send the enum index or name as an int/String.',
      ),
    );
    return;
  }
  if (type is! InterfaceType) {
    return;
  }

  final element = type.element;
  final name = element.name ?? 'value';
  final library = element.library.uri.toString();

  if (library.startsWith('dart:html') ||
      library == 'dart:ui' ||
      library.startsWith('package:flutter/')) {
    issues.add(
      _TypeIssue(
        '`$name` is a UI/DOM type and cannot cross the worker boundary.',
        hint:
            'Move transferable data into the task instead of DOM nodes or '
            'Flutter widgets.',
      ),
    );
    return;
  }
  if (library.startsWith('package:web/') &&
      const <String>{
        'Element',
        'HTMLElement',
        'Node',
        'Document',
        'Window',
        'Worker',
        'Event',
        'Blob',
      }.contains(name)) {
    issues.add(
      _TypeIssue(
        '`$name` is a browser object and cannot cross the worker boundary.',
        hint: 'Copy the data you need into a List/Map before calling the task.',
      ),
    );
    return;
  }
  if (library == 'dart:isolate') {
    issues.add(
      _TypeIssue(
        '`$name` is an isolate capability and cannot cross a web worker '
        'boundary.',
      ),
    );
    return;
  }
  if (library == 'dart:ffi') {
    issues.add(_TypeIssue('`$name` is a native/FFI value.'));
    return;
  }
  if (library == 'dart:js_interop') {
    issues.add(_TypeIssue('`$name` is a JS interop value.'));
    return;
  }
  if (library == 'dart:typed_data') {
    if (name.endsWith('List') || name == 'ByteBuffer' || name == 'ByteData') {
      if (_supportedTypedData.contains(name)) return;
      issues.add(
        _TypeIssue(
          '`$name` is not a supported transferable typed-data type.',
          hint: 'Use Uint8List, another typed list, ByteData or ByteBuffer.',
        ),
      );
      return;
    }
    issues.add(
      _TypeIssue(
        '`$name` is not a known transferable typed-data type.',
      ),
    );
    return;
  }
  if (library == 'dart:async') {
    issues.add(
      _TypeIssue(
        '`$name` is not a known structured-cloneable value.',
      ),
    );
    return;
  }
  if (name == 'DateTime') {
    issues.add(
      const _TypeIssue(
        'DateTime is not converted by DWI serialization yet.',
        hint: 'Send millisecondsSinceEpoch as an int.',
      ),
    );
    return;
  }

  issues.add(
    _TypeIssue(
      '`$name` is not a known structured-cloneable type. DWI does not generate '
      'codecs; use primitives, untyped List/Map/Set or typed data.',
    ),
  );
}

String? _importUri({
  required LibraryElement library,
  required String file,
  required String root,
  required String packageName,
  required DwiBuildConfig config,
}) {
  final uri = library.uri;
  if (uri.scheme == 'package') return uri.toString();
  if (uri.scheme != 'file') return null;

  final libDirectory = p.join(root, 'lib');
  if (p.isWithin(libDirectory, file)) {
    final relative = p.relative(file, from: libDirectory);
    return 'package:$packageName/${p.posix.joinAll(p.split(relative))}';
  }

  final workerDirectory = p.dirname(config.absoluteWorkerSource);
  final relative = p.relative(file, from: workerDirectory);
  return p.posix.joinAll(p.split(relative));
}

void _collectDependencies(
  LibraryElement library, {
  required String display,
  required String root,
  required Set<String> dependencyFiles,
  required Set<String> visitedLibraries,
  required List<DwiDiagnostic> diagnostics,
}) {
  final pending = <LibraryElement>[library];
  final reported = <String>{};
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    final uri = current.uri.toString();
    if (!visitedLibraries.add(uri)) continue;

    // SDK libraries are trusted to choose their own internals. Following them
    // would report imports that the web compilers never select (for example
    // conditional `dart:isolate` branches inside package:dwi itself).
    if (uri.startsWith('dart:')) continue;

    final currentIsSafe = _isSafePackage(uri);
    for (final fragment in current.fragments) {
      final source = fragment.source;
      if (!source.uri.toString().startsWith('dart:')) {
        dependencyFiles.add(p.normalize(source.fullName));
      }
      for (final imported in fragment.importedLibraries) {
        final importedUri = imported.uri.toString();
        if (_forbiddenLibrary(importedUri) != null) {
          if (!currentIsSafe && reported.add(importedUri)) {
            diagnostics.add(
              DwiDiagnostic(
                code: 'DWI002',
                severity: DwiDiagnosticSeverity.error,
                message:
                    'Task library imports `$importedUri`, which is not '
                    'available in a web worker.',
                file: display,
                hint:
                    'Move the task and its helpers into a pure-Dart library '
                    'that does not import Flutter, dart:ui, dart:io, dart:html '
                    'or dart:isolate.',
              ),
            );
          }
          continue;
        }
        pending.add(imported);
      }
      for (final export in fragment.libraryExports) {
        final exported = export.exportedLibrary;
        if (exported == null) continue;
        final exportedUri = exported.uri.toString();
        if (_forbiddenLibrary(exportedUri) != null) {
          if (!currentIsSafe && reported.add(exportedUri)) {
            diagnostics.add(
              DwiDiagnostic(
                code: 'DWI002',
                severity: DwiDiagnosticSeverity.error,
                message:
                    'Task library exports `$exportedUri`, which is not '
                    'available in a web worker.',
                file: display,
                hint:
                    'Keep Flutter, dart:ui, dart:io, dart:html and '
                    'dart:isolate out of the task library closure.',
              ),
            );
          }
          continue;
        }
        pending.add(exported);
      }
    }
  }
}

bool _isSafePackage(String uri) =>
    uri.startsWith('package:dwi/') ||
    uri.startsWith('package:dwi_annotations/') ||
    uri.startsWith('package:dwi_core/') ||
    uri.startsWith('package:dwi_protocol/') ||
    uri.startsWith('package:dwi_web/');

String? _forbiddenLibrary(String uri) {
  if (uri == 'dart:io' ||
      uri == 'dart:html' ||
      uri == 'dart:ui' ||
      uri == 'dart:ffi' ||
      uri == 'dart:isolate') {
    return uri;
  }
  if (uri.startsWith('package:flutter/')) return uri;
  return null;
}

Future<String> _readPackageName(String root) async {
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!await pubspec.exists()) {
    throw DwiBuildException(
      'No pubspec.yaml found in $root; run dwi from the application package.',
    );
  }
  final document = loadYaml(await pubspec.readAsString());
  if (document is! YamlMap || document['name'] is! String) {
    throw DwiBuildException('${pubspec.path} has no package name.');
  }
  return document['name'] as String;
}

List<String> _collectDartFiles(
  DwiBuildConfig config,
  List<DwiDiagnostic> diagnostics,
) {
  final root = config.absoluteProjectRoot;
  final excluded = config.absoluteExcludePaths;
  final files = <String>{};

  for (final include in config.absoluteIncludePaths) {
    final type = FileSystemEntity.typeSync(include);
    if (type == FileSystemEntityType.file) {
      if (include.endsWith('.dart') &&
          !_isExcluded(include, excluded, config)) {
        files.add(p.normalize(include));
      }
      continue;
    }
    if (type != FileSystemEntityType.directory) {
      diagnostics.add(
        DwiDiagnostic(
          code: 'DWI005',
          severity: DwiDiagnosticSeverity.error,
          message: 'Include path does not exist: $include',
          file: _displayPath(include, root),
        ),
      );
      continue;
    }
    for (final entity in Directory(
      include,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = p.normalize(entity.path);
      if (_isExcluded(path, excluded, config)) continue;
      files.add(path);
    }
  }

  final sorted = files.toList(growable: false)..sort();
  return sorted;
}

bool _isExcluded(String path, List<String> excluded, DwiBuildConfig config) {
  final segments = p.split(path);
  if (segments.contains('.dart_tool') ||
      segments.contains('.git') ||
      segments.contains('.dwi') ||
      segments.contains('build')) {
    return true;
  }
  // The repository's analyzer configuration excludes build_runner output.
  // Discovery must not try to analyze those files (the analyzer cannot provide
  // a context for them), and generated task files are not task declarations.
  if (path.endsWith('.g.dart') || path.endsWith('.freezed.dart')) {
    return true;
  }
  if (p.equals(path, config.absoluteProxies) ||
      p.equals(path, config.absoluteWorkerSource)) {
    return true;
  }
  for (final entry in excluded) {
    if (p.equals(path, entry) || p.isWithin(entry, path)) return true;
  }
  return false;
}

String _displayPath(String path, String root) {
  if (p.isWithin(root, path)) {
    return p.posix.joinAll(p.split(p.relative(path, from: root)));
  }
  return p.posix.joinAll(p.split(path));
}

int _lineOf(ResolvedUnitResult result, int offset) =>
    result.lineInfo.getLocation(offset).lineNumber;

int _columnOf(ResolvedUnitResult result, int offset) =>
    result.lineInfo.getLocation(offset).columnNumber;

void _checkDuplicateNames(
  List<DwiTaskDescriptor> tasks,
  String root,
  List<DwiDiagnostic> diagnostics,
) {
  final names = <String, DwiTaskDescriptor>{};
  final functionNames = <String, DwiTaskDescriptor>{};
  for (final task in tasks) {
    final previous = names[task.name];
    if (previous != null) {
      diagnostics.add(
        DwiDiagnostic(
          code: 'DWI004',
          severity: DwiDiagnosticSeverity.error,
          message: 'Duplicate task name "${task.name}".',
          file: _displayPath(task.sourcePath, root),
          line: task.line,
          column: task.column,
          hint:
              'Also declared at ${_displayPath(previous.sourcePath, root)}:'
              '${previous.line}. Use @DwiTask(name: ...) to disambiguate.',
        ),
      );
    } else {
      names[task.name] = task;
    }

    final previousFunction = functionNames[task.functionName];
    if (previousFunction != null) {
      diagnostics.add(
        DwiDiagnostic(
          code: 'DWI004',
          severity: DwiDiagnosticSeverity.error,
          message:
              'Two tasks use the function name "${task.functionName}", so '
              'their generated proxies would collide.',
          file: _displayPath(task.sourcePath, root),
          line: task.line,
          column: task.column,
          hint:
              'Also declared at '
              '${_displayPath(previousFunction.sourcePath, root)}:'
              '${previousFunction.line}. Rename one function or split the tasks '
              'into packages with separate proxy files.',
        ),
      );
    } else {
      functionNames[task.functionName] = task;
    }
  }
}
