# Changelog

## 1.3.1

- Version aligned with the 1.3.1 release; no API change in this package.

## 1.3.0

- Adds `computeParallelBounded(task, inputs, {concurrency = 4})`: a bounded batch
  that keeps results in input order and stops admitting calls on the first failure
  (ADR-034). `computeParallel` is unchanged.

## 1.2.0

- Version aligned with the 1.2.0 release; no API change in this package.

## 1.1.1

- Documentation: the pub.dev README shows the basic and advanced examples inline, so the features can be read without running the example files.

## 1.1.0

- Version 1.1.0 with the other packages. No behaviour change in this package.

## 1.0.0

- Version 1.0.0: the stable API of this package; see `docs/release-notes-1.0.0.md`. No behaviour change in this package at 1.0.0.

## 0.11.0

- Version bump to match 0.11.0. No behaviour change in this package.

## 0.10.0

- First release. `computeParallel(task, inputs)` runs one DWI task per input on
  the shared pool and returns the results in input order. The first error fails
  the call; calls already dispatched keep running (ADR-025).
