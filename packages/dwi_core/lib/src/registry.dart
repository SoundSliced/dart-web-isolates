import 'exceptions.dart';

/// A callable task implementation: one structured-cloneable input, one output.
typedef DwiTask = Object? Function(Object? input);

/// Name → implementation registry used by the native backend and by generated
/// worker entrypoints.
///
/// Registration is explicit; a task name is never turned into code.
class DwiTaskRegistry {
  DwiTaskRegistry();

  final Map<String, DwiTask> _tasks = <String, DwiTask>{};

  /// Registers [task] under [name]. Re-registering replaces the old task.
  void register(String name, DwiTask task) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    _tasks[name] = task;
  }

  /// Registers several tasks at once.
  void registerAll(Map<String, DwiTask> tasks) {
    tasks.forEach(register);
  }

  bool contains(String name) => _tasks.containsKey(name);

  /// Returns the task or throws [DwiUnknownTaskException].
  DwiTask lookup(String name) {
    final task = _tasks[name];
    if (task == null) {
      throw DwiUnknownTaskException('unknown task "$name"');
    }
    return task;
  }

  /// Runs a registered task synchronously in the current isolate.
  Object? invoke(String name, Object? input) => lookup(name)(input);

  Iterable<String> get names => _tasks.keys;

  void clear() => _tasks.clear();
}
