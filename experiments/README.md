# Experiments

Time-boxed proofs. An experiment answers one question, produces one findings
document, and is not maintained as product code.

Rules:

- Every experiment has a `README.md` stating the question and how to run it.
- Every experiment has a findings document with exactly one verdict:
  `PASS`, `PASS WITH LIMITATIONS` or `FAIL`.
- Numbers in findings are measured on the machine and browsers named in the
  document. No illustrative figures presented as results.
- An experiment that graduates into the product moves to `packages/` and its
  findings are linked from `docs/architecture.md`.

## Index

| Experiment | Question | Verdict |
| --- | --- | --- |
| `dart_worker_poc/` (M001) | Can compiled Dart run CPU work in a browser worker while Flutter keeps rendering? | Pending |
