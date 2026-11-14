# Changelog

## 0.10.0

- First release. `computeParallel(task, inputs)` runs one DWI task per input on
  the shared pool and returns the results in input order. The first error fails
  the call; calls already dispatched keep running (ADR-025).
