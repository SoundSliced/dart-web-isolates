// Experimental probe: what can the analyzer resolve for the six DWI-5
// function forms? It answers, for each `Dwi.run(...)` call site, whether the
// target is statically identifiable, what the target element is, and which
// enclosing values an inline closure captures.
//
// This is feasibility evidence, not a public API and not a code generator.
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final forms = p.normalize(
    p.absolute(args.isEmpty ? 'lib/forms.dart' : args.first),
  );
  final collection = AnalysisContextCollection(
    includedPaths: <String>[p.dirname(forms)],
  );
  try {
    final context = collection.contextFor(forms);
    final resolved = await context.currentSession.getResolvedUnit(forms);
    if (resolved is! ResolvedUnitResult) {
      stderr.writeln('could not resolve $forms');
      exit(1);
    }
    stderr.writeln('probe: ${resolved.path}');
    stderr.writeln('diagnostics: ${resolved.diagnostics.length}');
    for (final diagnostic in resolved.diagnostics) {
      stderr.writeln('  ${diagnostic.severity.name}: ${diagnostic.message}');
    }

    final visitor = _RunCallVisitor(resolved);
    resolved.unit.accept(visitor);
    visitor.report();
  } finally {
    await collection.dispose();
  }
}

class _RunCall {
  _RunCall({
    required this.line,
    required this.argumentType,
    required this.classification,
    required this.element,
    required this.staticallyIdentifiable,
    required this.captures,
    required this.notes,
  });

  final int line;
  final String argumentType;
  final String classification;
  final String element;
  final bool staticallyIdentifiable;
  final List<String> captures;
  final List<String> notes;
}

class _RunCallVisitor extends RecursiveAstVisitor<void> {
  _RunCallVisitor(this.result);

