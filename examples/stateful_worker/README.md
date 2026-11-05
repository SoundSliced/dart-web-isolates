# Stateful worker

Shows the difference between a dedicated `DwiWorker` handle and the pooled
`Dwi.run` path. The task increments a variable that lives inside the execution
context, so a handle observes `1, 2, 3` while a new handle starts at `1` again.

```bash
cd examples/stateful_worker
dart pub get
dart run bin/main.dart
```

Expected output:

```text
first  1
second 2
third  3
other  1
fourth 4
```

## When to use a handle

Create a `DwiWorker` when several calls must share warm worker-local state or
identity: a parser cache, an index built once, incremental computation, or a
task sequence that must not interleave with other work. Use `Dwi.run` for
one-off tasks, where the pool amortises startup without keeping a context per
caller.

## What is not retained

Losing the context loses its state. `close()`, a task timeout, a crash, a
heartbeat failure, or cancelling a running call all move the handle out of
service; `restart()` or a new `spawn()` starts with fresh local state. DWI never
replays a call on the replacement and never restores lost state.

A handle runs one task at a time. A running task cannot observe cancellation, so
cancelling it terminates the dedicated context (native `Isolate.kill`, web
`Worker.terminate`) and fails the handle.

On web the same example uses the generated worker artefact
(`DwiConfig.workerScript`, default `dwi/worker.dart.js`) and needs no URL
argument. On native it runs on one persistent isolate.
