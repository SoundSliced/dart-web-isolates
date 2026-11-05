# Native handle benchmark

Compares one dedicated `DwiWorker` handle with the pooled `Dwi.run` path on the
VM, including a workload that benefits from retained isolate-local state.

```bash
cd benchmarks/native_handle
dart pub get
dart run bin/benchmark.dart
```

The command prints one JSON object. Run it three times; `docs/benchmarks.md`
records the medians, machine and commit. Timings are microsecond medians over
100 dispatches (calls), 10 spawns, 10 closes and 5 restarts. `rss` is the
process RSS in bytes, so the per-handle number is approximate and includes the
isolate group shared with the host.
