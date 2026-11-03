# Contributing to DWI

Thank you for helping. This project is deliberately strict about evidence,
because it makes claims about compiler and browser behaviour that are easy to
get wrong.

## Before you start

1. Read [`AGENTS.md`](AGENTS.md) — the mandatory engineering rules apply to
   humans and AI agents alike.
2. Check that your idea is not already covered by an ADR in
   [`docs/architecture.md`](docs/architecture.md).
3. For anything that changes a public API, open an issue first. Public API
   changes require an ADR.

## Ground rules

- **Evidence over assertion.** A claim about `dart:isolate`, `dart2js`,
  `dart2wasm`, `package:web` or a browser must cite a repository, file, symbol
  and version, or be backed by a reproducible probe committed to the repo.
- **Scope discipline.** Change only what the issue or ADR describes. Adjacent
  refactors belong in their own pull request.
- **Tests first for concurrency.** Any change to worker lifecycle, messaging or
  serialisation needs a test that exercises the failure path, not only the happy
  path.
- **Do not present unsupported behaviour as parity.** If the web backend cannot
  match a native semantic, document the difference.

## Development setup

```bash
# Dart and Flutter are expected to be on PATH.
dart --version
flutter --version

# Packages are plain Dart/Flutter packages; each is developed independently.
cd packages/dwi && dart pub get && dart test

# The M001 experiment needs Chrome (and optionally Firefox/Safari/Edge).
cd experiments/dart_worker_poc
flutter pub get
dart run tool/build_worker.dart
```

## Checks that must pass

```bash
dart analyze                      # zero issues, no warnings ignored
dart test                         # per package
flutter test                      # Flutter packages
dart test -p chrome               # browser integration tests
```

Performance-sensitive changes also require a before/after benchmark table in the
pull request description, produced with `tooling/benchmark_runner`.

## Commit and pull-request style

- Keep commits focused and grouped by concern.
- Describe *what was measured* and *what was not*.
- Reference the ADR or issue in the description.
- Do not commit generated build output, `.research/` clones or scratch probes.

## Code of conduct

Participation is covered by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
