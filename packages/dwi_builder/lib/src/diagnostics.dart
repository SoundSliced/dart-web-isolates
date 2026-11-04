/// Severity of a build-time DWI diagnostic.
enum DwiDiagnosticSeverity {
  /// The build must not continue.
  error,

  /// The build can continue, but the task may fail at runtime.
  warning,

  /// Informational output.
  info,
}

/// A build-time diagnostic with a stable code, location and optional hint.
class DwiDiagnostic {
  const DwiDiagnostic({
    required this.code,
    required this.severity,
    required this.message,
    required this.file,
    this.line = 1,
    this.column = 1,
    this.hint,
  });

  /// Stable diagnostic code, for example `DWI001`.
  final String code;

  /// Whether this diagnostic stops generation.
  final DwiDiagnosticSeverity severity;

  /// Human-readable description.
  final String message;

  /// Path of the file that caused the diagnostic.
  final String file;

  /// One-based line number.
  final int line;

  /// One-based column number.
  final int column;

  /// Optional remediation hint.
  final String? hint;

  /// Renders the diagnostic in the compiler-like form used by the CLI.
  String format() {
    final buffer = StringBuffer()
      ..writeln('$code: $message')
      ..write('$file:$line:$column');
    final hint = this.hint;
    if (hint != null && hint.isNotEmpty) {
      buffer
        ..writeln()
        ..write(hint);
    }
    return buffer.toString();
  }

  @override
  String toString() => format();
}

/// Thrown when discovery or compilation cannot produce a worker.
class DwiBuildException implements Exception {
  DwiBuildException(this.summary, [this.diagnostics = const <DwiDiagnostic>[]]);

  /// One-line summary of the failure.
  final String summary;

  /// Diagnostics collected before the failure.
  final List<DwiDiagnostic> diagnostics;

  @override
  String toString() {
    final buffer = StringBuffer(summary);
    for (final diagnostic in diagnostics) {
      buffer
        ..writeln()
        ..write(diagnostic.format());
    }
    return buffer.toString();
  }
}