  final ResolvedUnitResult result;
  final List<_RunCall> calls = <_RunCall>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (node.methodName.name == 'run' &&
        target is SimpleIdentifier &&
        target.name == 'Dwi' &&
        node.argumentList.arguments.isNotEmpty) {
      calls.add(_classify(node));
    }
    super.visitMethodInvocation(node);
  }

  void report() {
    for (final call in calls) {
      stdout.writeln('---');
      stdout.writeln('line: ${call.line}');
      stdout.writeln('argument-node: ${call.argumentType}');
      stdout.writeln('classification: ${call.classification}');
      stdout.writeln('element: ${call.element}');
      stdout.writeln('static-target: ${call.staticallyIdentifiable}');
      stdout.writeln(
        'captures: ${call.captures.isEmpty ? '(none)' : call.captures.join(', ')}',
      );
      for (final note in call.notes) {
        stdout.writeln('note: $note');
      }
    }
    stdout.writeln('---');
    stdout.writeln('total-run-calls: ${calls.length}');
  }

  _RunCall _classify(MethodInvocation node) {
    final argument = node.argumentList.arguments.first;
    final line = result.lineInfo.getLocation(argument.offset).lineNumber;
    final argumentType = argument.runtimeType.toString();
    final notes = <String>[];

    if (argument is SimpleIdentifier) {
      final element = argument.element;
      final elementText = _describeElement(element);
      if (element is TopLevelFunctionElement) {
        return _RunCall(
          line: line,
          argumentType: argumentType,
          classification: 'static-top-level-function',
          element: elementText,
          staticallyIdentifiable: true,
          captures: const <String>[],
          notes: notes,
        );
      }
      if (element is MethodElement && element.isStatic) {
        return _RunCall(
          line: line,
          argumentType: argumentType,
          classification: 'static-method',
          element: elementText,
          staticallyIdentifiable: true,
          captures: const <String>[],
          notes: notes,
        );
      }
      if (element is LocalVariableElement ||
          element is FormalParameterElement) {
        notes.add(_candidateTargets(argument.name));
        return _RunCall(
          line: line,
          argumentType: argumentType,
          classification: 'dynamic-function-value',
          element: elementText,
          staticallyIdentifiable: false,
          captures: const <String>[],
          notes: notes,
        );
      }
      return _RunCall(
        line: line,
        argumentType: argumentType,
        classification: 'unresolved-simple-identifier',
        element: elementText,
        staticallyIdentifiable: false,
        captures: const <String>[],
        notes: notes,
      );
    }

    if (argument is PrefixedIdentifier) {
      final element = argument.element;
      final elementText = _describeElement(element);
      final receiver = argument.prefix;
      final receiverElement = receiver.element;
      if (element is MethodElement && element.isStatic) {
        return _RunCall(
          line: line,
          argumentType: argumentType,
          classification: 'static-method',
          element: elementText,
          staticallyIdentifiable: true,
          captures: const <String>[],
          notes: notes,
        );
      }
      if (element is MethodElement && !element.isStatic) {
        notes.add('receiver: ${_describeElement(receiverElement)}');
        return _RunCall(
          line: line,
          argumentType: argumentType,
          classification: 'instance-method-tearoff',
          element: elementText,
          staticallyIdentifiable: false,
          captures: const <String>[],
          notes: notes,
        );
      }
      return _RunCall(
        line: line,
        argumentType: argumentType,
        classification: 'dynamic-function-value',
        element: elementText,
        staticallyIdentifiable: false,
        captures: const <String>[],
        notes: notes,
      );
    }

    if (argument is FunctionExpression) {
      final analysis = _analyzeClosure(argument);
      final block = argument.body is BlockFunctionBody;
      return _RunCall(
        line: line,
        argumentType: argumentType,
        classification: block ? 'inline-block-body' : 'inline-closure',
        element: 'inline ${block ? 'block' : 'expression'} body',
        staticallyIdentifiable: true,
        captures: analysis.captures,
        notes: analysis.notes,
      );
    }

    return _RunCall(
      line: line,
      argumentType: argumentType,
      classification: 'other-expression',
      element: '(not a function reference or closure)',
      staticallyIdentifiable: false,
      captures: const <String>[],
      notes: notes,
    );
  }

  _ClosureAnalysis _analyzeClosure(FunctionExpression closure) {
    final captures = <String>[];
    final notes = <String>[];
    final enclosingFunction = _enclosingFunctionElement(closure);
    final functionType = closure.staticType;
    if (functionType is FunctionType) {
      notes.add(
        'signature: ${functionType.returnType.getDisplayString()} '
        '(${functionType.formalParameters.map((parameter) => '${parameter.type.getDisplayString()} ${parameter.name ?? ''}').join(', ')})',
      );
    }
    if (enclosingFunction == null) {
      notes.add('enclosing function element: unresolved');
    }

    final collector = _CaptureVisitor(
      closure: closure,
      enclosingFunction: enclosingFunction,
    );
    closure.body.accept(collector);
    captures.addAll(collector.captures);
    notes.addAll(collector.notes);
    if (captures.isEmpty) {
      notes.add('no enclosing values captured');
    } else {
      final unsupported = collector.captures
          .where((capture) => capture.contains('UNSUPPORTED'))
          .toList();
      if (unsupported.isNotEmpty) {
        notes.add('non-serializable captures present: ${unsupported.length}');
      }
    }
    return _ClosureAnalysis(captures: captures, notes: notes);
  }

  String _candidateTargets(String variableName) {
    final declarations = _allVariables(result.unit);
    final declaration = declarations[variableName];
    if (declaration == null) return 'candidate targets: unknown';
    final initializer = declaration.initializer;
    if (initializer == null) return 'candidate targets: no initializer';
    final targets = <String>[];
    initializer.accept(_FunctionReferenceCollector(targets.add));
    if (targets.isEmpty) {
      return 'candidate targets: none statically visible '
          '(initializer: ${initializer.runtimeType})';
    }
    final unique = targets.toSet().toList(growable: false);
    return 'candidates in initializer only: ${unique.join(' | ')}';
  }

  static Map<String, VariableDeclaration> _allVariables(CompilationUnit unit) {
    final map = <String, VariableDeclaration>{};
    unit.accept(_VariableCollector(map));
    return map;
  }
}

class _ClosureAnalysis {
  _ClosureAnalysis({required this.captures, required this.notes});
  final List<String> captures;
  final List<String> notes;
}

class _CaptureVisitor extends RecursiveAstVisitor<void> {
  _CaptureVisitor({required this.closure, required this.enclosingFunction});

