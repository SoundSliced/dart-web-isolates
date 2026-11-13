/// Annotations for declaring Dart Web Isolates (DWI) worker tasks.
///
/// `dwi_builder` discovers [DwiTask]-annotated top-level functions and public
/// class or enum static methods and compiles
/// them into a generated worker entrypoint. No worker `main()`, registry or
/// manifest is written by hand.
library;

/// Marks a top-level function or a public class or enum static method as a
/// worker task.
///
/// The function must:
///
/// - be public and top-level, or static in a public non-generic class or
///   enum;
/// - not be generic, external, a local function, getter, setter or instance
///   method;
/// - not be a member of a mixin, extension or extension type;
/// - take no parameters, or exactly one required positional parameter;
/// - return a structured-cloneable value, `void`, or a `Future` of one.
///
/// The generated worker calls the function with the task input and returns its
/// result. The optional [name] overrides the task name, which defaults to the
/// function name (or `Class.method` / `Enum.method` for static methods).
///
/// ```dart
/// import 'package:dwi_annotations/dwi_annotations.dart';
///
/// @DwiTask()
/// int calculatePrimes(int limit) {
///   // ...
/// }
/// ```
///
/// Any other placement — a class, mixin, enum, extension, extension type or
/// typedef declaration, a constructor, field, enum constant, variable or
/// parameter — is a `DWI003` build
/// error rather than being ignored.
///
/// The annotation is only a marker. It has no runtime behaviour; discovery and
/// code generation are performed by `dwi_builder`.
class DwiTask {
  /// Creates a task marker.
  ///
  /// When [name] is omitted the function name or `Class.method` is used.
  const DwiTask({this.name});

  /// The task name exposed to `Dwi.run`, or `null` to use the default name.
  final String? name;
}

/// Marks a class whose instances may be sent to and returned from a worker
/// task (ADR-021).
///
/// `dwi_builder` generates the encoder and decoder. The class must:
///
/// - be public, concrete and non-generic, in a library under `lib/`;
/// - have a public unnamed constructor;
/// - expose, for every constructor parameter, a public instance getter or
///   field with the same name and the same type.
///
/// Only the constructor parameters cross the boundary: the worker receives a
/// new instance built from them, never the original object. State that is not
/// a constructor parameter is not transferred, and a subclass instance arrives
/// as the declared class.
///
/// ```dart
/// @DwiPayload()
/// class Range {
///   const Range(this.start, {required this.end});
///   final int start;
///   final int end;
/// }
/// ```
final class DwiPayload {
  /// Creates a payload marker.
  const DwiPayload();
}
