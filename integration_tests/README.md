# Integration tests

Cross-cutting tests that cannot live inside a single package: browser matrix,
compiler matrix, and end-to-end lifecycle behaviour.

Nothing has been implemented yet. This directory will hold:

- browser matrix runs (Chrome, Safari, Firefox, Edge; desktop and mobile where
  available) using `dart test -p chrome` and, where required, driven browser
  sessions;
- compiler matrix runs for dart2js and dart2wasm;
- lifecycle and race tests: worker crash, timeout, cancellation, teardown,
  message ordering, concurrent tasks.

Results are recorded in `docs/browser-matrix.md`. A platform that was not
exercised is marked "unverified", never assumed to pass.
