# API Proposal (v0.2 target)

Status: proposed. Public API changes require this document plus an ADR
(AGENTS.md rule 2). Implemented surface must not exceed what is written here.

## Level 1 — named task (the only supported release API)

```dart
import 'package:dwi/dwi.dart';

final count = await Dwi.run<int>(
  'primes',
  {'limit': 5000000, 'rounds': 40},
);
```

Rules:

- `task` is a name registered in the worker (and, on native, in the isolate
  registry). Unknown names throw `DwiUnknownTaskException` **without** starting
  a worker.
- `input` must be a structured-cloneable value (see `serialization.md`).
  Unsupported values throw `DwiSerializationException` on the caller's side.
- The return value is the decoded result; type is checked by the caller. A
  mismatched `R` throws `DwiResultTypeException`.
- No closure overload exists. There is no `Dwi.run(fn)` in v0.2.

## Configuration

```dart
Dwi.configure(const DwiConfig(
  workerScript: 'dwi/worker.dart.js',
  maxWorkers: 4,
  taskTimeout: Duration(seconds: 30),
  startupTimeout: Duration(seconds: 10),
));
```

- `workerScript` is required on web; ignored on native.
- Defaults: `maxWorkers = min(hardwareConcurrency - 1, 4)`, at least 1.
- Timeouts are mandatory: a worker that never becomes ready must fail
  (`DwiStartupException`), a task that never returns must fail
  (`DwiTimeoutException`), and the worker must be terminated.

## Capability query

```dart
final caps = await Dwi.capabilities();
// { backend: 'isolate' | 'worker' | 'unsupported',
//   transferables: bool, workerCount: int, protocolVersion: 1 }
```

`backend: 'unsupported'` is reported when no worker script is configured on web;
calls then throw `DwiUnsupportedException`. There is no transparent fallback to
the main thread.

## Errors

```dart
sealed class DwiException implements Exception {}

class DwiStartupException extends DwiException {}
class DwiTimeoutException extends DwiException {}
class DwiUnknownTaskException extends DwiException {}
class DwiSerializationException extends DwiException {}
class DwiResultTypeException extends DwiException {}
class DwiUnsupportedException extends DwiException {}
class DwiRemoteException extends DwiException {
  final String remoteType;      // best-effort Dart type name
  final String message;
  final String remoteStackTrace;
  final String? workerId;
  final int? taskId;
}
```

`DwiRemoteException` is thrown for failures inside the worker. Its
`remoteStackTrace` is whatever the worker runtime captured; it is never presented
as a local stack trace.

## Lifecycle (later levels, not shipped yet)

```dart
final worker = await DwiWorker.spawn('dwi/worker.dart.js');
await worker.run('parseJson', payload);
await worker.close();

final pool = DwiPool(workers: 4);
final task = pool.submit('imageTransform', bytes);
task.cancel();  // cooperative first, terminate only on explicit escalation
```

These are **proposals**; they are not implemented in v0.2 and must not be
documented as available.

## Native mapping

| DWI | Native backend |
| --- | --- |
| `Dwi.run(task, input)` | registry lookup → `Isolate.run(() => fn(input))` |
| `Dwi.capabilities()` | `backend: 'isolate'`, `transferables: true` |
| errors | local exceptions; `DwiRemoteException` only if the isolate sends one |
| timeout | `Future.timeout` + isolate cannot be killed mid-run (documented) |

Native task registration is explicit:

```dart
Dwi.registerTask('primes', (Object? input) {
  final args = input! as Map<String, Object?>;
  return countPrimes(args['limit']! as int, args['rounds']! as int);
});
```

## Web mapping

| DWI | Web backend |
| --- | --- |
| `Dwi.run(task, input)` | pool acquire → protocol `request` → `result` |
| `Dwi.capabilities()` | worker count, transferables from feature detection |
| errors | `error` envelope → `DwiRemoteException` |
| timeout | terminate worker, `DwiTimeoutException` |

The web worker entrypoint is user-provided in v0.2 (generated in v0.3).

## Non-goals for v0.2

- Closures or function values.
- `SendPort`/`ReceivePort` emulation.
- Shared memory.
- Wasm backend.
- Automatic worker discovery or compilation.
- Flutter `compute()` replacement.

Each of these requires an ADR and, for the closure case, a compiler feature.

## Documentation requirement

Every exported declaration is dartdoc'd and has a runnable example in
`examples/` (AGENTS.md rule 14).
