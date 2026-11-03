# Fibonacci

Smallest native use of the public API: register a task, configure, run it on an
isolate.

```bash
cd examples/fibonacci
dart pub get
dart run bin/main.dart 32
```

On web the same code needs a worker entrypoint and a `workerScript`; see
`integration_tests/web_backend/` for a complete worker that speaks protocol v1.
