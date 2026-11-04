/// Annotations for declaring Dart Web Isolates (DWI) worker tasks.
///
/// `dwi_builder` discovers [DwiTask]-annotated top-level functions and compiles
/// them into a generated worker entrypoint. No worker `main()`, registry or
/// manifest is written by hand.
library;

/// Marks a top-level function as a DWI worker task.
///
/// The function must:
///
/// - be a public top-level function (not a method, local function or getter);
/// - take no parameters, or exactly one required positional parameter;
/// - return a structured-cloneable value, `void`, or a `Future` of one.
///
/// The generated worker calls the function with the task input and returns its
/// result. The optional [name] overrides the task name, which defaults to the
/// function name.
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
/// The annotation is only a marker. It has no runtime behaviour; discovery and
/// code generation are performed by `dwi_builder`.
class DwiTask {
  /// Creates a task marker.
  ///
  /// When [name] is omitted the annotated function's name is used.
  const DwiTask({this.name});

  /// The task name exposed to `Dwi.run`, or `null` to use the function name.
  final String? name;
}