  final FunctionExpression closure;
  final ExecutableElement? enclosingFunction;
  final List<String> captures = <String>[];
  final List<String> notes = <String>[];

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    final DartType? captureType = element is LocalVariableElement
        ? element.type
        : element is FormalParameterElement
        ? element.type
        : null;
    if (captureType != null) {
      final owner = element?.enclosingElement;
      if (identical(owner, enclosingFunction) &&
          !captures.any((capture) => capture.startsWith('${node.name}:'))) {
        captures.add(
          '${node.name}: ${captureType.getDisplayString()} '
          '(${_serializable(captureType) ? 'serializable' : 'UNSUPPORTED'})',
        );
      }
    } else if (element is FieldElement) {
      captures.add(
        '${node.name}: ${element.type.getDisplayString()} '
        '(field; ${element.isStatic ? 'static' : 'instance'}; '
        '${_serializable(element.type) ? 'serializable' : 'UNSUPPORTED'})',
      );
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    notes.add('captures `this` (instance state cannot be lifted)');
    super.visitThisExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    notes.add('invokes a function value inside the body');
    super.visitFunctionExpressionInvocation(node);
  }
}

class _FunctionReferenceCollector extends RecursiveAstVisitor<void> {
  _FunctionReferenceCollector(this.add);
  final void Function(String) add;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    if (element is TopLevelFunctionElement ||
        (element is MethodElement && element.isStatic)) {
      add(_describeElement(element));
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final element = node.element;
    if (element is TopLevelFunctionElement ||
        (element is MethodElement && element.isStatic)) {
      add(_describeElement(element));
    }
    super.visitPrefixedIdentifier(node);
  }
}

class _VariableCollector extends RecursiveAstVisitor<void> {
  _VariableCollector(this.map);
  final Map<String, VariableDeclaration> map;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    map[node.name.lexeme] = node;
    super.visitVariableDeclaration(node);
  }
}

ExecutableElement? _enclosingFunctionElement(AstNode node) {
  AstNode? current = node.parent;
  while (current != null) {
    if (current is FunctionDeclaration) {
      return current.declaredFragment?.element;
    }
    if (current is MethodDeclaration) {
      return current.declaredFragment?.element;
    }
    current = current.parent;
  }
  return null;
}

bool _serializable(DartType type) {
  if (type is InvalidType || type is DynamicType) return false;
  if (type is InterfaceType) {
    final name = type.element.name;
    if (const <String>{
      'int',
      'double',
      'num',
      'String',
      'bool',
      'Null',
      'Uint8List',
      'Int8List',
      'Uint16List',
      'Int16List',
      'Uint32List',
      'Int32List',
      'Uint64List',
      'Int64List',
      'Float32List',
      'Float64List',
      'ByteData',
      'ByteBuffer',
    }.contains(name)) {
      return true;
    }
    if (name == 'List' || name == 'Set') {
      return type.typeArguments.length == 1 &&
          _serializable(type.typeArguments.single);
    }
    if (name == 'Map') {
      return type.typeArguments.length == 2 &&
          _serializable(type.typeArguments[0]) &&
          _serializable(type.typeArguments[1]);
    }
    return false;
  }
  if (type is RecordType) {
    return type.positionalFields.every((field) => _serializable(field.type)) &&
        type.namedFields.every((field) => _serializable(field.type));
  }
  return false;
}

String _describeElement(Element? element) {
  if (element == null) return '(unresolved)';
  final library = element.library?.uri.toString() ?? '(no library)';
  if (element is TopLevelFunctionElement) {
    return 'TopLevelFunctionElement ${element.name} in $library';
  }
  if (element is MethodElement) {
    return 'MethodElement ${element.name} '
        '(static: ${element.isStatic}) in $library';
  }
  if (element is LocalVariableElement) {
    return 'LocalVariableElement ${element.name} '
        '(${element.type.getDisplayString()})';
  }
  if (element is FormalParameterElement) {
    return 'FormalParameterElement ${element.name} '
        '(${element.type.getDisplayString()})';
  }
  if (element is FieldElement) {
    return 'FieldElement ${element.name} '
        '(static: ${element.isStatic})';
  }
  if (element is PropertyAccessorElement) {
    return 'PropertyAccessorElement ${element.name} '
        '(static: ${element.isStatic})';
  }
  return '${element.runtimeType} ${element.name ?? ''}';
}
