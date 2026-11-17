# Changelog

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
